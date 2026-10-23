import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import { LibraryDatabase } from "./lib/database.js";
import { ReaderService } from "./lib/reader-service.js";
import { SyncService } from "./lib/sync-service.js";
import {
  DEFAULT_READER_TIMING,
  bridgeSettingsSource,
  isTagRearmReady,
  isTagVisuallyReleased,
  normalizeReaderTiming,
  storedRearmDelayMs,
} from "./lib/reader-timing.js";
import { parseCatalogWorkbook } from "./lib/xlsx-import.js";
import { isBadgeEpc, isCardEpc, isValidEpc } from "./lib/epc.js";
import { CataloguingService } from "./lib/cataloguing/service.js";
import { handleCataloguingRequest } from "./lib/cataloguing/routes.js";
import {
  AGENT_EMPTY_EPC,
  AGENT_ERASE_PATH,
  AGENT_EVENTS_PATH,
  AGENT_KEY_HEADER,
  AGENT_WRITE_PATH,
  DEFAULT_AGENT_ORIGINS,
  agentHeaders,
  agentKeyAccepted,
  allowOrigin,
  generateAgentKey as buildAgentKey,
  normalizeEpcToWrite,
  parseAgentOrigins,
  publicSnapshot,
  readAgentBody,
  writeTarget,
} from "./lib/reader-agent.js";

const execFileAsync = promisify(execFile);
const root = path.dirname(fileURLToPath(import.meta.url));
const publicRoot = path.join(root, "public");
const nativeRoot = root.includes(`${path.sep}app.asar`)
  ? root.replace(`${path.sep}app.asar`, `${path.sep}app.asar.unpacked`)
  : root;
const bridgeRoot = process.env.BIBLIORFID_BRIDGE_DIR
  ? path.resolve(process.env.BIBLIORFID_BRIDGE_DIR)
  : path.join(nativeRoot, "bridge");
const bridgeExe = path.join(bridgeRoot, "bin", "ReaderBridge.exe");
const bridgeSource = path.join(bridgeRoot, "ReaderBridge.cs");
const bridgeSettingsPath = path.join(bridgeRoot, "BridgeSettings.cs");
const dataRoot = process.env.BIBLIORFID_DATA_DIR
  ? path.resolve(process.env.BIBLIORFID_DATA_DIR)
  : path.join(root, "data");
const db = new LibraryDatabase(path.join(dataRoot, "library.db"));
const syncService = new SyncService(db);
syncService.initialize();
const cataloguingService = new CataloguingService(db, { dataRoot });
// Photos abandonnées lors d'un catalogage interrompu : elles ne servent plus.
cataloguingService.purgeStaleCaptures(48);

const marker = "__RFID_JSON__";
const EMPTY_EPC = "000000000000000000000000";
let simulatedTag = {
  epc: "300833B2DDD9014000000001",
  tid: "E28068940000500A12AB0001",
  rssi: 62,
  antenna: 1,
};
const reader = new ReaderService(bridgeExe, marker);
const presentTags = new Map();
const stableTags = new Map();
const announcedTags = new Map();
const pendingActivityTags = new Set();
let presenceSessionId = 0;
const eventClients = new Set();
/** Les pages servies par la passerelle, abonnées à l'agent lecteur. */
const agentClients = new Set();
const presenceTimeoutMs = 450;
const visualReleaseDelayMs = 200;
const configuredRearmDelayMs = storedRearmDelayMs(
  db.getSetting("beep_rearm_ms", ""),
  db.getSetting("beep_rearm_seconds", ""),
);
let readerTiming = normalizeReaderTiming({
  beepMode: db.getSetting("beep_mode", DEFAULT_READER_TIMING.beepMode),
  beepDurationMs: Number(
    db.getSetting("beep_duration_ms", DEFAULT_READER_TIMING.beepDurationMs),
  ),
  rearmDelayMs: configuredRearmDelayMs,
});
const phoneCameraSessions = new Map();
const phoneCameraLifetimeMs = 30 * 60 * 1000;
if (db.getSetting("beep_rearm_ms", "") !== String(configuredRearmDelayMs))
  db.setSettings({ beep_rearm_ms: String(configuredRearmDelayMs) });
let beepRearmTimeoutMs = readerTiming.rearmDelayMs;
let readerStatus = { connected: false, status: "Déconnecté" };
let activeConnectionKey = "";
let connectionPromise = null;
let broadcastTimer = null;
let beepTimer = null;
let lastPresenceSignature = "";
let timingBuildPromise = null;

function normalizeTag(tag = {}) {
  return {
    epc: String(tag.epc ?? tag.Epc ?? "")
      .trim()
      .toUpperCase(),
    tid: String(tag.tid ?? tag.Tid ?? "")
      .trim()
      .toUpperCase(),
    rssi: Number(tag.rssi ?? tag.Rssi ?? 0),
    antenna: Number(tag.antenna ?? tag.Antenna ?? 0),
  };
}

function normalizeBridgePayload(payload) {
  if (Array.isArray(payload.tags))
    payload.tags = payload.tags.map(normalizeTag);
  if (payload.tag) payload.tag = normalizeTag(payload.tag);
  return payload;
}

function presenceKey(tag) {
  return tag.tid || tag.epc;
}

/**
 * Nature d'un tag d'après son EPC, même inconnu de ce poste (encodé sur un
 * autre appareil, pas encore synchronisé) : livre, carte d'abonné, badge du
 * personnel ou vierge.
 */
function tagKind(epc, book, subscriber, staff = null) {
  if (book) return "book";
  if (subscriber || isCardEpc(epc)) return "card";
  if (staff || isBadgeEpc(epc)) return "badge";
  return isValidEpc(epc) ? "book" : "blank";
}

function currentSnapshot({ raw = false } = {}) {
  const source = raw ? presentTags : stableTags;
  const tags = [...source.values()].map(({ tag }) => {
    const normalized = normalizeTag(tag);
    const book = db.recognizeTag(normalized.epc, normalized.tid);
    const subscriber = book
      ? null
      : publicSubscriber(db.recognizeCard(normalized.epc, normalized.tid));
    const staff =
      book || subscriber
        ? null
        : publicStaff(db.recognizeBadge(normalized.epc, normalized.tid));
    return {
      ...normalized,
      book,
      subscriber,
      staff,
      kind: tagKind(normalized.epc, book, subscriber, staff),
    };
  });
  const books = [
    ...new Map(
      tags.filter((tag) => tag.book).map((tag) => [tag.book.id, tag.book]),
    ).values(),
  ];
  return {
    ok: true,
    count: tags.length,
    tags,
    book: tags.length === 1 ? tags[0].book : null,
    subscriber: tags.length === 1 ? tags[0].subscriber : null,
    staff: tags.length === 1 ? tags[0].staff : null,
    books,
    unknownCount: tags.filter(
      (tag) => !tag.book && !tag.subscriber && !tag.staff,
    ).length,
    presenceSessionId,
    reader: readerStatus,
    mode: "continuous",
  };
}

function publicSubscriber(subscriber) {
  if (!subscriber) return null;
  return {
    id: subscriber.id,
    member_number: subscriber.member_number,
    name: subscriber.name,
    email: subscriber.email,
    phone: subscriber.phone,
  };
}

function publicStaff(staff) {
  if (!staff) return null;
  return {
    id: staff.id,
    staff_number: staff.staff_number,
    name: staff.name,
    position: staff.position,
  };
}

function sendEvent(response, event, payload) {
  response.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

function recordPresenceChange(snapshot, signature) {
  lastPresenceSignature = signature;
  if (!snapshot.tags.length) return;
  for (const tag of snapshot.tags) {
    const key = presenceKey(tag);
    if (!pendingActivityTags.delete(key)) continue;
    if (tag.subscriber) {
      db.addActivity(
        "lecture",
        "succes",
        null,
        `Carte d'abonné reconnue : ${tag.subscriber.name} (${tag.subscriber.member_number})`,
        tag.epc,
        tag.tid,
      );
      continue;
    }
    if (tag.staff) {
      db.addActivity(
        "lecture",
        "succes",
        null,
        `Badge du personnel reconnu : ${tag.staff.name} (${tag.staff.staff_number})`,
        tag.epc,
        tag.tid,
      );
      continue;
    }
    db.addActivity(
      "lecture",
      "succes",
      tag.book?.id || null,
      snapshot.tags.length > 1
        ? tag.book
          ? `Identification multiple : ${tag.book.accession}`
          : "Tag inconnu dans la lecture multiple"
        : tag.book
          ? `Livre reconnu : ${tag.book.accession}`
          : "Tag inconnu détecté",
      tag.epc,
      tag.tid,
    );
  }
}

function broadcastSnapshot(force = false) {
  const snapshot = currentSnapshot();
  const signature = snapshot.tags
    .map((tag) => `${tag.tid}:${tag.epc}`)
    .sort()
    .join("|");
  if (!force && signature === lastPresenceSignature) return;
  recordPresenceChange(snapshot, signature);
  for (const client of eventClients) sendEvent(client, "snapshot", snapshot);
  if (!agentClients.size) return;
  // L'agent ne voit que le matériel : l'instantané complet porte le livre, le
  // lecteur et le badge reconnus par la base LOCALE du poste, qui n'est pas la
  // référence du catalogue. Les laisser sortir ferait afficher à l'écran de la
  // passerelle un titre qu'elle ignore.
  const publique = publicSnapshot(snapshot);
  for (const client of agentClients) sendEvent(client, "snapshot", publique);
}

function scheduleBroadcast(delay = 140) {
  clearTimeout(broadcastTimer);
  broadcastTimer = setTimeout(() => broadcastSnapshot(), delay);
}

function scheduleBeep() {
  if (beepTimer || !reader.connected) return;
  beepTimer = setTimeout(async () => {
    beepTimer = null;
    try {
      await reader.beep();
    } catch (error) {
      console.error(`Buzzer RFID: ${error.message}`);
    }
  }, 80);
}

function handleReaderTag(rawTag) {
  const tag = normalizeTag(rawTag);
  const key = presenceKey(tag);
  if (!key) return;
  const now = Date.now();
  const alreadyAnnounced = announcedTags.has(key);
  if (!alreadyAnnounced && announcedTags.size === 0) presenceSessionId++;
  presentTags.set(key, { tag, lastSeen: now });
  stableTags.set(key, { tag, lastSeen: now });
  announcedTags.set(key, now);
  if (!alreadyAnnounced) {
    pendingActivityTags.add(key);
    scheduleBeep();
  }
  scheduleBroadcast();
}

function clearPresence() {
  presentTags.clear();
  stableTags.clear();
  announcedTags.clear();
  pendingActivityTags.clear();
  clearTimeout(beepTimer);
  beepTimer = null;
  clearTimeout(broadcastTimer);
  broadcastTimer = null;
  broadcastSnapshot(true);
}

async function ensureReaderConnection(connection) {
  const key = `${connection.type}:${connection.endpoint || ""}`;
  if (connection.type === "simulation") {
    if (reader.connected) await reader.disconnect();
    activeConnectionKey = key;
    readerStatus = {
      connected: true,
      status: "Simulation",
      reader: "Lecteur virtuel",
    };
    presentTags.clear();
    stableTags.clear();
    const simulatedPresence = {
      tag: simulatedTag,
      lastSeen: Number.POSITIVE_INFINITY,
    };
    presentTags.set(presenceKey(simulatedTag), simulatedPresence);
    stableTags.set(presenceKey(simulatedTag), simulatedPresence);
    broadcastSnapshot(true);
    return readerStatus;
  }
  if (reader.connected && activeConnectionKey === key) return readerStatus;
  if (connectionPromise) {
    await connectionPromise;
    if (reader.connected && activeConnectionKey === key) return readerStatus;
  }
  connectionPromise = (async () => {
    buildBridgeIfNeeded();
    readerStatus = { connected: false, status: "Connexion en cours" };
    clearPresence();
    const result = await reader.connect(connection);
    activeConnectionKey = key;
    readerStatus = {
      connected: true,
      status: result.status || connection.type.toUpperCase(),
      reader: result.reader || "Lecteur RFID",
      serialNumber: result.serialNumber || "",
      buzzerControlled: result.buzzerControlled === true,
    };
    broadcastSnapshot(true);
    return readerStatus;
  })();
  try {
    return await connectionPromise;
  } catch (error) {
    readerStatus = { connected: false, status: "Erreur", error: error.message };
    broadcastSnapshot(true);
    throw error;
  } finally {
    connectionPromise = null;
  }
}

reader.on("tag", handleReaderTag);
reader.on("connected", () => {
  if (presentTags.size) scheduleBeep();
});
reader.on("disconnected", () => {
  readerStatus = { connected: false, status: "Déconnecté" };
  activeConnectionKey = "";
  clearPresence();
});
reader.on("diagnostic", (message) => {
  const value = String(message || "").trim();
  if (value) console.error(`Pont RFID: ${value}`);
});

setInterval(() => {
  if (activeConnectionKey.startsWith("simulation:")) return;
  const now = Date.now();
  const cutoff = now - presenceTimeoutMs;
  for (const [key, entry] of presentTags) {
    if (entry.lastSeen < cutoff) presentTags.delete(key);
  }
  let stableChanged = false;
  for (const [key, entry] of stableTags) {
    if (
      !presentTags.has(key) &&
      isTagVisuallyReleased({
        lastSeen: entry.lastSeen,
        now,
        presenceTimeoutMs,
        visualReleaseDelayMs,
      })
    ) {
      stableChanged = stableTags.delete(key) || stableChanged;
    }
  }
  for (const [key, lastSeen] of announcedTags) {
    if (
      !presentTags.has(key) &&
      isTagRearmReady({
        lastSeen,
        now,
        rearmDelayMs: beepRearmTimeoutMs,
        presenceTimeoutMs,
        visualReleaseDelayMs,
      })
    ) {
      announcedTags.delete(key);
    }
  }
  if (stableChanged) broadcastSnapshot(true);
}, 120);

function buildBridgeIfNeeded() {
  const missing = !fs.existsSync(bridgeExe);
  const stale =
    !missing &&
    [bridgeSource, bridgeSettingsPath].some(
      (source) => fs.statSync(source).mtimeMs > fs.statSync(bridgeExe).mtimeMs,
    );
  if (!missing && !stale) return;
  compileBridge();
}

function compileBridge() {
  const result = spawnSync(
    "powershell",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      path.join(bridgeRoot, "build.ps1"),
    ],
    {
      cwd: bridgeRoot,
      encoding: "utf8",
    },
  );
  if (result.status !== 0)
    throw new Error(
      result.stderr || result.stdout || "Compilation du pont RFID impossible.",
    );
}

async function updateReaderTiming(input) {
  if (timingBuildPromise)
    throw new Error("Une compilation du pont RFID est déjà en cours.");
  const timing = normalizeReaderTiming(input, readerTiming);
  timingBuildPromise = (async () => {
    const previousSource = fs.readFileSync(bridgeSettingsPath, "utf8");
    const previousConnection = reader.connection
      ? { ...reader.connection }
      : null;
    await reader.shutdown();
    try {
      fs.writeFileSync(
        bridgeSettingsPath,
        bridgeSettingsSource(timing),
        "utf8",
      );
      compileBridge();
    } catch (error) {
      fs.writeFileSync(bridgeSettingsPath, previousSource, "utf8");
      try {
        compileBridge();
      } catch {}
      if (previousConnection) {
        try {
          await ensureReaderConnection(previousConnection);
        } catch {}
      }
      throw error;
    }

    readerTiming = timing;
    beepRearmTimeoutMs = timing.rearmDelayMs;
    db.setSettings({
      beep_mode: timing.beepMode,
      beep_duration_ms: String(timing.beepDurationMs),
      beep_rearm_ms: String(timing.rearmDelayMs),
    });

    let reconnectError = "";
    if (previousConnection) {
      try {
        await ensureReaderConnection(previousConnection);
      } catch (error) {
        reconnectError = error.message;
      }
    }
    return {
      ok: true,
      ...timing,
      compiledAt: new Date().toISOString(),
      command:
        "powershell -NoProfile -ExecutionPolicy Bypass -File bridge\\build.ps1",
      reconnected: previousConnection ? reader.connected : false,
      reconnectError,
    };
  })();
  try {
    return await timingBuildPromise;
  } finally {
    timingBuildPromise = null;
  }
}

async function runBridge(command, connection, extra = []) {
  buildBridgeIfNeeded();
  const args =
    command === "list"
      ? ["list"]
      : [command, connection.type, connection.endpoint || "", ...extra];
  try {
    const { stdout } = await execFileAsync(bridgeExe, args, {
      cwd: path.dirname(bridgeExe),
      timeout: 20000,
      windowsHide: true,
      maxBuffer: 1024 * 1024,
    });
    const line = stdout
      .split(/\r?\n/)
      .findLast((entry) => entry.startsWith(marker));
    if (!line)
      throw new Error("Le pilote n'a renvoyé aucune réponse exploitable.");
    return normalizeBridgePayload(JSON.parse(line.slice(marker.length)));
  } catch (error) {
    const output = `${error.stdout || ""}\n${error.stderr || ""}`;
    const line = output
      .split(/\r?\n/)
      .findLast((entry) => entry.startsWith(marker));
    if (line)
      return normalizeBridgePayload(JSON.parse(line.slice(marker.length)));
    throw new Error(
      error.killed
        ? "Le lecteur n'a pas répondu dans le délai prévu."
        : error.message,
    );
  }
}

function normalizeConnection(input = {}) {
  const type = ["usb", "serial", "tcp", "simulation"].includes(input.type)
    ? input.type
    : "usb";
  let endpoint = String(input.endpoint || "").trim();
  if (type === "serial" && endpoint && !endpoint.includes(":"))
    endpoint = `${endpoint}:115200`;
  if (type === "tcp" && endpoint && !endpoint.includes(":"))
    endpoint = `${endpoint}:6180`;
  return { type, endpoint };
}

async function readJsonBody(
  request,
  maximumSize = 1024 * 1024,
  message = "Requête trop volumineuse.",
) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximumSize) throw new Error(message);
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new Error("Corps JSON invalide.");
  }
}

async function readBody(request) {
  return readJsonBody(request);
}

async function readBinaryBody(request, maximumSize = 25 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximumSize)
      throw new Error("Le fichier XLSX dépasse la limite de 25 Mo.");
    chunks.push(chunk);
  }
  if (!chunks.length) throw new Error("Aucun fichier XLSX n'a été reçu.");
  return Buffer.concat(chunks);
}

function json(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}

const sessionCookieName = "bibliorfid_session";
const sessionLifetimeSeconds = 12 * 60 * 60;

function requestCookies(request) {
  return Object.fromEntries(
    String(request.headers.cookie || "")
      .split(";")
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const separator = part.indexOf("=");
        if (separator < 0) return [part, ""];
        return [
          decodeURIComponent(part.slice(0, separator)),
          decodeURIComponent(part.slice(separator + 1)),
        ];
      }),
  );
}

function sessionToken(request) {
  return requestCookies(request)[sessionCookieName] || "";
}

function setSessionCookie(response, token, maxAge = sessionLifetimeSeconds) {
  const value = encodeURIComponent(token || "");
  response.setHeader(
    "Set-Cookie",
    `${sessionCookieName}=${value}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}`,
  );
}

function csvCell(value) {
  return `"${String(value ?? "").replaceAll('"', '""')}"`;
}

function serveStatic(request, response, pathname) {
  const requested = pathname === "/" ? "index.html" : pathname.slice(1);
  const fullPath = path.resolve(publicRoot, requested);
  if (!fullPath.startsWith(path.resolve(publicRoot))) return false;
  if (!fs.existsSync(fullPath) || !fs.statSync(fullPath).isFile()) return false;
  const types = {
    ".html": "text/html",
    ".css": "text/css",
    ".js": "text/javascript",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".ico": "image/x-icon",
  };
  const extension = path.extname(fullPath);
  response.writeHead(200, {
    "Content-Type": `${types[extension] || "application/octet-stream"}; charset=utf-8`,
    "Cache-Control": [".html", ".js", ".css"].includes(extension)
      ? "no-cache, no-store, must-revalidate"
      : "public, max-age=3600",
  });
  fs.createReadStream(fullPath).pipe(response);
  return true;
}

function cleanupPhoneCameraSessions() {
  const now = Date.now();
  for (const [token, session] of phoneCameraSessions)
    if (session.expiresAt <= now) phoneCameraSessions.delete(token);
}

function networkHosts() {
  const hosts = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      hosts.push(entry.address);
    }
  }
  return [...new Set(hosts)];
}

function phoneCameraUrl(host, token) {
  return `http://${host}/phone-camera.html?token=${encodeURIComponent(token)}`;
}

function phoneCameraUrls(request, token) {
  const currentHost = String(request.headers.host || `127.0.0.1:${port}`);
  const hosts = [
    ...networkHosts().map((address) => `${address}:${port}`),
    currentHost,
  ];
  return [...new Set(hosts)].map((host) => phoneCameraUrl(host, token));
}

function createPhoneCameraSession(request, user) {
  cleanupPhoneCameraSessions();
  const token = randomBytes(24).toString("base64url");
  const now = Date.now();
  const session = {
    token,
    userId: user.id,
    createdAt: now,
    expiresAt: now + phoneCameraLifetimeMs,
    uploads: [],
  };
  phoneCameraSessions.set(token, session);
  const urls = phoneCameraUrls(request, token);
  return {
    token,
    url: urls[0],
    urls,
    expiresAt: new Date(session.expiresAt).toISOString(),
  };
}

function phoneCameraSession(token) {
  cleanupPhoneCameraSessions();
  return phoneCameraSessions.get(String(token || "")) || null;
}

function isAcceptedImageDataUrl(value) {
  return /^data:image\/(?:jpeg|png|webp);base64,[a-z0-9+/=\s]+$/i.test(
    String(value || ""),
  );
}

async function handlePhoneCameraPublicRequest(request, response, url) {
  const match = url.pathname.match(
    /^\/api\/cataloguing\/phone-camera\/([^/]+)\/uploads$/,
  );
  if (!match || request.method !== "POST") return false;
  const session = phoneCameraSession(decodeURIComponent(match[1]));
  if (!session)
    return json(response, 404, { error: "Lien caméra expiré ou inconnu." });
  try {
    const input = await readJsonBody(
      request,
      14 * 1024 * 1024,
      "L’image envoyée est trop volumineuse.",
    );
    if (!isAcceptedImageDataUrl(input.image))
      throw new Error("Image JPEG, PNG ou WebP attendue.");
    if (input.thumb && !isAcceptedImageDataUrl(input.thumb))
      throw new Error("Vignette JPEG, PNG ou WebP attendue.");
    if (session.uploads.length >= 20)
      throw new Error("Trop de photos en attente sur ce lien.");
    const kind = ["front", "back", "title", "other"].includes(input.kind)
      ? input.kind
      : "front";
    session.uploads.push({
      id: randomBytes(12).toString("base64url"),
      kind,
      image: input.image,
      thumb: input.thumb || input.image,
      name: String(input.name || "telephone").slice(0, 120),
      uploadedAt: new Date().toISOString(),
    });
    return json(response, 201, { ok: true, pending: session.uploads.length });
  } catch (error) {
    return json(response, 400, { error: error.message });
  }
}

/** Une clé d'appairage neuve, tirée du générateur du système. */
function generateAgentKey() {
  return buildAgentKey(randomBytes);
}

/** Les origines que l'agent sert, telles qu'elles sont réglées. */
function agentOrigins() {
  const regle = db.getSetting("agent_origins", "");
  return parseAgentOrigins(regle || DEFAULT_AGENT_ORIGINS);
}

/** Une réponse JSON de l'agent, avec les en-têtes de son origine. */
function agentJson(response, origine, status, payload) {
  response.writeHead(status, agentHeaders(origine, "application/json; charset=utf-8"));
  return response.end(JSON.stringify(payload));
}

/**
 * Écrire sur le tag posé : encoder, ou désencoder.
 *
 * <p>C'est la procédure sûre de `PROTOCOL.md`, et elle n'est pas raccourcie :
 * un seul tag, un TID, écriture, <b>relecture en filtrant ce TID</b>, et
 * validation sur égalité exacte. Une écriture non relue associerait un jour un
 * TID au mauvais livre, et c'est un bogue qui ne se voit que des mois plus
 * tard, quand un lecteur rend un livre qui en était un autre.
 *
 * <p>Ce que cette route ne fait pas, et ne doit pas faire : toucher au
 * catalogue local. Le poste n'est plus la référence du fonds. Il dit ce que
 * l'antenne a accepté ; c'est la passerelle qui enregistre, après quoi les
 * deux disent la même chose parce qu'une seule a écrit.
 */
async function agentWrite(request, response, url, origine) {
  if (!agentKeyAccepted(request.headers[AGENT_KEY_HEADER], db.getSetting("agent_key", ""))) {
    // Fermé par défaut : sans clé réglée sur le poste, aucune écriture ne
    // passe. Un poste mis à jour ne doit pas s'ouvrir tout seul.
    return agentJson(response, origine, 403, {
      ok: false,
      error:
        "Écriture refusée : clé d'appairage absente ou incorrecte. "
        + "Réglez la clé du poste et donnez-la à l'ILMS.",
    });
  }

  const desencodage = url.pathname === AGENT_ERASE_PATH;
  let corps;
  try {
    corps = await readAgentBody(request);
  } catch (error) {
    return agentJson(response, origine, 400, { ok: false, error: error.message });
  }

  const epc = desencodage ? AGENT_EMPTY_EPC : normalizeEpcToWrite(corps.epc);
  if (!epc) {
    return agentJson(response, origine, 400, {
      ok: false,
      error: "EPC invalide : 24 caractères hexadécimaux sont attendus.",
    });
  }

  try {
    // La connexion vient des réglages du poste, jamais de la demande : prise
    // de l'URL ou du corps, le port série et l'adresse du lecteur
    // deviendraient réglables à distance.
    await ensureReaderConnection(
      normalizeConnection({
        type: db.getSetting("connection_type", "usb"),
        endpoint: db.getSetting("connection_endpoint", ""),
      }),
    );

    const cible = writeTarget(currentSnapshot({ raw: true }));
    if (cible.error) {
      return agentJson(response, origine, 409, { ok: false, error: cible.error });
    }

    // Au désencodage, l'appelant peut dire quel tag il croit effacer. On le
    // vérifie plutôt que de l'ignorer : effacer le tag voisin de celui qu'on
    // visait rendrait un livre introuvable sans que personne le sache.
    const attendu = String(corps.tid ?? "").trim().toUpperCase();
    if (attendu && attendu !== cible.tag.tid) {
      return agentJson(response, origine, 409, {
        ok: false,
        error: "Le tag posé n'est pas celui attendu.",
      });
    }

    let resultat;
    if (reader.connection?.type === "simulation" || db.getSetting("connection_type", "usb") === "simulation") {
      simulatedTag = { ...simulatedTag, epc, tid: cible.tag.tid };
      resultat = { ok: true, verified: true, tag: { ...simulatedTag } };
    } else {
      resultat = normalizeBridgePayload(await reader.write(epc, cible.tag.tid));
    }

    if (!resultat.verified || resultat.tag?.epc !== epc || resultat.tag?.tid !== cible.tag.tid) {
      throw new Error("L'écriture n'a pas pu être vérifiée par relecture.");
    }

    // La présence suit le tag réécrit : son EPC vient de changer, et le laisser
    // sous son ancienne clé ferait apparaître deux tags là où il n'y en a qu'un.
    const ancienne = presenceKey(cible.tag);
    presentTags.delete(ancienne);
    stableTags.delete(ancienne);
    const presence = { tag: resultat.tag, lastSeen: Date.now() };
    presentTags.set(presenceKey(resultat.tag), presence);
    stableTags.set(presenceKey(resultat.tag), presence);
    broadcastSnapshot(true);

    db.addActivity(
      desencodage ? "desencodage" : "ecriture",
      "succes",
      null,
      "Demandé par l'ILMS",
      epc,
      resultat.tag.tid,
    );
    return agentJson(response, origine, 200, {
      ok: true,
      verified: true,
      tag: { epc: resultat.tag.epc, tid: resultat.tag.tid },
    });
  } catch (error) {
    db.addActivity(
      desencodage ? "desencodage" : "ecriture",
      "echec",
      null,
      error.message,
      epc,
      null,
    );
    // 503 et non 500 : le matériel n'a pas répondu comme attendu, et la
    // demande est rejouable une fois le tag reposé.
    return agentJson(response, origine, 503, { ok: false, error: error.message });
  }
}

/**
 * L'agent lecteur : la seule surface publique du poste.
 *
 * <p>Elle est placée <b>avant</b> la porte d'authentification, et c'est
 * volontaire : l'opérateur est authentifié par la passerelle, pas ici. C'est
 * donc le contrôle d'origine qui tient lieu de porte, et il doit rester la
 * première chose que fait cette fonction.
 *
 * <p>Lecture libre, écriture appairée. Le flux de présence ne demande que
 * l'origine ; encoder ou désencoder demande en plus la clé du poste, parce
 * qu'une écriture abîme un tag et qu'une lecture n'abîme rien. Les réglages du
 * lecteur, eux, restent derrière la session du poste : la connexion de
 * l'antenne n'a pas à être réglable à distance.
 */
function agent(request, response, url) {
  const origine = allowOrigin(request.headers.origin, agentOrigins());
  if (!origine) {
    // Sans en-tête `Access-Control-Allow-Origin`, le navigateur refusera de
    // toute façon la réponse ; le 403 est là pour que le journal du poste dise
    // franchement ce qui s'est passé.
    return json(response, 403, { error: "Origine non autorisée." });
  }

  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      ...agentHeaders(origine, "text/plain"),
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": `Content-Type, ${AGENT_KEY_HEADER}`,
      "Access-Control-Max-Age": "600",
    });
    return response.end();
  }

  if (
    request.method === "POST" &&
    (url.pathname === AGENT_WRITE_PATH || url.pathname === AGENT_ERASE_PATH)
  ) {
    return agentWrite(request, response, url, origine);
  }

  if (request.method !== "GET" || url.pathname !== AGENT_EVENTS_PATH) {
    response.writeHead(404, agentHeaders(origine, "application/json"));
    return response.end(JSON.stringify({ error: "Route inconnue." }));
  }

  response.writeHead(200, {
    ...agentHeaders(origine, "text/event-stream; charset=utf-8"),
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  response.flushHeaders?.();
  agentClients.add(response);
  sendEvent(response, "snapshot", publicSnapshot(currentSnapshot()));

  const keepAlive = setInterval(() => response.write(": ping\n\n"), 15000);
  request.on("close", () => {
    clearInterval(keepAlive);
    agentClients.delete(response);
  });

  // Le lecteur se connecte sur la connexion réglée du poste : la page distante
  // ne choisit pas le port série ni l'adresse du lecteur, qui sont des choses
  // du poste et resteraient réglables à distance si on les prenait de l'URL.
  ensureReaderConnection(
    normalizeConnection({
      type: db.getSetting("connection_type", "usb"),
      endpoint: db.getSetting("connection_endpoint", ""),
    }),
  )
    .then(() => sendEvent(response, "snapshot", publicSnapshot(currentSnapshot())))
    .catch((error) => sendEvent(response, "reader-error", { error: error.message }));
}

async function api(request, response, url) {
  const pathname = url.pathname;

  if (await handlePhoneCameraPublicRequest(request, response, url)) return;

  if (request.method === "GET" && pathname === "/api/auth/status") {
    const user = db.userForSession(sessionToken(request));
    return json(response, 200, {
      ...db.authStatus(),
      authenticated: Boolean(user),
      user,
    });
  }
  if (request.method === "POST" && pathname === "/api/auth/setup") {
    if (!db.authStatus().setupRequired)
      return json(response, 409, { error: "L’administrateur a déjà été créé." });
    const input = await readBody(request);
    let user;
    try {
      user = db.createUser({ ...input, role: "admin" });
    } catch (error) {
      return json(response, 400, { error: error.message });
    }
    const session = db.createSession(user.id);
    setSessionCookie(response, session.token);
    return json(response, 201, { authenticated: true, user });
  }
  if (request.method === "POST" && pathname === "/api/auth/login") {
    const input = await readBody(request);
    const user = db.authenticateUser(input.email, input.password);
    if (!user)
      return json(response, 401, { error: "Adresse e-mail ou mot de passe incorrect." });
    const session = db.createSession(user.id);
    setSessionCookie(response, session.token);
    return json(response, 200, { authenticated: true, user });
  }
  if (request.method === "POST" && pathname === "/api/auth/logout") {
    db.deleteSession(sessionToken(request));
    setSessionCookie(response, "", 0);
    return json(response, 200, { authenticated: false });
  }

  const user = db.userForSession(sessionToken(request));
  if (!user) return json(response, 401, { error: "Authentification requise." });
  request.authUser = user;
  if (request.method === "GET" && pathname === "/api/auth/me")
    return json(response, 200, { authenticated: true, user });

  if (pathname.startsWith("/api/cataloguing"))
    return handleCataloguingRequest({
      request,
      response,
      url,
      db,
      service: cataloguingService,
      json,
      readBody,
      user,
    });

  if (request.method === "POST" && pathname === "/api/phone-camera")
    return json(response, 201, createPhoneCameraSession(request, user));

  const phoneUploads = pathname.match(/^\/api\/phone-camera\/([^/]+)\/uploads$/);
  if (phoneUploads && request.method === "GET") {
    const session = phoneCameraSession(decodeURIComponent(phoneUploads[1]));
    if (!session || session.userId !== user.id)
      return json(response, 404, { error: "Lien caméra expiré ou inconnu." });
    const uploads = session.uploads.splice(0, session.uploads.length);
    return json(response, 200, {
      uploads,
      expiresAt: new Date(session.expiresAt).toISOString(),
    });
  }
  if (phoneUploads && request.method === "DELETE") {
    const session = phoneCameraSession(decodeURIComponent(phoneUploads[1]));
    if (session?.userId === user.id) phoneCameraSessions.delete(session.token);
    return json(response, 200, { ok: true });
  }

  if (request.method === "GET" && pathname === "/api/dashboard")
    return json(response, 200, db.dashboard());
  if (request.method === "POST" && pathname === "/api/import/xlsx") {
    const workbook = await parseCatalogWorkbook(await readBinaryBody(request));
    const imported = db.importBooks(workbook.records);
    return json(response, 200, {
      ok: true,
      ...imported,
      skipped: workbook.skipped,
      sheets: workbook.sheets,
    });
  }
  if (request.method === "GET" && pathname === "/api/books") {
    const query = {
      search: url.searchParams.get("search") || "",
      status: url.searchParams.get("status") || "tous",
      limit: url.searchParams.has("limit")
        ? url.searchParams.get("limit")
        : null,
      offset: url.searchParams.get("offset") || 0,
    };
    const books = db.listBooks(query);
    if (url.searchParams.get("paged") === "1") {
      return json(response, 200, { books, total: db.countBooks(query) });
    }
    return json(response, 200, books);
  }
  if (request.method === "POST" && pathname === "/api/books")
    return json(response, 201, db.createBook(await readBody(request)));
  if (request.method === "GET" && pathname === "/api/subscribers")
    return json(
      response,
      200,
      db.listSubscribers(url.searchParams.get("search") || ""),
    );
  if (request.method === "GET" && pathname === "/api/loans")
    return json(
      response,
      200,
      db.listLoans({
        filter: url.searchParams.get("filter") || "active",
        search: url.searchParams.get("search") || "",
      }),
    );
  if (request.method === "GET" && pathname === "/api/subscriptions")
    return json(
      response,
      200,
      db.listSubscriptions({
        filter: url.searchParams.get("filter") || "tous",
        search: url.searchParams.get("search") || "",
      }),
    );
  // Abonnés et abonnements : les erreurs de validation renvoient 400.
  const lending = async (status, action) => {
    try {
      return json(response, status, await action());
    } catch (error) {
      return json(response, 400, { error: error.message });
    }
  };
  if (request.method === "POST" && pathname === "/api/subscribers")
    return lending(201, async () => db.createSubscriber(await readBody(request)));
  const subscriberMatch = pathname.match(/^\/api\/subscribers\/(\d+)$/);
  if (subscriberMatch && request.method === "GET") {
    const details = db.getSubscriberDetails(subscriberMatch[1]);
    return details
      ? json(response, 200, details)
      : json(response, 404, { error: "Abonné introuvable." });
  }
  if (subscriberMatch && request.method === "PUT") {
    const input = await readBody(request);
    return lending(200, () => {
      const updated = db.updateSubscriber(subscriberMatch[1], input);
      if (!updated) throw new Error("Abonné introuvable.");
      return updated;
    });
  }
  if (subscriberMatch && request.method === "DELETE")
    return lending(200, () => {
      if (!db.deleteSubscriber(subscriberMatch[1]))
        throw new Error("Abonné introuvable.");
      return { ok: true };
    });
  const subscriberSubscriptionsMatch = pathname.match(
    /^\/api\/subscribers\/(\d+)\/subscriptions$/,
  );
  if (subscriberSubscriptionsMatch && request.method === "POST") {
    const input = await readBody(request);
    return lending(201, () =>
      db.createSubscription(subscriberSubscriptionsMatch[1], input),
    );
  }
  const subscriptionMatch = pathname.match(/^\/api\/subscriptions\/(\d+)$/);
  if (subscriptionMatch && request.method === "PUT") {
    const input = await readBody(request);
    return lending(200, () => {
      const updated = db.updateSubscription(subscriptionMatch[1], input);
      if (!updated) throw new Error("Abonnement introuvable.");
      return updated;
    });
  }
  if (subscriptionMatch && request.method === "DELETE")
    return lending(200, () => {
      if (!db.deleteSubscription(subscriptionMatch[1]))
        throw new Error("Abonnement introuvable.");
      return { ok: true };
    });
  // Personnel, badges et portails antivol.
  if (request.method === "GET" && pathname === "/api/staff")
    return json(response, 200, db.listStaff(url.searchParams.get("search") || ""));
  if (request.method === "POST" && pathname === "/api/staff")
    return lending(201, async () => db.createStaff(await readBody(request)));
  const staffMatch = pathname.match(/^\/api\/staff\/(\d+)$/);
  if (staffMatch && request.method === "GET") {
    const details = db.getStaffDetails(staffMatch[1]);
    return details
      ? json(response, 200, details)
      : json(response, 404, { error: "Membre du personnel introuvable." });
  }
  if (staffMatch && request.method === "PUT") {
    const input = await readBody(request);
    return lending(200, () => {
      const updated = db.updateStaff(staffMatch[1], input);
      if (!updated) throw new Error("Membre du personnel introuvable.");
      return updated;
    });
  }
  if (staffMatch && request.method === "DELETE")
    return lending(200, () => {
      if (!db.deleteStaff(staffMatch[1]))
        throw new Error("Membre du personnel introuvable.");
      return { ok: true };
    });
  if (request.method === "GET" && pathname === "/api/staff-passages") {
    const day = url.searchParams.get("day") || "";
    return json(response, 200, {
      passages: db.listStaffPassages({
        day,
        search: url.searchParams.get("search") || "",
      }),
      presence: db.staffPresence(day),
    });
  }
  if (request.method === "GET" && pathname === "/api/gate/stats")
    return json(
      response,
      200,
      db.gateStats({
        from: url.searchParams.get("from") || "",
        to: url.searchParams.get("to") || "",
      }),
    );

  if (request.method === "DELETE" && pathname === "/api/books") {
    const input = await readBody(request);
    if (!Array.isArray(input.ids) || !input.ids.length)
      return json(response, 400, { error: "Sélectionnez au moins un livre." });
    return json(response, 200, { ok: true, ...db.deleteBooks(input.ids) });
  }

  const bookMatch = pathname.match(/^\/api\/books\/(\d+)$/);
  const bookDetailsMatch = pathname.match(/^\/api\/books\/(\d+)\/details$/);
  if (bookDetailsMatch && request.method === "GET") {
    const details = db.getBookDetails(bookDetailsMatch[1]);
    return details
      ? json(response, 200, details)
      : json(response, 404, { error: "Livre introuvable." });
  }
  const borrowMatch = pathname.match(/^\/api\/books\/(\d+)\/borrow$/);
  if (borrowMatch && request.method === "POST") {
    const result = db.borrowBook(borrowMatch[1], await readBody(request));
    return json(response, 201, result);
  }
  const returnMatch = pathname.match(/^\/api\/books\/(\d+)\/return$/);
  if (returnMatch && request.method === "POST") {
    const result = db.returnBook(returnMatch[1]);
    return json(response, 200, result);
  }
  if (bookMatch && request.method === "GET") {
    const book = db.getBook(bookMatch[1]);
    return book
      ? json(response, 200, book)
      : json(response, 404, { error: "Livre introuvable." });
  }
  if (bookMatch && request.method === "PUT") {
    const book = db.updateBook(bookMatch[1], await readBody(request));
    return book
      ? json(response, 200, book)
      : json(response, 404, { error: "Livre introuvable." });
  }
  if (bookMatch && request.method === "DELETE") {
    return db.deleteBook(bookMatch[1])
      ? json(response, 200, { ok: true })
      : json(response, 404, { error: "Livre introuvable." });
  }

  if (request.method === "GET" && pathname === "/api/activity")
    return json(response, 200, db.activity(url.searchParams.get("limit")));
  if (request.method === "GET" && pathname === "/api/reader/timing") {
    return json(response, 200, {
      ...readerTiming,
      command:
        "powershell -NoProfile -ExecutionPolicy Bypass -File bridge\\build.ps1",
    });
  }
  if (request.method === "PUT" && pathname === "/api/reader/timing") {
    return json(
      response,
      200,
      await updateReaderTiming(await readBody(request)),
    );
  }
  if (request.method === "GET" && pathname === "/api/settings")
    return json(response, 200, db.settings());
  if (request.method === "PUT" && pathname === "/api/settings") {
    const input = await readBody(request);
    const connection = normalizeConnection(input);
    const reglages = {
      connection_type: connection.type,
      connection_endpoint: connection.endpoint,
    };
    // Les origines de l'agent se règlent ici, et elles se valident à
    // l'écriture : un réglage abîmé découvert au moment où l'ILMS appelle
    // coûterait une intervention sur place.
    if (typeof input.agent_origins === "string") {
      const origines = parseAgentOrigins(input.agent_origins);
      if (input.agent_origins.trim() && origines.length === 0) {
        return json(response, 400, {
          error:
            "Aucune origine valide : HTTPS exacte, ou HTTP en local seulement.",
        });
      }
      reglages.agent_origins = origines.join(" ");
    }
    db.setSettings(reglages);
    return json(response, 200, db.settings());
  }

  // La clé d'appairage de l'agent : remise UNE SEULE FOIS, comme la clé de
  // secours de la 3.0. Elle se note, se colle dans l'ILMS, et ne se relit
  // plus — une clé relisible finit dans une capture d'écran de dépannage.
  if (request.method === "POST" && pathname === "/api/agent/key") {
    const cle = generateAgentKey();
    db.setSettings({ agent_key: cle });
    db.addActivity("agent", "succes", null, "Clé d'appairage de l'agent renouvelée");
    return json(response, 200, {
      key: cle,
      note: "Notez cette clé : elle ne sera plus affichée.",
    });
  }

  if (request.method === "DELETE" && pathname === "/api/agent/key") {
    // Retirer la clé referme l'écriture : c'est le geste à faire quand un
    // poste quitte le service, et il ne doit pas demander de réfléchir.
    db.setSettings({ agent_key: "" });
    db.addActivity("agent", "succes", null, "Clé d'appairage retirée : écriture fermée");
    return json(response, 200, { ok: true });
  }
  if (request.method === "GET" && pathname === "/api/sync/status")
    return json(response, 200, syncService.status());
  if (request.method === "PUT" && pathname === "/api/sync/settings") {
    try {
      const status = await syncService.configure(await readBody(request));
      return json(response, 200, status);
    } catch (error) {
      return json(response, 400, { error: error.message });
    }
  }
  if (request.method === "POST" && pathname === "/api/sync/run") {
    const status = await syncService.syncNow();
    return json(response, 200, status);
  }

  if (request.method === "GET" && pathname === "/api/devices") {
    const result = await runBridge("list", { type: "usb", endpoint: "" });
    return json(response, result.ok ? 200 : 503, result);
  }

  if (request.method === "GET" && pathname === "/api/reader/events") {
    const connection = normalizeConnection({
      type: url.searchParams.get("type") || "usb",
      endpoint: url.searchParams.get("endpoint") || "",
    });
    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-store",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    response.flushHeaders?.();
    eventClients.add(response);
    sendEvent(response, "snapshot", currentSnapshot());
    const keepAlive = setInterval(() => response.write(": ping\n\n"), 15000);
    request.on("close", () => {
      clearInterval(keepAlive);
      eventClients.delete(response);
    });
    ensureReaderConnection(connection)
      .then(() => sendEvent(response, "snapshot", currentSnapshot()))
      .catch((error) =>
        sendEvent(response, "reader-error", { error: error.message }),
      );
    return;
  }

  if (request.method === "POST" && pathname === "/api/reader/probe") {
    const connection = normalizeConnection(await readBody(request));
    try {
      const result = await ensureReaderConnection(connection);
      db.addActivity(
        "connexion",
        "succes",
        null,
        `Lecteur connecté en ${connection.type.toUpperCase()}`,
      );
      return json(response, 200, { ok: true, ...result });
    } catch (error) {
      db.addActivity("connexion", "echec", null, error.message);
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  if (request.method === "POST" && pathname === "/api/reader/beep-test") {
    const connection = normalizeConnection(await readBody(request));
    try {
      await ensureReaderConnection(connection);
      const result = await reader.beep();
      return json(response, result.ok ? 200 : 503, result);
    } catch (error) {
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  if (request.method === "POST" && pathname === "/api/reader/scan") {
    const input = await readBody(request);
    const connection = normalizeConnection(input);
    await ensureReaderConnection(connection);
    return json(response, 200, currentSnapshot());
  }

  const writeMatch = pathname.match(/^\/api\/books\/(\d+)\/write-tag$/);
  if (writeMatch && request.method === "POST") {
    const book = db.getBook(writeMatch[1]);
    if (!book) return json(response, 404, { error: "Livre introuvable." });
    const connection = normalizeConnection(await readBody(request));
    let result;
    try {
      await ensureReaderConnection(connection);
      const snapshot = currentSnapshot({ raw: true });
      if (snapshot.count === 0)
        return json(response, 409, {
          ok: false,
          error: "Aucun tag détecté. Posez un seul livre sur le lecteur.",
        });
      if (snapshot.count > 1)
        return json(response, 409, {
          ok: false,
          error: "Plusieurs tags détectés. Isolez le livre à encoder.",
        });
      const target = snapshot.tags[0];
      if (!target.tid)
        return json(response, 409, {
          ok: false,
          error:
            "Le tag ne fournit pas de TID; l'écriture sécurisée est annulée.",
        });
      const card = db.recognizeCard(target.epc, target.tid);
      if (card)
        return json(response, 409, {
          ok: false,
          error: `Ce tag est la carte de l'abonné ${card.name}. Utilisez un tag de livre.`,
        });
      if (target.staff || target.kind === "badge")
        return json(response, 409, {
          ok: false,
          error: target.staff
            ? `Ce tag est le badge de ${target.staff.name}. Utilisez un tag de livre.`
            : "Ce tag est un badge du personnel. Utilisez un tag de livre.",
        });
      if (connection.type === "simulation") {
        simulatedTag = { ...simulatedTag, epc: book.epc, tid: target.tid };
        result = {
          ok: true,
          verified: true,
          status: "Simulation",
          tag: simulatedTag,
        };
      } else {
        result = normalizeBridgePayload(
          await reader.write(book.epc, target.tid),
        );
      }
      const updated = db.markTagged(book.id, result.tag.tid);
      const oldKey = presenceKey(target);
      presentTags.delete(oldKey);
      stableTags.delete(oldKey);
      const writtenPresence = { tag: result.tag, lastSeen: Date.now() };
      presentTags.set(presenceKey(result.tag), writtenPresence);
      stableTags.set(presenceKey(result.tag), writtenPresence);
      broadcastSnapshot(true);
      return json(response, 200, { ...result, book: updated });
    } catch (error) {
      db.addActivity(
        "ecriture",
        "echec",
        book.id,
        error.message,
        book.epc,
        null,
      );
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  const eraseMatch = pathname.match(/^\/api\/books\/(\d+)\/erase-tag$/);
  if (eraseMatch && request.method === "POST") {
    const book = db.getBook(eraseMatch[1]);
    if (!book) return json(response, 404, { error: "Livre introuvable." });
    if (book.status !== "encode" || !book.tid)
      return json(response, 409, {
        error: "Ce livre n'a pas de tag encodé associé.",
      });
    const connection = normalizeConnection(await readBody(request));
    try {
      await ensureReaderConnection(connection);
      const snapshot = currentSnapshot({ raw: true });
      if (snapshot.count === 0)
        return json(response, 409, {
          ok: false,
          error: "Aucun tag détecté. Posez le tag du livre sur le lecteur.",
        });
      if (snapshot.count > 1)
        return json(response, 409, {
          ok: false,
          error: "Plusieurs tags détectés. Isolez le tag à désencoder.",
        });
      const target = snapshot.tags[0];
      if (target.tid !== book.tid || target.epc !== book.epc) {
        return json(response, 409, {
          ok: false,
          error: "Le tag détecté ne correspond pas à ce livre.",
        });
      }
      let result;
      if (connection.type === "simulation") {
        simulatedTag = { ...simulatedTag, epc: EMPTY_EPC };
        result = { ok: true, verified: true, tag: simulatedTag };
      } else {
        result = normalizeBridgePayload(
          await reader.write(EMPTY_EPC, target.tid),
        );
      }
      if (
        !result.verified ||
        result.tag?.epc !== EMPTY_EPC ||
        result.tag?.tid !== book.tid
      ) {
        throw new Error(
          "Le désencodage n'a pas pu être vérifié par relecture.",
        );
      }
      const updated = db.markUntagged(book.id);
      const oldKey = presenceKey(target);
      presentTags.delete(oldKey);
      stableTags.delete(oldKey);
      const erasedPresence = { tag: result.tag, lastSeen: Date.now() };
      presentTags.set(presenceKey(result.tag), erasedPresence);
      stableTags.set(presenceKey(result.tag), erasedPresence);
      broadcastSnapshot(true);
      return json(response, 200, { ...result, book: updated });
    } catch (error) {
      db.addActivity(
        "desencodage",
        "echec",
        book.id,
        error.message,
        book.epc,
        book.tid,
      );
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  // Tag encodé sur un autre poste (livre, carte ou badge absent d'ici) :
  // effacé sans passer par le catalogue, pour pouvoir le réutiliser.
  if (request.method === "POST" && pathname === "/api/reader/erase-foreign") {
    const input = await readBody(request);
    const connection = normalizeConnection(input);
    const expectedEpc = String(input.epc || "").trim().toUpperCase();
    const expectedTid = String(input.tid || "").trim().toUpperCase();
    try {
      await ensureReaderConnection(connection);
      const snapshot = currentSnapshot({ raw: true });
      if (snapshot.count === 0)
        return json(response, 409, {
          ok: false,
          error: "Aucun tag détecté. Posez le tag à désencoder sur le lecteur.",
        });
      if (snapshot.count > 1)
        return json(response, 409, {
          ok: false,
          error: "Plusieurs tags détectés. Isolez le tag à désencoder.",
        });
      const target = snapshot.tags[0];
      if (!target.tid)
        return json(response, 409, {
          ok: false,
          error: "Le tag ne fournit pas de TID; le désencodage sécurisé est annulé.",
        });
      if (target.epc !== expectedEpc || target.tid !== expectedTid)
        return json(response, 409, {
          ok: false,
          error: "Le tag posé n'est plus celui affiché. Recommencez.",
        });
      if (target.book || target.subscriber || target.staff)
        return json(response, 409, {
          ok: false,
          error:
            "Ce tag est connu de ce poste : désencodez-le depuis sa fiche.",
        });
      if (!["book", "card", "badge"].includes(target.kind))
        return json(response, 409, {
          ok: false,
          error: "Ce tag n'est pas encodé : il n'y a rien à effacer.",
        });
      let result;
      if (connection.type === "simulation") {
        simulatedTag = { ...simulatedTag, epc: EMPTY_EPC };
        result = { ok: true, verified: true, tag: simulatedTag };
      } else {
        result = normalizeBridgePayload(
          await reader.write(EMPTY_EPC, target.tid),
        );
      }
      if (
        !result.verified ||
        result.tag?.epc !== EMPTY_EPC ||
        result.tag?.tid !== target.tid
      )
        throw new Error("Le désencodage n'a pas pu être vérifié par relecture.");
      db.addActivity(
        "desencodage",
        "succes",
        null,
        `Tag d'un autre poste désencodé (${{ book: "livre", card: "carte d'abonné", badge: "badge du personnel" }[target.kind]})`,
        target.epc,
        target.tid,
      );
      const oldKey = presenceKey(target);
      presentTags.delete(oldKey);
      stableTags.delete(oldKey);
      const erasedPresence = { tag: result.tag, lastSeen: Date.now() };
      presentTags.set(presenceKey(result.tag), erasedPresence);
      stableTags.set(presenceKey(result.tag), erasedPresence);
      broadcastSnapshot(true);
      return json(response, 200, result);
    } catch (error) {
      db.addActivity(
        "desencodage",
        "echec",
        null,
        `Tag d'un autre poste : ${error.message}`,
        expectedEpc,
        expectedTid,
      );
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  if (request.method === "POST" && pathname === "/api/subscribers/card") {
    const input = await readBody(request);
    const connection = normalizeConnection(input);
    let subscriber;
    try {
      subscriber = db.upsertSubscriber(input);
    } catch (error) {
      return json(response, 400, { ok: false, error: error.message });
    }
    try {
      await ensureReaderConnection(connection);
      const snapshot = currentSnapshot({ raw: true });
      if (snapshot.count === 0)
        return json(response, 409, {
          ok: false,
          error: "Aucun tag détecté. Posez la carte de l'abonné sur le lecteur.",
        });
      if (snapshot.count > 1)
        return json(response, 409, {
          ok: false,
          error: "Plusieurs tags détectés. Isolez la carte à encoder.",
        });
      const target = snapshot.tags[0];
      if (!target.tid)
        return json(response, 409, {
          ok: false,
          error:
            "Le tag ne fournit pas de TID; l'écriture sécurisée est annulée.",
        });
      if (target.book)
        return json(response, 409, {
          ok: false,
          error: `Ce tag appartient au livre ${target.book.accession}. Utilisez une carte vierge.`,
        });
      if (target.subscriber && target.subscriber.id !== subscriber.id)
        return json(response, 409, {
          ok: false,
          error: `Ce tag est déjà la carte de ${target.subscriber.name}.`,
        });
      if (target.staff || target.kind === "badge")
        return json(response, 409, {
          ok: false,
          error: target.staff
            ? `Ce tag est le badge de ${target.staff.name}. Utilisez une carte vierge.`
            : "Ce tag est un badge du personnel. Utilisez une carte vierge.",
        });
      if (target.kind === "book")
        return json(response, 409, {
          ok: false,
          error:
            "Ce tag est un livre encodé sur un autre poste. Utilisez une carte vierge.",
        });
      if (!target.subscriber && target.kind === "card" && target.epc !== subscriber.card_epc)
        return json(response, 409, {
          ok: false,
          error:
            "Ce tag est la carte d'un autre abonné, pas encore synchronisée sur ce poste.",
        });
      let result;
      if (connection.type === "simulation") {
        simulatedTag = {
          ...simulatedTag,
          epc: subscriber.card_epc,
          tid: target.tid,
        };
        result = { ok: true, verified: true, tag: simulatedTag };
      } else {
        result = normalizeBridgePayload(
          await reader.write(subscriber.card_epc, target.tid),
        );
      }
      if (
        !result.verified ||
        result.tag?.epc !== subscriber.card_epc ||
        result.tag?.tid !== target.tid
      )
        throw new Error("L'écriture de la carte n'a pas pu être vérifiée.");
      const updated = db.markCardTagged(subscriber.id, result.tag.tid);
      const oldKey = presenceKey(target);
      presentTags.delete(oldKey);
      stableTags.delete(oldKey);
      const writtenPresence = { tag: result.tag, lastSeen: Date.now() };
      presentTags.set(presenceKey(result.tag), writtenPresence);
      stableTags.set(presenceKey(result.tag), writtenPresence);
      broadcastSnapshot(true);
      return json(response, 200, { ...result, subscriber: updated });
    } catch (error) {
      db.addActivity(
        "carte",
        "echec",
        null,
        `Carte de ${subscriber.name} : ${error.message}`,
        subscriber.card_epc,
        null,
      );
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  const badgeMatch = pathname.match(/^\/api\/staff\/(\d+)\/badge$/);
  if (badgeMatch && request.method === "POST") {
    const staff = db.getStaff(badgeMatch[1]);
    if (!staff)
      return json(response, 404, { error: "Membre du personnel introuvable." });
    const connection = normalizeConnection(await readBody(request));
    try {
      await ensureReaderConnection(connection);
      const snapshot = currentSnapshot({ raw: true });
      if (snapshot.count === 0)
        return json(response, 409, {
          ok: false,
          error: "Aucun tag détecté. Posez le badge sur le lecteur.",
        });
      if (snapshot.count > 1)
        return json(response, 409, {
          ok: false,
          error: "Plusieurs tags détectés. Isolez le badge à encoder.",
        });
      const target = snapshot.tags[0];
      if (!target.tid)
        return json(response, 409, {
          ok: false,
          error:
            "Le tag ne fournit pas de TID; l'écriture sécurisée est annulée.",
        });
      if (target.book || target.kind === "book")
        return json(response, 409, {
          ok: false,
          error: target.book
            ? `Ce tag appartient au livre ${target.book.accession}. Utilisez un badge vierge.`
            : "Ce tag est un livre encodé sur un autre poste. Utilisez un badge vierge.",
        });
      if (target.subscriber || target.kind === "card")
        return json(response, 409, {
          ok: false,
          error: target.subscriber
            ? `Ce tag est la carte d'abonné de ${target.subscriber.name}. Utilisez un badge vierge.`
            : "Ce tag est une carte d'abonné. Utilisez un badge vierge.",
        });
      if (target.staff && target.staff.id !== staff.id)
        return json(response, 409, {
          ok: false,
          error: `Ce tag est déjà le badge de ${target.staff.name}.`,
        });
      if (!target.staff && target.kind === "badge" && target.epc !== staff.badge_epc)
        return json(response, 409, {
          ok: false,
          error:
            "Ce tag est le badge d'un autre membre du personnel, pas encore synchronisé sur ce poste.",
        });
      let result;
      if (connection.type === "simulation") {
        simulatedTag = { ...simulatedTag, epc: staff.badge_epc, tid: target.tid };
        result = { ok: true, verified: true, tag: simulatedTag };
      } else {
        result = normalizeBridgePayload(
          await reader.write(staff.badge_epc, target.tid),
        );
      }
      if (
        !result.verified ||
        result.tag?.epc !== staff.badge_epc ||
        result.tag?.tid !== target.tid
      )
        throw new Error("L'écriture du badge n'a pas pu être vérifiée.");
      const updated = db.markBadgeTagged(staff.id, result.tag.tid);
      const oldKey = presenceKey(target);
      presentTags.delete(oldKey);
      stableTags.delete(oldKey);
      const writtenPresence = { tag: result.tag, lastSeen: Date.now() };
      presentTags.set(presenceKey(result.tag), writtenPresence);
      stableTags.set(presenceKey(result.tag), writtenPresence);
      broadcastSnapshot(true);
      return json(response, 200, { ...result, staff: updated });
    } catch (error) {
      db.addActivity(
        "badge",
        "echec",
        null,
        `Badge de ${staff.name} : ${error.message}`,
        staff.badge_epc,
        null,
      );
      return json(response, 503, { ok: false, error: error.message });
    }
  }

  if (request.method === "GET" && pathname === "/api/export.csv") {
    const header = [
      "Numéro",
      "Titre",
      "Auteur",
      "ISBN",
      "Catégorie",
      "Rayon",
      "Statut",
      "EPC",
      "TID",
    ];
    const rows = db
      .listBooks()
      .map((book) => [
        book.accession,
        book.title,
        book.author,
        book.isbn,
        book.category,
        book.shelf,
        book.status,
        book.epc,
        book.tid,
      ]);
    const content = `\uFEFF${[header, ...rows].map((row) => row.map(csvCell).join(";")).join("\r\n")}`;
    response.writeHead(200, {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": "attachment; filename=biblioteque-ztf.csv",
    });
    return response.end(content);
  }

  return json(response, 404, { error: "Route inconnue." });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");
  try {
    if (url.pathname.startsWith("/agent/"))
      return agent(request, response, url);
    if (url.pathname.startsWith("/api/"))
      return await api(request, response, url);
    if (
      url.pathname === "/vendor/sweetalert2/sweetalert2.all.min.js" ||
      url.pathname === "/vendor/sweetalert2/sweetalert2.min.css"
    ) {
      const asset = path.basename(url.pathname);
      const assetPath = path.join(
        root,
        "node_modules",
        "sweetalert2",
        "dist",
        asset,
      );
      const contentType = asset.endsWith(".css")
        ? "text/css; charset=utf-8"
        : "text/javascript; charset=utf-8";
      response.writeHead(200, {
        "Content-Type": contentType,
        "Cache-Control": "public, max-age=86400",
      });
      return fs.createReadStream(assetPath).pipe(response);
    }
    if (url.pathname === "/vendor/qrcode/qrcode.js") {
      const assetPath = path.join(
        root,
        "node_modules",
        "qrcode-generator",
        "qrcode.js",
      );
      response.writeHead(200, {
        "Content-Type": "text/javascript; charset=utf-8",
        "Cache-Control": "public, max-age=86400",
      });
      return fs.createReadStream(assetPath).pipe(response);
    }
    if (url.pathname.startsWith("/vendor/lucide/")) {
      const relative = url.pathname.slice("/vendor/lucide/".length);
      const lucideRoot = path.resolve(
        root,
        "node_modules",
        "lucide",
        "dist",
        "esm",
      );
      const lucidePath = path.resolve(lucideRoot, relative);
      if (
        lucidePath.startsWith(lucideRoot) &&
        fs.existsSync(lucidePath) &&
        fs.statSync(lucidePath).isFile()
      ) {
        response.writeHead(200, {
          "Content-Type": "text/javascript; charset=utf-8",
          "Cache-Control": "public, max-age=86400",
        });
        return fs.createReadStream(lucidePath).pipe(response);
      }
    }
    if (!serveStatic(request, response, url.pathname))
      serveStatic(request, response, "/");
  } catch (error) {
    console.error(error);
    if (!response.headersSent)
      json(response, 500, { error: error.message || "Erreur interne." });
    else response.end();
  }
});

let port = Number(process.env.PORT) || 4310;
const listenHost = process.env.BIBLIORFID_HOST || "0.0.0.0";
server.on("error", (error) => {
  if (error.code === "EADDRINUSE" && port < 4320) {
    port += 1;
    server.listen(port, listenHost);
  } else {
    throw error;
  }
});
server.on("listening", () => {
  const urls = [`http://127.0.0.1:${port}`];
  for (const address of networkHosts()) urls.push(`http://${address}:${port}`);
  console.log(`Bibliotèque ZTF disponible sur ${urls.join(" et ")}`);
});
server.listen(port, listenHost);

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  clearTimeout(broadcastTimer);
  clearTimeout(beepTimer);
  for (const client of eventClients) client.end();
  eventClients.clear();
  for (const client of agentClients) client.end();
  agentClients.clear();
  syncService.close();
  try {
    await cataloguingService.close();
  } catch {}
  try {
    await reader.shutdown();
  } catch {}
  server.close(() => {
    db.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 4000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
