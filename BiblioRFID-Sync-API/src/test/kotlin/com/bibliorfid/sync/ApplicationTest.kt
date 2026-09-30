package com.bibliorfid.sync

import io.ktor.client.call.body
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.websocket.WebSockets as ClientWebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.testing.testApplication
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import kotlin.test.Test
import kotlin.test.assertEquals

class ApplicationTest {
    @Test
    fun `push is idempotent and changes can be pulled`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val client = createClient { install(ContentNegotiation) { json(wireJsonForTests) } }
        val now = "2026-01-01T00:00:00Z"
        val book = SyncBook(
            serverId = "book-1",
            accession = "BCM-2026-000001",
            epc = "42434D0107EA000000000001",
            title = "Livre test",
            createdAt = now,
            updatedAt = now,
        )
        val request = PushRequest("reader-1", listOf(Mutation("mutation-1", "upsert", book.serverId, book)))

        repeat(2) {
            val response = client.post("/api/v1/sync/push") {
                header("X-Device-Key", "secret")
                header(HttpHeaders.ContentType, ContentType.Application.Json)
                setBody(request)
            }
            assertEquals(HttpStatusCode.OK, response.status)
        }

        val response = client.get("/api/v1/sync?since=0") { header("X-Device-Key", "secret") }
        val pull = response.body<PullResponse>()
        assertEquals(1, pull.changes.size)
        assertEquals("Livre test", pull.changes.single().book?.title)
        assertEquals(1, pull.changes.single().book?.revision)
    }

    @Test
    fun `subscribers and their cards are synchronized`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val client = createClient { install(ContentNegotiation) { json(wireJsonForTests) } }
        val now = "2026-01-01T00:00:00Z"
        suspend fun push(device: String, vararg mutations: Mutation) =
            client.post("/api/v1/sync/push") {
                header("X-Device-Key", "secret")
                header(HttpHeaders.ContentType, ContentType.Application.Json)
                setBody(PushRequest(device, mutations.toList()))
            }
        val first = SyncSubscriber(
            memberNumber = "ab-1",
            name = "Premier",
            cardEpc = "42434D02A1B2C3D4E5F60000",
            cardTid = "e2800000card",
            cardTaggedAt = now,
            createdAt = now,
            updatedAt = now,
        )
        assertEquals(
            HttpStatusCode.OK,
            push("desk", Mutation("m-1", "upsert", "AB-1", entityType = EntityType.SUBSCRIBER, subscriber = first)).status,
        )
        // La même carte est réencodée pour un autre abonné sur le mobile.
        val second = first.copy(memberNumber = "AB-2", name = "Second", cardEpc = "42434D02FFEEDDCCBBAA0000")
        push("mobile", Mutation("m-2", "upsert", "AB-2", entityType = EntityType.SUBSCRIBER, subscriber = second))

        val subscribers = client.get("/api/v1/subscribers") { header("X-Device-Key", "secret") }
            .body<List<SyncSubscriber>>()
            .associateBy { it.memberNumber }
        assertEquals(setOf("AB-1", "AB-2"), subscribers.keys)
        assertEquals(null, subscribers.getValue("AB-1").cardTid)
        assertEquals("E2800000CARD", subscribers.getValue("AB-2").cardTid)

        val pull = client.get("/api/v1/sync?since=0") { header("X-Device-Key", "secret") }.body<PullResponse>()
        assertEquals(listOf("AB-1", "AB-1", "AB-2"), pull.changes.map { it.entityId })
        assertEquals(true, pull.changes.all { it.entityType == EntityType.SUBSCRIBER && it.book == null })
        assertEquals(null, pull.changes[1].subscriber?.cardTid)
        assertEquals(2, pull.changes[1].subscriber?.revision)

        // Un ancien client (sans entityType) reste traité comme un livre.
        val legacy = client.post("/api/v1/sync/push") {
            header("X-Device-Key", "secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(
                """{"deviceId":"old","mutations":[{"mutationId":"m-3","operation":"upsert","entityId":"b-1",
                "book":{"serverId":"b-1","accession":"A","epc":"E","title":"Livre","createdAt":"$now","updatedAt":"$now"}}]}""",
            )
        }
        assertEquals(HttpStatusCode.OK, legacy.status)
        val last = client.get("/api/v1/sync?since=3") { header("X-Device-Key", "secret") }.body<PullResponse>()
        assertEquals(EntityType.BOOK, last.changes.single().entityType)
        assertEquals("Livre", last.changes.single().book?.title)
    }

    @Test
    fun `loans and subscriptions are synchronized with conflict rules`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val client = createClient { install(ContentNegotiation) { json(wireJsonForTests) } }
        val now = "2026-01-01T00:00:00Z"
        suspend fun push(device: String, vararg mutations: Mutation) =
            client.post("/api/v1/sync/push") {
                header("X-Device-Key", "secret")
                header(HttpHeaders.ContentType, ContentType.Application.Json)
                setBody(PushRequest(device, mutations.toList()))
            }
        val book = SyncBook(serverId = "book-1", accession = "A", epc = "E", title = "Livre", createdAt = now, updatedAt = now)
        val subscription = SyncSubscription(
            serverId = "sub-1",
            memberNumber = "ab-1",
            startsAt = now,
            endsAt = "2027-01-01T00:00:00Z",
            createdAt = now,
            updatedAt = now,
        )
        val first = SyncLoan(
            serverId = "loan-1",
            bookServerId = "book-1",
            memberNumber = "ab-1",
            subscriptionServerId = "sub-1",
            borrowedAt = "2026-01-02T10:00:00Z",
            dueAt = "2026-01-16T10:00:00Z",
            createdAt = now,
            updatedAt = now,
        )
        // Le lot arrive dans le désordre : le livre doit précéder l'emprunt.
        val response = push(
            "kiosk",
            Mutation("m-1", "upsert", "loan-1", entityType = EntityType.LOAN, loan = first),
            Mutation("m-2", "upsert", "sub-1", entityType = EntityType.SUBSCRIPTION, subscription = subscription),
            Mutation("m-3", "upsert", "book-1", book),
        )
        assertEquals(HttpStatusCode.OK, response.status)
        var pull = client.get("/api/v1/sync?since=0") { header("X-Device-Key", "secret") }.body<PullResponse>()
        assertEquals(
            listOf(EntityType.BOOK, EntityType.SUBSCRIPTION, EntityType.LOAN),
            pull.changes.map { it.entityType },
        )
        assertEquals("AB-1", pull.changes[1].subscription?.memberNumber)
        assertEquals("book-1", pull.changes[2].loan?.bookServerId)

        // Retour au poste, puis copie périmée (non rendue) envoyée par le mobile.
        val returned = first.copy(returnedAt = "2026-01-05T09:00:00Z", status = "returned")
        push("kiosk", Mutation("m-4", "upsert", "loan-1", entityType = EntityType.LOAN, loan = returned))
        push("mobile", Mutation("m-5", "upsert", "loan-1", entityType = EntityType.LOAN, loan = first.copy(notes = "Note")))
        var loans = client.get("/api/v1/loans") { header("X-Device-Key", "secret") }.body<List<SyncLoan>>()
        assertEquals("2026-01-05T09:00:00Z", loans.single().returnedAt)
        assertEquals("Note", loans.single().notes)

        // Deux emprunts actifs du même livre : le plus récent l'emporte.
        val older = first.copy(serverId = "loan-2", borrowedAt = "2026-02-01T10:00:00Z")
        val newer = first.copy(serverId = "loan-3", borrowedAt = "2026-02-03T10:00:00Z")
        push("mobile", Mutation("m-6", "upsert", "loan-3", entityType = EntityType.LOAN, loan = newer))
        push("kiosk", Mutation("m-7", "upsert", "loan-2", entityType = EntityType.LOAN, loan = older))
        loans = client.get("/api/v1/loans") { header("X-Device-Key", "secret") }.body<List<SyncLoan>>()
        val byId = loans.associateBy { it.serverId }
        assertEquals(null, byId.getValue("loan-3").returnedAt)
        assertEquals("2026-02-03T10:00:00Z", byId.getValue("loan-2").returnedAt)
        assertEquals(
            listOf("sub-1"),
            client.get("/api/v1/subscriptions") { header("X-Device-Key", "secret") }
                .body<List<SyncSubscription>>()
                .map { it.serverId },
        )
        pull = client.get("/api/v1/sync?since=0") { header("X-Device-Key", "secret") }.body<PullResponse>()
        assertEquals("loan-2", pull.changes.last().entityId)
        assertEquals("returned", pull.changes.last().loan?.status)
    }

    @Test
    fun `staff badges and gate activity are synchronized`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val client = createClient { install(ContentNegotiation) { json(wireJsonForTests) } }
        val now = "2026-09-30T07:00:00Z"
        suspend fun push(device: String, vararg mutations: Mutation) =
            client.post("/api/v1/sync/push") {
                header("X-Device-Key", "secret")
                header(HttpHeaders.ContentType, ContentType.Application.Json)
                setBody(PushRequest(device, mutations.toList()))
            }
        val alice = SyncStaff(
            serverId = "staff-1",
            staffNumber = "p-01",
            name = "Alice",
            position = "Bibliothécaire",
            badgeEpc = "42434D03A1B2C3D4E5F60000",
            badgeTid = "e2800000badge",
            badgeTaggedAt = now,
            createdAt = now,
            updatedAt = now,
        )
        assertEquals(
            HttpStatusCode.OK,
            push("desk", Mutation("s-1", "upsert", "staff-1", entityType = EntityType.STAFF, staff = alice)).status,
        )
        // Le même badge est réencodé pour Bruno : Alice le perd.
        val bruno = alice.copy(serverId = "staff-2", staffNumber = "P-02", name = "Bruno", badgeEpc = "42434D03FFEEDDCCBBAA0000")
        push("desk", Mutation("s-2", "upsert", "staff-2", entityType = EntityType.STAFF, staff = bruno))
        val staff = client.get("/api/v1/staff") { header("X-Device-Key", "secret") }.body<List<SyncStaff>>()
        assertEquals(listOf("Alice" to null, "Bruno" to "E2800000BADGE"), staff.map { it.name to it.badgeTid })
        assertEquals("P-01", staff.first().staffNumber)

        val day = SyncGateDay(serverId = "", gateId = "gate-1", gateName = "Entrée", day = "2026-09-30", entries = 12, exits = 9, alarms = 1, updatedAt = now)
        push("gate-1", Mutation("g-1", "upsert", "gate-1:2026-09-30", entityType = EntityType.GATE_DAY, gateDay = day))
        // Un portail réinstallé repart de zéro : les compteurs déjà reçus restent.
        push("gate-1", Mutation("g-2", "upsert", "gate-1:2026-09-30", entityType = EntityType.GATE_DAY, gateDay = day.copy(entries = 2, exits = 10, alarms = 0)))
        val days = client.get("/api/v1/gate-days?from=2026-09-01") { header("X-Device-Key", "secret") }.body<List<SyncGateDay>>()
        assertEquals(listOf(Triple(12, 10, 1)), days.map { Triple(it.entries, it.exits, it.alarms) })
        assertEquals("gate-1:2026-09-30", days.single().serverId)

        val passage = SyncStaffPassage(
            serverId = "pass-1", staffServerId = "staff-2", staffNumber = "P-02", staffName = "Bruno",
            direction = "in", passedAt = now, gateId = "gate-1", gateName = "Entrée", createdAt = now,
        )
        push("gate-1", Mutation("p-1", "upsert", "pass-1", entityType = EntityType.STAFF_PASSAGE, staffPassage = passage))
        assertEquals(
            HttpStatusCode.BadRequest,
            push("gate-1", Mutation("p-2", "upsert", "pass-2", entityType = EntityType.STAFF_PASSAGE, staffPassage = passage.copy(serverId = "pass-2", direction = "sideways"))).status,
        )
        val passages = client.get("/api/v1/staff/staff-2/passages") { header("X-Device-Key", "secret") }.body<List<SyncStaffPassage>>()
        assertEquals(listOf("in"), passages.map { it.direction })

        val pull = client.get("/api/v1/sync?since=0") { header("X-Device-Key", "secret") }.body<PullResponse>()
        assertEquals(
            listOf(EntityType.STAFF, EntityType.STAFF, EntityType.STAFF, EntityType.GATE_DAY, EntityType.GATE_DAY, EntityType.STAFF_PASSAGE),
            pull.changes.map { it.entityType },
        )
        assertEquals("Bruno", pull.changes.last().staffPassage?.staffName)
        assertEquals(12, pull.changes[4].gateDay?.entries)
        val history = client.get("/api/v1/history?entityType=staff_passage") { header("X-Device-Key", "secret") }
            .body<List<HistoryEntry>>()
        assertEquals("pass-1", history.single().change.staffPassage?.serverId)
    }

    @Test
    fun `registration exposes a stable database id and the cursor`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val client = createClient { install(ContentNegotiation) { json(wireJsonForTests) } }
        suspend fun register() = client.post("/api/v1/devices/register") {
            header("X-Device-Key", "secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(DeviceRegistration("poste-1", "Poste"))
        }.body<DeviceResponse>()
        val first = register()
        assertEquals(36, first.databaseId.length)
        assertEquals(0, first.cursor)
        val now = "2026-01-01T00:00:00Z"
        client.post("/api/v1/sync/push") {
            header("X-Device-Key", "secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(PushRequest("poste-1", listOf(Mutation("m-1", "upsert", "b-1", SyncBook("b-1", "A", "E", title = "T", createdAt = now, updatedAt = now)))))
        }
        val second = register()
        assertEquals(first.databaseId, second.databaseId)
        assertEquals(1, second.cursor)
        // Une base recréée a un autre identifiant.
        val other = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        kotlin.test.assertNotEquals(first.databaseId, other.databaseId)
    }

    @Test
    fun `private routes reject invalid keys`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        assertEquals(HttpStatusCode.Unauthorized, client.get("/api/v1/sync").status)
    }

    @Test
    fun `websocket reports the current cursor`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", wireJsonForTests)
        application { module(store, "secret") }
        val socketClient = createClient { install(ClientWebSockets) }

        socketClient.webSocket("/api/v1/events?apiKey=secret") {
            val frame = incoming.receive() as Frame.Text
            val signal = wireJsonForTests.decodeFromString<EventSignal>(frame.readText())
            assertEquals("changes", signal.type)
            assertEquals(0, signal.cursor)
        }
    }

    private companion object {
        val wireJsonForTests = kotlinx.serialization.json.Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = true
        }
    }
}
