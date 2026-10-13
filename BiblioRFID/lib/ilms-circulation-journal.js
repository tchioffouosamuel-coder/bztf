import { DatabaseSync } from "node:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { ILMS_UUID, IlmsClientError, nativeOperation, nativeScope, nativeUuid } from "./ilms-circulation-client.js";

const APPLICATION_ID = 0x494c4d53;
function scopeValues(scope) {
  const canonical = nativeScope({gatewayUrl: scope?.gateway_url, accountId: scope?.account_id, libraryId: scope?.library_id});
  return [canonical.gateway_url, canonical.account_id, canonical.library_id];
}
function signature(operation) {
  const payload = {...operation.payload}; if (operation.kind === "checkout") delete payload.operation_id;
  return createHash("sha256").update(JSON.stringify({kind: operation.kind, payload})).digest("hex");
}

// Dedicated SQLite file: never adopt the legacy catalogue or convert its pending mutations.
export class IlmsCirculationJournal {
  constructor(filePath, {now = Date.now} = {}) {
    this.now = now;
    try {
      this.db = new DatabaseSync(filePath); this.db.exec("PRAGMA busy_timeout = 5000;");
      this.transaction(() => {
        const owner = this.db.prepare("PRAGMA application_id").get().application_id;
        const tables = this.db.prepare("SELECT count(*) AS count FROM sqlite_master WHERE type = 'table'").get().count;
        if ((owner !== 0 && owner !== APPLICATION_ID) || (owner === 0 && tables !== 0)) throw new IlmsClientError("storage");
        if (owner === APPLICATION_ID && this.db.prepare("PRAGMA user_version").get().user_version !== 1) throw new IlmsClientError("storage");
        if (owner === 0) {
          this.db.exec(`CREATE TABLE operations (
            id TEXT PRIMARY KEY, gateway_url TEXT NOT NULL, account_id TEXT NOT NULL, library_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('checkout', 'return')), payload TEXT NOT NULL, signature TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            last_status INTEGER, state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending', 'blocked')),
            lease_id TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
            UNIQUE(gateway_url, account_id, library_id, signature)
          ); CREATE INDEX operations_scope ON operations(gateway_url, account_id, library_id);
          PRAGMA application_id = ${APPLICATION_ID}; PRAGMA user_version = 1;`);
        }
      });
      this.db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;");
    } catch { this.db?.close(); throw new IlmsClientError("storage"); }
  }
  transaction(action) {
    try {
      this.db.exec("BEGIN IMMEDIATE;");
      try { const result = action(); this.db.exec("COMMIT;"); return result; }
      catch (error) { this.db.exec("ROLLBACK;"); throw error; }
    } catch (error) { throw error instanceof IlmsClientError ? error : new IlmsClientError("storage"); }
  }
  list(scope) {
    try { return this.db.prepare("SELECT * FROM operations WHERE gateway_url = ? AND account_id = ? AND library_id = ? ORDER BY created_at, rowid")
      .all(...scopeValues(scope)).map(row => this.entry(row)); }
    catch (error) { throw error instanceof IlmsClientError ? error : new IlmsClientError("storage"); }
  }
  enqueue(scope, input) {
    const operation = nativeOperation(input); const hash = signature(operation); const values = scopeValues(scope);
    return this.transaction(() => {
      const entries = this.list(scope); const previous = entries.find(entry => signature(entry) === hash);
      if (previous) return previous;
      if (entries.length >= 100) throw new IlmsClientError("capacity");
      const id = operation.kind === "checkout" ? operation.payload.operation_id : randomUUID(); const date = new Date(this.now()).toISOString();
      this.db.prepare("INSERT INTO operations(id, gateway_url, account_id, library_id, kind, payload, signature, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(id, ...values, operation.kind, JSON.stringify(operation.payload), hash, date, date);
      return this.list(scope).find(entry => entry.id === id);
    });
  }
  claim(scope, id, lease) {
    lease = nativeUuid(lease);
    return this.transaction(() => {
      const entry = this.find(scope, id);
      if (entry.lease_until > this.now()) throw new IlmsClientError("busy");
      this.db.prepare("UPDATE operations SET lease_id = ?, lease_until = ?, attempts = attempts + 1, updated_at = ? WHERE id = ?")
        .run(lease, this.now() + 120000, new Date(this.now()).toISOString(), entry.id);
      return this.find(scope, id);
    });
  }
  failed(scope, id, lease, status) {
    if (!Number.isInteger(status) || status < 0 || status > 599) throw new IlmsClientError("input");
    this.transaction(() => {
      const entry = this.find(scope, id); if (entry.lease_id !== lease) throw new IlmsClientError("busy");
      const state = status >= 400 && status < 500 && ![408, 425, 429].includes(status) ? "blocked" : "pending";
      this.db.prepare("UPDATE operations SET lease_id = NULL, lease_until = 0, last_status = ?, state = ?, updated_at = ? WHERE id = ?")
        .run(status, state, new Date(this.now()).toISOString(), entry.id);
    });
  }
  remove(scope, id, lease) {
    this.transaction(() => {
      const entry = this.find(scope, id);
      if (lease ? entry.lease_id !== lease : entry.lease_until > this.now()) throw new IlmsClientError("busy");
      this.db.prepare("DELETE FROM operations WHERE id = ?").run(entry.id);
    });
  }
  find(scope, id) {
    const entry = this.list(scope).find(item => item.id === nativeUuid(id));
    if (!entry) throw new IlmsClientError("scope"); return entry;
  }
  entry(row) {
    let operation;
    try { operation = nativeOperation({kind: row.kind, payload: JSON.parse(row.payload)}); } catch { throw new IlmsClientError("storage"); }
    if (JSON.stringify(operation.payload) !== row.payload || signature(operation) !== row.signature || !["pending", "blocked"].includes(row.state)
      || !Number.isInteger(row.attempts) || row.attempts < 0 || !Number.isSafeInteger(row.lease_until) || row.lease_until < 0
      || (row.lease_id !== null && (typeof row.lease_id !== "string" || !ILMS_UUID.test(row.lease_id)))
      || (row.lease_id === null && row.lease_until !== 0) || (row.last_status !== null && (!Number.isInteger(row.last_status) || row.last_status < 0 || row.last_status > 599))
      || !Number.isFinite(Date.parse(row.created_at)) || !Number.isFinite(Date.parse(row.updated_at))) throw new IlmsClientError("storage");
    const id = nativeUuid(row.id, "storage");
    if (operation.kind === "checkout" && operation.payload.operation_id !== id) throw new IlmsClientError("storage");
    return {...operation, id, gateway_url: row.gateway_url, account_id: row.account_id, library_id: row.library_id,
      created_at: row.created_at, updated_at: row.updated_at, attempts: row.attempts, last_status: row.last_status,
      state: row.state, lease_id: row.lease_id, lease_until: row.lease_until};
  }
  close() { this.db.close(); }
}
