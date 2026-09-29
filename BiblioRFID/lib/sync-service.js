import { randomUUID } from "node:crypto";

const SYNC_INTERVAL_MS = 60_000;
const REQUEST_TIMEOUT_MS = 30_000;

function normalizeServerUrl(value) {
  const text = String(value || "").trim().replace(/\/+$/, "");
  if (!text) return "";
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error("L’adresse du serveur est invalide.");
  }
  if (!["https:", "http:"].includes(url.protocol))
    throw new Error("L’adresse doit commencer par https:// ou http://.");
  return url.toString().replace(/\/+$/, "");
}

export class SyncService {
  constructor(database) {
    this.database = database;
    this.serverUrl = "";
    this.apiKey = "";
    this.deviceId = "";
    this.deviceName = "Poste Bibliothèque ZTF";
    this.connected = false;
    this.syncing = false;
    this.lastSyncAt = null;
    this.error = null;
    this.timer = null;
    this.debounce = null;
    this.socket = null;
    this.stopped = false;
  }

  get configured() {
    return Boolean(this.serverUrl && this.apiKey);
  }

  initialize() {
    this.serverUrl = this.database.getSetting(
      "sync_server_url",
      "https://bztf.onrender.com",
    );
    this.apiKey = this.database.getSetting("sync_api_key", "");
    this.deviceId = this.database.getSetting("sync_device_id", "");
    this.deviceName = this.database.getSetting(
      "sync_device_name",
      "Poste Bibliothèque ZTF",
    );
    this.lastSyncAt = this.database.getSetting("sync_last_at", "") || null;
    if (!this.deviceId) {
      this.deviceId = randomUUID();
      this.database.setSettings({ sync_device_id: this.deviceId });
    }
    this.database.prepareInitialSync();
    this.database.onMutation = () => this.schedule();
    this.timer = setInterval(() => this.syncNow(), SYNC_INTERVAL_MS);
    this.timer.unref?.();
    if (this.configured) this.schedule(10);
  }

  status() {
    return {
      configured: this.configured,
      connected: this.connected,
      syncing: this.syncing,
      serverUrl: this.serverUrl,
      apiKeyConfigured: Boolean(this.apiKey),
      deviceId: this.deviceId,
      deviceName: this.deviceName,
      pendingCount: this.database.pendingMutationCount(),
      lastSyncAt: this.lastSyncAt,
      error: this.error,
    };
  }

  async configure(input = {}) {
    const serverUrl = normalizeServerUrl(input.serverUrl);
    const suppliedKey = String(input.apiKey || "").trim();
    const apiKey = suppliedKey || this.apiKey;
    const deviceName =
      String(input.deviceName || "").trim().slice(0, 120) ||
      "Poste Bibliothèque ZTF";
    if (serverUrl && !apiKey)
      throw new Error("La clé d’appareil est obligatoire.");

    this.serverUrl = serverUrl;
    this.apiKey = serverUrl ? apiKey : "";
    this.deviceName = deviceName;
    this.connected = false;
    this.error = null;
    this.disconnectSocket();
    this.database.setSettings({
      sync_server_url: this.serverUrl,
      sync_api_key: this.apiKey,
      sync_device_id: this.deviceId,
      sync_device_name: this.deviceName,
    });
    if (this.configured) await this.syncNow();
    return this.status();
  }

  schedule(delay = 300) {
    if (!this.configured || this.stopped) return;
    clearTimeout(this.debounce);
    this.debounce = setTimeout(() => this.syncNow(), delay);
    this.debounce.unref?.();
  }

  async syncNow() {
    if (!this.configured || this.syncing || this.stopped) return this.status();
    this.syncing = true;
    this.error = null;
    try {
      await this.registerDevice();
      await this.pushPending();
      await this.pullAll();
      this.connected = true;
      this.lastSyncAt = new Date().toISOString();
      this.database.setSettings({ sync_last_at: this.lastSyncAt });
      this.connectSocket();
    } catch (error) {
      this.connected = false;
      this.error = this.friendlyError(error);
    } finally {
      this.syncing = false;
    }
    return this.status();
  }

  async registerDevice() {
    await this.request("/api/v1/devices/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: this.deviceId, name: this.deviceName }),
    });
  }

  async pushPending() {
    for (let batch = 0; batch < 100; batch++) {
      const rows = this.database.pendingMutations(500);
      if (!rows.length) return;
      const mutations = rows.map((row) => {
        const entityType = row.entity_type || "book";
        const payload = row.payload ? JSON.parse(row.payload) : null;
        return {
          mutationId: row.mutation_id,
          operation: row.operation,
          entityId: row.entity_id,
          entityType,
          book: entityType === "book" ? payload : null,
          subscriber: entityType === "subscriber" ? payload : null,
          subscription: entityType === "subscription" ? payload : null,
          loan: entityType === "loan" ? payload : null,
        };
      });
      const result = await this.request("/api/v1/sync/push", {
        method: "POST",
        body: JSON.stringify({ deviceId: this.deviceId, mutations }),
      });
      const acknowledged = Array.isArray(result.acknowledgedMutationIds)
        ? result.acknowledgedMutationIds
        : [];
      if (!acknowledged.length)
        throw new Error("Le serveur n’a confirmé aucune modification.");
      this.database.acknowledgeMutations(acknowledged);
    }
    throw new Error("Trop de modifications en attente pour une synchronisation.");
  }

  async pullAll() {
    let cursor = this.database.syncCursor();
    for (let page = 0; page < 100; page++) {
      const result = await this.request(
        `/api/v1/sync?since=${encodeURIComponent(cursor)}&limit=500`,
      );
      cursor = Number(result.cursor) || cursor;
      this.database.applyRemoteChanges(result.changes, cursor);
      if (!result.hasMore) return;
    }
    throw new Error("La récupération des changements est incomplète.");
  }

  async request(route, options = {}) {
    const response = await fetch(`${this.serverUrl}${route}`, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        "X-Device-Key": this.apiKey,
        "X-Device-Id": this.deviceId,
        ...(options.headers || {}),
      },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    let payload = {};
    try {
      payload = await response.json();
    } catch {
      // The status below remains useful when a proxy returns a non-JSON page.
    }
    if (!response.ok)
      throw new Error(payload.error || `Erreur serveur ${response.status}.`);
    return payload;
  }

  connectSocket() {
    if (this.socket || !this.configured || this.stopped) return;
    try {
      const url = new URL(`${this.serverUrl}/api/v1/events`);
      url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
      url.searchParams.set("apiKey", this.apiKey);
      const socket = new WebSocket(url);
      this.socket = socket;
      socket.addEventListener("message", () => this.schedule(250));
      socket.addEventListener("close", () => {
        if (this.socket === socket) this.socket = null;
      });
      socket.addEventListener("error", () => socket.close());
    } catch {
      this.socket = null;
    }
  }

  disconnectSocket() {
    const socket = this.socket;
    this.socket = null;
    try {
      socket?.close();
    } catch {
      // The periodic HTTP synchronization remains available.
    }
  }

  friendlyError(error) {
    if (error?.name === "TimeoutError")
      return "Le serveur distant n’a pas répondu dans le délai prévu.";
    return String(error?.message || error).replace(
      /^(TypeError|Error):\s*/,
      "",
    );
  }

  close() {
    this.stopped = true;
    clearInterval(this.timer);
    clearTimeout(this.debounce);
    this.disconnectSocket();
    this.database.onMutation = null;
  }
}

