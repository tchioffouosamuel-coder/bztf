import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { ILMS_DEFAULT_GATEWAY_URL, IlmsCirculationClient, IlmsClientError, nativeOperation, nativeScope, nativeTag } from "../lib/ilms-circulation-client.js";
import { IlmsCirculationJournal } from "../lib/ilms-circulation-journal.js";

const fixture = JSON.parse(fs.readFileSync(new URL("./fixtures/ilms-circulation-contract.json", import.meta.url), "utf8"));
const operation = () => structuredClone(fixture.operations[0].normalized);
const returned = () => structuredClone(fixture.operations[1].normalized);
const response = (body = fixture.loan, status = 201) => new Response(JSON.stringify(body), {status, headers: {"Content-Type": "application/json"}});
function setup(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ilms-client-test-"));
  const context = {directory, file: path.join(directory, "native-journal.db"), session: {...fixture.scope, accessToken: "fake.jwt.token"}};
  context.journal = new IlmsCirculationJournal(context.file, options);
  context.client = new IlmsCirculationClient({journal: context.journal, getSession: () => context.session,
    fetchImpl: options.fetchImpl ?? (async () => response()), timeoutMs: options.timeoutMs ?? 30000});
  t.after(() => {
    context.journal.close();
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    assert(path.basename(directory).startsWith("ilms-client-test-")); fs.rmSync(directory, {recursive: true, force: true});
  });
  return context;
}
async function server(t, handler) {
  const service = http.createServer(handler); await new Promise(resolve => service.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise(resolve => { service.close(resolve); service.closeAllConnections(); }));
  return `http://127.0.0.1:${service.address().port}`;
}

test("desktop normalization matches the shared native mobile contract and removes extraneous fields", () => {
  for (const entry of fixture.operations) assert.deepEqual(nativeOperation(entry.input), entry.normalized);
});
test("requires a precise HTTPS gateway or explicit loopback HTTP, never URL credentials or alternate service paths", () => {
  for (const gatewayUrl of ["http://ilms.test", "https://user:password@ilms.test", "https://ilms.test/api", "https://ilms.test/?token=secret", "https://ilms.test/#x", "file:///x", "https://ilms.test\n.evil"]) {
    assert.throws(() => nativeScope({...fixture.scope, gatewayUrl}), IlmsClientError);
  }
  assert.equal(nativeScope({...fixture.scope, gatewayUrl: "https://ILMS.test/"}).gateway_url, "https://ilms.test");
  assert.equal(nativeScope({...fixture.scope, gatewayUrl: "http://[::1]:8081"}).gateway_url, "http://[::1]:8081");
});
test("rejects bad tags, missing snapshot IDs and ambiguous due dates", () => {
  for (const value of [{}, {epc: "ABC"}, {tid: "NOT-HEX"}, {epc: 42}, {epc: "AA".repeat(128)}]) assert.throws(() => nativeTag(value), IlmsClientError);
  const input = operation(); delete input.payload.expected_card_id; assert.throws(() => nativeOperation(input), IlmsClientError);
  const bad = operation(); bad.payload.preferred_return_date = "2030-12-01"; assert.throws(() => nativeOperation(bad), IlmsClientError);
});
test("refuses an existing legacy database without altering its rows, owner or schema", t => {
  const context = setup(t); const legacyFile = path.join(context.directory, "legacy.db"); const legacy = new DatabaseSync(legacyFile);
  legacy.exec("CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT); INSERT INTO books VALUES (1, 'Keep this book');"); legacy.close();
  assert.throws(() => new IlmsCirculationJournal(legacyFile), IlmsClientError);
  const after = new DatabaseSync(legacyFile); assert.equal(after.prepare("SELECT title FROM books").get().title, "Keep this book");
  assert.equal(after.prepare("PRAGMA application_id").get().application_id, 0);
  assert.equal(after.prepare("SELECT count(*) AS count FROM sqlite_master WHERE type = 'table'").get().count, 1); after.close();
});
test("refuses an unknown journal schema version rather than trying a destructive conversion", t => {
  const context = setup(t); context.journal.db.exec("PRAGMA user_version = 2;"); context.journal.close();
  assert.throws(() => new IlmsCirculationJournal(context.file), IlmsClientError);
  const raw = new DatabaseSync(context.file); raw.exec("PRAGMA user_version = 1;"); raw.close();
  context.journal = new IlmsCirculationJournal(context.file);
});
test("enqueue does no HTTP and stores minimal immutable intent without any credentials or resolved names", t => {
  let calls = 0; const context = setup(t, {fetchImpl: async () => { calls++; return response(); }});
  context.session.accessToken = ""; const entry = context.client.enqueue(fixture.operations[0].input);
  assert.equal(calls, 0); assert.equal(entry.attempts, 0); assert.deepEqual(entry.payload, operation().payload);
  const raw = context.journal.db.prepare("SELECT * FROM operations").get(); const persisted = JSON.stringify(raw);
  for (const privateValue of ["not-persisted", "fake.jwt.token", "Lecteur Test", "MEM-42"]) assert(!persisted.includes(privateValue));
});
test("identical intent reuses the first UUID; a changed native identity is a distinct request", t => {
  const context = setup(t); const first = context.client.enqueue(operation()); const same = operation(); same.payload.operation_id = randomUUID();
  assert.equal(context.client.enqueue(same).id, first.id);
  same.payload.expected_card_id = randomUUID(); assert.notEqual(context.client.enqueue(same).id, first.id); assert.equal(context.client.list().length, 2);
});
test("reusing a UUID with different content cannot overwrite a saved intent", t => {
  const context = setup(t); const first = context.client.enqueue(operation()); const changed = operation(); changed.payload.copy = {epc: "AA00"};
  assert.throws(() => context.client.enqueue(changed), IlmsClientError); assert.deepEqual(context.client.list(), [first]);
});
test("gateway, account and library scopes are all isolated", t => {
  const context = setup(t); const original = {...context.session}; context.client.enqueue(operation());
  for (const update of [{gatewayUrl: "https://another.test"}, {accountId: randomUUID()}, {libraryId: randomUUID()}]) {
    context.session = {...original, ...update}; assert.deepEqual(context.client.list(), []);
    assert.throws(() => context.client.discard(operation().payload.operation_id), IlmsClientError);
  }
  context.session = original; assert.equal(context.client.list().length, 1);
});
test("journal survives connection reopen and never evicts pending operations at its capacity", t => {
  const context = setup(t);
  for (let index = 0; index < 100; index++) { const input = operation(); input.payload.operation_id = randomUUID(); input.payload.copy = {epc: index.toString(16).padStart(4, "0")}; context.client.enqueue(input); }
  context.journal.close(); context.journal = new IlmsCirculationJournal(context.file); context.client.journal = context.journal;
  assert.equal(context.client.list().length, 100); const overflow = operation(); overflow.payload.operation_id = randomUUID();
  assert.throws(() => context.client.enqueue(overflow), error => error.code === "capacity"); assert.equal(context.client.list().length, 100);
});
test("SQLite leases coordinate separate connections and only their owner may acknowledge or release", t => {
  let now = Date.now(); const context = setup(t, {now: () => now}); const second = new IlmsCirculationJournal(context.file, {now: () => now});
  const scope = nativeScope(context.session); const entry = context.client.enqueue(operation()); const lease = randomUUID(); const newer = randomUUID();
  try {
    context.journal.claim(scope, entry.id, lease);
    assert.throws(() => second.claim(scope, entry.id, newer), error => error.code === "busy");
    assert.throws(() => second.remove(scope, entry.id), error => error.code === "busy");
    now += 120001; second.claim(scope, entry.id, newer);
    assert.throws(() => context.journal.remove(scope, entry.id, lease), error => error.code === "busy");
    assert.throws(() => context.journal.failed(scope, entry.id, lease, 500), error => error.code === "busy");
    second.remove(scope, entry.id, newer); assert.deepEqual(context.client.list(), []);
  } finally { second.close(); }
});
test("corrupt persisted payloads fail closed rather than being replayed or discarded", t => {
  const context = setup(t); context.client.enqueue(operation()); context.journal.db.exec("UPDATE operations SET payload = '{}';");
  assert.throws(() => context.client.list(), error => error.code === "storage");
  assert.equal(context.journal.db.prepare("SELECT count(*) AS count FROM operations").get().count, 1);
});
test("native checkout is committed and claimed before HTTP; a valid acknowledgement removes it", async t => {
  const context = setup(t); let calls = 0;
  context.client.fetch = async (url, options) => {
    calls++; assert.equal(url, `${fixture.scope.gatewayUrl}/library-service/api/v1/libraries/${fixture.scope.libraryId}/circulation/rfid/checkouts`);
    assert.equal(options.redirect, "error"); assert.equal(options.credentials, "omit"); assert.equal(options.headers.Authorization, "Bearer fake.jwt.token");
    assert.equal(options.headers["X-Device-Key"], undefined); assert.equal(context.client.list()[0].attempts, 1);
    assert.deepEqual(JSON.parse(options.body), operation().payload); return response({...fixture.loan, member_name: "Not persisted"});
  };
  const loan = await context.client.checkout(operation().payload); assert.equal(loan.id, fixture.loan.id);
  assert.equal(loan.member_name, undefined); assert.equal(calls, 1); assert.deepEqual(context.client.list(), []);
});
for (const status of [401, 403, 404, 409, 429, 503]) test(`HTTP ${status} retains the request and only its numeric status, never the server's secret error body`, async t => {
  const context = setup(t, {fetchImpl: async () => response({message: "private-secret-body"}, status)});
  await assert.rejects(context.client.checkout(operation().payload), error => error.status === status && !String(error).includes("private-secret-body"));
  const [entry] = context.client.list(); assert.equal(entry.last_status, status);
  assert.equal(entry.state, status < 500 && status !== 429 ? "blocked" : "pending"); assert.equal(entry.lease_id, null);
  assert(!JSON.stringify(entry).includes("private-secret-body"));
});
for (const update of [{library_id: randomUUID()}, {member_id: randomUUID()}, {copy_id: randomUUID()}, {id: "bad"}, {status: 99}]) {
  test(`does not acknowledge a malformed or mismatched loan (${Object.keys(update)[0]})`, async t => {
    const context = setup(t, {fetchImpl: async () => response({...fixture.loan, ...update})});
    await assert.rejects(context.client.checkout(operation().payload), error => error.code === "response"); assert.equal(context.client.list().length, 1);
  });
}
test("return replay uses the original loan, needs no card and rejects a different loan or non-returned status", async t => {
  const context = setup(t); let request;
  context.client.fetch = async (_url, options) => { request = JSON.parse(options.body); return response({...fixture.loan, status: 2}, 200); };
  await context.client.returnCopy(returned().payload); assert.deepEqual(request, returned().payload); assert.equal(request.card, undefined);
  context.client.fetch = async () => response({...fixture.loan, status: 1}, 200);
  await assert.rejects(context.client.returnCopy(returned().payload), error => error.code === "response");
  context.client.fetch = async () => response({...fixture.loan, id: randomUUID(), status: 2}, 200);
  await assert.rejects(context.client.retry(context.client.list()[0].id), error => error.code === "response");
});
test("a missing token keeps an offline enqueue without HTTP or claim", async t => {
  let calls = 0; const context = setup(t, {fetchImpl: async () => { calls++; return response(); }}); context.session.accessToken = "";
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "auth");
  assert.equal(calls, 0); assert.equal(context.client.list()[0].attempts, 0);
});
test("scope change or logout during HTTP cannot acknowledge or expose a late response", async t => {
  const context = setup(t); const original = {...context.session};
  context.client.fetch = async () => { context.session = {...context.session, accountId: randomUUID()}; return response(); };
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "scope"); context.session = original;
  assert.equal(context.client.list().length, 1);
  context.client.fetch = async () => { context.session = null; return response(); };
  await assert.rejects(context.client.retry(context.client.list()[0].id), error => error.code === "scope"); context.session = original;
  assert.equal(context.client.list().length, 1);
});
test("network timeout is bounded and releases the lease without losing the UUID", async t => {
  const context = setup(t, {timeoutMs: 25, fetchImpl: async (_url, options) => new Promise((_resolve, reject) => options.signal.addEventListener("abort", () => reject(new Error("Secret network error")), {once: true}))});
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "network" && !String(error).includes("Secret"));
  const [entry] = context.client.list(); assert.equal(entry.id, operation().payload.operation_id); assert.equal(entry.lease_id, null);
});
test("bad content type, malformed JSON and oversized replies do not clear the journal", async t => {
  const context = setup(t);
  for (const bad of [() => new Response("{}"), () => new Response("{", {headers: {"Content-Type": "application/json"}}),
    () => response({padding: "x".repeat(70000)})]) {
    context.client.fetch = async () => bad(); await assert.rejects(context.client.checkout(operation().payload), error => error.code === "response");
  }
  assert.equal(context.client.list().length, 1);
});
test("an acknowledgement storage failure retains the exact request for idempotent recovery", async t => {
  const context = setup(t); const remove = context.journal.remove;
  context.journal.remove = () => { throw new IlmsClientError("storage"); };
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "storage");
  assert.equal(context.client.list()[0].id, operation().payload.operation_id); context.journal.remove = remove;
  await context.client.retry(context.client.list()[0].id); assert.deepEqual(context.client.list(), []);
});
test("resolves only native member/copy identities and validates their active loan", async t => {
  const context = setup(t); let body;
  context.client.fetch = async (url, options) => { body = JSON.parse(options.body); return response(url.endsWith("members/resolve") ? fixture.member : fixture.copy, 200); };
  assert.equal((await context.client.resolveMember({epc: "aa12"})).member_id, fixture.member.member_id); assert.deepEqual(body, {epc: "AA12"});
  assert.equal((await context.client.resolveCopy({tid: "bb34"})).copy.id, fixture.copy.copy.id);
  context.client.fetch = async () => response({...fixture.copy, active_loan: {...fixture.loan, copy_id: randomUUID()}}, 200);
  await assert.rejects(context.client.resolveCopy({tid: "BB34"}), error => error.code === "response"); assert.deepEqual(context.client.list(), []);
});

test("malformed lookup IDs and nested loans are explicit response failures without leaking implementation errors", async t => {
  const context = setup(t);
  for (const member of [{...fixture.member, member_id: [fixture.member.member_id]}, {...fixture.member, card_id: [fixture.member.card_id]}]) {
    context.client.fetch = async () => response(member, 200);
    await assert.rejects(context.client.resolveMember({epc: "AA12"}), error => error.code === "response");
  }
  for (const copy of [{...fixture.copy, copy: {...fixture.copy.copy, id: [fixture.copy.copy.id]}}, {...fixture.copy, active_loan: false}]) {
    context.client.fetch = async () => response(copy, 200);
    await assert.rejects(context.client.resolveCopy({tid: "BB34"}), error => error.code === "response");
  }
});

test("optional null tag fields are omitted but an entirely empty tag is rejected", () => {
  assert.deepEqual(nativeTag({epc: "aa12", tid: null}), {epc: "AA12"});
  assert.throws(() => nativeTag({epc: null, tid: null}), IlmsClientError);
});

test("a late scope change also aborts the response transport", async t => {
  const context = setup(t); let signal; const original = {...context.session};
  context.client.fetch = async (_url, options) => { signal = options.signal; context.session = null; return response(); };
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "scope");
  assert.equal(signal.aborted, true); context.session = original; assert.equal(context.client.list().length, 1);
});
test("all four native routes use the direct gateway path, never Angular's local api prefix", async t => {
  const prefix = `/library-service/api/v1/libraries/${fixture.scope.libraryId}/circulation/rfid/`;
  const replies = new Map([
    [`${prefix}members/resolve`, fixture.member], [`${prefix}copies/resolve`, fixture.copy],
    [`${prefix}checkouts`, fixture.loan], [`${prefix}returns`, {...fixture.loan, status: 2}]
  ]);
  const paths = [];
  const gateway = await server(t, async (request, reply) => {
    paths.push(request.url);
    for await (const _chunk of request) { /* Drain the request before replying. */ }
    assert.equal(request.method, "POST");
    reply.writeHead(replies.has(request.url) ? 200 : 404, {"Content-Type": "application/json"});
    reply.end(JSON.stringify(replies.get(request.url) ?? {}));
  });
  const context = setup(t, {fetchImpl: fetch}); context.session.gatewayUrl = gateway;
  await context.client.resolveMember({epc: "AA12"}); await context.client.resolveCopy({tid: "BB34"});
  await context.client.checkout(operation().payload); await context.client.returnCopy(returned().payload);
  assert.deepEqual(paths, [...replies.keys()]); assert.deepEqual(context.client.list(), []);
});

test("real HTTP replay after database reopen preserves the exact native payload and avoids every legacy endpoint", async t => {
  const requests = []; let failed = true;
  const gateway = await server(t, async (request, reply) => {
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    requests.push({url: request.url, body: JSON.parse(Buffer.concat(chunks).toString()), authorization: request.headers.authorization, legacyKey: request.headers["x-device-key"]});
    reply.writeHead(failed ? 503 : 201, {"Content-Type": "application/json"}); reply.end(JSON.stringify(failed ? {message: "Uncertain"} : fixture.loan));
  });
  const context = setup(t, {fetchImpl: fetch}); context.session.gatewayUrl = gateway;
  await assert.rejects(context.client.checkout(operation().payload)); context.journal.close(); context.journal = new IlmsCirculationJournal(context.file); context.client.journal = context.journal;
  const [entry] = context.client.list(); failed = false; await context.client.retry(entry.id);
  assert.deepEqual(requests[0], requests[1]); assert.equal(requests[0].legacyKey, undefined);
  assert(requests.every(request => request.url.endsWith("/circulation/rfid/checkouts"))); assert.deepEqual(context.client.list(), []);
});
test("real HTTP redirects are not followed and never forward the ILMS bearer token", async t => {
  let foreignCalls = 0; const destination = await server(t, (_request, reply) => { foreignCalls++; reply.end("{}"); });
  const source = await server(t, (_request, reply) => { reply.writeHead(302, {Location: destination + "/stolen"}); reply.end(); });
  const context = setup(t, {fetchImpl: fetch}); context.session.gatewayUrl = source;
  await assert.rejects(context.client.checkout(operation().payload), error => error.code === "network");
  assert.equal(foreignCalls, 0); assert.equal(context.client.list().length, 1);
});

const cli = fileURLToPath(new URL("../ilms-sync.js", import.meta.url));
function command(context, args, input, overrides = {}) {
  return new Promise((resolve, reject) => {
    const env = {...process.env, ILMS_GATEWAY_URL: context.session.gatewayUrl, ILMS_ACCOUNT_ID: context.session.accountId,
      ILMS_LIBRARY_ID: context.session.libraryId, ILMS_ACCESS_TOKEN: context.session.accessToken, ILMS_JOURNAL_PATH: context.file, ...overrides};
    for (const key of Object.keys(overrides)) if (overrides[key] === undefined) delete env[key];
    const child = spawn(process.execPath, ["--no-warnings=ExperimentalWarning", cli, ...args], {windowsHide: true, env});
    let stdout = ""; let stderr = ""; child.stdout.on("data", data => stdout += data); child.stderr.on("data", data => stderr += data);
    child.on("error", reject); child.on("close", code => resolve({code, stdout, stderr})); child.stdin.end(input ? JSON.stringify(input) : "");
  });
}
test("desktop CLI persists across separate processes, then explicitly replays through real loopback HTTP", async t => {
  let calls = 0;
  const gateway = await server(t, async (request, reply) => {
    calls++; assert.equal(request.headers.authorization, "Bearer fake.jwt.token");
    assert(request.url.endsWith("/circulation/rfid/checkouts")); reply.writeHead(201, {"Content-Type": "application/json"}); reply.end(JSON.stringify(fixture.loan));
  });
  const context = setup(t); context.session.gatewayUrl = gateway;
  const queued = await command(context, ["enqueue"], fixture.operations[0].input); assert.equal(queued.code, 0);
  const saved = JSON.parse(queued.stdout); assert.equal(saved.accepted_by_ilms, false); assert.equal(calls, 0);
  const listed = await command(context, ["list"]); assert.equal(JSON.parse(listed.stdout)[0].id, saved.entry.id);
  const result = await command(context, ["retry", saved.entry.id]); assert.equal(result.code, 0); assert.equal(JSON.parse(result.stdout).accepted_by_ilms, true);
  assert.equal(calls, 1); assert.deepEqual(JSON.parse((await command(context, ["list"])).stdout), []);
});
test("CLI falls back to the deployed gateway, and an explicit origin still wins", async t => {
  assert.equal(ILMS_DEFAULT_GATEWAY_URL, "https://gateway.bibliotheque-ztf.org");
  assert.equal(nativeScope({...fixture.scope, gatewayUrl: ILMS_DEFAULT_GATEWAY_URL}).gateway_url, ILMS_DEFAULT_GATEWAY_URL);
  const context = setup(t); const entry = context.client.enqueue(returned());
  // Sans origine explicite le CLI vise le gateway deployé : la portee change,
  // donc le journal de la portee de test n'est plus visible — et rien n'echoue.
  const withoutOrigin = await command(context, ["list"], undefined, {ILMS_GATEWAY_URL: undefined});
  assert.equal(withoutOrigin.code, 0);
  assert.deepEqual(JSON.parse(withoutOrigin.stdout), []);
  const listed = await command(context, ["list"]);
  assert.equal(listed.code, 0); assert.equal(JSON.parse(listed.stdout)[0].id, entry.id);
});
test("CLI discard requires explicit local confirmation and never represents a remote cancellation", async t => {
  const context = setup(t); const [entry] = [context.client.enqueue(returned())];
  const rejected = await command(context, ["discard", entry.id]); assert.equal(rejected.code, 1); assert.equal(context.client.list().length, 1);
  const confirmed = await command(context, ["discard", entry.id, "--confirm-local-discard"]); assert.equal(confirmed.code, 0);
  assert.deepEqual(JSON.parse(confirmed.stdout), {removed_locally: true, cancelled_in_ilms: false}); assert.deepEqual(context.client.list(), []);
});
