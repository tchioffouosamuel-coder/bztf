package com.bibliorfid.sync

import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.application.call
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.cors.routing.CORS
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.header
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.DefaultWebSocketSession
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import io.ktor.websocket.send
import io.ktor.websocket.close
import kotlinx.coroutines.channels.consumeEach
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap

private val wireJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = true
}

fun main() {
    val port = System.getenv("PORT")?.toIntOrNull() ?: 8080
    embeddedServer(Netty, host = "0.0.0.0", port = port) { module() }.start(wait = true)
}

fun Application.module(
    store: SyncStore = SyncStore(
        System.getenv("BIBLIORFID_DATABASE_URL") ?: "jdbc:sqlite:data/bibliorfid-sync.db",
        wireJson,
    ),
    apiKey: String = System.getenv("BIBLIORFID_API_KEY") ?: "change-me-in-production",
    readApiKey: String? = System.getenv("BIBLIORFID_READ_API_KEY"),
    logs: LogBuffer = LogBuffer(),
    publicLogs: Boolean = System.getenv("BIBLIORFID_PUBLIC_LOGS") != "false",
) {
    val keys = ApiKeys(apiKey, readApiKey)
    val data = DataQueries(store, wireJson)
    val sessions = ConcurrentHashMap.newKeySet<DefaultWebSocketSession>()
    val logger = environment.log
    install(CallLogging)
    install(ContentNegotiation) { json(wireJson) }
    install(WebSockets) {
        pingPeriodMillis = 20_000
        timeoutMillis = 15_000
        maxFrameSize = 1024 * 1024
    }
    install(CORS) {
        anyHost()
        allowMethod(HttpMethod.Get)
        allowMethod(HttpMethod.Post)
        allowHeader(HttpHeaders.ContentType)
        allowHeader("X-Device-Key")
        allowHeader("X-Device-Id")
        allowHeader("X-Api-Key")
        allowHeader(HttpHeaders.Authorization)
        exposeHeader("X-Total-Count")
    }
    install(StatusPages) {
        exception<IllegalArgumentException> { call, cause ->
            call.respond(HttpStatusCode.BadRequest, ErrorResponse(cause.message ?: "Requête invalide."))
        }
        exception<Throwable> { call, cause ->
            logger.error("Unhandled API error", cause)
            call.respond(HttpStatusCode.InternalServerError, ErrorResponse("Erreur interne du serveur."))
        }
    }

    suspend fun broadcast(cursor: Long) {
        val message = wireJson.encodeToString(EventSignal(cursor = cursor))
        sessions.toList().forEach { session ->
            try {
                session.send(message)
            } catch (_: Throwable) {
                sessions.remove(session)
            }
        }
    }

    routing {
        get("/health") {
            call.respond(HealthResponse("ok", "bibliorfid-sync-api", Instant.now().toString()))
        }
        logRoutes(logs, apiKey, publicLogs)
        route("/api/v1") {
            post("/devices/register") {
                if (!call.authorized(apiKey)) return@post
                call.respond(store.registerDevice(call.receive<DeviceRegistration>()))
            }
            dataRoutes(data, keys)
            get("/sync") {
                if (!call.authorized(apiKey)) return@get
                val since = call.request.queryParameters["since"]?.toLongOrNull() ?: 0
                val limit = call.request.queryParameters["limit"]?.toIntOrNull() ?: 500
                call.respond(store.pull(since, limit))
            }
            post("/sync/push") {
                if (!call.authorized(apiKey)) return@post
                val response = store.push(call.receive<PushRequest>())
                call.respond(response)
                broadcast(response.cursor)
            }
            webSocket("/events") {
                val suppliedKey = call.request.queryParameters["apiKey"] ?: call.request.header("X-Device-Key")
                if (suppliedKey != apiKey) {
                    close(io.ktor.websocket.CloseReason(io.ktor.websocket.CloseReason.Codes.VIOLATED_POLICY, "Clé invalide"))
                    return@webSocket
                }
                sessions += this
                send(wireJson.encodeToString(EventSignal(cursor = store.currentCursor())))
                try {
                    incoming.consumeEach { frame ->
                        if (frame is Frame.Text && frame.readText() == "ping") send("pong")
                    }
                } finally {
                    sessions -= this
                }
            }
        }
    }

    environment.monitor.subscribe(io.ktor.server.application.ApplicationStopped) {
        store.close()
    }
}

private suspend fun ApplicationCall.authorized(apiKey: String): Boolean {
    if (request.header("X-Device-Key") == apiKey) return true
    respond(HttpStatusCode.Unauthorized, ErrorResponse("Clé d'appareil invalide."))
    return false
}
