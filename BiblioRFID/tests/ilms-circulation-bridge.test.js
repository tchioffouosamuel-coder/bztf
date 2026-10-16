import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { IlmsCirculationClient, IlmsClientError } from "../lib/ilms-circulation-client.js";
import { IlmsCirculationJournal } from "../lib/ilms-circulation-journal.js";
import { mirrorCheckout, mirrorReturn } from "../lib/ilms-circulation-bridge.js";

const GATEWAY = "https://gateway.example.org";
const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const LIBRARY = "22222222-2222-4222-8222-222222222222";
const COPY = "44444444-4444-4444-8444-444444444444";
const MEMBER = "55555555-5555-4555-8555-555555555555";
const CARD = "66666666-6666-4666-8666-666666666666";
const DOCUMENT = "77777777-7777-4777-8777-777777777777";
const LOAN = "99999999-9999-4999-8999-999999999999";
const OPERATION = "88888888-8888-4888-8888-888888888888";

const BOOK = {epc: "300833B2DDD9014000000001", tid: "E28068940000500A12AB0001"};
const SUBSCRIBER = {card_epc: "300833B2DDD9014000000099", card_tid: "E28068940000500A12AB0099"};
const DUE = "2026-11-01T12:00:00.000Z";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {status, headers: {"Content-Type": "application/json"}});

const memberReply = (overrides = {}) =>
  json({member_id: MEMBER, card_id: CARD, name: "Lecteur", number: "AB-1", status: 1, eligible: true, ...overrides});

const copyReply = (overrides = {}) =>
  json({copy: {id: COPY, document_id: DOCUMENT, number: "EX-1"}, title: "Un titre",
    available_for_checkout: true, active_loan: null, ...overrides});

const loanReply = (overrides = {}) =>
  json({id: LOAN, library_id: LIBRARY, member_id: MEMBER, copy_id: COPY, document_id: DOCUMENT,
    number: "PR-2026-0001", status: 1, ...overrides}, 201);

/** Session active par defaut : le pont ne doit pas avoir a la construire. */
function sessionStub({active = true, scoped = true} = {}) {
  return {
    active,
    session: scoped
      ? {gatewayUrl: GATEWAY, accountId: ACCOUNT, libraryId: LIBRARY, accessToken: "fake.jwt.token"}
      : null,
  };
}

function setup(t, routes = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ilms-bridge-test-"));
  const journal = new IlmsCirculationJournal(path.join(directory, "journal.db"));
  const calls = [];
  const session = sessionStub();
  const client = new IlmsCirculationClient({
    journal,
    getSession: () => session.session ?? {},
    fetchImpl: async (url, init) => {
      const route = new URL(url).pathname.split("/circulation/rfid/")[1];
      calls.push({route, body: JSON.parse(init.body)});
      if (routes[route]) return routes[route]();
      if (route === "members/resolve") return memberReply();
      if (route === "copies/resolve") return copyReply();
      return loanReply();
    },
  });
  t.after(() => {
    journal.close();
    assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
    fs.rmSync(directory, {recursive: true, force: true});
  });
  return {journal, client, session, calls};
}

const checkout = (context, overrides = {}) =>
  mirrorCheckout({
    client: context.client,
    session: context.session,
    book: BOOK,
    subscriber: SUBSCRIBER,
    dueAt: DUE,
    operationId: OPERATION,
    ...overrides,
  });

test("a checkout resolves card then copy, then sends the loan", async t => {
  const context = setup(t);
  const result = await checkout(context);

  assert.equal(result.status, "sent");
  assert.equal(result.loan.number, "PR-2026-0001");
  assert.deepEqual(context.calls.map(call => call.route),
    ["members/resolve", "copies/resolve", "checkouts"]);
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 0);
});

test("the local loan identifier is the idempotency key sent to ILMS", async t => {
  const context = setup(t);
  await checkout(context);
  const sent = context.calls.find(call => call.route === "checkouts").body;

  assert.equal(sent.operation_id, OPERATION);
  assert.equal(sent.expected_member_id, MEMBER);
  assert.equal(sent.expected_card_id, CARD);
  assert.equal(sent.expected_copy_id, COPY);
  assert.equal(sent.preferred_return_date, DUE);
});

test("a network outage leaves the request in the journal rather than losing it", async t => {
  const context = setup(t, {checkouts: () => { throw new Error("socket"); }});
  const result = await checkout(context);

  assert.equal(result.status, "queued");
  assert.equal(typeof result.entry_id, "string");
  // La demande survit : c'est tout l'interet du journal durable.
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 1);
});

test("a firm refusal is kept too: the operator arbitrates from the settings", async t => {
  const context = setup(t, {checkouts: () => json({error: "nope"}, 409)});
  const result = await checkout(context);

  assert.equal(result.status, "queued");
  assert.equal(result.code, "denied");
});

test("no session means the loan simply stays local", async t => {
  const context = setup(t);
  const result = await checkout(context, {session: sessionStub({scoped: false})});

  assert.equal(result.status, "skipped");
  assert.equal(result.code, "no_session");
  assert.equal(context.calls.length, 0);
});

test("an expired session is named, not retried", async t => {
  const context = setup(t);
  const result = await checkout(context, {session: {...sessionStub(), active: false}});

  assert.equal(result.status, "skipped");
  assert.equal(result.code, "expired");
  assert.equal(context.calls.length, 0);
});

test("a subscriber without an encoded card is skipped before reaching ILMS", async t => {
  const context = setup(t);
  const result = await checkout(context, {subscriber: {card_epc: null, card_tid: null}});

  assert.equal(result.status, "skipped");
  assert.equal(result.code, "no_card");
  assert.equal(context.calls.length, 0);
});

test("a book without a tag is skipped before reaching ILMS", async t => {
  const context = setup(t);
  const result = await checkout(context, {book: {epc: "", tid: null}});

  assert.equal(result.status, "skipped");
  assert.equal(result.code, "no_tag");
  assert.equal(context.calls.length, 0);
});

test("a member ILMS refuses is reported with the server's reason", async t => {
  const context = setup(t, {
    "members/resolve": () => memberReply({eligible: false, blocked_reason: "Abonnement expire."}),
  });
  const result = await checkout(context);

  assert.equal(result.status, "refused");
  assert.equal(result.code, "not_eligible");
  assert.equal(result.message, "Abonnement expire.");
  // Rien n'est enfile : la demande serait refusee a chaque reprise.
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 0);
});

test("a copy ILMS gives as unavailable is refused, not queued", async t => {
  const context = setup(t, {"copies/resolve": () => copyReply({available_for_checkout: false})});
  const result = await checkout(context);

  assert.equal(result.status, "refused");
  assert.equal(result.code, "not_available");
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 0);
});

test("an unknown card is refused without queuing anything", async t => {
  const context = setup(t, {"members/resolve": () => json({error: "unknown"}, 404)});
  const result = await checkout(context);

  assert.equal(result.status, "refused");
  assert.equal(result.ilms_status, 404);
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 0);
});

test("a return targets the loan ILMS knows, not the local one", async t => {
  const context = setup(t, {
    "copies/resolve": () => copyReply({
      active_loan: {id: LOAN, library_id: LIBRARY, member_id: MEMBER, copy_id: COPY,
        document_id: DOCUMENT, number: "PR-2026-0001", status: 1},
    }),
    returns: () => json({id: LOAN, library_id: LIBRARY, member_id: MEMBER, copy_id: COPY,
      document_id: DOCUMENT, number: "PR-2026-0001", status: 2}, 200),
  });
  const result = await mirrorReturn({client: context.client, session: context.session, book: BOOK});

  assert.equal(result.status, "sent");
  assert.equal(context.calls.find(call => call.route === "returns").body.loan_id, LOAN);
});

test("a copy ILMS holds no loan on is skipped, never queued", async t => {
  const context = setup(t);
  const result = await mirrorReturn({client: context.client, session: context.session, book: BOOK});

  assert.equal(result.status, "skipped");
  assert.equal(result.code, "no_loan");
  assert.equal(context.journal.list(
    {gateway_url: GATEWAY, account_id: ACCOUNT, library_id: LIBRARY}).length, 0);
});

test("the bridge never throws, whatever the client does", async t => {
  const context = setup(t);
  const exploding = {
    resolveMember: async () => { throw new TypeError("boom"); },
    resolveCopy: async () => { throw new TypeError("boom"); },
    enqueue: () => { throw new IlmsClientError("storage"); },
    retry: async () => { throw new TypeError("boom"); },
    list: () => [],
  };

  const borrowed = await checkout(context, {client: exploding});
  assert.equal(borrowed.status, "refused");

  const returned = await mirrorReturn({client: exploding, session: context.session, book: BOOK});
  assert.equal(returned.status, "refused");
});
