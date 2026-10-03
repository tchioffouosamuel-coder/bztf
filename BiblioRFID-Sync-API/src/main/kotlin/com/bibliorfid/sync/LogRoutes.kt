package com.bibliorfid.sync

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.call
import io.ktor.server.request.header
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import java.time.Instant

/** Ligne de log envoyée par un appareil : heure de l'appareil et texte. */
@Serializable
data class DeviceLogLine(val at: String = "", val line: String)

@Serializable
data class DeviceLogBatch(
    val deviceId: String,
    val name: String = "",
    val lines: List<DeviceLogLine> = emptyList(),
)

@Serializable
data class StoredLogLine(
    val id: Long,
    val receivedAt: String,
    val deviceId: String,
    val device: String,
    val at: String,
    val line: String,
)

@Serializable
data class LogPage(val lines: List<StoredLogLine>, val cursor: Long)

@Serializable
data class LogAccepted(val accepted: Int)

/**
 * Logs des appareils pour le débogage à distance : gardés en mémoire (les
 * [capacity] dernières lignes), perdus au redémarrage du service.
 */
class LogBuffer(private val capacity: Int = 5000) {
    private val lines = ArrayDeque<StoredLogLine>()
    private var nextId = 1L

    @Synchronized
    fun append(batch: DeviceLogBatch): Int {
        val receivedAt = Instant.now().toString()
        val deviceId = batch.deviceId.take(MAX_FIELD)
        val device = batch.name.ifBlank { deviceId }.take(MAX_FIELD)
        val accepted = batch.lines.takeLast(MAX_BATCH)
        for (line in accepted) {
            lines.addLast(
                StoredLogLine(
                    id = nextId++,
                    receivedAt = receivedAt,
                    deviceId = deviceId,
                    device = device,
                    at = line.at.take(MAX_FIELD),
                    line = line.line.take(MAX_LINE),
                ),
            )
        }
        while (lines.size > capacity) lines.removeFirst()
        return accepted.size
    }

    /** Lignes postérieures à [after], les plus anciennes d'abord. */
    @Synchronized
    fun read(after: Long, deviceId: String?, limit: Int): LogPage {
        val page = lines.asSequence()
            .filter { it.id > after && (deviceId.isNullOrBlank() || it.deviceId == deviceId) }
            .toList()
            .takeLast(limit.coerceIn(1, capacity))
        return LogPage(page, page.lastOrNull()?.id ?: maxOf(after, nextId - 1))
    }

    private companion object {
        const val MAX_BATCH = 1000
        const val MAX_LINE = 4000
        const val MAX_FIELD = 120
    }
}

/**
 * Envoi par les appareils (clé d'appareil) et lecture publique, sans clé :
 * page `/logs` rafraîchie en continu et `/api/v1/logs` en JSON. La lecture
 * publique se coupe avec `BIBLIORFID_PUBLIC_LOGS=false`.
 */
fun Route.logRoutes(logs: LogBuffer, apiKey: String, publicLogs: Boolean) {
    post("/api/v1/logs") {
        if (call.request.header("X-Device-Key") != apiKey) {
            call.respond(HttpStatusCode.Unauthorized, ErrorResponse("Clé d'appareil invalide."))
            return@post
        }
        call.respond(LogAccepted(logs.append(call.receive<DeviceLogBatch>())))
    }
    get("/api/v1/logs") {
        if (!publicLogs) {
            call.respond(HttpStatusCode.NotFound, ErrorResponse("Logs publics désactivés."))
            return@get
        }
        val parameters = call.request.queryParameters
        call.respond(
            logs.read(
                after = parameters["after"]?.toLongOrNull() ?: 0,
                deviceId = parameters["device"],
                limit = parameters["limit"]?.toIntOrNull() ?: 1000,
            ),
        )
    }
    get("/logs") {
        if (!publicLogs) {
            call.respond(HttpStatusCode.NotFound, ErrorResponse("Logs publics désactivés."))
            return@get
        }
        call.respondText(LOG_PAGE, ContentType.Text.Html)
    }
}

private val LOG_PAGE = """
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Logs BiblioRFID</title>
<style>
  :root { color-scheme: light dark; --bg: #f4f7fa; --fg: #152b3b; --muted: #637685; --line: #d6e1e8; --accent: #0b659e; }
  @media (prefers-color-scheme: dark) { :root { --bg: #0f1a22; --fg: #e3edf3; --muted: #8fa3b1; --line: #24343f; --accent: #55afe1; } }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; }
  header { position: sticky; top: 0; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 10px 16px; background: var(--bg); border-bottom: 1px solid var(--line); }
  h1 { font-size: 16px; margin: 0 12px 0 0; }
  input, select, button { font: inherit; padding: 4px 8px; border: 1px solid var(--line); border-radius: 6px; background: transparent; color: inherit; }
  #status { color: var(--muted); margin-left: auto; }
  pre { margin: 0; padding: 8px 16px 40px; font: 12px/1.45 ui-monospace, Consolas, monospace; white-space: pre-wrap; word-break: break-all; }
  .meta { color: var(--muted); }
  .gate { color: #c2410c; } .desk { color: #7c3aed; } .err { color: #dc2626; font-weight: 600; }
</style>
</head>
<body>
<header>
  <h1>Logs BiblioRFID</h1>
  <select id="device"><option value="">Tous les appareils</option></select>
  <input id="filter" placeholder="Filtrer (ex. Gate, Portail)">
  <button id="pause">Pause</button>
  <button id="clear">Effacer l’écran</button>
  <span id="status">Connexion…</span>
</header>
<pre id="out"></pre>
<script>
  const out = document.getElementById('out');
  const status = document.getElementById('status');
  const deviceSelect = document.getElementById('device');
  const filter = document.getElementById('filter');
  const pause = document.getElementById('pause');
  const devices = new Map();
  let cursor = 0, paused = false, all = [];

  function classOf(line) {
    if (/ E\/|Exception|error|Erreur|parsing error/i.test(line)) return 'err';
    if (/BiblioGate|Portail/.test(line)) return 'gate';
    if (/BiblioDeskReader|Poste/.test(line)) return 'desk';
    return '';
  }
  function visible(item) {
    const device = deviceSelect.value;
    const text = filter.value.trim().toLowerCase();
    return (!device || item.deviceId === device) && (!text || item.line.toLowerCase().includes(text));
  }
  function render(items, reset) {
    const atBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 40;
    if (reset) out.textContent = '';
    for (const item of items) {
      if (!visible(item)) continue;
      const row = document.createElement('div');
      const meta = document.createElement('span');
      meta.className = 'meta';
      meta.textContent = (item.at || item.receivedAt).replace('T', ' ').slice(0, 23) + ' [' + item.device + '] ';
      const text = document.createElement('span');
      text.className = classOf(item.line);
      text.textContent = item.line;
      row.append(meta, text);
      out.append(row);
    }
    if (atBottom) window.scrollTo(0, document.body.scrollHeight);
  }
  async function poll() {
    if (!paused) {
      try {
        const response = await fetch('/api/v1/logs?after=' + cursor + '&limit=2000');
        const page = await response.json();
        cursor = page.cursor;
        for (const item of page.lines) {
          if (!devices.has(item.deviceId)) {
            devices.set(item.deviceId, item.device);
            deviceSelect.add(new Option(item.device, item.deviceId));
          }
        }
        all = all.concat(page.lines).slice(-5000);
        render(page.lines, false);
        status.textContent = 'À jour ' + new Date().toLocaleTimeString();
      } catch (error) {
        status.textContent = 'Serveur injoignable, nouvel essai…';
      }
    }
    setTimeout(poll, 2000);
  }
  deviceSelect.onchange = filter.oninput = () => render(all, true);
  pause.onclick = () => { paused = !paused; pause.textContent = paused ? 'Reprendre' : 'Pause'; };
  document.getElementById('clear').onclick = () => { all = []; out.textContent = ''; };
  poll();
</script>
</body>
</html>
""".trimIndent()
