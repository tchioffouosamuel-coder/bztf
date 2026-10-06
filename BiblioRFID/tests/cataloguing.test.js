import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { LibraryDatabase } from "../lib/database.js";
import {
  AiCataloguingService,
  normalizeAiRoles,
  normalizeFieldResponse,
  parseJsonResponse,
  serializeAiRoles,
} from "../lib/cataloguing/ai.js";
import {
  extractHints,
  extractIsbns,
  extractPublisher,
  extractTitleAndAuthor,
  extractYear,
} from "../lib/cataloguing/extract.js";
import {
  isValidIsbn,
  normalizeIsbn,
  toIsbn10,
  toIsbn13,
} from "../lib/cataloguing/isbn.js";
import { NoticeLookupService } from "../lib/cataloguing/lookup.js";
import { BnfSource, SudocSource } from "../lib/cataloguing/sources.js";
import {
  NoticeNetworkError,
  NoticeNotFoundError,
  noticeToBookFields,
  publicationYear,
} from "../lib/cataloguing/notice.js";
import {
  OcrService,
  normalizeOcrEngine,
  normalizeOcrLanguages,
} from "../lib/cataloguing/ocr.js";
import { CataloguingService, mergeFields } from "../lib/cataloguing/service.js";
import { CaptureStore, sniffImageType } from "../lib/cataloguing/store.js";
import { parseUnimarcNotices } from "../lib/cataloguing/unimarc.js";

const JPEG = Buffer.concat([
  Buffer.from([0xff, 0xd8, 0xff, 0xe0]),
  Buffer.alloc(32, 7),
]);
const PNG = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(32, 3),
]);

function temporaryDirectory(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

const UNIMARC = `<?xml version="1.0" encoding="UTF-8"?>
<srw:searchRetrieveResponse xmlns:srw="http://www.loc.gov/zing/srw/">
  <srw:records><srw:record><srw:recordData>
    <mxc:record xmlns:mxc="info:lc/xmlns/marcxchange-v2">
      <mxc:controlfield tag="001">FRBNF123456789</mxc:controlfield>
      <mxc:datafield tag="010"><mxc:subfield code="a">978-2-07-040850-4</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="101"><mxc:subfield code="a">fre</mxc:subfield><mxc:subfield code="c">eng</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="200">
        <mxc:subfield code="a">Le vieil homme et la mer</mxc:subfield>
        <mxc:subfield code="e">récit</mxc:subfield>
      </mxc:datafield>
      <mxc:datafield tag="205"><mxc:subfield code="a">Nouvelle édition</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="210">
        <mxc:subfield code="a">Paris</mxc:subfield>
        <mxc:subfield code="c">Gallimard</mxc:subfield>
        <mxc:subfield code="d">1972</mxc:subfield>
      </mxc:datafield>
      <mxc:datafield tag="215"><mxc:subfield code="a">148 p.</mxc:subfield><mxc:subfield code="d">18 cm</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="225"><mxc:subfield code="a">Folio</mxc:subfield><mxc:subfield code="v">7</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="330"><mxc:subfield code="a">Un pêcheur cubain affronte un espadon.</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="606">
        <mxc:subfield code="a">Pêche</mxc:subfield>
        <mxc:subfield code="x">Cuba</mxc:subfield>
      </mxc:datafield>
      <mxc:datafield tag="676"><mxc:subfield code="a">813.52</mxc:subfield></mxc:datafield>
      <mxc:datafield tag="700">
        <mxc:subfield code="a">Hemingway</mxc:subfield>
        <mxc:subfield code="b">Ernest</mxc:subfield>
        <mxc:subfield code="4">070</mxc:subfield>
      </mxc:datafield>
      <mxc:datafield tag="702">
        <mxc:subfield code="a">Dutourd</mxc:subfield>
        <mxc:subfield code="b">Jean</mxc:subfield>
        <mxc:subfield code="4">730</mxc:subfield>
      </mxc:datafield>
    </mxc:record>
  </srw:recordData></srw:record></srw:records>
</srw:searchRetrieveResponse>`;

test("ISBN : validation et conversions identiques au mobile", () => {
  assert.equal(normalizeIsbn("2-07-040850-x"), "207040850X");
  assert.equal(toIsbn13("0-306-40615-2"), "9780306406157");
  assert.equal(toIsbn10("9780306406157"), "0306406152");
  assert.equal(toIsbn10("9791234567896"), null);
  assert.ok(isValidIsbn("9780306406157"));
  assert.ok(!isValidIsbn("9780306406158"));
  assert.throws(() => toIsbn13("1234567890"), /ISBN invalide/);
});

test("UNIMARC : zones, sous-zones et rôles d'auteur", () => {
  const [notice] = parseUnimarcNotices(UNIMARC, { sourceNotice: "BnF" });
  assert.equal(notice.title, "Le vieil homme et la mer");
  assert.equal(notice.subtitle, "récit");
  assert.equal(notice.publisher, "Gallimard");
  assert.equal(notice.publicationPlace, "Paris");
  assert.equal(notice.publicationDate, "1972");
  assert.equal(notice.edition, "Nouvelle édition");
  assert.equal(notice.collection, "Folio");
  assert.equal(notice.collectionNumber, "7");
  assert.equal(notice.language, "fre");
  assert.equal(notice.originalLanguage, "eng");
  assert.equal(notice.classification, "813.52");
  assert.equal(notice.sourceIdentifier, "FRBNF123456789");
  assert.deepEqual(notice.subjects, ["Pêche -- Cuba"]);
  assert.deepEqual(notice.authors, [
    { name: "Hemingway Ernest", role: "auteur" },
    { name: "Dutourd Jean", role: "traducteur" },
  ]);
});

test("UNIMARC : le traducteur n'est pas versé dans l'auteur du livre", () => {
  const [notice] = parseUnimarcNotices(UNIMARC, { sourceNotice: "BnF" });
  const fields = noticeToBookFields(notice, { isbn: "9782070408504" });
  assert.equal(fields.author, "Hemingway Ernest");
  assert.equal(fields.isbn, "9782070408504");
  assert.equal(fields.publication_year, "1972");
  assert.equal(fields.dewey, "813.52");
  assert.equal(fields.subjects, "Pêche -- Cuba");
  assert.equal(fields.source_notice, "BnF");
});

test("UNIMARC : un XML sans notice exploitable ne lève pas", () => {
  assert.deepEqual(parseUnimarcNotices("<vide/>", { sourceNotice: "BnF" }), []);
  assert.deepEqual(parseUnimarcNotices("pas du xml <", { sourceNotice: "BnF" }), []);
});

test("Année de publication : seules quatre chiffres sont conservés", () => {
  assert.equal(publicationYear("cop. 1972"), "1972");
  assert.equal(publicationYear("s.d."), "");
});

test("OCR : les ISBN valides sont extraits, les invalides ignorés", () => {
  const text = `Prix 12 €\nISBN 978-2-07-040850-4\nEAN 9780306406157\nCode 1234567890123`;
  const isbns = extractIsbns(text);
  assert.equal(isbns[0], "9782070408504", "l'ISBN étiqueté passe en premier");
  assert.ok(isbns.includes("9780306406157"));
  assert.ok(!isbns.includes("1234567890123"), "clé de contrôle fausse");
});

test("OCR : titre, auteur, éditeur et année d'une couverture", () => {
  const front = "ERNEST HEMINGWAY\nLE VIEIL HOMME ET LA MER\nGallimard";
  const { title, author } = extractTitleAndAuthor(front);
  assert.equal(title, "LE VIEIL HOMME ET LA MER");
  assert.equal(author, "ERNEST HEMINGWAY");
  assert.equal(extractPublisher(front), "Gallimard");
  assert.equal(extractYear("Dépôt légal : mars 1972\nréimpression 2019"), "2019");
});

test("OCR : les indices agrègent première et quatrième de couverture", () => {
  const hints = extractHints({
    front: "ERNEST HEMINGWAY\nLE VIEIL HOMME ET LA MER",
    back: [
      "ISBN 978-2-07-040850-4",
      "Collection Folio",
      "Un vieux pêcheur cubain affronte seul un espadon gigantesque au large de La Havane, dans un combat qui dure trois jours.",
    ].join("\n"),
  });
  assert.equal(hints.title, "LE VIEIL HOMME ET LA MER");
  assert.equal(hints.author, "ERNEST HEMINGWAY");
  assert.deepEqual(hints.isbns, ["9782070408504"]);
  assert.equal(hints.collection, "Folio");
  assert.match(hints.summary, /espadon/);
});

test("Sources : 404 = inconnu, 429 = quota, parsing UNIMARC de la BnF", async () => {
  const calls = [];
  const responses = new Map([
    [404, { ok: false, status: 404, text: async () => "" }],
    [429, { ok: false, status: 429, text: async () => "" }],
    [200, { ok: true, status: 200, text: async () => UNIMARC }],
  ]);
  const source = new BnfSource({
    timeoutMs: 1000,
    fetchImpl: async (url) => {
      calls.push(url);
      return responses.get(calls.length === 1 ? 200 : calls.length === 2 ? 404 : 429);
    },
  });
  const notices = await source.lookupIsbn("9782070408504");
  assert.equal(notices[0].title, "Le vieil homme et la mer");
  assert.match(calls[0], /bib\.isbn\+adj/, "la BnF est interrogée sur l'ISBN");
  assert.ok(
    calls[0].includes("2070408507"),
    "la requête BnF utilise la forme ISBN-10, seule reconnue par le SRU",
  );
  assert.deepEqual(await source.lookupIsbn("9782070408504"), [], "404 : inconnu");
  await assert.rejects(() => source.lookupIsbn("9782070408504"), /quota/);
});

test("Sources : un ISBN sans équivalent en dix chiffres n'interroge pas la BnF", async () => {
  let called = false;
  const source = new BnfSource({
    fetchImpl: async () => {
      called = true;
      return { ok: true, status: 200, text: async () => "" };
    },
  });
  assert.deepEqual(await source.lookupIsbn("9791234567896"), []);
  assert.equal(called, false);
});

test("Sources : le SUDOC distingue un ISBN inconnu d'une panne", async () => {
  const unknown = new SudocSource({
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      text: async () => "<sudoc><error>Not found</error></sudoc>",
    }),
  });
  assert.deepEqual(await unknown.lookupIsbn("9782070408504"), []);
  const broken = new SudocSource({
    fetchImpl: async () => {
      throw new Error("ECONNRESET");
    },
  });
  await assert.rejects(() => broken.lookupIsbn("9782070408504"), /injoignable/);
});

function fakeSource(name, { notices = [], fail = false, text = [] } = {}) {
  return {
    name,
    calls: 0,
    async lookupIsbn() {
      this.calls += 1;
      if (fail) throw new Error("coupé");
      return notices;
    },
    async searchText() {
      if (fail) throw new Error("coupé");
      return text;
    },
  };
}

const NOTICE = {
  title: "Le vieil homme et la mer",
  authors: [{ name: "Hemingway Ernest", role: "auteur" }],
  subjects: [],
  publisher: "Gallimard",
};

test("Recherche : le catalogue local court-circuite les sources", async () => {
  const source = fakeSource("BnF", { notices: [NOTICE] });
  const service = new NoticeLookupService({
    sources: [source],
    localLookup: async () => [{ id: 4, title: "Déjà là" }],
  });
  const result = await service.lookupByIsbn("9782070408504");
  assert.equal(result.alreadyCatalogued, true);
  assert.equal(result.books[0].title, "Déjà là");
  assert.equal(source.calls, 0, "aucune requête réseau inutile");
});

test("Recherche : la première source utile arrête la chaîne", async () => {
  const first = fakeSource("BnF", { notices: [NOTICE] });
  const second = fakeSource("SUDOC", { notices: [NOTICE] });
  const service = new NoticeLookupService({ sources: [first, second] });
  const result = await service.lookupByIsbn("9782070408504");
  assert.equal(result.notices.length, 1);
  assert.equal(result.notices[0].sourceNotice, "BnF");
  assert.equal(second.calls, 0);
});

test("Recherche : `collectAll` fusionne les doublons et garde le plus complet", async () => {
  const poor = fakeSource("Open Library", { notices: [{ ...NOTICE, publisher: "" }] });
  const rich = fakeSource("BnF", {
    notices: [{ ...NOTICE, publicationDate: "1972", summary: "Un combat en mer." }],
  });
  const service = new NoticeLookupService({ sources: [poor, rich] });
  const result = await service.lookupByIsbn("9782070408504", { collectAll: true });
  assert.equal(result.notices.length, 1, "même titre et même auteur : un seul candidat");
  assert.equal(result.notices[0].summary, "Un combat en mer.");
});

test("Recherche : toutes les sources muettes = introuvable, toutes en panne = réseau", async () => {
  const silent = new NoticeLookupService({ sources: [fakeSource("BnF")] });
  await assert.rejects(
    () => silent.lookupByIsbn("9782070408504"),
    NoticeNotFoundError,
  );
  const broken = new NoticeLookupService({
    sources: [fakeSource("BnF", { fail: true })],
  });
  await assert.rejects(
    () => broken.lookupByIsbn("9782070408504"),
    NoticeNetworkError,
  );
});

test("Recherche : le cache évite un second appel réseau", async () => {
  const store = new Map();
  const source = fakeSource("BnF", { notices: [NOTICE] });
  const service = new NoticeLookupService({
    sources: [source],
    cache: {
      read: async (key) => store.get(key) || [],
      write: async (key, value) => store.set(key, value),
    },
  });
  await service.lookupByIsbn("9782070408504");
  const cached = await service.lookupByIsbn("9782070408504");
  assert.equal(source.calls, 1);
  assert.equal(cached.fromCache, true);
});

test("Recherche par titre : interroge toutes les sources en parallèle", async () => {
  const service = new NoticeLookupService({
    sources: [
      fakeSource("BnF", { text: [{ ...NOTICE, sourceNotice: "BnF" }] }),
      fakeSource("Google Books", {
        text: [{ title: "Autre titre", authors: [], subjects: [] }],
      }),
    ],
  });
  const result = await service.searchByText({ title: "vieil homme" });
  assert.equal(result.notices.length, 2);
  await assert.rejects(
    () => service.searchByText({ title: "ab" }),
    /trois caractères/,
  );
});

test("IA : le JSON est récupéré même entouré de texte ou de balises", () => {
  assert.deepEqual(parseJsonResponse('```json\n{"title":"X"}\n```'), { title: "X" });
  assert.deepEqual(parseJsonResponse('Voici : {"title":"X"} — fin'), { title: "X" });
  assert.throws(() => parseJsonResponse("aucun json"), /JSON/);
});

test("IA : la réponse est bornée aux champs attendus", () => {
  const normalized = normalizeFieldResponse({
    title: "  Le vieil homme   et la mer ",
    publication_year: "paru en 1972",
    confidence: "200",
    inventé: "ignoré",
  });
  assert.equal(normalized.fields.title, "Le vieil homme et la mer");
  assert.equal(normalized.fields.publication_year, "1972");
  assert.equal(normalized.confidence, 100);
  assert.equal("inventé" in normalized.fields, false);
});

test("IA : rôles désactivés par défaut et refus explicite", async () => {
  const roles = normalizeAiRoles("structure,inconnu");
  assert.equal(roles.structure, true);
  assert.equal(roles.arbitrate, false);
  assert.equal(serializeAiRoles(roles), "structure");

  const service = new AiCataloguingService({ provider: "claude", apiKey: "" });
  await assert.rejects(
    () => service.structureFromOcr({ frontText: "x" }),
    /clé API/,
  );
  service.configure({ apiKey: "k", roles: { structure: false } });
  await assert.rejects(
    () => service.structureFromOcr({ frontText: "x" }),
    /désactivé/,
  );
});

test("IA : DeepSeek ne lit pas les images", async () => {
  const service = new AiCataloguingService({
    provider: "deepseek",
    apiKey: "k",
    roles: { vision: true },
  });
  await assert.rejects(
    () => service.readImages({ images: [{ base64: "AAAA" }] }),
    /Claude ou ChatGPT/,
  );
});

test("IA : l'arbitrage renvoie l'index de la notice retenue", async () => {
  const service = new AiCataloguingService({
    provider: "chatgpt",
    apiKey: "k",
    roles: { arbitrate: true },
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        choices: [
          { message: { content: '{"index":1,"confidence":88,"reason":"Édition Folio"}' } },
        ],
      }),
    }),
  });
  const verdict = await service.arbitrate({
    candidates: [{ title: "A" }, { title: "B" }],
  });
  assert.deepEqual(verdict, { index: 1, reason: "Édition Folio", confidence: 88 });
});

test("IA : un index hors bornes est refusé plutôt que suivi", async () => {
  const service = new AiCataloguingService({
    provider: "chatgpt",
    apiKey: "k",
    roles: { arbitrate: true },
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: '{"index":9}' } }] }),
    }),
  });
  const verdict = await service.arbitrate({
    candidates: [{ title: "A" }, { title: "B" }],
  });
  assert.equal(verdict.index, -1);
});

test("OCR : moteur et langues normalisés, Vision exige une clé", async () => {
  assert.equal(normalizeOcrEngine("inconnu"), "tesseract");
  assert.equal(normalizeOcrEngine("google_vision"), "google_vision");
  assert.equal(normalizeOcrLanguages("FRA, eng ; xx"), "fra+eng");
  assert.equal(normalizeOcrLanguages(""), "fra+eng");

  const vision = new OcrService({ engine: "google_vision", visionApiKey: "" });
  assert.equal(vision.available, false);
  await assert.rejects(() => vision.recognize(JPEG), /clé API Google Vision/);
});

test("OCR : Google Vision renvoie le texte complet de la page", async () => {
  const service = new OcrService({
    engine: "google_vision",
    visionApiKey: "clé",
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        responses: [
          {
            fullTextAnnotation: {
              text: "LE VIEIL HOMME ET LA MER",
              pages: [{ confidence: 0.91 }],
            },
          },
        ],
      }),
    }),
  });
  const result = await service.recognize(JPEG);
  assert.equal(result.text, "LE VIEIL HOMME ET LA MER");
  assert.equal(result.confidence, 91);
  assert.equal(result.engine, "google_vision");
});

test("OCR : une erreur Google Vision est rapportée telle quelle", async () => {
  const service = new OcrService({
    engine: "google_vision",
    visionApiKey: "clé",
    fetchImpl: async () => ({
      ok: false,
      status: 403,
      json: async () => ({ error: { message: "API key not valid" } }),
    }),
  });
  await assert.rejects(() => service.recognize(JPEG), /API key not valid/);
});

test("OCR : les reconnaissances Tesseract sont sérialisées", async () => {
  let active = 0;
  let maximum = 0;
  const service = new OcrService({
    engine: "tesseract",
    createWorkerImpl: async () => ({
      async recognize() {
        active += 1;
        maximum = Math.max(maximum, active);
        await new Promise((resolve) => setTimeout(resolve, 10));
        active -= 1;
        return { data: { text: "texte", confidence: 80 } };
      },
      async terminate() {},
    }),
  });
  const results = await Promise.all([
    service.recognize(JPEG),
    service.recognize(JPEG),
    service.recognize(JPEG),
  ]);
  assert.equal(maximum, 1, "un seul moteur à la fois");
  assert.equal(results[2].text, "texte");
  await service.close();
});

test("Stockage : format détecté par les octets, pas par l'en-tête annoncé", () => {
  const root = temporaryDirectory("captures-");
  const store = new CaptureStore(root);
  assert.equal(sniffImageType(JPEG), "image/jpeg");
  assert.equal(sniffImageType(PNG), "image/png");
  const saved = store.save({
    buffer: PNG,
    thumbBuffer: JPEG,
    contentType: "image/jpeg",
  });
  assert.match(saved.relativePath, /\.png$/, "le contenu réel décide de l'extension");
  assert.match(saved.thumbRelativePath, /\.thumb\.jpg$/);
  assert.deepEqual(store.read(saved.relativePath), PNG);
  // Un en-tête « image/jpeg » menteur ne suffit pas à faire écrire le fichier.
  assert.throws(
    () => store.save({ buffer: Buffer.from("pas une image"), contentType: "image/jpeg" }),
    /n’est pas une image/,
  );
  // À l'inverse, un en-tête absent ou farfelu n'empêche pas une vraie image.
  assert.match(
    store.save({ buffer: JPEG, contentType: "application/pdf" }).relativePath,
    /\.jpg$/,
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test("Stockage : aucune sortie de la racine des couvertures", () => {
  const root = temporaryDirectory("captures-");
  const store = new CaptureStore(root);
  assert.equal(store.resolve("../library.db"), "");
  assert.equal(store.resolve("2026/10/../../../secret.txt"), "");
  assert.equal(store.read("../library.db"), null);
  assert.ok(store.resolve("2026/10/image.jpg"));
  fs.rmSync(root, { recursive: true, force: true });
});

test("Fusion : une valeur déjà saisie n'est jamais écrasée", () => {
  const merged = mergeFields(
    { title: "Titre humain", author: "", dewey: "" },
    { title: "Titre IA", author: "Hemingway", dewey: "813.52", inconnu: "x" },
  );
  assert.equal(merged.title, "Titre humain");
  assert.equal(merged.author, "Hemingway");
  assert.equal(merged.dewey, "813.52");
  assert.equal("inconnu" in merged, false);
});

function temporaryDatabase() {
  const directory = temporaryDirectory("biblio-cat-");
  const database = new LibraryDatabase(path.join(directory, "library.db"));
  return { database, directory };
}

test("Base : les champs de notice sont enregistrés et relus", () => {
  const { database, directory } = temporaryDatabase();
  const book = database.createBook({
    title: "Le vieil homme et la mer",
    author: "Hemingway Ernest",
    isbn: "9782070408504",
    subtitle: "récit",
    collection: "Folio",
    dewey: "813.52",
    summary: "Un combat en mer.",
    source_notice: "BnF",
    catalog_draft: true,
  });
  assert.equal(book.subtitle, "récit");
  assert.equal(book.collection, "Folio");
  assert.equal(book.catalog_draft, 1);
  assert.equal(database.markCatalogued(book.id).catalog_draft, 0);

  // Une mise à jour partielle ne doit pas effacer la notice.
  const updated = database.updateBook(book.id, {
    title: "Le vieil homme et la mer",
    shelf: "R HEM",
  });
  assert.equal(updated.dewey, "813.52");
  assert.equal(updated.shelf, "R HEM");

  database.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

test("Base : la synchronisation n'emporte pas les champs locaux", () => {
  const { database, directory } = temporaryDatabase();
  const book = database.createBook({ title: "X", summary: "résumé local" });
  const payload = database.toSyncBook(database.getBook(book.id));
  assert.equal("summary" in payload, false);
  assert.equal("catalogDraft" in payload, false);
  database.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

test("Base : recherche d'un ISBN déjà au catalogue, en 10 comme en 13", () => {
  const { database, directory } = temporaryDatabase();
  // 2070408507 est l'ISBN-10 de 9782070408504 : même ouvrage, deux écritures.
  database.createBook({ title: "Treize", isbn: "978-2-07-040850-4" });
  database.createBook({ title: "Dix", isbn: "2070408507" });
  const found = database.findBooksByIsbn("9782070408504");
  assert.deepEqual(found.map((book) => book.title).sort(), ["Dix", "Treize"]);
  // Un ISBN-10 voisin mais de clé différente ne doit pas être confondu.
  database.createBook({ title: "Voisin", isbn: "2070408515" });
  assert.equal(
    database.findBooksByIsbn("9782070408504").length,
    2,
    "pas de rapprochement sur le préfixe",
  );
  assert.deepEqual(database.findBooksByIsbn(""), []);
  assert.deepEqual(database.findBooksByIsbn("9782070999994"), []);
  database.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

test("Base : cache de notices expiré puis rafraîchi", () => {
  const { database, directory } = temporaryDatabase();
  database.writeNoticeCache("9782070408504", [NOTICE]);
  assert.equal(database.readNoticeCache("9782070408504").length, 1);
  assert.equal(database.readNoticeCache("9782070408504", -1).length, 0, "expiré");
  assert.equal(database.readNoticeCache("9782070408504").length, 0, "purgé");
  database.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

test("Base : les clés API ne sortent pas de la base", () => {
  const { database, directory } = temporaryDatabase();
  database.setSettings({
    cataloguing_ai_key: "sk-secret",
    cataloguing_vision_api_key: "vision-secret",
    cataloguing_ai_provider: "claude",
  });
  const settings = database.settings();
  assert.equal("cataloguing_ai_key" in settings, false);
  assert.equal("cataloguing_vision_api_key" in settings, false);
  assert.equal(settings.cataloguing_ai_key_set, true);
  assert.equal(settings.cataloguing_vision_api_key_set, true);
  assert.equal(settings.cataloguing_ai_provider, "claude");
  database.close();
  fs.rmSync(directory, { recursive: true, force: true });
});

function temporaryService({ ocr, ai } = {}) {
  const directory = temporaryDirectory("biblio-svc-");
  const database = new LibraryDatabase(path.join(directory, "library.db"));
  const service = new CataloguingService(database, {
    dataRoot: directory,
    ocrService: ocr,
    aiService: ai,
  });
  return {
    database,
    service,
    cleanup() {
      database.close();
      fs.rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("Service : paramètres par défaut, OCR actif et IA inactive", () => {
  const { service, cleanup } = temporaryService();
  const settings = service.settings();
  assert.equal(settings.ocr.enabled, true);
  assert.equal(settings.ocr.engine, "tesseract");
  assert.equal(settings.ai.enabled, false);
  assert.equal(service.ai.roleEnabled("structure"), false);
  cleanup();
});

test("Service : activer l'IA n'active que les rôles demandés", () => {
  const { service, cleanup } = temporaryService();
  const settings = service.updateSettings({
    aiEnabled: true,
    aiProvider: "claude",
    aiKey: "sk-test",
    aiRoles: ["structure", "complete"],
  });
  assert.equal(settings.ai.enabled, true);
  assert.equal(settings.ai.keySet, true);
  assert.equal(settings.ai.roles.structure, true);
  assert.equal(settings.ai.roles.arbitrate, false);
  assert.equal(service.ai.roleEnabled("complete"), true);
  assert.equal(service.ai.roleEnabled("quality"), false);
  // Clé jamais renvoyée au navigateur.
  assert.equal("apiKey" in settings.ai, false);
  cleanup();
});

test("Service : l'IA coupée laisse l'identification se terminer", async () => {
  const { database, service, cleanup } = temporaryService();
  service.updateSettings({
    aiEnabled: true,
    aiKey: "sk-test",
    aiRoles: ["structure", "complete", "quality"],
  });
  service.ai.ask = async () => {
    throw new Error("fournisseur injoignable");
  };
  service.lookup = {
    lookupByIsbn: async () => ({
      alreadyCatalogued: false,
      books: [],
      notices: [
        {
          ...NOTICE,
          subjects: [],
          authors: [{ name: "Hemingway Ernest", role: "auteur" }],
        },
      ],
      unavailableSources: [],
    }),
    searchByText: async () => ({ notices: [], unavailableSources: [] }),
  };
  const capture = service.addCapture({
    buffer: JPEG,
    contentType: "image/jpeg",
    kind: "front",
  });
  database.saveCaptureOcr(capture.id, {
    text: "ERNEST HEMINGWAY\nLE VIEIL HOMME ET LA MER\nISBN 978-2-07-040850-4",
    engine: "tesseract",
    confidence: 82,
  });
  const result = await service.identify({
    captures: database.capturesForBook(null).length
      ? []
      : [database.getCapture(capture.id)],
  });
  assert.equal(result.fields.title, "Le vieil homme et la mer");
  assert.equal(result.ai.warnings.length, 3, "chaque rôle signale son échec");
  assert.ok(result.fields.isbn.startsWith("978"));
  cleanup();
});

test("Service : la validation crée la fiche et y rattache les photos", () => {
  const { database, service, cleanup } = temporaryService();
  const front = service.addCapture({ buffer: JPEG, contentType: "image/jpeg", kind: "front" });
  const back = service.addCapture({ buffer: JPEG, contentType: "image/jpeg", kind: "back" });
  const book = service.commit({
    fields: { title: "Le vieil homme et la mer", author: "Hemingway", dewey: "813.52" },
    captureIds: [front.id, back.id],
  });
  assert.equal(book.catalog_draft, 0);
  assert.equal(book.dewey, "813.52");
  const covers = service.coversFor(book.id);
  assert.equal(covers.length, 2);
  assert.deepEqual(
    covers.map((cover) => cover.kind).sort(),
    ["back", "front"],
  );
  assert.equal(database.getCapture(front.id).book_id, book.id);
  cleanup();
});

test("Service : le lot enregistre des brouillons, jamais de tag", () => {
  const { database, service, cleanup } = temporaryService();
  const session = database.createCatalogSession({ label: "Carton 1" });
  const ready = database.createCatalogItem(session.id);
  const incomplete = database.createCatalogItem(session.id);
  const capture = service.addCapture({
    buffer: JPEG,
    contentType: "image/jpeg",
    kind: "front",
    itemId: ready.id,
  });
  database.updateCatalogItem(ready.id, {
    status: "pret",
    fields: { title: "Le vieil homme et la mer", author: "Hemingway" },
  });
  database.updateCatalogItem(incomplete.id, {
    status: "echec",
    message: "Aucun titre identifié",
  });

  const result = service.commitSession(session.id);
  assert.equal(result.saved.length, 1);
  assert.equal(result.skipped.length, 1);
  const book = database.getBook(result.saved[0].bookId);
  assert.equal(book.catalog_draft, 1, "brouillon : encodage à faire à la station");
  assert.equal(book.status, "a_encoder");
  assert.equal(book.tid, null, "aucun tag écrit en lot");
  assert.equal(database.getCapture(capture.id).book_id, book.id);
  assert.equal(database.getCatalogItem(ready.id).status, "enregistre");
  cleanup();
});

test("Service : purge des photos abandonnées", () => {
  const { database, service, cleanup } = temporaryService();
  const orphan = service.addCapture({ buffer: JPEG, contentType: "image/jpeg" });
  const kept = service.addCapture({ buffer: JPEG, contentType: "image/jpeg" });
  const book = service.commit({ fields: { title: "Gardé" }, captureIds: [kept.id] });
  database.db
    .prepare("UPDATE captures SET created_at = ? WHERE id = ?")
    .run(new Date(Date.now() - 72 * 3600 * 1000).toISOString(), orphan.id);
  assert.equal(service.purgeStaleCaptures(48), 1);
  assert.equal(database.getCapture(orphan.id), undefined);
  assert.equal(database.capturesForBook(book.id).length, 1);
  cleanup();
});
