import { randomUUID } from "node:crypto";

export const ILMS_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Deploiement par defaut, aligne sur le portail (`environment.prod.ts`) et sur
// l'entree mobile `ilmsDefaultGatewayUrl`. C'est un reglage de deploiement, pas
// un secret d'exploitation. `nativeScope` reste strict : ce defaut s'applique
// uniquement a la lecture de la configuration, jamais a une origine fournie.
export const ILMS_DEFAULT_GATEWAY_URL = "https://gateway.bibliotheque-ztf.org";
const messages = {
  scope: "Compte, bibliotheque et origine ILMS valides requis.",
  auth: "Un jeton de session ILMS est requis.",
  input: "Demande native ILMS invalide.",
  storage: "Journal ILMS indisponible. Les demandes ne sont pas acquittees.",
  capacity: "Le journal contient deja 100 demandes pour ce compte et cette bibliotheque.",
  busy: "Cette demande est deja en cours dans un autre processus.",
  response: "Reponse ILMS invalide. La demande reste dans le journal.",
  network: "Resultat inconnu. Reprise explicite avec la demande d'origine requise.",
  denied: "Demande refusee par ILMS. Elle reste dans le journal pour verification.",
};
export class IlmsClientError extends Error {
  constructor(code, status = 0) { super(messages[code] ?? messages.network); this.code = code; this.status = status; }
}
export function nativeUuid(value, code = "input") {
  if (typeof value !== "string" || !ILMS_UUID.test(value)) throw new IlmsClientError(code);
  return value.toLowerCase();
}
export function nativeScope(session) {
  let url;
  try { url = new URL(session?.gatewayUrl); } catch { throw new IlmsClientError("scope"); }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && local)) || url.username || url.password
    || url.href !== url.origin + "/" || /[\x00-\x20\x7f]/.test(String(session.gatewayUrl).trim())) throw new IlmsClientError("scope");
  return {gateway_url: url.origin, account_id: nativeUuid(session.accountId, "scope"), library_id: nativeUuid(session.libraryId, "scope")};
}
export function nativeTag(value) {
  const result = {};
  for (const key of ["epc", "tid"]) {
    if (value?.[key] == null || value[key] === "") continue;
    if (typeof value[key] !== "string") throw new IlmsClientError("input");
    const normalized = value[key].trim().toUpperCase();
    if (normalized.length > 254 || !/^(?:[0-9A-F]{2})+$/.test(normalized)) throw new IlmsClientError("input");
    result[key] = normalized;
  }
  if (!result.epc && !result.tid) throw new IlmsClientError("input");
  return result;
}
export function nativeOperation(input) {
  const value = input?.payload;
  if (input?.kind === "checkout") {
    if (typeof value?.preferred_return_date !== "string" || !Number.isFinite(Date.parse(value.preferred_return_date))
      || !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value.preferred_return_date)) throw new IlmsClientError("input");
    return {kind: "checkout", payload: {operation_id: nativeUuid(value.operation_id), card: nativeTag(value.card), copy: nativeTag(value.copy),
      preferred_return_date: new Date(value.preferred_return_date).toISOString(), expected_card_id: nativeUuid(value.expected_card_id),
      expected_member_id: nativeUuid(value.expected_member_id), expected_copy_id: nativeUuid(value.expected_copy_id)}};
  }
  if (input?.kind !== "return") throw new IlmsClientError("input");
  return {kind: "return", payload: {copy: nativeTag(value?.copy), loan_id: nativeUuid(value?.loan_id)}};
}
function loanReply(value, scope, operation) {
  const validUuid = field => typeof value?.[field] === "string" && ILMS_UUID.test(value[field]);
  if (!["id", "library_id", "member_id", "copy_id", "document_id"].every(validUuid)
    || value.library_id.toLowerCase() !== scope.library_id || typeof value.number !== "string" || !value.number.trim() || value.number.length > 255
    || !Number.isInteger(value.status) || value.status < 0 || value.status > 8
    || (operation?.kind === "checkout" && (value.member_id.toLowerCase() !== operation.payload.expected_member_id || value.copy_id.toLowerCase() !== operation.payload.expected_copy_id))
    || (operation?.kind === "return" && (value.id.toLowerCase() !== operation.payload.loan_id || value.status !== 2))) throw new IlmsClientError("response");
  const loan = Object.fromEntries(["id", "library_id", "member_id", "copy_id", "document_id"].map(field => [field, value[field].toLowerCase()]));
  loan.number = value.number; loan.status = value.status;
  for (const field of ["due_date", "return_date"]) {
    if (value[field] !== undefined && value[field] !== null) {
      if (typeof value[field] !== "string" || !Number.isFinite(Date.parse(value[field]))) throw new IlmsClientError("response");
      loan[field] = value[field];
    }
  }
  return loan;
}

export class IlmsCirculationClient {
  constructor({journal, getSession, fetchImpl = fetch, timeoutMs = 30000}) {
    if (!journal || typeof getSession !== "function" || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000) throw new IlmsClientError("input");
    this.journal = journal; this.getSession = getSession; this.fetch = fetchImpl; this.timeoutMs = timeoutMs;
  }
  list() { return this.journal.list(nativeScope(this.getSession())); }
  enqueue(input) { return this.journal.enqueue(nativeScope(this.getSession()), nativeOperation(input)); }
  discard(id) { this.journal.remove(nativeScope(this.getSession()), id); }
  async checkout(payload) { const entry = this.enqueue({kind: "checkout", payload}); return this.retry(entry.id); }
  async returnCopy(payload) { const entry = this.enqueue({kind: "return", payload}); return this.retry(entry.id); }
  async resolveMember(tag) {
    const scope = nativeScope(this.getSession()); const value = await this.request(scope, "members/resolve", nativeTag(tag));
    const memberId = nativeUuid(value?.member_id, "response"); const cardId = nativeUuid(value?.card_id, "response");
    if (typeof value.name !== "string"
      || typeof value.number !== "string" || !Number.isInteger(value.status) || typeof value.eligible !== "boolean") throw new IlmsClientError("response");
    return {member_id: memberId, card_id: cardId, name: value.name, number: value.number,
      status: value.status, eligible: value.eligible, ...(typeof value.blocked_reason === "string" ? {blocked_reason: value.blocked_reason} : {})};
  }
  async resolveCopy(tag) {
    const scope = nativeScope(this.getSession()); const value = await this.request(scope, "copies/resolve", nativeTag(tag));
    const copyId = nativeUuid(value?.copy?.id, "response"); const documentId = nativeUuid(value?.copy?.document_id, "response");
    if (typeof value.copy.number !== "string" || !value.copy.number.trim() || typeof value.title !== "string"
      || typeof value.available_for_checkout !== "boolean") throw new IlmsClientError("response");
    const active = value.active_loan == null ? null : loanReply(value.active_loan, scope);
    if (active && active.copy_id !== copyId) throw new IlmsClientError("response");
    return {copy: {id: copyId, document_id: documentId, number: value.copy.number},
      title: value.title, available_for_checkout: value.available_for_checkout, active_loan: active};
  }
  async retry(id) {
    const scope = nativeScope(this.getSession());
    this.token();
    const lease = randomUUID(); const entry = this.journal.claim(scope, id, lease);
    try {
      const value = await this.request(scope, entry.kind === "checkout" ? "checkouts" : "returns", entry.payload);
      const loan = loanReply(value, scope, entry);
      this.requireScope(scope); this.journal.remove(scope, entry.id, lease);
      return loan;
    } catch (error) {
      const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
      this.journal.failed(scope, entry.id, lease, safe.status);
      throw safe;
    }
  }
  token() {
    const token = this.getSession()?.accessToken;
    if (typeof token !== "string" || token.length > 8192 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) throw new IlmsClientError("auth", 401);
    return token;
  }
  requireScope(expected) {
    const current = nativeScope(this.getSession());
    if (Object.keys(expected).some(key => expected[key] !== current[key])) throw new IlmsClientError("scope");
    this.token();
  }
  async request(scope, route, body) {
    if (!["members/resolve", "copies/resolve", "checkouts", "returns"].includes(route)) throw new IlmsClientError("input");
    this.requireScope(scope);
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetch(`${scope.gateway_url}/library-service/api/v1/libraries/${scope.library_id}/circulation/rfid/${route}`, {
        method: "POST", redirect: "error", credentials: "omit", cache: "no-store", signal: controller.signal,
        headers: {Authorization: `Bearer ${this.token()}`, "Content-Type": "application/json", Accept: "application/json"}, body: JSON.stringify(body),
      });
      this.requireScope(scope);
      if (!Number.isInteger(response.status) || response.status < 100 || response.status > 599) {
        await response.body?.cancel(); throw new IlmsClientError("response");
      }
      if (response.status < 200 || response.status >= 300) {
        await response.body?.cancel();
        throw new IlmsClientError("denied", response.status);
      }
      if (response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
        await response.body?.cancel(); throw new IlmsClientError("response");
      }
      const chunks = []; let size = 0;
      for await (const chunk of response.body ?? []) {
        size += chunk.byteLength;
        if (size > 65536) { controller.abort(); throw new IlmsClientError("response"); }
        chunks.push(Buffer.from(chunk));
      }
      this.requireScope(scope);
      try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new IlmsClientError("response"); }
    } catch (error) {
      controller.abort();
      throw error instanceof IlmsClientError ? error : new IlmsClientError("network");
    } finally { clearTimeout(timer); }
  }
}
