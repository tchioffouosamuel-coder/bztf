import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase } from "../lib/database.js";
import { SyncService } from "../lib/sync-service.js";

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

