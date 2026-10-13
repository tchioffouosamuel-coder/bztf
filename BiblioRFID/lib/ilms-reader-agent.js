import http from "node:http";
import { randomUUID, timingSafeEqual } from "node:crypto";

export const RFID_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEX = /^(?:[0-9A-F]{2})+$/;
const MAX_BODY = 4096;
const MAX_EVENTS = 256;
const EVENT_TTL_MS = 30000;

class AgentError extends Error {
  constructor(status, code) { super(code); this.status = status; }
}

function allowedOrigin(value) {
  const url = new URL(value);
  const local = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  if (value !== url.origin || (url.protocol !== "https:" && !(local && url.protocol === "http:"))) {
    throw new Error("Une origine ILMS HTTPS exacte (ou HTTP locale) est requise.");
  }
  return value;
}

function connectionFrom(value) {
  const type = value?.type;
  const endpoint = value?.endpoint ?? "";
  if (!value || Array.isArray(value) || Object.keys(value).some(key => !["type", "endpoint"].includes(key)) ||
      typeof endpoint !== "string" || endpoint.length > 512 || /[\x00-\x1F\x7F]/.test(endpoint)) {
    throw new AgentError(400, "invalid_connection");
  }
  if (type === "usb") return { type, endpoint: endpoint.trim() };
  if (type === "serial" && /^COM[1-9][0-9]{0,3}$/i.test(endpoint)) return { type, endpoint: endpoint.toUpperCase() };
  if (type === "tcp") {
    // IP literals on the local LAN only: never turn the agent into an HTTP/DNS proxy.
    const match = endpoint.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):([0-9]{1,5})$/);
    if (match) {
      const [, a, b, c, d, port] = match.map(Number);
      const privateIp = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
      if (privateIp && [a, b, c, d].every(n => n >= 0 && n <= 255) && port > 0 && port <= 65535) return { type, endpoint };
    }
  }
  throw new AgentError(400, "invalid_connection");
}

async function readJson(request) {
  if (request.headers["content-type"]?.split(";")[0].trim().toLowerCase() !== "application/json") {
    throw new AgentError(415, "json_required");
  }
  const chunks = await new Promise((resolve, reject) => {
    let size = 0;
    const received = [];
    const finish = (error) => {
      request.removeListener("data", data); request.removeListener("end", end);
      request.removeListener("error", failed); request.removeListener("aborted", aborted);
      if (error) { request.resume(); reject(error); }
      else resolve(received);
    };
    const data = chunk => {
      size += chunk.length;
      if (size > MAX_BODY) { finish(new AgentError(413, "body_too_large")); return; }
      received.push(chunk);
    };
    const end = () => finish();
    const failed = () => finish(new AgentError(400, "invalid_body"));
    const aborted = failed;
    request.on("data", data); request.once("end", end);
    request.once("error", failed); request.once("aborted", aborted);
  });
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw new AgentError(400, "invalid_json"); }
}

export function createIlmsReaderAgent({ reader, origin, token, deviceId, libraryId, now = Date.now }) {
  origin = allowedOrigin(origin);
  if (!/^[0-9a-f]{64}$/i.test(token ?? "")) throw new Error("Une cle locale de 32 octets en hexadecimal est requise.");
  if (!RFID_UUID.test(deviceId ?? "") || !RFID_UUID.test(libraryId ?? "")) throw new Error("UUID appareil et bibliotheque requis.");
  if (!reader?.on) throw new Error("Pont lecteur requis.");
  const expectedAuthorization = Buffer.from(`Bearer ${token}`);
  deviceId = deviceId.toLowerCase(); libraryId = libraryId.toLowerCase();
  let sessionId = null;
  let sequence = 0;
  let oldestCursor = 0;
  let events = [];
  let busy = false;
  let closed = false;
  let closePromise = null;
  const seen = new Map();

  const reset = () => {
    sessionId = null; events = []; seen.clear(); oldestCursor = sequence;
  };
  const prune = () => {
    const cutoff = now() - EVENT_TTL_MS;
    while (events.length && (events.length > MAX_EVENTS || events[0].timestamp < cutoff)) {
      oldestCursor = events.shift().sequence;
    }
    for (const [key, time] of seen) if (time < cutoff) seen.delete(key);
  };
  const onTag = raw => {
    if (!sessionId || !reader.connected || busy || closed) return;
    const epc = String(raw?.epc ?? raw?.Epc ?? "").trim().toUpperCase();
    const tid = String(raw?.tid ?? raw?.Tid ?? "").trim().toUpperCase();
    if ((!epc && !tid) || (epc && (!HEX.test(epc) || epc.length > 254)) || (tid && (!HEX.test(tid) || tid.length > 254))) return;
    prune();
    const key = `${epc}:${tid}`;
    const timestamp = now();
    if (seen.has(key) && timestamp - seen.get(key) < 750) return;
    seen.set(key, timestamp);
    if (seen.size > MAX_EVENTS) seen.delete(seen.keys().next().value);
    const rssi = raw.rssi ?? raw.Rssi;
    const antenna = raw.antenna ?? raw.Antenna;
    events.push({ sequence: ++sequence, timestamp, epc, tid,
      rssi: typeof rssi === "number" && Number.isFinite(rssi) ? rssi : null,
      antenna: Number.isInteger(antenna) ? antenna : null });
    prune();
  };
  reader.on("tag", onTag);
  reader.on("disconnected", reset);
  const status = () => ({ protocol_version: 1, device_id: deviceId, library_id: libraryId,
    capabilities: ["read"], connected: !!reader.connected && sessionId !== null,
    session_id: sessionId, cursor: sequence, busy });

  const server = http.createServer(async (request, response) => {
    const send = (code, value) => {
      response.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff" });
      response.end(value === undefined ? undefined : JSON.stringify(value));
    };
    try {
      const port = server.address()?.port;
      if (request.socket.remoteAddress !== "127.0.0.1" || request.headers.host !== `127.0.0.1:${port}`) throw new AgentError(403, "invalid_host");
      if (request.headers.origin !== origin) throw new AgentError(403, "invalid_origin");
      response.setHeader("Access-Control-Allow-Origin", origin);
      response.setHeader("Vary", "Origin");
      if (request.method === "OPTIONS") {
        if (!["GET", "POST"].includes(request.headers["access-control-request-method"])) throw new AgentError(403, "invalid_preflight");
        const headers = (request.headers["access-control-request-headers"] ?? "").toLowerCase().split(",").map(h => h.trim()).filter(Boolean);
        if (headers.some(h => !["authorization", "content-type"].includes(h))) throw new AgentError(403, "invalid_preflight");
        response.setHeader("Access-Control-Allow-Methods", "GET, POST");
        response.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
        if (request.headers["access-control-request-private-network"] === "true") response.setHeader("Access-Control-Allow-Private-Network", "true");
        send(204); return;
      }
      const authorization = Buffer.from(request.headers.authorization ?? "");
      if (authorization.length !== expectedAuthorization.length || !timingSafeEqual(authorization, expectedAuthorization)) {
        throw new AgentError(401, "local_authorization_required");
      }
      const url = new URL(request.url, "http://127.0.0.1");
      if (request.method === "GET" && url.pathname === "/v1/status") { send(200, status()); return; }
      if (request.method === "GET" && url.pathname === "/v1/reader/tags") {
        if (!sessionId || !reader.connected) throw new AgentError(409, "reader_disconnected");
        if (url.searchParams.get("session_id") !== sessionId) throw new AgentError(409, "reader_session_changed");
        const cursor = url.searchParams.get("after");
        if (!/^(?:0|[1-9][0-9]*)$/.test(cursor ?? "") || !Number.isSafeInteger(Number(cursor))) throw new AgentError(400, "invalid_cursor");
        prune();
        const after = Number(cursor);
        if (after < oldestCursor || after > sequence) throw new AgentError(409, "scan_window_lost");
        send(200, { ...status(), tags: events.filter(event => event.sequence > after).map(({ timestamp, ...event }) =>
          ({ ...event, received_at: new Date(timestamp).toISOString() })) }); return;
      }
      if (request.method === "POST" && ["/v1/reader/connect", "/v1/reader/disconnect"].includes(url.pathname)) {
        if (busy || closed) throw new AgentError(409, "reader_busy");
        busy = true;
        try {
          const input = await readJson(request);
          if (url.pathname.endsWith("/connect")) {
            const connection = connectionFrom(input);
            if (closed) throw new AgentError(503, "agent_stopped");
            reset();
            await reader.connect(connection);
            if (closed) { await reader.disconnect(); throw new AgentError(503, "agent_stopped"); }
            sessionId = randomUUID(); oldestCursor = sequence;
          } else {
            if (!input || typeof input !== "object" || Array.isArray(input) || Object.keys(input).length !== 0) throw new AgentError(400, "empty_object_required");
            reset(); await reader.disconnect();
          }
          busy = false;
          send(200, status());
        } finally { busy = false; }
        return;
      }
      throw new AgentError(404, "route_not_found");
    } catch (error) {
      request.resume();
      // Native errors can contain USB paths or diagnostics. Do not expose those to the browser.
      if (!response.headersSent && !response.destroyed) send(error instanceof AgentError ? error.status : 503,
        { error: error instanceof AgentError ? error.message : "reader_unavailable" });
    }
  });
  server.maxConnections = 16;
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return { server, status, close() {
    if (closePromise) return closePromise;
    closed = true; reset();
    reader.removeListener("tag", onTag); reader.removeListener("disconnected", reset);
    const stopped = server.listening ? new Promise(resolve => server.close(resolve)) : Promise.resolve();
    server.closeAllConnections();
    closePromise = Promise.allSettled([reader.shutdown(), stopped]).then(results => {
      const failure = results.find(result => result.status === "rejected");
      if (failure) throw failure.reason;
    });
    return closePromise;
  } };
}
