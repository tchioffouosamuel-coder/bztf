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
