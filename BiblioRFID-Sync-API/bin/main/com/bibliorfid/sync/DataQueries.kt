package com.bibliorfid.sync

import kotlinx.serialization.json.Json
import java.sql.PreparedStatement
import java.sql.ResultSet
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/** Une page de résultats et le nombre total de lignes correspondantes. */
data class Page<T>(val items: List<T>, val total: Int)

/** Pagination demandée : `limit` nul = tout. */
data class Paging(val limit: Int? = null, val offset: Int = 0) {
    init {
        require(limit == null || limit in 1..MAX_LIMIT) { "limit doit être compris entre 1 et $MAX_LIMIT." }
        require(offset >= 0) { "offset doit être positif." }
    }

    companion object {
        const val MAX_LIMIT = 10_000
    }
}

/** Conditions SQL et leurs paramètres, assemblées au fil des filtres. */
private class Conditions(base: String? = null) {
    val clauses = mutableListOf<String>().apply { if (base != null) add(base) }
    val params = mutableListOf<Any?>()

    fun add(clause: String, vararg values: Any?) {
        clauses += clause
        params.addAll(values)
    }

    val sql get() = if (clauses.isEmpty()) "" else "WHERE " + clauses.joinToString(" AND ")
}

/**
 * Requêtes en lecture de l'API de données : filtres, pagination et vues
 * enrichies, pour l'exploitation par des systèmes externes. Les écritures
 * passent uniquement par la synchronisation et les rapports d'appareil.
 */
class DataQueries(private val store: SyncStore, private val json: Json) {

    // --- Livres -----------------------------------------------------------

    fun books(search: String?, status: String?, updatedSince: String?, paging: Paging): Page<SyncBook> {
        val where = Conditions("deleted=0")
        search.like()?.let { where.add(SEARCH_BOOK, *Array(7) { _ -> it }) }
        status?.let { where.add("status=?", it) }
        updatedSince?.let { where.add("updated_at>=?", it) }
        return page("books", where, "accession", paging, "*") { store.readBook(it) }
    }

    fun book(serverId: String): SyncBook? =
        page("books", Conditions("deleted=0").apply { add("server_id=?", serverId) }, "accession", Paging(1), "*") {
            store.readBook(it)
        }.items.firstOrNull()

    // --- Abonnés ----------------------------------------------------------

    fun subscribers(
        search: String?,
        active: Boolean?,
        hasCard: Boolean?,
        updatedSince: String?,
        paging: Paging,
    ): Page<SyncSubscriber> {
        val where = Conditions("deleted=0")
        search.like()?.let { where.add("(member_number LIKE ? OR name LIKE ? OR email LIKE ? OR phone LIKE ?)", it, it, it, it) }
        active?.let { where.add("active=?", if (it) 1 else 0) }
        hasCard?.let { where.add(if (it) "card_tid IS NOT NULL" else "card_tid IS NULL") }
        updatedSince?.let { where.add("updated_at>=?", it) }
        return page("subscribers", where, "name COLLATE NOCASE", paging, "*") { store.readSubscriber(it) }
    }

    fun subscriber(memberNumber: String): SyncSubscriber? = page(
        "subscribers",
        Conditions("deleted=0").apply { add("member_number=?", memberNumber.trim().uppercase()) },
        "name",
        Paging(1),
        "*",
    ) { store.readSubscriber(it) }.items.firstOrNull()

    // --- Abonnements ------------------------------------------------------

    fun subscriptions(
        memberNumber: String?,
        status: String?,
        current: Boolean?,
        updatedSince: String?,
        paging: Paging,
        serverId: String? = null,
    ): Page<SubscriptionView> {
        val now = Instant.now().toString()
        val where = Conditions("sub.deleted=0")
        serverId?.let { where.add("sub.server_id=?", it) }
        memberNumber?.let { where.add("sub.member_number=?", it.trim().uppercase()) }
        status?.let { where.add("json_extract(sub.payload,'$.status')=?", it) }
        current?.let {
            where.add(if (it) CURRENT_SUBSCRIPTION else "NOT $CURRENT_SUBSCRIPTION", now, now)
        }
        updatedSince?.let { where.add("json_extract(sub.payload,'$.updatedAt')>=?", it) }
        return page(
            "subscriptions sub LEFT JOIN subscribers s ON s.member_number=sub.member_number",
            where,
            "json_extract(sub.payload,'$.endsAt') DESC",
            paging,
            "sub.payload, s.name AS subscriber_name",
        ) { rows ->
            val value = json.decodeFromString<SyncSubscription>(rows.getString("payload"))
            SubscriptionView(
                serverId = value.serverId,
                memberNumber = value.memberNumber,
                subscriberName = rows.getString("subscriber_name"),
                startsAt = value.startsAt,
                endsAt = value.endsAt,
                status = value.status,
                current = value.status == "active" && value.startsAt <= now && value.endsAt >= now,
                createdAt = value.createdAt,
                updatedAt = value.updatedAt,
                revision = value.revision,
            )
        }
    }

    fun subscription(serverId: String): SubscriptionView? =
        subscriptions(null, null, null, null, Paging(1), serverId).items.firstOrNull()

    // --- Emprunts et retours ----------------------------------------------

    /**
     * Emprunts. `status` : `active` (en cours), `overdue` (en cours et en
     * retard) ou `returned` ; `from`/`to` bornent la date d'emprunt.
     */
    fun loans(
        status: String?,
        memberNumber: String?,
        bookServerId: String?,
        from: String?,
        to: String?,
        updatedSince: String?,
        paging: Paging,
    ): Page<LoanView> {
        val where = Conditions("l.deleted=0")
        when (status) {
            null -> Unit
            "active" -> where.add("l.returned_at IS NULL")
            "overdue" -> where.add("l.returned_at IS NULL AND json_extract(l.payload,'$.dueAt')<?", Instant.now().toString())
            "returned" -> where.add("l.returned_at IS NOT NULL")
            else -> throw IllegalArgumentException("status doit valoir active, overdue ou returned.")
        }
        filterLoans(where, memberNumber, bookServerId)
        from?.let { where.add("l.borrowed_at>=?", it) }
        to?.let { where.add("l.borrowed_at<=?", it) }
        updatedSince?.let { where.add("json_extract(l.payload,'$.updatedAt')>=?", it) }
        return loanPage(where, "l.borrowed_at DESC", paging)
    }

    /** Remises de livres : emprunts rendus, bornés par la date de retour. */
    fun returns(
        memberNumber: String?,
        bookServerId: String?,
        from: String?,
        to: String?,
        late: Boolean?,
        paging: Paging,
    ): Page<LoanView> {
        val where = Conditions("l.deleted=0 AND l.returned_at IS NOT NULL")
        filterLoans(where, memberNumber, bookServerId)
        from?.let { where.add("l.returned_at>=?", it) }
        to?.let { where.add("l.returned_at<=?", it) }
        late?.let {
            where.add(if (it) "l.returned_at>json_extract(l.payload,'$.dueAt')" else "l.returned_at<=json_extract(l.payload,'$.dueAt')")
        }
        return loanPage(where, "l.returned_at DESC", paging)
    }

    fun loan(serverId: String): LoanView? =
        loanPage(Conditions("l.deleted=0").apply { add("l.server_id=?", serverId) }, "l.borrowed_at", Paging(1))
            .items.firstOrNull()

    private fun filterLoans(where: Conditions, memberNumber: String?, bookServerId: String?) {
        memberNumber?.let { where.add("l.member_number=?", it.trim().uppercase()) }
        bookServerId?.let { where.add("l.book_server_id=?", it) }
    }

    private fun loanPage(where: Conditions, orderBy: String, paging: Paging): Page<LoanView> {
        val now = Instant.now()
        return page(
            "loans l LEFT JOIN books b ON b.server_id=l.book_server_id " +
                "LEFT JOIN subscribers s ON s.member_number=l.member_number",
            where,
            orderBy,
            paging,
            "l.payload, b.title AS book_title, b.accession AS book_accession, s.name AS subscriber_name",
        ) { rows ->
            val loan = json.decodeFromString<SyncLoan>(rows.getString("payload"))
            val due = instant(loan.dueAt)
            val returned = loan.returnedAt?.let(::instant)
            LoanView(
                serverId = loan.serverId,
                bookServerId = loan.bookServerId,
                bookTitle = rows.getString("book_title"),
                bookAccession = rows.getString("book_accession"),
                memberNumber = loan.memberNumber,
                subscriberName = rows.getString("subscriber_name"),
                subscriptionServerId = loan.subscriptionServerId,
                borrowedAt = loan.borrowedAt,
                dueAt = loan.dueAt,
                returnedAt = loan.returnedAt,
                status = loan.status,
                overdue = loan.returnedAt == null && due != null && due.isBefore(now),
                returnedLate = returned != null && due != null && returned.isAfter(due),
                notes = loan.notes,
                createdAt = loan.createdAt,
                updatedAt = loan.updatedAt,
                revision = loan.revision,
            )
        }
    }

    // --- Personnel et portails antivol ------------------------------------

    fun staff(
        search: String?,
        active: Boolean?,
        hasBadge: Boolean?,
        updatedSince: String?,
        paging: Paging,
        serverId: String? = null,
    ): Page<SyncStaff> {
        val where = Conditions("deleted=0")
        serverId?.let { where.add("server_id=?", it) }
        search.like()?.let {
            where.add(
                "(json_extract(payload,'$.staffNumber') LIKE ? OR json_extract(payload,'$.name') LIKE ? " +
                    "OR json_extract(payload,'$.position') LIKE ? OR json_extract(payload,'$.email') LIKE ?)",
                it, it, it, it,
            )
        }
        active?.let { where.add("json_extract(payload,'$.active')=?", if (it) 1 else 0) }
        hasBadge?.let { where.add(if (it) "badge_tid IS NOT NULL" else "badge_tid IS NULL") }
        updatedSince?.let { where.add("json_extract(payload,'$.updatedAt')>=?", it) }
        return page("staff", where, "json_extract(payload,'$.name') COLLATE NOCASE", paging, "payload") {
            json.decodeFromString<SyncStaff>(it.getString("payload"))
        }
    }

    fun staffMember(serverId: String): SyncStaff? =
        staff(null, null, null, null, Paging(1), serverId).items.firstOrNull()

    /** Passages du personnel au portail ; `from`/`to` bornent l'heure de passage. */
    fun staffPassages(
        staffServerId: String?,
        gateId: String?,
        direction: String?,
        from: String?,
        to: String?,
        paging: Paging,
    ): Page<SyncStaffPassage> {
        val where = Conditions("deleted=0")
        staffServerId?.let { where.add("staff_server_id=?", it) }
        gateId?.let { where.add("json_extract(payload,'$.gateId')=?", it) }
        direction?.let {
            require(it == "in" || it == "out") { "direction doit valoir in ou out." }
            where.add("json_extract(payload,'$.direction')=?", it)
        }
        from?.let { where.add("passed_at>=?", it) }
        to?.let { where.add("passed_at<=?", it) }
        return page("staff_passages", where, "passed_at DESC", paging, "payload") {
            json.decodeFromString<SyncStaffPassage>(it.getString("payload"))
        }
    }

    /** Entrées, sorties et alarmes par portail et par jour (`from`/`to` : AAAA-MM-JJ). */
    fun gateDays(gateId: String?, from: String?, to: String?, paging: Paging): Page<SyncGateDay> {
        val where = Conditions("deleted=0")
        gateId?.let { where.add("gate_id=?", it) }
        from?.let { where.add("day>=?", it) }
        to?.let { where.add("day<=?", it) }
        return page("gate_days", where, "day DESC, gate_id", paging, "payload") {
            json.decodeFromString<SyncGateDay>(it.getString("payload"))
        }
    }

    // --- Appareils, comptes et activité -----------------------------------

    fun devices(paging: Paging, deviceId: String? = null): Page<DeviceView> = page(
        "devices d",
        Conditions().apply { deviceId?.let { add("d.device_id=?", it) } },
        "d.last_seen_at DESC",
        paging,
        """
        d.*,
        (SELECT COUNT(*) FROM user_accounts u WHERE u.device_id=d.device_id) AS user_count,
        (SELECT COUNT(*) FROM activity a WHERE a.device_id=d.device_id) AS activity_count,
        (SELECT COUNT(*) FROM events e WHERE e.device_id=d.device_id) AS change_count
        """.trimIndent(),
    ) { rows ->
        DeviceView(
            deviceId = rows.getString("device_id"),
            name = rows.getString("name"),
            platform = rows.getString("platform"),
            appVersion = rows.getString("app_version"),
            lastSeenAt = rows.getString("last_seen_at"),
            lastReportAt = rows.getString("last_report_at"),
            userCount = rows.getInt("user_count"),
            activityCount = rows.getInt("activity_count"),
            changeCount = rows.getInt("change_count"),
        )
    }

    fun device(deviceId: String): DeviceView? = devices(Paging(1), deviceId).items.firstOrNull()

    fun users(deviceId: String?, search: String?, role: String?, active: Boolean?, paging: Paging): Page<UserAccountView> {
        val where = Conditions()
        deviceId?.let { where.add("u.device_id=?", it) }
        search.like()?.let { where.add("(u.name LIKE ? OR u.email LIKE ?)", it, it) }
        role?.let { where.add("u.role=?", it) }
        active?.let { where.add("u.active=?", if (it) 1 else 0) }
        return page(
            "user_accounts u LEFT JOIN devices d ON d.device_id=u.device_id",
            where,
            "u.email COLLATE NOCASE, u.device_id",
            paging,
            "u.*, d.name AS device_name",
        ) { rows ->
            UserAccountView(
                deviceId = rows.getString("device_id"),
                deviceName = rows.getString("device_name").orEmpty(),
                localId = rows.getLong("local_id"),
                name = rows.getString("name"),
                email = rows.getString("email"),
                role = rows.getString("role"),
                active = rows.getInt("active") != 0,
                createdAt = rows.getString("created_at"),
                updatedAt = rows.getString("updated_at"),
                reportedAt = rows.getString("reported_at"),
            )
        }
    }

    fun activity(
        deviceId: String?,
        type: String?,
        result: String?,
        bookServerId: String?,
        from: String?,
        to: String?,
        paging: Paging,
    ): Page<ActivityView> {
        val where = Conditions()
        deviceId?.let { where.add("a.device_id=?", it) }
        type?.let { where.add("a.type=?", it) }
        result?.let { where.add("a.result=?", it) }
        bookServerId?.let { where.add("a.book_server_id=?", it) }
        from?.let { where.add("a.created_at>=?", it) }
        to?.let { where.add("a.created_at<=?", it) }
        return page(
            "activity a LEFT JOIN devices d ON d.device_id=a.device_id LEFT JOIN books b ON b.server_id=a.book_server_id",
            where,
            "a.created_at DESC, a.id DESC",
            paging,
            "a.*, d.name AS device_name, b.title AS book_title",
        ) { rows ->
            ActivityView(
                id = rows.getLong("id"),
                deviceId = rows.getString("device_id"),
                deviceName = rows.getString("device_name").orEmpty(),
                localId = rows.getLong("local_id"),
                type = rows.getString("type"),
                result = rows.getString("result"),
                message = rows.getString("message"),
                epc = rows.getString("epc"),
                tid = rows.getString("tid"),
                bookServerId = rows.getString("book_server_id"),
                bookTitle = rows.getString("book_title"),
                createdAt = rows.getString("created_at"),
                receivedAt = rows.getString("received_at"),
            )
        }
    }

    // --- Historique des modifications -------------------------------------

    /**
     * Journal des modifications synchronisées, du plus récent au plus ancien.
     * Avec `since` (numéro de séquence), ordre croissant pour une lecture
     * incrémentale.
     */
    fun history(
        entityType: String?,
        entityId: String?,
        deviceId: String?,
        from: String?,
        to: String?,
        since: Long?,
        paging: Paging,
    ): Page<HistoryEntry> {
        val where = Conditions()
        entityType?.let { where.add("e.entity_type=?", it) }
        entityId?.let { where.add("e.entity_id=?", it) }
        deviceId?.let { where.add("e.device_id=?", it) }
        from?.let { where.add("e.created_at>=?", it) }
        to?.let { where.add("e.created_at<=?", it) }
        since?.let { where.add("e.sequence>?", it) }
        return page(
            "events e LEFT JOIN devices d ON d.device_id=e.device_id",
            where,
            if (since != null) "e.sequence ASC" else "e.sequence DESC",
            paging,
            "e.*, d.name AS device_name",
        ) { rows ->
            val change = store.readChange(rows)
            val type = change.entityType
            HistoryEntry(
                sequence = change.sequence,
                entityType = type,
                entityId = change.entityId,
                operation = change.operation,
                deviceId = change.deviceId,
                deviceName = rows.getString("device_name"),
                createdAt = change.createdAt,
                change = change,
            )
        }
    }

    // --- Synthèse ---------------------------------------------------------

    fun stats(): StatsView = store.read { connection ->
        val now = Instant.now().toString()
        val today = LocalDate.now(ZoneOffset.UTC).atStartOfDay().toInstant(ZoneOffset.UTC).toString()
        fun count(sql: String, vararg params: Any?) = connection.prepareStatement(sql).use { statement ->
            bind(statement, params.toList())
            statement.executeQuery().use { rows -> rows.next(); rows.getInt(1) }
        }
        StatsView(
            books = count("SELECT COUNT(*) FROM books WHERE deleted=0"),
            booksOnLoan = count("SELECT COUNT(DISTINCT book_server_id) FROM loans WHERE deleted=0 AND returned_at IS NULL"),
            subscribers = count("SELECT COUNT(*) FROM subscribers WHERE deleted=0"),
            activeSubscribers = count("SELECT COUNT(*) FROM subscribers WHERE deleted=0 AND active=1"),
            currentSubscriptions = count("SELECT COUNT(*) FROM subscriptions sub WHERE sub.deleted=0 AND $CURRENT_SUBSCRIPTION", now, now),
            activeLoans = count("SELECT COUNT(*) FROM loans WHERE deleted=0 AND returned_at IS NULL"),
            overdueLoans = count(
                "SELECT COUNT(*) FROM loans WHERE deleted=0 AND returned_at IS NULL AND json_extract(payload,'$.dueAt')<?",
                now,
            ),
            returnsToday = count("SELECT COUNT(*) FROM loans WHERE deleted=0 AND returned_at>=?", today),
            devices = count("SELECT COUNT(*) FROM devices"),
            generatedAt = now,
        )
    }

    // --- Rapports d'appareil ----------------------------------------------

    /**
     * Enregistre le rapport d'un appareil : description, instantané de ses
     * comptes (remplace le précédent) et nouvelles entrées d'activité
     * (idempotent : une entrée déjà reçue est ignorée).
     */
    fun receiveReport(report: DeviceReport): DeviceReportResponse {
        require(report.deviceId.isNotBlank()) { "L'identifiant de l'appareil est obligatoire." }
        require((report.users?.size ?: 0) <= 500) { "Un rapport ne peut pas dépasser 500 comptes." }
        require(report.activity.size <= 1000) { "Un rapport ne peut pas dépasser 1000 entrées d'activité." }
        val now = Instant.now().toString()
        return store.transaction { connection ->
            connection.prepareStatement(
                """
                INSERT INTO devices(device_id, name, last_seen_at, platform, app_version, last_report_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE devices.name END,
                    last_seen_at=excluded.last_seen_at,
                    platform=COALESCE(NULLIF(excluded.platform,''), devices.platform),
                    app_version=COALESCE(NULLIF(excluded.app_version,''), devices.app_version),
                    last_report_at=excluded.last_report_at
                """.trimIndent(),
            ).use {
                bind(it, listOf(report.deviceId, report.name.take(120), now, report.platform.take(40), report.appVersion.take(40), now))
                it.executeUpdate()
            }
            val users = report.users
            if (users != null) {
                connection.prepareStatement("DELETE FROM user_accounts WHERE device_id=?").use {
                    it.setString(1, report.deviceId)
                    it.executeUpdate()
                }
                connection.prepareStatement(
                    """
                    INSERT INTO user_accounts(device_id, local_id, name, email, role, active, created_at, updated_at, reported_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """.trimIndent(),
                ).use { statement ->
                    users.distinctBy { it.localId }.forEach { user ->
                        bind(
                            statement,
                            listOf(
                                report.deviceId, user.localId, user.name.take(240), user.email.trim().lowercase().take(240),
                                user.role.take(20), if (user.active) 1 else 0, user.createdAt, user.updatedAt, now,
                            ),
                        )
                        statement.executeUpdate()
                    }
                }
            }
            connection.prepareStatement(
                """
                INSERT OR IGNORE INTO activity(device_id, local_id, type, result, message, epc, tid, book_server_id, created_at, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
            ).use { statement ->
                report.activity.forEach { entry ->
                    bind(
                        statement,
                        listOf(
                            report.deviceId, entry.localId, entry.type.take(40), entry.result.take(40),
                            entry.message.take(1000), entry.epc?.take(64), entry.tid?.take(128),
                            entry.bookServerId?.take(64), entry.createdAt, now,
                        ),
                    )
                    statement.executeUpdate()
                }
            }
            DeviceReportResponse(users?.size ?: 0, report.activity.maxOfOrNull { it.localId })
        }
    }

    // --- Outils -----------------------------------------------------------

    private fun <T> page(
        from: String,
        where: Conditions,
        orderBy: String,
        paging: Paging,
        columns: String,
        read: (ResultSet) -> T,
    ): Page<T> = store.read { connection ->
        val total = connection.prepareStatement("SELECT COUNT(*) FROM $from ${where.sql}").use { statement ->
            bind(statement, where.params)
            statement.executeQuery().use { rows -> rows.next(); rows.getInt(1) }
        }
        val limit = if (paging.limit != null) " LIMIT ${paging.limit} OFFSET ${paging.offset}" else if (paging.offset > 0) " LIMIT -1 OFFSET ${paging.offset}" else ""
        val items = connection.prepareStatement("SELECT $columns FROM $from ${where.sql} ORDER BY $orderBy$limit").use { statement ->
            bind(statement, where.params)
            statement.executeQuery().use { rows -> buildList { while (rows.next()) add(read(rows)) } }
        }
        Page(items, total)
    }

    private fun bind(statement: PreparedStatement, values: List<Any?>) {
        values.forEachIndexed { index, value ->
            when (value) {
                null -> statement.setObject(index + 1, null)
                is Int -> statement.setInt(index + 1, value)
                is Long -> statement.setLong(index + 1, value)
                else -> statement.setString(index + 1, value.toString())
            }
        }
    }

    private fun String?.like(): String? = this?.trim()?.takeIf { it.isNotEmpty() }?.let { "%$it%" }

    private fun instant(value: String): Instant? = runCatching { Instant.parse(value) }.getOrNull()

    private companion object {
        const val SEARCH_BOOK =
            "(title LIKE ? OR author LIKE ? OR accession LIKE ? OR isbn LIKE ? OR epc LIKE ? OR shelf LIKE ? OR category LIKE ?)"
        const val CURRENT_SUBSCRIPTION =
            "(json_extract(sub.payload,'$.status')='active' AND json_extract(sub.payload,'$.startsAt')<=? " +
                "AND json_extract(sub.payload,'$.endsAt')>=?)"
    }
}
