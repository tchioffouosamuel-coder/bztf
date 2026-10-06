package com.bibliorfid.sync

import io.ktor.client.call.body
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.testing.testApplication
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LogRoutesTest {
    @Test
    fun `devices send logs that anyone can read`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", logTestJson)
        application { module(store, "secret", logs = LogBuffer(capacity = 3)) }
        val client = createClient { install(ContentNegotiation) { json(logTestJson) } }
        val batch = DeviceLogBatch(
            deviceId = "gate-1",
            name = "Portail",
            lines = (1..4).map { DeviceLogLine("2026-10-03T10:00:0${it}Z", "ligne $it") },
        )

        val refused = client.post("/api/v1/logs") {
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(batch)
        }
        assertEquals(HttpStatusCode.Unauthorized, refused.status)

        val sent = client.post("/api/v1/logs") {
            header("X-Device-Key", "secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(batch)
        }
        assertEquals(4, sent.body<LogAccepted>().accepted)

        // Mémoire limitée : seules les dernières lignes restent.
        val page = client.get("/api/v1/logs").body<LogPage>()
        assertEquals(listOf("ligne 2", "ligne 3", "ligne 4"), page.lines.map { it.line })
        assertEquals("Portail", page.lines.first().device)
        val next = client.get("/api/v1/logs?after=${page.cursor}").body<LogPage>()
        assertTrue(next.lines.isEmpty())
        assertEquals(page.cursor, next.cursor)

        val html = client.get("/logs")
        assertEquals(HttpStatusCode.OK, html.status)
        assertTrue(html.bodyAsText().contains("Logs BiblioRFID"))
    }

    @Test
    fun `public reading can be disabled`() = testApplication {
        val store = SyncStore("jdbc:sqlite::memory:", logTestJson)
        application { module(store, "secret", publicLogs = false) }
        assertEquals(HttpStatusCode.NotFound, client.get("/logs").status)
        assertEquals(HttpStatusCode.NotFound, client.get("/api/v1/logs").status)
    }
}

private val logTestJson = kotlinx.serialization.json.Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = true
}
