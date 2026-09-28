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
            if ("entity_type" !in columns(statement, "events")) {
                statement.executeUpdate(
                    "ALTER TABLE events ADD COLUMN entity_type TEXT NOT NULL DEFAULT '${EntityType.BOOK}'",
                )
            }
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
        return DeviceResponse(registration.deviceId, true, now)
    }

    @Synchronized
    fun push(request: PushRequest): PushResponse {
        require(request.deviceId.isNotBlank()) { "L'identifiant de l'appareil est obligatoire." }
        require(request.mutations.size <= 500) { "Un lot ne peut pas dépasser 500 mutations." }
        val acknowledged = mutableListOf<String>()
        connection.autoCommit = false
        try {
            touchDevice(request.deviceId)
            request.mutations.forEach { mutation ->
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
                while (rows.next()) {
                    val payload = rows.getString("payload")
                    val entityType = rows.getString("entity_type")
                    changes += Change(
                        sequence = rows.getLong("sequence"),
                        operation = rows.getString("operation"),
                        entityId = rows.getString("entity_id"),
                        entityType = entityType,
                        book = payload?.takeIf { entityType == EntityType.BOOK }
                            ?.let { json.decodeFromString<SyncBook>(it) },
                        subscriber = payload?.takeIf { entityType == EntityType.SUBSCRIBER }
                            ?.let { json.decodeFromString<SyncSubscriber>(it) },
                        deviceId = rows.getString("device_id"),
                        createdAt = rows.getString("created_at"),
                    )
                }
            }
        }
        val hasMore = changes.size > limit
        val page = if (hasMore) changes.take(limit) else changes
        return PullResponse(page.lastOrNull()?.sequence ?: since, page, hasMore)
    }

    @Synchronized
    fun listBooks(): List<SyncBook> {
        val books = mutableListOf<SyncBook>()
        connection.prepareStatement("SELECT * FROM books WHERE deleted=0 ORDER BY accession").use { statement ->
            statement.executeQuery().use { rows ->
                while (rows.next()) books += readBook(rows)
            }
        }
        return books
    }

    @Synchronized
    fun listSubscribers(): List<SyncSubscriber> {
        val subscribers = mutableListOf<SyncSubscriber>()
        connection.prepareStatement("SELECT * FROM subscribers WHERE deleted=0 ORDER BY name").use { statement ->
            statement.executeQuery().use { rows ->
                while (rows.next()) subscribers += readSubscriber(rows)
            }
        }
        return subscribers
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

    private fun readBook(rows: java.sql.ResultSet) = SyncBook(
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

    private fun readSubscriber(rows: java.sql.ResultSet) = SyncSubscriber(
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
}
