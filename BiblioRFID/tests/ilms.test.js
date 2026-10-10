import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {
  createGatewayProxy,
  normalizeGatewayUrl,
  resolveIlmsRoot,
  serveIlms,
} from "../lib/ilms.js";

function listen(server) {
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve(server.address().port)),
  );
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

/** Paquet Angular minimal : un index, un script haché, un asset non haché. */
function bundle() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-ilms-"));
  fs.writeFileSync(
    path.join(directory, "index.html"),
    "<!doctype html><title>ILMS</title><app-root></app-root>",
  );
  fs.writeFileSync(path.join(directory, "main-ABCD1234.js"), "export {};");
  fs.mkdirSync(path.join(directory, "assets"));
  fs.writeFileSync(path.join(directory, "assets", "logo.svg"), "<svg/>");
  return directory;
}

async function withServer(handler, visit) {
  const server = http.createServer(handler);
  const port = await listen(server);
  try {
    return await visit(`http://127.0.0.1:${port}`);
  } finally {
    await close(server);
  }
}

test("trouve le paquet ILMS par variable d’environnement puis par le dépôt", () => {
  const directory = bundle();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-root-"));
  assert.equal(resolveIlmsRoot({ root, override: directory }), directory);
  assert.equal(resolveIlmsRoot({ root }), null);

  fs.mkdirSync(path.join(root, "ilms"));
  fs.writeFileSync(path.join(root, "ilms", "index.html"), "<title>x</title>");
  assert.equal(resolveIlmsRoot({ root }), path.join(root, "ilms"));
  // Un dossier sans index.html ne compte pas comme un paquet installé.
  assert.equal(
    resolveIlmsRoot({ root: fs.mkdtempSync(path.join(os.tmpdir(), "vide-")) }),
    null,
  );
});

test("sert le paquet, ses liens profonds et refuse d’en sortir", async () => {
  const directory = bundle();
  const stationIndex = "PAGE DU POSTE";
  await withServer(
    (request, response) => {
      const url = new URL(request.url, "http://localhost");
      if (serveIlms(response, url.pathname, directory, request.method)) return;
      response.writeHead(200, { "Content-Type": "text/html" });
      response.end(stationIndex);
    },
    async (origin) => {
      const redirect = await fetch(`${origin}/ilms`, { redirect: "manual" });
      assert.equal(redirect.status, 302);
      assert.equal(redirect.headers.get("location"), "/ilms/");

      const index = await fetch(`${origin}/ilms/`);
      assert.equal(index.status, 200);
      assert.match(index.headers.get("content-type"), /text\/html/);
      assert.match(index.headers.get("cache-control"), /no-store/);
      assert.match(await index.text(), /app-root/);

      const script = await fetch(`${origin}/ilms/main-ABCD1234.js`);
      assert.equal(script.headers.get("content-type"), "text/javascript; charset=utf-8");
      assert.match(script.headers.get("cache-control"), /immutable/);

      // Les assets copiés tels quels peuvent changer sans changer de nom.
      const logo = await fetch(`${origin}/ilms/assets/logo.svg`);
      assert.equal(logo.headers.get("content-type"), "image/svg+xml; charset=utf-8");
      assert.equal(logo.headers.get("cache-control"), "no-cache");

      // Lien profond Angular : l'index du paquet, jamais celui du poste.
      const deep = await fetch(`${origin}/ilms/admin/libraries/42/dashboard`);
      assert.equal(deep.status, 200);
      const deepBody = await deep.text();
      assert.match(deepBody, /app-root/);
      assert.doesNotMatch(deepBody, /PAGE DU POSTE/);

      // Remontée de dossier : traitée comme introuvable.
      const escape = await fetch(`${origin}/ilms/..%2f..%2fserver.js`);
      assert.equal(escape.status, 200);
      assert.match(await escape.text(), /app-root/);

      const posted = await fetch(`${origin}/ilms/`, { method: "POST" });
      assert.equal(posted.status, 405);
    },
  );
});

test("annonce clairement un exécutable produit sans le module ILMS", async () => {
  await withServer(
    (request, response) => {
      const url = new URL(request.url, "http://localhost");
      serveIlms(response, url.pathname, null, request.method);
    },
    async (origin) => {
      const response = await fetch(`${origin}/ilms/`);
      assert.equal(response.status, 503);
      assert.match(response.headers.get("content-type"), /text\/html/);
      assert.match(await response.text(), /Module ILMS absent/);
    },
  );
});

test("normalise l’adresse de la passerelle et refuse les autres schémas", () => {
  assert.equal(
    normalizeGatewayUrl("https://gateway.bibliotheque-ztf.org/"),
    "https://gateway.bibliotheque-ztf.org",
  );
  assert.equal(
    normalizeGatewayUrl("  https://exemple.org/api/  "),
    "https://exemple.org/api",
  );
  assert.equal(normalizeGatewayUrl(""), "");
  assert.equal(normalizeGatewayUrl(null), "");
  assert.throws(() => normalizeGatewayUrl("ftp://exemple.org"), /HTTP/);
  assert.throws(() => normalizeGatewayUrl("pas une adresse"), /invalide/);
});

test("relaie la passerelle en conservant le jeton et sans l’origine du poste", async () => {
  const received = [];
  const upstream = http.createServer((request, response) => {
    received.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      origin: request.headers.origin,
      host: request.headers.host,
    });
    response.writeHead(201, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
  });
  const upstreamPort = await listen(upstream);
  const base = `http://127.0.0.1:${upstreamPort}`;
  const proxy = createGatewayProxy({ baseUrl: () => base });

  try {
    await withServer(
      (request, response) =>
        proxy(request, response, new URL(request.url, "http://localhost")),
      async (origin) => {
        const response = await fetch(
          `${origin}/gateway/library-service/api/v1/libraries?limit=2`,
          {
            method: "POST",
            headers: {
              Authorization: "Bearer jeton-de-test",
              Origin: origin,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ name: "Test" }),
          },
        );
        assert.equal(response.status, 201);
        assert.deepEqual(await response.json(), { ok: true });
      },
    );
  } finally {
    await close(upstream);
  }

  assert.equal(received.length, 1);
  assert.equal(received[0].method, "POST");
  assert.equal(received[0].url, "/library-service/api/v1/libraries?limit=2");
  assert.equal(received[0].authorization, "Bearer jeton-de-test");
  assert.equal(received[0].origin, undefined);
  assert.equal(received[0].host, `127.0.0.1:${upstreamPort}`);
});

test("explique la coupure réseau au lieu d’un échec brut", async () => {
  const unreachable = createGatewayProxy({
    baseUrl: () => "http://127.0.0.1:1",
    timeoutMs: 500,
  });
  await withServer(
    (request, response) =>
      unreachable(request, response, new URL(request.url, "http://localhost")),
    async (origin) => {
      const response = await fetch(`${origin}/gateway/health`);
      assert.equal(response.status, 504);
      const payload = await response.json();
      assert.equal(payload.offline, true);
      assert.match(payload.error, /injoignable|à temps/);
    },
  );

  const unset = createGatewayProxy({ baseUrl: () => "" });
  await withServer(
    (request, response) =>
      unset(request, response, new URL(request.url, "http://localhost")),
    async (origin) => {
      const response = await fetch(`${origin}/gateway/health`);
      assert.equal(response.status, 503);
      const payload = await response.json();
      assert.equal(payload.offline, true);
      assert.match(payload.error, /non configurée/);
    },
  );
});
