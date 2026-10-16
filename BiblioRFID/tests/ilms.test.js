import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {
  createGatewayProxy,
  gatewayTarget,
  normalizeGatewayUrl,
  resolveIlmsRoot,
  startIlmsServer,
} from "../lib/ilms.js";

function listen(server) {
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve(server.address().port)),
  );
}

function close(server) {
  return new Promise((resolve) => (server ? server.close(resolve) : resolve()));
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

test("retire le préfixe /api que l’application ajoute à ses appels", () => {
  const base = "https://gateway.exemple.org";
  // Les routes de la passerelle sont nommées d'après le service.
  assert.equal(
    gatewayTarget(base, "/api/library-service/api/v1/libraries", "?limit=2"),
    "https://gateway.exemple.org/library-service/api/v1/libraries?limit=2",
  );
  assert.equal(
    gatewayTarget(base, "/api/auth-service/api/v1/auth/login"),
    "https://gateway.exemple.org/auth-service/api/v1/auth/login",
  );
  // Un chemin hors /api est relayé tel quel.
  assert.equal(
    gatewayTarget(base, "/ilms-auth-service/oauth/token"),
    "https://gateway.exemple.org/ilms-auth-service/oauth/token",
  );
});

test("sert le paquet à la racine de son port et relaie son API", async () => {
  const directory = bundle();
  const calls = [];
  const upstream = http.createServer((request, response) => {
    calls.push({
      url: request.url,
      authorization: request.headers.authorization,
      origin: request.headers.origin,
    });
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
  });
  const upstreamPort = await listen(upstream);
  const ilms = await startIlmsServer({
    ilmsRoot: directory,
    baseUrl: () => `http://127.0.0.1:${upstreamPort}`,
    port: 0,
    maxPort: 0,
  });

  try {
    assert.ok(ilms.origin, "le serveur ILMS doit démarrer");

    const index = await fetch(`${ilms.origin}/`);
    assert.equal(index.status, 200);
    assert.match(index.headers.get("content-type"), /text\/html/);
    assert.match(await index.text(), /app-root/);

    const script = await fetch(`${ilms.origin}/main-ABCD1234.js`);
    assert.equal(
      script.headers.get("content-type"),
      "text/javascript; charset=utf-8",
    );
    assert.match(script.headers.get("cache-control"), /immutable/);

    // Les assets copiés tels quels peuvent changer sans changer de nom.
    const logo = await fetch(`${ilms.origin}/assets/logo.svg`);
    assert.equal(logo.headers.get("cache-control"), "no-cache");

    // Lien profond Angular : l'index du paquet.
    const deep = await fetch(`${ilms.origin}/admin/libraries/42/dashboard`);
    assert.equal(deep.status, 200);
    assert.match(await deep.text(), /app-root/);

    // Remontée de dossier : traitée comme un lien profond, jamais servie.
    const escape = await fetch(`${ilms.origin}/..%2f..%2fserver.js`);
    assert.equal(escape.status, 200);
    assert.match(await escape.text(), /app-root/);

    const relayed = await fetch(
      `${ilms.origin}/api/library-service/api/v1/stats?limit=3`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer jeton-de-test",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ q: 1 }),
      },
    );
    assert.equal(relayed.status, 200);
    assert.deepEqual(await relayed.json(), { ok: true });
  } finally {
    await close(ilms.server);
    await close(upstream);
  }

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/library-service/api/v1/stats?limit=3");
  assert.equal(calls[0].authorization, "Bearer jeton-de-test");
  // L'origine du poste n'a pas de sens pour la passerelle.
  assert.equal(calls[0].origin, undefined);
});

test("n’écoute que sur la boucle locale", async () => {
  const ilms = await startIlmsServer({
    ilmsRoot: bundle(),
    baseUrl: () => "",
    port: 0,
    maxPort: 0,
  });
  try {
    assert.equal(ilms.server.address().address, "127.0.0.1");
  } finally {
    await close(ilms.server);
  }
});

test("annonce clairement un exécutable produit sans le module ILMS", async () => {
  const ilms = await startIlmsServer({
    ilmsRoot: null,
    baseUrl: () => "",
    port: 0,
    maxPort: 0,
  });
  try {
    const response = await fetch(`${ilms.origin}/`);
    assert.equal(response.status, 503);
    assert.match(response.headers.get("content-type"), /text\/html/);
    assert.match(await response.text(), /Module ILMS absent/);
  } finally {
    await close(ilms.server);
  }
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

test("explique la coupure réseau au lieu d’un échec brut", async () => {
  const proxy = createGatewayProxy({
    baseUrl: () => "http://127.0.0.1:1",
    timeoutMs: 500,
  });
  const server = http.createServer((request, response) =>
    proxy(request, response, new URL(request.url, "http://localhost")),
  );
  const port = await listen(server);
  try {
    const response = await fetch(`http://127.0.0.1:${port}/api/health`);
    assert.equal(response.status, 504);
    const payload = await response.json();
    assert.equal(payload.offline, true);
    assert.match(payload.error, /injoignable|à temps/);
  } finally {
    await close(server);
  }

  const unset = createGatewayProxy({ baseUrl: () => "" });
  const bare = http.createServer((request, response) =>
    unset(request, response, new URL(request.url, "http://localhost")),
  );
  const barePort = await listen(bare);
  try {
    const response = await fetch(`http://127.0.0.1:${barePort}/api/health`);
    assert.equal(response.status, 503);
    const payload = await response.json();
    assert.equal(payload.offline, true);
    assert.match(payload.error, /non configurée/);
  } finally {
    await close(bare);
  }
});
