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
