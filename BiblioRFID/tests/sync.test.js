import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase } from "../lib/database.js";
import { SyncService } from "../lib/sync-service.js";
import { generateCardEpc } from "../lib/epc.js";

function listen(server) {
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve(server.address().port)),
  );
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

test("envoie les mutations locales et applique les livres distants", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-sync-"));
  const database = new LibraryDatabase(path.join(directory, "catalogue.db"));
  const local = database.createBook({ title: "Livre local" });
  const requests = [];
  const remote = {
    serverId: "11111111-1111-4111-8111-111111111111",
    accession: "DISTANT-1",
    epc: "42434D0107EA000000ABCDEF",
    tid: null,
    title: "Livre distant",
    author: "Auteur distant",
    isbn: "",
    publisher: "",
    publicationYear: "2026",
    category: "Test",
    shelf: "A1",
    notes: "",
    status: "a_encoder",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    taggedAt: null,
    revision: 1,
  };
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = chunks.length
      ? JSON.parse(Buffer.concat(chunks).toString("utf8"))
      : null;
    requests.push({ url: request.url, key: request.headers["x-device-key"], body });
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/api/v1/devices/register")
      return response.end(JSON.stringify({ registered: true }));
    if (request.url === "/api/v1/sync/push")
      return response.end(
        JSON.stringify({
          acknowledgedMutationIds: body.mutations.map((item) => item.mutationId),
          cursor: 1,
        }),
      );
    if (request.url.startsWith("/api/v1/sync?"))
      return response.end(
        JSON.stringify({
          cursor: 1,
          changes: [
            {
              sequence: 1,
              operation: "upsert",
              entityId: remote.serverId,
              book: remote,
              deviceId: "mobile-test",
              createdAt: new Date().toISOString(),
            },
          ],
          hasMore: false,
        }),
      );
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Route inconnue" }));
  });
  const service = new SyncService(database);
  try {
    const port = await listen(server);
    service.initialize();
    const status = await service.configure({
      serverUrl: `http://127.0.0.1:${port}`,
      apiKey: "secret-test",
      deviceName: "Poste de test",
    });

    assert.equal(status.connected, true);
    assert.equal(status.pendingCount, 0);
    assert.equal(database.listBooks().length, 2);
    assert.equal(database.recognizeTag(remote.epc, "")?.title, "Livre distant");
    const push = requests.find((item) => item.url === "/api/v1/sync/push");
    assert.equal(push.key, "secret-test");
    assert.equal(push.body.mutations[0].book.serverId, local.server_id);
  } finally {
    service.close();
    await close(server);
    database.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});


test("synchronise les abonnés et leurs cartes RFID", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-sync-sub-"));
  const database = new LibraryDatabase(path.join(directory, "catalogue.db"));
  const local = database.upsertSubscriber({ member_number: "ab-1", name: "Local" });
  database.markCardTagged(local.id, "E2800000LOCAL");
  const now = new Date().toISOString();
  const remote = {
    memberNumber: "AB-2",
    name: "Distant",
    email: "",
    phone: "600",
    active: true,
    cardEpc: generateCardEpc(),
    // La carte de l'abonné local a été réencodée pour AB-2 sur un autre poste.
    cardTid: "E2800000LOCAL",
    cardTaggedAt: now,
    createdAt: now,
    updatedAt: now,
    revision: 1,
  };
  let pushed;
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = chunks.length
      ? JSON.parse(Buffer.concat(chunks).toString("utf8"))
      : null;
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/api/v1/devices/register")
      return response.end(JSON.stringify({ registered: true }));
    if (request.url === "/api/v1/sync/push") {
      pushed = body.mutations;
      return response.end(
        JSON.stringify({
          acknowledgedMutationIds: body.mutations.map((item) => item.mutationId),
          cursor: 1,
        }),
      );
    }
    if (request.url.startsWith("/api/v1/sync?"))
      return response.end(
        JSON.stringify({
          cursor: 2,
          changes: [
            {
              sequence: 2,
              operation: "upsert",
              entityId: "AB-2",
              entityType: "subscriber",
              book: null,
              subscriber: remote,
              deviceId: "mobile-test",
              createdAt: now,
            },
          ],
          hasMore: false,
        }),
      );
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Route inconnue" }));
  });
  const service = new SyncService(database);
  try {
    const port = await listen(server);
    service.initialize();
    const status = await service.configure({
      serverUrl: `http://127.0.0.1:${port}`,
      apiKey: "secret-test",
      deviceName: "Poste de test",
    });
    assert.equal(status.connected, true);
    assert.equal(status.pendingCount, 0);

    const sent = pushed.find((item) => item.entityType === "subscriber");
    assert.equal(sent.entityId, "AB-1");
    assert.equal(sent.book, null);
    assert.equal(sent.subscriber.cardTid, "E2800000LOCAL");
    assert.equal(sent.subscriber.cardEpc, local.card_epc);

    assert.equal(
      database.recognizeCard(remote.cardEpc, "E2800000LOCAL")?.member_number,
      "AB-2",
    );
    assert.equal(database.recognizeCard(local.card_epc, "E2800000LOCAL"), null);
    assert.equal(database.getSubscriber(local.id).card_tid, null);
    assert.equal(database.listBooks().length, 0);
  } finally {
    service.close();
    await close(server);
    database.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("synchronise les emprunts et les abonnements entre appareils", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-loans-"));
  const deskA = new LibraryDatabase(path.join(directory, "a.db"));
  const book = deskA.createBook({ title: "Livre partagé" });
  deskA.borrowBook(book.id, {
    member_number: "ab-1",
    name: "Awa",
    due_at: new Date(Date.now() + 14 * 86400000).toISOString(),
  });
  const outbox = Object.fromEntries(
    deskA.pendingMutations().map((row) => [row.entity_type, row]),
  );
  const loan = JSON.parse(outbox.loan.payload);
  const subscription = JSON.parse(outbox.subscription.payload);
  assert.equal(loan.bookServerId, deskA.getBook(book.id).server_id);
  assert.equal(loan.memberNumber, "AB-1");
  assert.equal(loan.subscriptionServerId, subscription.serverId);

  const change = (entityType, entityId, payload) => ({
    operation: "upsert",
    entityType,
    entityId,
    [entityType]: payload,
  });
  const deskB = new LibraryDatabase(path.join(directory, "b.db"));
  // L'emprunt arrive avant son livre : il attend ses références.
  deskB.applyRemoteChanges([change("loan", loan.serverId, loan)], 1);
  assert.equal(deskB.db.prepare("SELECT COUNT(*) AS n FROM loans").get().n, 0);
  const sourceBook = deskA.getBook(book.id);
  deskB.applyRemoteChanges(
    [
      change("subscription", subscription.serverId, subscription),
      change("book", sourceBook.server_id, deskA.toSyncBook(sourceBook)),
      change(
        "subscriber",
        "AB-1",
        deskA.toSyncSubscriber(
          deskA.db.prepare("SELECT * FROM subscribers").get(),
        ),
      ),
    ],
    2,
  );
  const localBook = deskB.db.prepare("SELECT * FROM books").get();
  assert.equal(localBook.status, "indisponible");
  assert.equal(deskB.activeLoanForBook(localBook.id).member_number, "AB-1");

  // Retour sur B : l'emprunt repart avec sa date de retour.
  deskB.returnBook(localBook.id);
  const returned = deskB
    .pendingMutations()
    .find((row) => row.entity_type === "loan");
  assert.equal(returned.entity_id, loan.serverId);
  assert.ok(JSON.parse(returned.payload).returnedAt);
  deskB.acknowledgeMutations(deskB.pendingMutations().map((row) => row.mutation_id));

  // Nouvel emprunt fait ailleurs puis supprimé.
  deskB.applyRemoteChanges(
    [
      change("loan", "loan-remote", {
        ...loan,
        serverId: "loan-remote",
        borrowedAt: new Date().toISOString(),
      }),
    ],
    3,
  );
  assert.equal(deskB.activeLoanForBook(localBook.id).server_id, "loan-remote");
  deskB.applyRemoteChanges(
    [{ operation: "delete", entityType: "loan", entityId: "loan-remote" }],
    4,
  );
  assert.equal(deskB.activeLoanForBook(localBook.id), null);
  assert.equal(deskB.getBook(localBook.id).status, "a_encoder");
});

test("envoie les comptes et l'activité du poste dans son rapport", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-sync-report-"));
  const database = new LibraryDatabase(path.join(directory, "catalogue.db"));
  database.createUser({
    name: "Admin",
    email: "admin@bztf.org",
    password: "mot-de-passe-solide",
    role: "admin",
  });
  const book = database.createBook({ title: "Livre rapporté" });
  database.addActivity("lecture", "succes", book.id, "Tag lu", book.epc, "E280TID");
  const reports = [];
  const server = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : null;
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/api/v1/devices/register")
      return response.end(JSON.stringify({ registered: true }));
    if (request.url === "/api/v1/sync/push")
      return response.end(
        JSON.stringify({
          acknowledgedMutationIds: body.mutations.map((item) => item.mutationId),
          cursor: 1,
        }),
      );
    if (request.url.startsWith("/api/v1/sync?"))
      return response.end(JSON.stringify({ cursor: 1, changes: [], hasMore: false }));
    if (request.url.endsWith("/report")) {
      reports.push({ url: request.url, body });
      const ids = body.activity.map((entry) => entry.localId);
      return response.end(
        JSON.stringify({
          usersStored: body.users?.length ?? 0,
          activityAcknowledgedUntil: ids.length ? Math.max(...ids) : null,
        }),
      );
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Route inconnue" }));
  });
  const service = new SyncService(database);
  try {
    const port = await listen(server);
    service.initialize();
    const status = await service.configure({
      serverUrl: `http://127.0.0.1:${port}`,
      apiKey: "secret-test",
      deviceName: "Poste de test",
    });
    assert.equal(status.connected, true);
    assert.equal(status.reportError, null);

    const [first] = reports;
    assert.equal(first.url, `/api/v1/devices/${service.deviceId}/report`);
    assert.equal(first.body.platform, "windows");
    assert.equal(first.body.name, "Poste de test");
    assert.deepEqual(
      first.body.users.map((user) => [user.email, user.role, user.active]),
      [["admin@bztf.org", "admin", true]],
    );
    assert.doesNotMatch(JSON.stringify(first.body), /password|salt|hash/i);
    const read = first.body.activity.find((entry) => entry.type === "lecture");
    assert.equal(read.bookServerId, book.server_id);
    assert.equal(read.tid, "E280TID");

    // Le rapport suivant ne renvoie que l'activité nouvelle.
    database.addActivity("connexion", "succes", null, "Lecteur connecté");
    await service.syncNow();
    const last = reports.at(-1).body.activity;
    assert.deepEqual(last.map((entry) => entry.type), ["connexion"]);
  } finally {
    service.close();
    await close(server);
    database.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("un serveur sans rapport d'appareil ne bloque pas la synchronisation", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-sync-old-"));
  const database = new LibraryDatabase(path.join(directory, "catalogue.db"));
  const server = http.createServer((request, response) => {
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/api/v1/devices/register")
      return response.end(JSON.stringify({ registered: true }));
    if (request.url.startsWith("/api/v1/sync?"))
      return response.end(JSON.stringify({ cursor: 0, changes: [], hasMore: false }));
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Route inconnue" }));
  });
  const service = new SyncService(database);
  try {
    const port = await listen(server);
    service.initialize();
    const status = await service.configure({
      serverUrl: `http://127.0.0.1:${port}`,
      apiKey: "secret-test",
    });
    assert.equal(status.connected, true);
    assert.equal(status.error, null);
    assert.equal(status.reportError, "Route inconnue");
  } finally {
    service.close();
    await close(server);
    database.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
