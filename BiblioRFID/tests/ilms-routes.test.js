import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { IlmsCirculationClient, IlmsClientError } from "../lib/ilms-circulation-client.js";
import { IlmsCirculationJournal } from "../lib/ilms-circulation-journal.js";
import { IlmsSessionStore } from "../lib/ilms-session.js";
import { handleIlmsRequest } from "../lib/ilms-routes.js";

const GATEWAY = "https://gateway.example.org";
const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const LIBRARY = "22222222-2222-4222-8222-222222222222";
const OTHER = "33333333-3333-4333-8333-333333333333";
const COPY = "44444444-4444-4444-8444-444444444444";
const MEMBER = "55555555-5555-4555-8555-555555555555";
const CARD = "66666666-6666-4666-8666-666666666666";
const DOCUMENT = "77777777-7777-4777-8777-777777777777";
const OPERATION = "88888888-8888-4888-8888-888888888888";

const NOW = Date.UTC(2026, 9, 15, 12, 0, 0);
const now = () => NOW;

function jwt(expSeconds) {
  const part = value => Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
  return `${part({alg: "none"})}.${part({exp: expSeconds})}.c2ln`;
}
const VALID = jwt(Math.floor(NOW / 1000) + 3600);

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {status, headers: {"Content-Type": "application/json"}});

const credentials = {
  gateway_url: GATEWAY,
  username: "operateur",
  password: "secret",
  client_id: "test-client",
  client_secret: "secret",
};

function loginTransport(libraries = [{id: LIBRARY, name: "Bibliotheque ZTF"}]) {
  return async url => {
    const pathname = new URL(url).pathname;
    if (pathname === "/auth-service/oauth/token") {
      return json({token_type: "bearer", expires_in: 300, access_token: "bootstrap.token"});
    }
    if (pathname === "/auth-service/api/v1/auth/login") {
      return json({access_token: {type: "Bearer", token: VALID}, user: {id: ACCOUNT}});
    }
    if (pathname === "/library-service/api/v1/libraries") return json(libraries);
    return json({}, 404);
  };
}

/** Collecte la reponse telle que `server.js` la rendrait. */
function recorder() {
  const sent = {};
  return {
    sent,
    json: (response, status, body) => {
      sent.status = status;
      sent.body = body;
      return sent;
    },
  };
}

function setup(t, {libraries, circulationFetch, withJournal = true} = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ilms-routes-test-"));
  const session = new IlmsSessionStore({fetchImpl: loginTransport(libraries), now});
  let client = null;
  let journal = null;
  if (withJournal) {
    journal = new IlmsCirculationJournal(path.join(directory, "journal.db"));
    client = new IlmsCirculationClient({
      journal,
      getSession: () => session.session ?? {},
      fetchImpl: circulationFetch ?? (async () => json({}, 500)),
    });
  }
  t.after(() => {
    journal?.close();
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    fs.rmSync(directory, {recursive: true, force: true});
  });
  return {session, client, journal};
}

async function call(context, method, pathname, body, search = "") {
  const {sent, json: respond} = recorder();
  await handleIlmsRequest({
    request: {method},
    response: {},
    url: new URL(`http://127.0.0.1${pathname}${search}`),
    session: context.session,
    client: context.client,
    json: respond,
    readBody: async () => body ?? {},
  });
  return sent;
}

test("an unopened session reports itself without a journal", async t => {
  const context = setup(t);
  const result = await call(context, "GET", "/api/ilms/session");

  assert.equal(result.status, 200);
  assert.equal(result.body.signed_in, false);
  assert.equal(result.body.journal, null);
});

test("signing in returns the session and its journal, never the token", async t => {
  const context = setup(t);
  const result = await call(context, "POST", "/api/ilms/session", credentials);

  assert.equal(result.status, 200);
  assert.equal(result.body.signed_in, true);
  assert.equal(result.body.library_id, LIBRARY);
  assert.deepEqual(result.body.journal, {total: 0, pending: 0, blocked: 0, entries: []});
  assert.equal(JSON.stringify(result.body).includes(VALID), false);
});

test("a wrong password answers 401, not a retryable outage", async t => {
  const context = setup(t);
  context.session.fetch = async url =>
    new URL(url).pathname === "/auth-service/oauth/token"
      ? json({token_type: "bearer", expires_in: 300, access_token: "bootstrap.token"})
      : json({error: "bad"}, 401);

  const result = await call(context, "POST", "/api/ilms/session", credentials);
  assert.equal(result.status, 401);
  assert.equal(result.body.code, "auth");
});

test("an account without a library answers 403 and names the cause", async t => {
  const context = setup(t, {libraries: []});
  const result = await call(context, "POST", "/api/ilms/session", credentials);

  assert.equal(result.status, 403);
  assert.equal(result.body.code, "no_library");
});

test("a malformed origin answers 403 before any network call", async t => {
  const context = setup(t);
  const result = await call(context, "POST", "/api/ilms/session",
    {...credentials, gateway_url: "https://user:pass@gateway.example.org"});

  assert.equal(result.status, 403);
  assert.equal(result.body.code, "scope");
});

test("choosing among several libraries completes the scope", async t => {
  const context = setup(t, {
    libraries: [{id: LIBRARY, name: "Bibliotheque ZTF"}, {id: OTHER, name: "Annexe"}],
  });
  const signedIn = await call(context, "POST", "/api/ilms/session", credentials);
  assert.equal(signedIn.body.library_id, null);
  assert.equal(signedIn.body.journal, null);

  const chosen = await call(context, "PUT", "/api/ilms/session/library", {library_id: OTHER});
  assert.equal(chosen.status, 200);
  assert.equal(chosen.body.library_id, OTHER);
  assert.deepEqual(chosen.body.journal.entries, []);
});

test("a library the server did not grant is refused", async t => {
  const context = setup(t);
  await call(context, "POST", "/api/ilms/session", credentials);
  const result = await call(context, "PUT", "/api/ilms/session/library", {library_id: OTHER});

  assert.equal(result.status, 403);
  assert.equal(result.body.code, "scope");
});

test("signing out clears the session", async t => {
  const context = setup(t);
  await call(context, "POST", "/api/ilms/session", credentials);
  const result = await call(context, "DELETE", "/api/ilms/session");

  assert.equal(result.status, 200);
  assert.equal(result.body.signed_in, false);
  assert.equal(result.body.library_id, null);
});

test("a pending request is listed with its attempts and last refusal", async t => {
  const context = setup(t);
  await call(context, "POST", "/api/ilms/session", credentials);

  context.client.enqueue({
    kind: "checkout",
    payload: {
      operation_id: OPERATION,
      card: {epc: "AABB"},
      copy: {tid: "CCDD"},
      preferred_return_date: "2026-11-01T12:00:00Z",
      expected_card_id: CARD,
      expected_member_id: MEMBER,
      expected_copy_id: COPY,
    },
  });

  const result = await call(context, "GET", "/api/ilms/session");
  assert.equal(result.body.journal.total, 1);
  assert.equal(result.body.journal.pending, 1);
  assert.equal(result.body.journal.entries[0].kind, "checkout");
  // La demande elle-meme ne sort pas : elle porte des tags, l'ecran n'en a
  // pas l'usage et ils identifient une carte de lecteur.
  assert.equal("payload" in result.body.journal.entries[0], false);
});

test("a successful retry clears the entry and returns the loan", async t => {
  const context = setup(t, {
    circulationFetch: async () => json({
      id: "99999999-9999-4999-8999-999999999999",
      library_id: LIBRARY,
      member_id: MEMBER,
      copy_id: COPY,
      document_id: DOCUMENT,
      number: "PR-2026-0001",
      status: 1,
    }, 201),
  });
  await call(context, "POST", "/api/ilms/session", credentials);

  const entry = context.client.enqueue({
    kind: "checkout",
    payload: {
      operation_id: OPERATION,
      card: {epc: "AABB"},
      copy: {tid: "CCDD"},
      preferred_return_date: "2026-11-01T12:00:00Z",
      expected_card_id: CARD,
      expected_member_id: MEMBER,
      expected_copy_id: COPY,
    },
  });

  const result = await call(context, "POST", `/api/ilms/journal/${entry.id}/retry`);
  assert.equal(result.status, 200);
  assert.equal(result.body.loan.number, "PR-2026-0001");
  assert.equal(result.body.journal.total, 0);
});

test("a refused retry keeps the entry and reports the ILMS status", async t => {
  const context = setup(t, {circulationFetch: async () => json({error: "nope"}, 409)});
  await call(context, "POST", "/api/ilms/session", credentials);

  const entry = context.client.enqueue({
    kind: "return",
    payload: {copy: {epc: "AABB"}, loan_id: OPERATION},
  });

  const result = await call(context, "POST", `/api/ilms/journal/${entry.id}/retry`);
  assert.equal(result.status, 409);
  assert.equal(result.body.code, "denied");

  const after = await call(context, "GET", "/api/ilms/session");
  assert.equal(after.body.journal.total, 1);
  assert.equal(after.body.journal.entries[0].last_status, 409);
});

test("discarding a request requires an explicit confirmation", async t => {
  const context = setup(t);
  await call(context, "POST", "/api/ilms/session", credentials);
  const entry = context.client.enqueue({
    kind: "return",
    payload: {copy: {epc: "AABB"}, loan_id: OPERATION},
  });

  const refused = await call(context, "DELETE", `/api/ilms/journal/${entry.id}`);
  assert.equal(refused.status, 400);

  const still = await call(context, "GET", "/api/ilms/session");
  assert.equal(still.body.journal.total, 1);

  const removed = await call(context, "DELETE", `/api/ilms/journal/${entry.id}`, null, "?confirm=local-discard");
  assert.equal(removed.status, 200);
  // L'abandon est local : il n'annule rien chez ILMS, et le dit.
  assert.equal(removed.body.cancelled_in_ilms, false);
  assert.equal(removed.body.journal.total, 0);
});

test("without a journal the session still answers, and says why", async t => {
  const context = setup(t, {withJournal: false});
  const state = await call(context, "GET", "/api/ilms/session");

  assert.equal(state.status, 200);
  assert.equal(state.body.journal_error, true);

  const retry = await call(context, "POST", `/api/ilms/journal/${OPERATION}/retry`);
  assert.equal(retry.status, 503);
  assert.equal(retry.body.code, "storage");
});

test("an unknown ILMS route is a 404, not a silent success", async t => {
  const context = setup(t);
  const result = await call(context, "GET", "/api/ilms/unknown");
  assert.equal(result.status, 404);
});

test("an expired session is shown as inactive while still listing its library", async t => {
  const clock = {value: NOW};
  const session = new IlmsSessionStore({fetchImpl: loginTransport(), now: () => clock.value});
  const context = {session, client: null};

  await call(context, "POST", "/api/ilms/session", credentials);
  clock.value = NOW + 3600 * 1000 + 1;

  const result = await call(context, "GET", "/api/ilms/session");
  assert.equal(result.body.signed_in, true);
  assert.equal(result.body.active, false);
  assert.equal(result.body.library_id, LIBRARY);
});

test("a native error never leaks as a 500", async t => {
  const context = setup(t);
  for (const [error, expected] of [
    [new IlmsClientError("input"), 400],
    [new IlmsClientError("auth", 401), 401],
    [new IlmsClientError("capacity"), 409],
    [new IlmsClientError("busy"), 423],
    [new IlmsClientError("storage"), 503],
    [new IlmsClientError("network"), 502],
  ]) {
    context.session.signIn = async () => { throw error; };
    const result = await call(context, "POST", "/api/ilms/session", credentials);
    assert.equal(result.status, expected, error.code);
    assert.equal(result.body.code, error.code);
  }
});
