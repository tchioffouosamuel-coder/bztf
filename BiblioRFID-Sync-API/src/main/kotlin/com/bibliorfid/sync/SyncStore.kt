package com.bibliorfid.sync

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.Closeable
import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.Statement
import java.time.Instant

class SyncStore(databaseUrl: String, private val json: Json) : Closeable {
    private val connection: Connection

    init {
        Class.forName("org.sqlite.JDBC")
        if (databaseUrl.startsWith("jdbc:sqlite:") && databaseUrl != "jdbc:sqlite::memory:") {
            File(databaseUrl.removePrefix("jdbc:sqlite:")).absoluteFile.parentFile?.mkdirs()
        }
        connection = DriverManager.getConnection(databaseUrl)
        connection.createStatement().use {
            it.execute("PRAGMA journal_mode=WAL")
            it.execute("PRAGMA foreign_keys=ON")
            it.execute("PRAGMA busy_timeout=5000")
        }
        migrate()
    }

    @Synchronized
    private fun migrate() {
        connection.createStatement().use { statement ->
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS books (
                    server_id TEXT PRIMARY KEY,
                    accession TEXT NOT NULL,
                    epc TEXT NOT NULL,
                    tid TEXT,
                    title TEXT NOT NULL,
                    author TEXT NOT NULL,
                    isbn TEXT NOT NULL,
                    publisher TEXT NOT NULL,
                    publication_year TEXT NOT NULL,
                    category TEXT NOT NULL,
                    shelf TEXT NOT NULL,
                    notes TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    tagged_at TEXT,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS mutations (
                    mutation_id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    applied_at TEXT NOT NULL
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    payload TEXT,
                    device_id TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """.trimIndent(),
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_books_accession ON books(accession)")
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_books_epc ON books(epc)")
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS subscribers (
                    member_number TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    email TEXT NOT NULL,
                    phone TEXT NOT NULL,
                    active INTEGER NOT NULL,
                    card_epc TEXT,
                    card_tid TEXT,
                    card_tagged_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_subscribers_card_tid ON subscribers(card_tid)")
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS subscriptions (
                    server_id TEXT PRIMARY KEY,
                    member_number TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS loans (
                    server_id TEXT PRIMARY KEY,
                    book_server_id TEXT NOT NULL,
                    member_number TEXT NOT NULL,
                    borrowed_at TEXT NOT NULL,
                    returned_at TEXT,
                    payload TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                "CREATE INDEX IF NOT EXISTS idx_loans_book ON loans(book_server_id, returned_at)",
            )
            if ("entity_type" !in columns(statement, "events")) {
                statement.executeUpdate(
                    "ALTER TABLE events ADD COLUMN entity_type TEXT NOT NULL DEFAULT '${EntityType.BOOK}'",
                )
            }
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_events_entity ON events(entity_type, entity_id)")
            val deviceColumns = columns(statement, "devices")
            for ((column, type) in listOf("platform" to "TEXT", "app_version" to "TEXT", "last_report_at" to "TEXT")) {
                if (column !in deviceColumns) statement.executeUpdate("ALTER TABLE devices ADD COLUMN $column $type")
            }
            // Comptes et journal d'activité propres à chaque poste : remontés
            // par rapport d'appareil, hors du flux de synchronisation.
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS user_accounts (
                    device_id TEXT NOT NULL,
                    local_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    email TEXT NOT NULL,
                    role TEXT NOT NULL,
                    active INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    reported_at TEXT NOT NULL,
                    PRIMARY KEY(device_id, local_id)
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL,
                    local_id INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    result TEXT NOT NULL,
                    message TEXT NOT NULL,
                    epc TEXT,
                    tid TEXT,
                    book_server_id TEXT,
                    created_at TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    UNIQUE(device_id, local_id)
                )
                """.trimIndent(),
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_activity_created ON activity(created_at)")
            // Personnel et portails antivol : charge utile JSON, comme les
            // abonnements et les emprunts.
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS staff (
                    server_id TEXT PRIMARY KEY,
                    badge_tid TEXT,
                    payload TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_staff_badge_tid ON staff(badge_tid)")
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS gate_days (
                    server_id TEXT PRIMARY KEY,
                    gate_id TEXT NOT NULL,
                    day TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_gate_days_day ON gate_days(day)")
            statement.executeUpdate(
                """
                CREATE TABLE IF NOT EXISTS staff_passages (
                    server_id TEXT PRIMARY KEY,
                    staff_server_id TEXT NOT NULL,
                    passed_at TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            statement.executeUpdate(
                "CREATE INDEX IF NOT EXISTS idx_staff_passages_staff ON staff_passages(staff_server_id, passed_at)",
            )
            statement.executeUpdate("CREATE INDEX IF NOT EXISTS idx_staff_passages_at ON staff_passages(passed_at)")
            statement.executeUpdate("CREATE TABLE IF NOT EXISTS store_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            statement.executeUpdate(
                "INSERT OR IGNORE INTO store_meta(key, value) VALUES ('database_id', '${java.util.UUID.randomUUID()}')",
            )
        }
    }

    /** Identifiant de cette base, stable tant qu'elle n'est pas recréée. */
    val databaseId: String by lazy {
        read { connection ->
            connection.createStatement().use { statement ->
                statement.executeQuery("SELECT value FROM store_meta WHERE key='database_id'").use { rows ->
                    rows.next()
                    rows.getString(1)
                }
            }
        }
    }

    /** Lecture sous le verrou du magasin (requêtes de l'API de données). */
    @Synchronized
    internal fun <T> read(block: (Connection) -> T): T = block(connection)

    /** Écriture transactionnelle sous le verrou du magasin. */
    @Synchronized
    internal fun <T> transaction(block: (Connection) -> T): T {
        connection.autoCommit = false
        try {
            return block(connection).also { connection.commit() }
        } catch (error: Throwable) {
            connection.rollback()
            throw error
        } finally {
            connection.autoCommit = true
        }
    }

    private fun columns(statement: Statement, table: String): Set<String> =
        statement.executeQuery("PRAGMA table_info($table)").use { rows ->
            buildSet { while (rows.next()) add(rows.getString("name")) }
        }

    @Synchronized
    fun registerDevice(registration: DeviceRegistration): DeviceResponse {
        require(registration.deviceId.isNotBlank()) { "L'identifiant de l'appareil est obligatoire." }
        val now = Instant.now().toString()
        connection.prepareStatement(
            """
            INSERT INTO devices(device_id, name, last_seen_at) VALUES (?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET name=excluded.name, last_seen_at=excluded.last_seen_at
            """.trimIndent(),
        ).use {
            it.setString(1, registration.deviceId)
            it.setString(2, registration.name.take(120))
            it.setString(3, now)
            it.executeUpdate()
        }
        return DeviceResponse(registration.deviceId, true, now, databaseId, currentCursor())
    }

    @Synchronized
    fun push(request: PushRequest): PushResponse {
        require(request.deviceId.isNotBlank()) { "L'identifiant de l'appareil est obligatoire." }
        require(request.mutations.size <= 500) { "Un lot ne peut pas dépasser 500 mutations." }
        val acknowledged = mutableListOf<String>()
        connection.autoCommit = false
        try {
            touchDevice(request.deviceId)
            // Livres et abonnés avant les abonnements et emprunts qui les
            // référencent : les clients reçoivent les événements dans cet ordre.
            request.mutations.sortedBy { EntityType.priority(it.entityType) }.forEach { mutation ->
                require(mutation.mutationId.isNotBlank()) { "mutationId est obligatoire." }
                if (mutationExists(mutation.mutationId)) {
                    acknowledged += mutation.mutationId
                    return@forEach
                }
                when (mutation.entityType to mutation.operation) {
                    EntityType.BOOK to "upsert" -> upsertBook(
                        requireNotNull(mutation.book) { "Le livre est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.BOOK to "delete" -> deleteBook(mutation.entityId, request.deviceId)
                    EntityType.SUBSCRIBER to "upsert" -> upsertSubscriber(
                        requireNotNull(mutation.subscriber) { "L'abonné est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.SUBSCRIBER to "delete" -> deleteSubscriber(mutation.entityId, request.deviceId)
                    EntityType.SUBSCRIPTION to "upsert" -> upsertSubscription(
                        requireNotNull(mutation.subscription) { "L'abonnement est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.SUBSCRIPTION to "delete" -> deleteRecord(
                        "subscriptions",
                        mutation.entityId,
                        request.deviceId,
                        EntityType.SUBSCRIPTION,
                    )
                    EntityType.LOAN to "upsert" -> upsertLoan(
                        requireNotNull(mutation.loan) { "L'emprunt est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.LOAN to "delete" -> deleteRecord("loans", mutation.entityId, request.deviceId, EntityType.LOAN)
                    EntityType.STAFF to "upsert" -> upsertStaff(
                        requireNotNull(mutation.staff) { "Le membre du personnel est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.STAFF to "delete" -> deleteRecord("staff", mutation.entityId, request.deviceId, EntityType.STAFF)
                    EntityType.GATE_DAY to "upsert" -> upsertGateDay(
                        requireNotNull(mutation.gateDay) { "Les compteurs du portail sont obligatoires pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.STAFF_PASSAGE to "upsert" -> upsertStaffPassage(
                        requireNotNull(mutation.staffPassage) { "Le passage est obligatoire pour un upsert." },
                        request.deviceId,
                    )
                    EntityType.STAFF_PASSAGE to "delete" -> deleteRecord(
                        "staff_passages",
                        mutation.entityId,
                        request.deviceId,
                        EntityType.STAFF_PASSAGE,
                    )
                    else -> throw IllegalArgumentException(
                        "Opération inconnue : ${mutation.entityType}/${mutation.operation}",
                    )
                }
                connection.prepareStatement(
                    "INSERT INTO mutations(mutation_id, device_id, applied_at) VALUES (?, ?, ?)",
                ).use {
                    it.setString(1, mutation.mutationId)
                    it.setString(2, request.deviceId)
                    it.setString(3, Instant.now().toString())
                    it.executeUpdate()
                }
                acknowledged += mutation.mutationId
            }
            connection.commit()
            return PushResponse(acknowledged, currentCursor())
        } catch (error: Throwable) {
            connection.rollback()
            throw error
        } finally {
            connection.autoCommit = true
        }
    }

    @Synchronized
    fun pull(since: Long, limit: Int = 500): PullResponse {
        val changes = mutableListOf<Change>()
        connection.prepareStatement(
            "SELECT * FROM events WHERE sequence > ? ORDER BY sequence ASC LIMIT ?",
        ).use { statement ->
            statement.setLong(1, since.coerceAtLeast(0))
            statement.setInt(2, limit.coerceIn(1, 1000) + 1)
            statement.executeQuery().use { rows ->
                while (rows.next()) changes += readChange(rows)
            }
        }
        val hasMore = changes.size > limit
        val page = if (hasMore) changes.take(limit) else changes
        return PullResponse(page.lastOrNull()?.sequence ?: since, page, hasMore)
    }

    /** Changement d'une ligne de `events`, charge utile décodée selon son type. */
    internal fun readChange(rows: java.sql.ResultSet): Change {
        val payload = rows.getString("payload")
        val type = rows.getString("entity_type")
        fun <T> decode(expected: String, read: (String) -> T): T? =
            payload?.takeIf { type == expected }?.let(read)
        return Change(
            sequence = rows.getLong("sequence"),
            operation = rows.getString("operation"),
            entityId = rows.getString("entity_id"),
            entityType = type,
            book = decode(EntityType.BOOK) { json.decodeFromString<SyncBook>(it) },
            subscriber = decode(EntityType.SUBSCRIBER) { json.decodeFromString<SyncSubscriber>(it) },
            subscription = decode(EntityType.SUBSCRIPTION) { json.decodeFromString<SyncSubscription>(it) },
            loan = decode(EntityType.LOAN) { json.decodeFromString<SyncLoan>(it) },
            staff = decode(EntityType.STAFF) { json.decodeFromString<SyncStaff>(it) },
            gateDay = decode(EntityType.GATE_DAY) { json.decodeFromString<SyncGateDay>(it) },
            staffPassage = decode(EntityType.STAFF_PASSAGE) { json.decodeFromString<SyncStaffPassage>(it) },
            deviceId = rows.getString("device_id"),
            createdAt = rows.getString("created_at"),
        )
    }

    @Synchronized
    fun currentCursor(): Long = connection.createStatement().use { statement ->
        statement.executeQuery("SELECT COALESCE(MAX(sequence), 0) FROM events").use { rows ->
            rows.next()
            rows.getLong(1)
        }
    }

    private fun touchDevice(deviceId: String) {
        val now = Instant.now().toString()
        connection.prepareStatement(
            """
            INSERT INTO devices(device_id, name, last_seen_at) VALUES (?, '', ?)
            ON CONFLICT(device_id) DO UPDATE SET last_seen_at=excluded.last_seen_at
            """.trimIndent(),
        ).use {
            it.setString(1, deviceId)
            it.setString(2, now)
            it.executeUpdate()
        }
    }

    private fun mutationExists(mutationId: String): Boolean = connection.prepareStatement(
        "SELECT 1 FROM mutations WHERE mutation_id=? LIMIT 1",
    ).use {
        it.setString(1, mutationId)
        it.executeQuery().use { rows -> rows.next() }
    }

    private fun upsertBook(input: SyncBook, deviceId: String) {
        require(input.serverId.isNotBlank() && input.title.isNotBlank()) {
            "serverId et title sont obligatoires."
        }
        val existingRevision = connection.prepareStatement(
            "SELECT revision FROM books WHERE server_id=?",
        ).use {
            it.setString(1, input.serverId)
            it.executeQuery().use { rows -> if (rows.next()) rows.getLong(1) else 0L }
        }
        val canonical = input.copy(revision = existingRevision + 1)
        connection.prepareStatement(
            """
            INSERT INTO books(
                server_id, accession, epc, tid, title, author, isbn, publisher,
                publication_year, category, shelf, notes, status, created_at,
                updated_at, tagged_at, revision, deleted
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET
                accession=excluded.accession, epc=excluded.epc, tid=excluded.tid,
                title=excluded.title, author=excluded.author, isbn=excluded.isbn,
                publisher=excluded.publisher, publication_year=excluded.publication_year,
                category=excluded.category, shelf=excluded.shelf, notes=excluded.notes,
                status=excluded.status, updated_at=excluded.updated_at,
                tagged_at=excluded.tagged_at, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use { statement ->
            bindBook(statement, canonical)
            statement.executeUpdate()
        }
        addEvent("upsert", canonical.serverId, json.encodeToString(canonical), deviceId)
    }

    private fun deleteBook(serverId: String, deviceId: String) {
        if (serverId.isBlank()) return
        connection.prepareStatement(
            "UPDATE books SET deleted=1, revision=revision+1, updated_at=? WHERE server_id=?",
        ).use {
            it.setString(1, Instant.now().toString())
            it.setString(2, serverId)
            it.executeUpdate()
        }
        addEvent("delete", serverId, null, deviceId)
    }

    private fun upsertSubscriber(input: SyncSubscriber, deviceId: String) {
        val memberNumber = input.memberNumber.trim().uppercase()
        require(memberNumber.isNotBlank() && input.name.isNotBlank()) {
            "memberNumber et name sont obligatoires."
        }
        val cardTid = input.cardTid?.trim()?.uppercase()?.ifBlank { null }
        val existing = findSubscriber(memberNumber)
        val canonical = input.copy(
            memberNumber = memberNumber,
            cardEpc = input.cardEpc?.trim()?.uppercase()?.ifBlank { null },
            cardTid = cardTid,
            createdAt = existing?.createdAt ?: input.createdAt,
            revision = (existing?.revision ?: 0) + 1,
        )
        // Une carte physique n'appartient qu'à un abonné : si elle a été
        // réencodée pour quelqu'un d'autre, l'ancien titulaire la perd.
        if (cardTid != null) {
            previousCardHolders(cardTid, memberNumber).forEach { holder ->
                writeSubscriber(
                    holder.copy(
                        cardTid = null,
                        cardTaggedAt = null,
                        updatedAt = Instant.now().toString(),
                        revision = holder.revision + 1,
                    ),
                    deviceId,
                )
            }
        }
        writeSubscriber(canonical, deviceId)
    }

    private fun writeSubscriber(subscriber: SyncSubscriber, deviceId: String) {
        connection.prepareStatement(
            """
            INSERT INTO subscribers(
                member_number, name, email, phone, active, card_epc, card_tid,
                card_tagged_at, created_at, updated_at, revision, deleted
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(member_number) DO UPDATE SET
                name=excluded.name, email=excluded.email, phone=excluded.phone,
                active=excluded.active, card_epc=excluded.card_epc,
                card_tid=excluded.card_tid, card_tagged_at=excluded.card_tagged_at,
                updated_at=excluded.updated_at, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, subscriber.memberNumber)
            it.setString(2, subscriber.name.take(240))
            it.setString(3, subscriber.email.take(240))
            it.setString(4, subscriber.phone.take(80))
            it.setInt(5, if (subscriber.active) 1 else 0)
            it.setString(6, subscriber.cardEpc)
            it.setString(7, subscriber.cardTid)
            it.setString(8, subscriber.cardTaggedAt)
            it.setString(9, subscriber.createdAt)
            it.setString(10, subscriber.updatedAt)
            it.setLong(11, subscriber.revision)
            it.executeUpdate()
        }
        addEvent(
            "upsert",
            subscriber.memberNumber,
            json.encodeToString(subscriber),
            deviceId,
            EntityType.SUBSCRIBER,
        )
    }

    private fun deleteSubscriber(memberNumber: String, deviceId: String) {
        val normalized = memberNumber.trim().uppercase()
        if (normalized.isBlank()) return
        connection.prepareStatement(
            "UPDATE subscribers SET deleted=1, revision=revision+1, updated_at=? WHERE member_number=?",
        ).use {
            it.setString(1, Instant.now().toString())
            it.setString(2, normalized)
            it.executeUpdate()
        }
        addEvent("delete", normalized, null, deviceId, EntityType.SUBSCRIBER)
    }

    private fun upsertSubscription(input: SyncSubscription, deviceId: String) {
        val memberNumber = input.memberNumber.trim().uppercase()
        require(input.serverId.isNotBlank() && memberNumber.isNotBlank()) {
            "serverId et memberNumber sont obligatoires."
        }
        require(input.status in SUBSCRIPTION_STATUSES) { "Statut d'abonnement inconnu : ${input.status}" }
        val existing = findPayload("subscriptions", input.serverId) { json.decodeFromString<SyncSubscription>(it) }
        val canonical = input.copy(
            memberNumber = memberNumber,
            createdAt = existing?.createdAt ?: input.createdAt,
            revision = (existing?.revision ?: 0) + 1,
        )
        val payload = json.encodeToString(canonical)
        connection.prepareStatement(
            """
            INSERT INTO subscriptions(server_id, member_number, payload, revision, deleted)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET member_number=excluded.member_number,
                payload=excluded.payload, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, canonical.serverId)
            it.setString(2, memberNumber)
            it.setString(3, payload)
            it.setLong(4, canonical.revision)
            it.executeUpdate()
        }
        addEvent("upsert", canonical.serverId, payload, deviceId, EntityType.SUBSCRIPTION)
    }

    private fun upsertLoan(input: SyncLoan, deviceId: String) {
        val memberNumber = input.memberNumber.trim().uppercase()
        require(input.serverId.isNotBlank() && input.bookServerId.isNotBlank() && memberNumber.isNotBlank()) {
            "serverId, bookServerId et memberNumber sont obligatoires."
        }
        val existing = findPayload("loans", input.serverId) { json.decodeFromString<SyncLoan>(it) }
        var canonical = input.copy(
            memberNumber = memberNumber,
            returnedAt = input.returnedAt?.ifBlank { null },
            createdAt = existing?.createdAt ?: input.createdAt,
            revision = (existing?.revision ?: 0) + 1,
        )
        // Un retour enregistré n'est jamais annulé par une copie plus ancienne.
        if (existing?.returnedAt != null && canonical.returnedAt == null) {
            canonical = canonical.copy(returnedAt = existing.returnedAt, status = existing.status)
        }
        if (canonical.returnedAt == null) {
            // Un livre n'a qu'un emprunt en cours : le plus récent reste
            // actif, les autres ont forcément été rendus avant lui.
            val others = activeLoansForBook(canonical.bookServerId, canonical.serverId)
            val latestBorrow = (others.map { it.borrowedAt } + canonical.borrowedAt).max()
            val incomingIsLatest = canonical.borrowedAt >= latestBorrow
            others
                .filter { incomingIsLatest || it.borrowedAt < latestBorrow }
                .forEach { writeLoan(closeLoan(it, latestBorrow).copy(revision = it.revision + 1), deviceId) }
            if (!incomingIsLatest) canonical = closeLoan(canonical, latestBorrow)
        }
        writeLoan(canonical, deviceId)
    }

    private fun closeLoan(loan: SyncLoan, at: String) = loan.copy(
        returnedAt = at,
        status = "returned",
        notes = listOf(loan.notes, "Clôturé automatiquement : livre emprunté de nouveau.")
            .filter { it.isNotBlank() }
            .joinToString(" "),
        updatedAt = Instant.now().toString(),
    )

    private fun writeLoan(loan: SyncLoan, deviceId: String) {
        val payload = json.encodeToString(loan)
        connection.prepareStatement(
            """
            INSERT INTO loans(server_id, book_server_id, member_number, borrowed_at, returned_at, payload, revision, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET book_server_id=excluded.book_server_id,
                member_number=excluded.member_number, borrowed_at=excluded.borrowed_at,
                returned_at=excluded.returned_at, payload=excluded.payload,
                revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, loan.serverId)
            it.setString(2, loan.bookServerId)
            it.setString(3, loan.memberNumber)
            it.setString(4, loan.borrowedAt)
            it.setString(5, loan.returnedAt)
            it.setString(6, payload)
            it.setLong(7, loan.revision)
            it.executeUpdate()
        }
        addEvent("upsert", loan.serverId, payload, deviceId, EntityType.LOAN)
    }

    private fun activeLoansForBook(bookServerId: String, exceptServerId: String): List<SyncLoan> =
        connection.prepareStatement(
            "SELECT payload FROM loans WHERE book_server_id=? AND returned_at IS NULL AND deleted=0 AND server_id<>?",
        ).use {
            it.setString(1, bookServerId)
            it.setString(2, exceptServerId)
            it.executeQuery().use { rows ->
                buildList { while (rows.next()) add(json.decodeFromString<SyncLoan>(rows.getString(1))) }
            }
        }

    private fun upsertStaff(input: SyncStaff, deviceId: String) {
        val staffNumber = input.staffNumber.trim().uppercase()
        require(input.serverId.isNotBlank() && staffNumber.isNotBlank() && input.name.isNotBlank()) {
            "serverId, staffNumber et name sont obligatoires."
        }
        val badgeTid = input.badgeTid?.trim()?.uppercase()?.ifBlank { null }
        val existing = findPayload("staff", input.serverId) { json.decodeFromString<SyncStaff>(it) }
        val canonical = input.copy(
            staffNumber = staffNumber,
            badgeEpc = input.badgeEpc?.trim()?.uppercase()?.ifBlank { null },
            badgeTid = badgeTid,
            createdAt = existing?.createdAt ?: input.createdAt,
            revision = (existing?.revision ?: 0) + 1,
        )
        // Un badge physique n'appartient qu'à une personne : réencodé pour
        // quelqu'un d'autre, l'ancien titulaire le perd.
        if (badgeTid != null) {
            previousBadgeHolders(badgeTid, canonical.serverId).forEach { holder ->
                writeStaff(
                    holder.copy(
                        badgeTid = null,
                        badgeTaggedAt = null,
                        updatedAt = Instant.now().toString(),
                        revision = holder.revision + 1,
                    ),
                    deviceId,
                )
            }
        }
        writeStaff(canonical, deviceId)
    }

    private fun writeStaff(staff: SyncStaff, deviceId: String) {
        val payload = json.encodeToString(staff)
        connection.prepareStatement(
            """
            INSERT INTO staff(server_id, badge_tid, payload, revision, deleted) VALUES (?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET badge_tid=excluded.badge_tid,
                payload=excluded.payload, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, staff.serverId)
            it.setString(2, staff.badgeTid)
            it.setString(3, payload)
            it.setLong(4, staff.revision)
            it.executeUpdate()
        }
        addEvent("upsert", staff.serverId, payload, deviceId, EntityType.STAFF)
    }

    private fun previousBadgeHolders(badgeTid: String, serverId: String): List<SyncStaff> =
        connection.prepareStatement(
            "SELECT payload FROM staff WHERE badge_tid=? AND server_id<>? AND deleted=0",
        ).use {
            it.setString(1, badgeTid)
            it.setString(2, serverId)
            it.executeQuery().use { rows ->
                buildList { while (rows.next()) add(json.decodeFromString<SyncStaff>(rows.getString(1))) }
            }
        }

    /**
     * Les compteurs d'une journée ne font que croître : un portail
     * réinstallé qui repart de zéro n'efface pas ce qui a déjà été compté.
     */
    private fun upsertGateDay(input: SyncGateDay, deviceId: String) {
        require(input.gateId.isNotBlank() && DAY.matches(input.day)) {
            "gateId et day (AAAA-MM-JJ) sont obligatoires."
        }
        require(input.entries >= 0 && input.exits >= 0 && input.alarms >= 0) {
            "Les compteurs du portail ne peuvent pas être négatifs."
        }
        val serverId = "${input.gateId}:${input.day}"
        val existing = findPayload("gate_days", serverId) { json.decodeFromString<SyncGateDay>(it) }
        val canonical = input.copy(
            serverId = serverId,
            entries = maxOf(input.entries, existing?.entries ?: 0),
            exits = maxOf(input.exits, existing?.exits ?: 0),
            alarms = maxOf(input.alarms, existing?.alarms ?: 0),
            revision = (existing?.revision ?: 0) + 1,
        )
        val payload = json.encodeToString(canonical)
        connection.prepareStatement(
            """
            INSERT INTO gate_days(server_id, gate_id, day, payload, revision, deleted) VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, serverId)
            it.setString(2, canonical.gateId)
            it.setString(3, canonical.day)
            it.setString(4, payload)
            it.setLong(5, canonical.revision)
            it.executeUpdate()
        }
        addEvent("upsert", serverId, payload, deviceId, EntityType.GATE_DAY)
    }

    private fun upsertStaffPassage(input: SyncStaffPassage, deviceId: String) {
        require(input.serverId.isNotBlank() && input.staffServerId.isNotBlank()) {
            "serverId et staffServerId sont obligatoires."
        }
        require(input.direction in PASSAGE_DIRECTIONS) { "Sens de passage inconnu : ${input.direction}" }
        val existing = findPayload("staff_passages", input.serverId) { json.decodeFromString<SyncStaffPassage>(it) }
        val canonical = input.copy(
            createdAt = existing?.createdAt ?: input.createdAt,
            revision = (existing?.revision ?: 0) + 1,
        )
        val payload = json.encodeToString(canonical)
        connection.prepareStatement(
            """
            INSERT INTO staff_passages(server_id, staff_server_id, passed_at, payload, revision, deleted)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(server_id) DO UPDATE SET staff_server_id=excluded.staff_server_id,
                passed_at=excluded.passed_at, payload=excluded.payload, revision=excluded.revision, deleted=0
            """.trimIndent(),
        ).use {
            it.setString(1, canonical.serverId)
            it.setString(2, canonical.staffServerId)
            it.setString(3, canonical.passedAt)
            it.setString(4, payload)
            it.setLong(5, canonical.revision)
            it.executeUpdate()
        }
        addEvent("upsert", canonical.serverId, payload, deviceId, EntityType.STAFF_PASSAGE)
    }

    private fun <T> findPayload(table: String, serverId: String, decode: (String) -> T): T? =
        connection.prepareStatement("SELECT payload FROM $table WHERE server_id=?").use {
            it.setString(1, serverId)
            it.executeQuery().use { rows -> if (rows.next()) decode(rows.getString(1)) else null }
        }

    private fun deleteRecord(table: String, serverId: String, deviceId: String, entityType: String) {
        if (serverId.isBlank()) return
        connection.prepareStatement(
            "UPDATE $table SET deleted=1, revision=revision+1 WHERE server_id=?",
        ).use {
            it.setString(1, serverId)
            it.executeUpdate()
        }
        addEvent("delete", serverId, null, deviceId, entityType)
    }

    private fun findSubscriber(memberNumber: String): SyncSubscriber? = connection.prepareStatement(
        "SELECT * FROM subscribers WHERE member_number=?",
    ).use {
        it.setString(1, memberNumber)
        it.executeQuery().use { rows -> if (rows.next()) readSubscriber(rows) else null }
    }

    private fun previousCardHolders(cardTid: String, memberNumber: String): List<SyncSubscriber> =
        connection.prepareStatement(
            "SELECT * FROM subscribers WHERE card_tid=? AND member_number<>? AND deleted=0",
        ).use {
            it.setString(1, cardTid)
            it.setString(2, memberNumber)
            it.executeQuery().use { rows ->
                buildList { while (rows.next()) add(readSubscriber(rows)) }
            }
        }

    private fun addEvent(
        operation: String,
        entityId: String,
        payload: String?,
        deviceId: String,
        entityType: String = EntityType.BOOK,
    ) {
        connection.prepareStatement(
            "INSERT INTO events(operation, entity_id, payload, device_id, created_at, entity_type) VALUES (?, ?, ?, ?, ?, ?)",
        ).use {
            it.setString(1, operation)
            it.setString(2, entityId)
            it.setString(3, payload)
            it.setString(4, deviceId)
            it.setString(5, Instant.now().toString())
            it.setString(6, entityType)
            it.executeUpdate()
        }
    }

    private fun bindBook(statement: java.sql.PreparedStatement, book: SyncBook) {
        val values = listOf(
            book.serverId, book.accession, book.epc, book.tid, book.title, book.author,
            book.isbn, book.publisher, book.publicationYear, book.category, book.shelf,
            book.notes, book.status, book.createdAt, book.updatedAt, book.taggedAt,
        )
        values.forEachIndexed { index, value -> statement.setString(index + 1, value) }
        statement.setLong(17, book.revision)
    }

    internal fun readBook(rows: java.sql.ResultSet) = SyncBook(
        serverId = rows.getString("server_id"),
        accession = rows.getString("accession"),
        epc = rows.getString("epc"),
        tid = rows.getString("tid"),
        title = rows.getString("title"),
        author = rows.getString("author"),
        isbn = rows.getString("isbn"),
        publisher = rows.getString("publisher"),
        publicationYear = rows.getString("publication_year"),
        category = rows.getString("category"),
        shelf = rows.getString("shelf"),
        notes = rows.getString("notes"),
        status = rows.getString("status"),
        createdAt = rows.getString("created_at"),
        updatedAt = rows.getString("updated_at"),
        taggedAt = rows.getString("tagged_at"),
        revision = rows.getLong("revision"),
    )

    internal fun readSubscriber(rows: java.sql.ResultSet) = SyncSubscriber(
        memberNumber = rows.getString("member_number"),
        name = rows.getString("name"),
        email = rows.getString("email"),
        phone = rows.getString("phone"),
        active = rows.getInt("active") != 0,
        cardEpc = rows.getString("card_epc"),
        cardTid = rows.getString("card_tid"),
        cardTaggedAt = rows.getString("card_tagged_at"),
        createdAt = rows.getString("created_at"),
        updatedAt = rows.getString("updated_at"),
        revision = rows.getLong("revision"),
    )

    override fun close() = connection.close()

    private companion object {
        val SUBSCRIPTION_STATUSES = setOf("active", "expired", "suspended")
        val PASSAGE_DIRECTIONS = setOf("in", "out")
        val DAY = Regex("^\\d{4}-\\d{2}-\\d{2}$")
    }
}
