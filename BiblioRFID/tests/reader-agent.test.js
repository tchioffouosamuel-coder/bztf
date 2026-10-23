import test from "node:test";
import assert from "node:assert/strict";
import {
  AGENT_EMPTY_EPC,
  AGENT_MAX_BODY_BYTES,
  DEFAULT_AGENT_ORIGINS,
  agentHeaders,
  agentKeyAccepted,
  allowOrigin,
  generateAgentKey,
  normalizeAgentOrigin,
  normalizeEpcToWrite,
  parseAgentOrigins,
  publicSnapshot,
  readAgentBody,
  writeTarget,
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

// --- L'écriture, ouverte le 21 octobre 2026 -------------------------------

test("une écriture sans clé réglée est refusée", () => {
  // Fermé par défaut : un poste mis à jour vers une version qui sait écrire ne
  // doit pas se mettre à accepter des écritures parce que personne n'a encore
  // ouvert ses réglages.
  assert.equal(agentKeyAccepted("peu-importe", ""), false);
  assert.equal(agentKeyAccepted("peu-importe", null), false);
  assert.equal(agentKeyAccepted("peu-importe", "   "), false);
  // Et une clé réglée ne s'ouvre pas sur une demande qui n'en présente aucune.
  assert.equal(agentKeyAccepted("", "cle-du-poste"), false);
  assert.equal(agentKeyAccepted(undefined, "cle-du-poste"), false);
});

test("la clé d'appairage est comparée en entier", () => {
  assert.equal(agentKeyAccepted("cle-du-poste", "cle-du-poste"), true);
  assert.equal(agentKeyAccepted(" cle-du-poste ", "cle-du-poste"), true);
  assert.equal(agentKeyAccepted("cle-du-poste-x", "cle-du-poste"), false);
  assert.equal(agentKeyAccepted("cle-du-postf", "cle-du-poste"), false);
  // Une casse différente est une autre clé : la clé n'est pas un identifiant.
  assert.equal(agentKeyAccepted("CLE-DU-POSTE", "cle-du-poste"), false);
});

test("n'écrit que 96 bits, et rien d'autre", () => {
  assert.equal(
    normalizeEpcToWrite("42434d0120260000000100ab"),
    "42434D0120260000000100AB",
  );
  assert.equal(normalizeEpcToWrite(" 42434D0120260000000100AB "), "42434D0120260000000100AB");
  // 23 ou 25 caractères, c'est un tag que personne ne saura relire.
  assert.equal(normalizeEpcToWrite("42434D0120260000000100A"), "");
  assert.equal(normalizeEpcToWrite("42434D0120260000000100ABC"), "");
  assert.equal(normalizeEpcToWrite("ZZ434D0120260000000100AB"), "");
  assert.equal(normalizeEpcToWrite(""), "");
  assert.equal(normalizeEpcToWrite(null), "");
  // Le désencodage écrit 24 zéros : c'est un EPC écrivable comme un autre.
  assert.equal(normalizeEpcToWrite(AGENT_EMPTY_EPC), AGENT_EMPTY_EPC);
});

test("refuse d'écrire sans un seul tag portant un TID", () => {
  assert.match(writeTarget({ tags: [] }).error, /Aucun tag/);
  assert.match(
    writeTarget({ tags: [{ tid: "E2800001" }, { tid: "E2800002" }] }).error,
    /Plusieurs tags/,
  );
  // Sans TID, l'écriture ne peut pas être relue en filtrant la puce, donc pas
  // vérifiée — et une écriture non vérifiée associe un jour le mauvais livre.
  assert.match(writeTarget({ tags: [{ epc: "AABB", tid: "" }] }).error, /TID/);
  assert.match(writeTarget(null).error, /Aucun tag/);

  const cible = writeTarget({ tags: [{ epc: "42434d01", tid: "e2800001" }] });
  assert.equal(cible.error, undefined);
  // Majuscules, comme partout dans le contrat : l'index ne rattrape pas deux
  // écritures de casse différente.
  assert.deepEqual(cible.tag, { epc: "42434D01", tid: "E2800001" });
});

test("borne le corps pendant la lecture, pas après", async () => {
  const { Readable } = await import("node:stream");
  const petit = Readable.from([Buffer.from(JSON.stringify({ epc: "A".repeat(24) }))]);
  assert.deepEqual(await readAgentBody(petit), { epc: "A".repeat(24) });

  const vide = Readable.from([Buffer.from("")]);
  assert.deepEqual(await readAgentBody(vide), {});

  const abime = Readable.from([Buffer.from("{ceci n'est pas du json")]);
  await assert.rejects(() => readAgentBody(abime), /JSON/);

  // Attendre la fin pour mesurer laisserait un client occuper la mémoire du
  // poste avec un corps sans fin.
  const enorme = Readable.from([Buffer.alloc(AGENT_MAX_BODY_BYTES + 1, 0x20)]);
  await assert.rejects(() => readAgentBody(enorme), /volumineuse/);
});

test("la clé d'appairage évite les caractères qu'on recopie de travers", async () => {
  const { randomBytes } = await import("node:crypto");
  const cle = generateAgentKey(randomBytes);
  assert.equal(cle.length, 24);
  // Ni O ni 0, ni I ni 1 : la clé se note sur un papier et se retape ailleurs.
  assert.match(cle, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{24}$/);
  assert.notEqual(cle, generateAgentKey(randomBytes));

  // Mesure du 21 octobre 2026 : l'alphabet compte 32 symboles et 256 en est un
  // multiple exact, donc AUCUN octet n'est rejeté et chaque octet donne une
  // lettre. C'est ce qui rend le tirage uniforme — le rejet prévu dans le code
  // ne sert que si l'alphabet change de taille.
  const octets = (n) => Buffer.from(Array.from({ length: n }, (_, i) => (i % 2 ? 255 : 0)));
  assert.equal(generateAgentKey(octets, 4), "A9A9");
  // Toutes les valeurs d'octet tombent dans l'alphabet, aucune n'est perdue.
  const toutes = generateAgentKey((n) => Buffer.from(Array.from({ length: n }, (_, i) => i)), 256);
  assert.equal(toutes.length, 256);
  assert.equal(new Set(toutes).size, 32);
});
