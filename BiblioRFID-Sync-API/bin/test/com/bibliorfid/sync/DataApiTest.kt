package com.bibliorfid.sync

import io.ktor.client.HttpClient
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
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.temporal.ChronoUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DataApiTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = true
    }

    private fun ApplicationTestBuilder.setup(): HttpClient {
        val store = SyncStore("jdbc:sqlite::memory:", json)
        application { module(store, "device-secret", "read-secret") }
        return createClient { install(ContentNegotiation) { json(json) } }
    }

    private suspend fun HttpClient.push(device: String, vararg mutations: Mutation) {
        val response = post("/api/v1/sync/push") {
            header("X-Device-Key", "device-secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(PushRequest(device, mutations.toList()))
        }
        assertEquals(HttpStatusCode.OK, response.status)
    }

    private suspend fun HttpClient.read(path: String) = get(path) { header("X-Api-Key", "read-secret") }

    private fun ago(days: Long) = Instant.now().minus(days, ChronoUnit.DAYS).toString()
    private fun ahead(days: Long) = Instant.now().plus(days, ChronoUnit.DAYS).toString()

    private suspend fun HttpClient.seed() {
        val now = Instant.now().toString()
        fun book(id: String, title: String, shelf: String) = SyncBook(
            serverId = id, accession = "BCM-2026-$id", epc = "EPC-$id", title = title,
            shelf = shelf, status = "encode", createdAt = now, updatedAt = now,
        )
        fun loan(id: String, book: String, member: String, borrowed: String, due: String, returned: String? = null) = SyncLoan(
            serverId = id, bookServerId = book, memberNumber = member, borrowedAt = borrowed, dueAt = due,
            returnedAt = returned, status = if (returned == null) "active" else "returned", createdAt = now, updatedAt = now,
        )
        push(
            "poste-1",
            Mutation("b1", "upsert", "B1", book("B1", "Atlas", "A-12")),
            Mutation("b2", "upsert", "B2", book("B2", "Botanique", "B-01")),
            Mutation("b3", "upsert", "B3", book("B3", "Chimie", "C-03")),
            Mutation(
                "s1", "upsert", "AB-1", entityType = EntityType.SUBSCRIBER,
                subscriber = SyncSubscriber("AB-1", "Awa Nkolo", cardTid = "E280", createdAt = now, updatedAt = now),
            ),
            Mutation(
                "s2", "upsert", "AB-2", entityType = EntityType.SUBSCRIBER,
                subscriber = SyncSubscriber("AB-2", "Paul Mba", active = false, createdAt = now, updatedAt = now),
            ),
            Mutation(
                "sub1", "upsert", "SUB-1", entityType = EntityType.SUBSCRIPTION,
                subscription = SyncSubscription("SUB-1", "AB-1", ago(30), ahead(300), createdAt = now, updatedAt = now),
            ),
            Mutation(
                "sub2", "upsert", "SUB-2", entityType = EntityType.SUBSCRIPTION,
                subscription = SyncSubscription("SUB-2", "AB-2", ago(400), ago(35), createdAt = now, updatedAt = now),
            ),
            Mutation("l1", "upsert", "L1", entityType = EntityType.LOAN, loan = loan("L1", "B1", "AB-1", ago(3), ahead(11))),
            Mutation("l2", "upsert", "L2", entityType = EntityType.LOAN, loan = loan("L2", "B2", "AB-1", ago(20), ago(6))),
            Mutation("l3", "upsert", "L3", entityType = EntityType.LOAN, loan = loan("L3", "B3", "AB-2", ago(40), ago(26), ago(20))),
            Mutation("l4", "upsert", "L4", entityType = EntityType.LOAN, loan = loan("L4", "B3", "AB-1", ago(15), ago(10), ago(12))),
        )
    }

    @Test
    fun `read key reads everything but cannot write`() = testApplication {
        val client = setup()
        assertEquals(HttpStatusCode.Unauthorized, client.get("/api/v1/books").status)
        assertEquals(HttpStatusCode.Unauthorized, client.get("/api/v1/books") { header("X-Api-Key", "faux") }.status)
        assertEquals(HttpStatusCode.OK, client.read("/api/v1/books").status)
        assertEquals(
            HttpStatusCode.OK,
            client.get("/api/v1/books") { header(HttpHeaders.Authorization, "Bearer read-secret") }.status,
        )
        assertEquals(HttpStatusCode.OK, client.get("/api/v1/books") { header("X-Device-Key", "device-secret") }.status)
        val write = client.post("/api/v1/devices/poste-1/report") {
            header("X-Api-Key", "read-secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(DeviceReport("poste-1"))
        }
        assertEquals(HttpStatusCode.Unauthorized, write.status)
        val push = client.post("/api/v1/sync/push") {
            header("X-Api-Key", "read-secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(PushRequest("x", emptyList()))
        }
        assertEquals(HttpStatusCode.Unauthorized, push.status)
    }

    @Test
    fun `books subscribers and subscriptions with filters and paging`() = testApplication {
        val client = setup()
        client.seed()

        val page = client.read("/api/v1/books?limit=2&offset=1")
        assertEquals("3", page.headers["X-Total-Count"])
        assertEquals(listOf("B2", "B3"), page.body<List<SyncBook>>().map { it.serverId })
        assertEquals(listOf("Atlas"), client.read("/api/v1/books?search=a-12").body<List<SyncBook>>().map { it.title })
        assertEquals("Botanique", client.read("/api/v1/books/B2").body<SyncBook>().title)
        assertEquals(HttpStatusCode.NotFound, client.read("/api/v1/books/INCONNU").status)
        assertEquals(2, client.read("/api/v1/books/B3/loans").body<List<LoanView>>().size)

        assertEquals(listOf("AB-1"), client.read("/api/v1/subscribers?active=true").body<List<SyncSubscriber>>().map { it.memberNumber })
        assertEquals(listOf("AB-2"), client.read("/api/v1/subscribers?hasCard=false").body<List<SyncSubscriber>>().map { it.memberNumber })
        assertEquals("Awa Nkolo", client.read("/api/v1/subscribers/ab-1").body<SyncSubscriber>().name)
        assertEquals(3, client.read("/api/v1/subscribers/AB-1/loans").body<List<LoanView>>().size)
        assertEquals(HttpStatusCode.BadRequest, client.read("/api/v1/subscribers?active=peut-etre").status)

        val current = client.read("/api/v1/subscriptions?current=true").body<List<SubscriptionView>>()
        assertEquals(listOf("SUB-1"), current.map { it.serverId })
        assertEquals("Awa Nkolo", current.single().subscriberName)
        assertTrue(current.single().current)
        assertFalse(client.read("/api/v1/subscriptions/SUB-2").body<SubscriptionView>().current)
        assertEquals(listOf("SUB-2"), client.read("/api/v1/subscribers/AB-2/subscriptions").body<List<SubscriptionView>>().map { it.serverId })

        val stats = client.read("/api/v1/stats").body<StatsView>()
        assertEquals(3, stats.books)
        assertEquals(2, stats.activeLoans)
        assertEquals(1, stats.overdueLoans)
        assertEquals(1, stats.currentSubscriptions)
    }

    @Test
    fun `loans and returns are enriched and filtered`() = testApplication {
        val client = setup()
        client.seed()

        val active = client.read("/api/v1/loans?status=active").body<List<LoanView>>()
        assertEquals(setOf("L1", "L2"), active.map { it.serverId }.toSet())
        val overdue = client.read("/api/v1/loans?status=overdue").body<List<LoanView>>().single()
        assertEquals("L2", overdue.serverId)
        assertTrue(overdue.overdue)
        assertEquals("Botanique", overdue.bookTitle)
        assertEquals("Awa Nkolo", overdue.subscriberName)
        assertEquals(HttpStatusCode.BadRequest, client.read("/api/v1/loans?status=perdu").status)
        assertEquals(listOf("L1"), client.read("/api/v1/loans?bookServerId=B1").body<List<LoanView>>().map { it.serverId })
        assertEquals("BCM-2026-B1", client.read("/api/v1/loans/L1").body<LoanView>().bookAccession)

        val returns = client.read("/api/v1/returns").body<List<LoanView>>()
        assertEquals(listOf("L4", "L3"), returns.map { it.serverId })
        // L3 : échéance il y a 26 jours, rendu il y a 20 jours.
        val late = client.read("/api/v1/returns?late=true").body<List<LoanView>>().single()
        assertEquals("L3", late.serverId)
        assertTrue(late.returnedLate)
        assertEquals(listOf("L4"), client.read("/api/v1/returns?late=false").body<List<LoanView>>().map { it.serverId })
        assertEquals(listOf("L3"), client.read("/api/v1/returns?memberNumber=ab-2").body<List<LoanView>>().map { it.serverId })
        assertEquals(listOf("L4"), client.read("/api/v1/returns?from=${ago(13)}").body<List<LoanView>>().map { it.serverId })
    }

    @Test
    fun `device reports expose accounts and activity without passwords`() = testApplication {
        val client = setup()
        client.seed()
        val now = Instant.now().toString()
        suspend fun report(report: DeviceReport) = client.post("/api/v1/devices/${report.deviceId}/report") {
            header("X-Device-Key", "device-secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(report)
        }
        val first = DeviceReport(
            deviceId = "poste-1",
            name = "Borne accueil",
            platform = "android",
            appVersion = "1.3.0",
            users = listOf(
                ReportedUser(1, "Admin", "Admin@BZTF.org", "admin", true, now, now),
                ReportedUser(2, "Agent", "agent@bztf.org", "operateur", false, now, now),
            ),
            activity = listOf(
                ReportedActivity(10, "emprunt", "succes", "Emprunt de Atlas", bookServerId = "B1", createdAt = ago(1)),
                ReportedActivity(11, "lecture", "succes", "Tag lu", epc = "EPC-B2", createdAt = now),
            ),
        )
        val response = report(first).body<DeviceReportResponse>()
        assertEquals(2, response.usersStored)
        assertEquals(11L, response.activityAcknowledgedUntil)
        // Rejouer le même rapport ne duplique rien.
        report(first)
        // L'appareil du rapport doit être celui de l'adresse.
        val mismatch = client.post("/api/v1/devices/poste-1/report") {
            header("X-Device-Key", "device-secret")
            header(HttpHeaders.ContentType, ContentType.Application.Json)
            setBody(first.copy(deviceId = "autre"))
        }
        assertEquals(HttpStatusCode.BadRequest, mismatch.status)

        val users = client.read("/api/v1/users?deviceId=poste-1")
        assertEquals("2", users.headers["X-Total-Count"])
        val admin = users.body<List<UserAccountView>>().first()
        assertEquals("admin@bztf.org", admin.email)
        assertEquals("Borne accueil", admin.deviceName)
        assertFalse(users.bodyAsText().contains("password", ignoreCase = true))
        assertEquals(listOf("agent@bztf.org"), client.read("/api/v1/users?active=false").body<List<UserAccountView>>().map { it.email })

        // Un compte supprimé sur le poste disparaît au rapport suivant.
        report(DeviceReport("poste-1", users = listOf(first.users!!.first())))
        assertEquals(1, client.read("/api/v1/devices/poste-1/users").body<List<UserAccountView>>().size)

        val activity = client.read("/api/v1/activity").body<List<ActivityView>>()
        assertEquals(listOf(11L, 10L), activity.map { it.localId })
        assertEquals("Atlas", activity.last().bookTitle)
        assertEquals(listOf(10L), client.read("/api/v1/activity?type=emprunt").body<List<ActivityView>>().map { it.localId })

        val device = client.read("/api/v1/devices/poste-1").body<DeviceView>()
        assertEquals("Borne accueil", device.name)
        assertEquals("android", device.platform)
        assertEquals(1, device.userCount)
        assertEquals(2, device.activityCount)
        assertTrue(device.changeCount > 0)
        assertEquals(HttpStatusCode.NotFound, client.read("/api/v1/devices/inconnu").status)
    }

    @Test
    fun `history lists changes and reads incrementally`() = testApplication {
        val client = setup()
        client.seed()
        val latest = client.read("/api/v1/history?limit=2")
        assertEquals("11", latest.headers["X-Total-Count"])
        val newest = latest.body<List<HistoryEntry>>()
        assertEquals(listOf(11L, 10L), newest.map { it.sequence })

        val bookHistory = client.read("/api/v1/history?entityType=book&entityId=B1").body<List<HistoryEntry>>()
        assertEquals("Atlas", bookHistory.single().change.book?.title)

        val incremental = client.read("/api/v1/history?since=9").body<List<HistoryEntry>>()
        assertEquals(listOf(10L, 11L), incremental.map { it.sequence })
        assertNull(incremental.first().change.book)
        assertEquals("poste-1", incremental.first().deviceId)
    }
}
