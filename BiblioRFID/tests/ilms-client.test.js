import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase } from "../lib/database.js";
import { IlmsClient } from "../lib/ilms-client.js";

function listen(server) {
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve(server.address().port)),
  );
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function database() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-ilms-cli-"));
  return new LibraryDatabase(path.join(directory, "library.db"));
}

function configure(db, gatewayUrl) {
  db.setSettings({
    ilms_gateway_url: gatewayUrl,
    ilms_username: "poste-1",
    ilms_password: "secret-du-poste",
    ilms_library_id: "11111111-1111-4111-8111-111111111111",
  });
}

/** Passerelle simulée : connexion, puis recherche d'exemplaire par tag. */
function gateway({ copy = null, expiresIn = 3600, loginStatus = 200 } = {}) {
  const calls = { logins: 0, lookups: [], authorizations: [] };
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/auth-service/api/v1/auth/login") {
      calls.logins += 1;
      if (loginStatus !== 200) {
        response.writeHead(loginStatus, { "Content-Type": "application/json" });
        return response.end(JSON.stringify({ message: "Identifiants refusés" }));
      }
      response.writeHead(200, { "Content-Type": "application/json" });
      return response.end(
        JSON.stringify({
          user: { id: "u1" },
          access_token: {
            type: "Bearer",
            token: `jeton-${calls.logins}`,
            expires_in: expiresIn,
          },
        }),
      );
    }
    if (url.pathname.endsWith("/copies/by-rfid")) {
      calls.lookups.push(url.search);
      calls.authorizations.push(request.headers.authorization);
      if (copy === "unauthorized-once" && calls.authorizations.length === 1) {
        response.writeHead(401, { "Content-Type": "application/json" });
        return response.end(JSON.stringify({ message: "Jeton expiré" }));
      }
      response.writeHead(200, { "Content-Type": "application/json" });
      return response.end(copy && copy !== "unauthorized-once" ? JSON.stringify(copy) : "");
    }
    response.writeHead(404);
    response.end();
  });
  return { server, calls };
}

test("ne garde qu’une connexion tant que le jeton est valide", async () => {
  const { server, calls } = gateway({ copy: { id: "c1", rfid_code: "ABC" } });
  const port = await listen(server);
  const db = database();
  configure(db, `http://127.0.0.1:${port}`);
  const client = new IlmsClient(db);

  try {
    await client.findCopyByTag({ epc: "ABC" });
    await client.findCopyByTag({ epc: "ABC" });
    assert.equal(calls.logins, 1, "le jeton doit être réutilisé");
    assert.deepEqual(calls.authorizations, [
      "Bearer jeton-1",
      "Bearer jeton-1",
    ]);
  } finally {
    await close(server);
    db.close();
  }
});

test("redemande un jeton expiré, et un seul malgré des appels simultanés", async () => {
  const { server, calls } = gateway({
    copy: { id: "c1" },
    expiresIn: 30, // sous la marge de renouvellement : toujours à renouveler
  });
  const port = await listen(server);
  const db = database();
  configure(db, `http://127.0.0.1:${port}`);
  const client = new IlmsClient(db);

  try {
    await Promise.all([
      client.findCopyByTag({ epc: "A" }),
      client.findCopyByTag({ epc: "B" }),
    ]);
    // Deux appels lancés ensemble ne doivent provoquer qu'une connexion.
    assert.equal(calls.logins, 1);
    await client.findCopyByTag({ epc: "C" });
    assert.equal(calls.logins, 2, "le jeton périmé doit être redemandé");
  } finally {
    await close(server);
    db.close();
  }
});

test("rejoue l’appel une fois quand la passerelle refuse le jeton", async () => {
  const { server, calls } = gateway({ copy: "unauthorized-once" });
  const port = await listen(server);
  const db = database();
  configure(db, `http://127.0.0.1:${port}`);
  const client = new IlmsClient(db);

  try {
    const copy = await client.findCopyByTag({ tid: "E280" });
    assert.equal(copy, null);
    assert.equal(calls.logins, 2, "le jeton refusé doit être redemandé");
    assert.deepEqual(calls.authorizations, [
      "Bearer jeton-1",
      "Bearer jeton-2",
    ]);
  } finally {
    await close(server);
    db.close();
  }
});

test("un tag inconnu est une réponse, pas une erreur", async () => {
  const { server } = gateway({ copy: null });
  const port = await listen(server);
  const db = database();
  configure(db, `http://127.0.0.1:${port}`);
  const client = new IlmsClient(db);

  try {
    assert.equal(await client.findCopyByTag({ epc: "INCONNU" }), null);
  } finally {
    await close(server);
    db.close();
  }
});

test("traduit l’exemplaire trouvé dans les termes du poste", async () => {
  const { server, calls } = gateway({
    copy: {
      id: "c1",
      number: "EX-12",
      document_id: "d1",
      document_number: "N-7",
      quote: "A 123",
      rfid_code: "42434D0107EA000000010123",
      rfid_tid: "E28068940000500A12AB0010",
      status: 1,
      shelf_name: "Rayon 3",
      section_name: "Adultes",
    },
  });
  const port = await listen(server);
  const db = database();
  configure(db, `http://127.0.0.1:${port}`);
  const client = new IlmsClient(db);

  try {
    const copy = await client.findCopyByTag({
      epc: "42434D0107EA000000010123",
      tid: "E28068940000500A12AB0010",
    });
    assert.equal(copy.epc, "42434D0107EA000000010123");
    assert.equal(copy.tid, "E28068940000500A12AB0010");
    assert.equal(copy.quote, "A 123");
    assert.equal(copy.documentNumber, "N-7");
    // Les deux identifiants sont transmis : le serveur choisit le TID.
    assert.match(calls.lookups[0], /epc=42434D0107EA000000010123/);
    assert.match(calls.lookups[0], /tid=E28068940000500A12AB0010/);
  } finally {
    await close(server);
    db.close();
  }
});

test("distingue une panne réseau d’un refus de l’ILMS", async () => {
  const db = database();
  configure(db, "http://127.0.0.1:1");
  const unreachable = new IlmsClient(db, { timeoutMs: 400 });
  await assert.rejects(() => unreachable.findCopyByTag({ epc: "A" }), (error) => {
    assert.equal(error.offline, true);
    assert.match(error.message, /injoignable|à temps/);
    return true;
  });

  const { server } = gateway({ loginStatus: 401 });
  const port = await listen(server);
  configure(db, `http://127.0.0.1:${port}`);
  const refused = new IlmsClient(db);
  try {
    await assert.rejects(() => refused.findCopyByTag({ epc: "A" }), (error) => {
      assert.equal(error.offline, undefined);
      assert.match(error.message, /Identifiants refusés/);
      return true;
    });
  } finally {
    await close(server);
    db.close();
  }
});

test("refuse d’appeler l’ILMS tant que le compte du poste est incomplet", async () => {
  const db = database();
  db.setSettings({ ilms_gateway_url: "https://exemple.org" });
  const client = new IlmsClient(db);
  try {
    assert.equal(client.configured, false);
    await assert.rejects(
      () => client.findCopyByTag({ epc: "A" }),
      /incomplet/,
    );
    await assert.rejects(() => client.findCopyByTag({}), /EPC ou le TID/);
  } finally {
    db.close();
  }
});

test("ne laisse pas le mot de passe du poste ressortir des réglages", () => {
  const db = database();
  configure(db, "https://exemple.org");
  try {
    const settings = db.settings();
    assert.equal(settings.ilms_password, undefined);
    assert.equal(settings.ilms_password_set, true);
    assert.equal(settings.ilms_username, "poste-1");
  } finally {
    db.close();
  }
});

function operatorFixture(handler) {
  const session = {
    gatewayUrl: "https://operator.test",
    accountId: "operator",
    libraryId: "library-operator",
    accessToken: "operator-token",
  };
  const calls = [];
  const db = database();
  configure(db, "https://service.test");
  const client = new IlmsClient(db, {
    getSession: () => session,
    fetchImpl: async (url, options) => {
      calls.push({ url, ...options });
      return handler(url, options);
    },
  });
  return { client, db, session, calls };
}

test("la recherche utilise la bibliotheque et le jeton de l'operateur, puis lit la notice", async () => {
  const { client, db, calls } = operatorFixture(url => Response.json(url.includes("/copies/") ? {
    id: "c1", document_id: "d1", library_id: "library-operator", number: "EX-12", status: 3,
  } : { id: "d1", title: "Titre ILMS", primary_authors: ["Auteur"], isbn13: "9782070408504" }));
  try {
    const copy = await client.findCopyByTag({ epc: "AA12", tid: "BB34", includeDocument: true });
    assert.deepEqual(calls.map(call => call.url), [
      "https://operator.test/library-service/api/v1/libraries/library-operator/copies/by-rfid?epc=AA12&tid=BB34",
      "https://operator.test/library-service/api/v1/libraries/library-operator/documents/d1",
    ]);
    assert.ok(calls.every(call => call.headers.Authorization === "Bearer operator-token" && call.redirect === "error"));
    assert.equal(copy.document.title, "Titre ILMS");
    assert.deepEqual(copy.document.authors, ["Auteur"]);
    assert.equal(copy.document.isbn, "9782070408504");
    assert.equal(copy.status, 3, "l'etat de conservation n'est pas une disponibilite de pret");
  } finally { db.close(); }
});

test("session expiree ou sans bibliotheque : aucun repli sur le compte de service", async () => {
  const { client, db, session, calls } = operatorFixture(() => assert.fail("aucun appel attendu"));
  try {
    session.accessToken = "";
    await assert.rejects(client.findCopyByTag({ epc: "AA12" }), error => error.status === 401);
    session.libraryId = null;
    await assert.rejects(client.findCopyByTag({ epc: "AA12" }), error => error.status === 403);
    assert.equal(calls.length, 0);
  } finally { db.close(); }
});

test("un refus du jeton operateur ne reconnecte pas le compte de service", async () => {
  const { client, db, calls } = operatorFixture(() => Response.json({ message: "Session ILMS refusée" }, { status: 401 }));
  try {
    await assert.rejects(client.findCopyByTag({ epc: "AA12" }), error => error.status === 401);
    assert.equal(calls.length, 1);
  } finally { db.close(); }
});

test("un changement de bibliotheque pendant la recherche invalide sa reponse", async () => {
  let finish;
  const { client, db, session, calls } = operatorFixture(() => new Promise(resolve => { finish = resolve; }));
  try {
    const lookup = client.findCopyByTag({ epc: "AA12", includeDocument: true });
    session.libraryId = "another-library";
    finish(Response.json({ id: "c1", document_id: "d1" }));
    await assert.rejects(lookup, error => error.status === 409);
    assert.equal(calls.length, 1);
  } finally { db.close(); }
});

test("une notice indisponible conserve l'identite de l'exemplaire", async () => {
  const { client, db } = operatorFixture(url => url.includes("/copies/")
    ? Response.json({ id: "c1", number: "EX-12", document_id: "d1" })
    : Response.json({ message: "Erreur interne" }, { status: 503 }));
  try {
    const copy = await client.findCopyByTag({ epc: "AA12", includeDocument: true });
    assert.equal(copy.number, "EX-12");
    assert.equal(copy.document, null);
    assert.match(copy.documentError, /indisponible/);
  } finally { db.close(); }
});

test("une deconnexion pendant la lecture de notice invalide aussi l'exemplaire", async () => {
  const { client, db, session } = operatorFixture(url => {
    if (url.includes("/copies/")) return Response.json({ id: "c1", document_id: "d1" });
    session.accessToken = "";
    return Response.json({ id: "d1", title: "Notice obsolete" });
  });
  try {
    await assert.rejects(client.findCopyByTag({ epc: "AA12", includeDocument: true }), error => error.status === 401);
  } finally { db.close(); }
});

test("un 404 de route absente et une reponse mal formee ne signifient pas tag inconnu", async () => {
  for (const response of [new Response("", { status: 404 }), new Response("<html>Erreur</html>"), Response.json({}), Response.json(false)]) {
    const { client, db } = operatorFixture(() => response);
    try {
      await assert.rejects(client.findCopyByTag({ epc: "AA12" }), error => [404, 502].includes(error.status));
    } finally { db.close(); }
  }
});

test("rejette une correspondance rendue hors bibliotheque", async () => {
  const { client, db } = operatorFixture(() => Response.json({ id: "c1", library_id: "other-library" }));
  try {
    await assert.rejects(client.findCopyByTag({ epc: "AA12" }), error => error.status === 502);
  } finally { db.close(); }
});
