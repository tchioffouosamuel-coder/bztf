import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_AGENT_ORIGINS,
  agentHeaders,
  allowOrigin,
  normalizeAgentOrigin,
  parseAgentOrigins,
  publicSnapshot,
} from "../lib/reader-agent.js";

test("n'accepte le clair qu'en local", () => {
  assert.equal(
    normalizeAgentOrigin("https://gateway.bibliotheque-ztf.org"),
    "https://gateway.bibliotheque-ztf.org",
  );
  assert.equal(normalizeAgentOrigin("http://127.0.0.1:4200"), "http://127.0.0.1:4200");
  assert.equal(normalizeAgentOrigin("http://localhost:4200"), "http://localhost:4200");
  // Un flux en clair sur le réseau laisserait lire les identifiants de tags de
  // toute la bibliothèque.
  assert.equal(normalizeAgentOrigin("http://192.168.1.40"), "");
  assert.equal(normalizeAgentOrigin("http://exemple.test"), "");
});

test("exige exactement une origine", () => {
  // Un chemin, une requête ou un fragment n'est pas une origine : les accepter
  // laisserait une URL habilement formée se faire passer pour celle réglée.
  assert.equal(normalizeAgentOrigin("https://gateway.bibliotheque-ztf.org/reader"), "");
  assert.equal(normalizeAgentOrigin("https://gateway.bibliotheque-ztf.org/?x=1"), "");
  assert.equal(normalizeAgentOrigin("https://gateway.bibliotheque-ztf.org/#a"), "");
  assert.equal(normalizeAgentOrigin("https://jean:secret@gateway.bibliotheque-ztf.org"), "");
  // Un caractère de contrôle à l'intérieur est un découpage d'en-tête ; un
  // retour à la ligne en bout n'est que du blanc dans un réglage, et se coupe.
  assert.equal(normalizeAgentOrigin("https://gateway\n.bibliotheque-ztf.org"), "");
  assert.equal(
    normalizeAgentOrigin("  https://gateway.bibliotheque-ztf.org\n"),
    "https://gateway.bibliotheque-ztf.org",
  );
  assert.equal(normalizeAgentOrigin("ws://gateway.bibliotheque-ztf.org"), "");
  assert.equal(normalizeAgentOrigin("file:///C:/"), "");
  assert.equal(normalizeAgentOrigin(""), "");
  assert.equal(normalizeAgentOrigin(null), "");
});

test("écarte une entrée abîmée sans fermer l'agent", () => {
  assert.deepEqual(
    parseAgentOrigins("https://gateway.bibliotheque-ztf.org, http://192.168.1.40 http://localhost:4200"),
    ["https://gateway.bibliotheque-ztf.org", "http://localhost:4200"],
  );
  assert.deepEqual(parseAgentOrigins(""), []);
  assert.deepEqual(parseAgentOrigins(DEFAULT_AGENT_ORIGINS), [
    "https://gateway.bibliotheque-ztf.org",
  ]);
});

test("ne sert qu'une origine réglée, et jamais l'étoile", () => {
  const reglees = parseAgentOrigins(DEFAULT_AGENT_ORIGINS);
  assert.equal(
    allowOrigin("https://gateway.bibliotheque-ztf.org", reglees),
    "https://gateway.bibliotheque-ztf.org",
  );
  assert.equal(allowOrigin("https://autre.example", reglees), "");
  // Une requête sans en-tête `Origin` n'est pas une page : elle n'a rien à
  // faire ici, et lui répondre `*` ouvrirait l'agent à tout le web.
  assert.equal(allowOrigin(undefined, reglees), "");
  assert.equal(agentHeaders("https://gateway.bibliotheque-ztf.org", "text/event-stream")[
    "Access-Control-Allow-Origin"
  ], "https://gateway.bibliotheque-ztf.org");
  assert.equal(agentHeaders("https://gateway.bibliotheque-ztf.org", "text/event-stream").Vary, "Origin");
});

test("ne laisse sortir que le matériel", () => {
  const interne = {
    ok: true,
    count: 1,
    tags: [
      {
        epc: "42434D0120260001ABCD",
        tid: "E2800001",
        rssi: -52,
        antenna: 1,
        book: { id: 7, title: "Titre du poste" },
        subscriber: null,
        staff: null,
        kind: "book",
      },
    ],
    book: { id: 7, title: "Titre du poste" },
    books: [{ id: 7 }],
    subscriber: null,
    staff: null,
    unknownCount: 0,
    presenceSessionId: 3,
    reader: { connected: true, status: "USB", reader: "Lecteur", serialNumber: "SN-42" },
    mode: "continuous",
  };

  const dehors = publicSnapshot(interne);

  assert.deepEqual(dehors.tags, [
    { epc: "42434D0120260001ABCD", tid: "E2800001", rssi: -52, antenna: 1 },
  ]);
  // Le poste n'est plus la référence du catalogue : laisser sortir le livre
  // qu'il reconnaît ferait afficher un titre que la passerelle ignore, ou pire,
  // un titre périmé.
  assert.equal("book" in dehors, false);
  assert.equal("books" in dehors, false);
  assert.equal("subscriber" in dehors, false);
  assert.equal("staff" in dehors, false);
  assert.equal(JSON.stringify(dehors).includes("Titre du poste"), false);
  assert.equal(dehors.reader.serialNumber, undefined);
  assert.deepEqual(dehors.reader, { connected: true, status: "USB", reader: "Lecteur" });
  assert.equal(dehors.count, 1);
});

test("supporte un instantané vide ou abîmé", () => {
  assert.deepEqual(publicSnapshot({}).tags, []);
  assert.equal(publicSnapshot(null).count, 0);
  assert.equal(publicSnapshot(undefined).reader.connected, false);
});
