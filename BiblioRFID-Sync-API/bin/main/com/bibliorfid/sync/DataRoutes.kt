package com.bibliorfid.sync

import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.header
import io.ktor.server.request.receive
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post

/**
 * Accès de l'API de données. La clé d'appareil (`X-Device-Key`) peut tout
 * faire ; la clé de lecture, facultative, ne donne accès qu'aux routes GET.
 */
class ApiKeys(val deviceKey: String, val readKey: String?) {
    fun canRead(call: ApplicationCall): Boolean {
        if (call.request.header("X-Device-Key") == deviceKey) return true
        val key = readKey?.takeIf { it.isNotBlank() } ?: return false
        return call.request.header("X-Api-Key") == key ||
            call.request.header(HttpHeaders.Authorization) == "Bearer $key"
    }

    fun canWrite(call: ApplicationCall) = call.request.header("X-Device-Key") == deviceKey
}

/** Routes en lecture de toutes les données, et réception des rapports d'appareil. */
fun Route.dataRoutes(data: DataQueries, keys: ApiKeys, defaultLimit: Int = 100) {
    suspend fun ApplicationCall.readable(): Boolean {
        if (keys.canRead(this)) return true
        respond(HttpStatusCode.Unauthorized, ErrorResponse("Clé d'API invalide."))
        return false
    }

    get("/stats") {
        if (!call.readable()) return@get
        call.respond(data.stats())
    }

    get("/books") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(data.books(q.text("search"), q.text("status"), q.text("updatedSince"), q.paging(null)))
    }
    get("/books/{serverId}") {
        if (!call.readable()) return@get
        call.respondFound(data.book(call.parameters["serverId"].orEmpty()), "Livre")
    }
    get("/books/{serverId}/loans") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.loans(q.text("status"), null, call.parameters["serverId"], null, null, null, q.paging(null)),
        )
    }

    get("/subscribers") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.subscribers(q.text("search"), q.bool("active"), q.bool("hasCard"), q.text("updatedSince"), q.paging(null)),
        )
    }
    get("/subscribers/{memberNumber}") {
        if (!call.readable()) return@get
        call.respondFound(data.subscriber(call.parameters["memberNumber"].orEmpty()), "Abonné")
    }
    get("/subscribers/{memberNumber}/subscriptions") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.subscriptions(call.parameters["memberNumber"], q.text("status"), q.bool("current"), null, q.paging(null)),
        )
    }
    get("/subscribers/{memberNumber}/loans") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.loans(q.text("status"), call.parameters["memberNumber"], null, null, null, null, q.paging(null)),
        )
    }

    get("/subscriptions") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.subscriptions(q.text("memberNumber"), q.text("status"), q.bool("current"), q.text("updatedSince"), q.paging(null)),
        )
    }
    get("/subscriptions/{serverId}") {
        if (!call.readable()) return@get
        call.respondFound(data.subscription(call.parameters["serverId"].orEmpty()), "Abonnement")
    }

    get("/loans") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.loans(
                q.text("status"), q.text("memberNumber"), q.text("bookServerId"),
                q.text("from"), q.text("to"), q.text("updatedSince"), q.paging(null),
            ),
        )
    }
    get("/loans/{serverId}") {
        if (!call.readable()) return@get
        call.respondFound(data.loan(call.parameters["serverId"].orEmpty()), "Emprunt")
    }

    get("/returns") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.returns(
                q.text("memberNumber"), q.text("bookServerId"), q.text("from"), q.text("to"),
                q.bool("late"), q.paging(null),
            ),
        )
    }

    get("/devices") {
        if (!call.readable()) return@get
        call.respondPage(data.devices(call.query().paging(null)))
    }
    get("/devices/{deviceId}") {
        if (!call.readable()) return@get
        call.respondFound(data.device(call.parameters["deviceId"].orEmpty()), "Appareil")
    }
    get("/devices/{deviceId}/users") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(data.users(call.parameters["deviceId"], q.text("search"), q.text("role"), q.bool("active"), q.paging(null)))
    }
    post("/devices/{deviceId}/report") {
        if (!keys.canWrite(call)) {
            call.respond(HttpStatusCode.Unauthorized, ErrorResponse("Clé d'appareil invalide."))
            return@post
        }
        val report = call.receive<DeviceReport>()
        require(report.deviceId == call.parameters["deviceId"]) { "L'appareil du rapport ne correspond pas à l'adresse." }
        call.respond(data.receiveReport(report))
    }

    get("/users") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(data.users(q.text("deviceId"), q.text("search"), q.text("role"), q.bool("active"), q.paging(null)))
    }

    get("/activity") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.activity(
                q.text("deviceId"), q.text("type"), q.text("result"), q.text("bookServerId"),
                q.text("from"), q.text("to"), q.paging(defaultLimit),
            ),
        )
    }

    get("/history") {
        if (!call.readable()) return@get
        val q = call.query()
        call.respondPage(
            data.history(
                q.text("entityType"), q.text("entityId"), q.text("deviceId"),
                q.text("from"), q.text("to"), q.long("since"), q.paging(defaultLimit),
            ),
        )
    }
}

/** Listes : tableau JSON, total dans l'en-tête `X-Total-Count`. */
private suspend inline fun <reified T : Any> ApplicationCall.respondPage(page: Page<T>) {
    response.header("X-Total-Count", page.total.toString())
    respond(page.items)
}

private suspend inline fun <reified T : Any> ApplicationCall.respondFound(value: T?, what: String) {
    if (value == null) respond(HttpStatusCode.NotFound, ErrorResponse("$what introuvable."))
    else respond(value)
}

/** Paramètres de requête validés : une valeur invalide renvoie 400. */
private class Query(private val call: ApplicationCall) {
    private fun raw(name: String) = call.request.queryParameters[name]?.trim()?.takeIf { it.isNotEmpty() }

    fun text(name: String): String? = raw(name)

    fun bool(name: String): Boolean? = raw(name)?.let {
        when (it.lowercase()) {
            "true", "1", "oui" -> true
            "false", "0", "non" -> false
            else -> throw IllegalArgumentException("$name doit valoir true ou false.")
        }
    }

    fun long(name: String): Long? = raw(name)?.let {
        it.toLongOrNull() ?: throw IllegalArgumentException("$name doit être un nombre entier.")
    }

    /** `limit` absent : [defaultLimit] (nul = tout). */
    fun paging(defaultLimit: Int?): Paging {
        val limit = long("limit")?.toInt() ?: defaultLimit
        return Paging(limit, long("offset")?.toInt() ?: 0)
    }
}

private fun ApplicationCall.query() = Query(this)
