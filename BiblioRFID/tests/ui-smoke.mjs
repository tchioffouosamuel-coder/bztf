import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const crcTable = Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1)
    value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/** PNG blanc valide, pour éprouver la capture sans dépendance d'image. */
function buildPng(width, height) {
  const stride = width * 3 + 1;
  const raw = Buffer.alloc(stride * height, 0xff);
  for (let y = 0; y < height; y += 1) raw[y * stride] = 0;
  const chunk = (type, data) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const edge = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const output = path.join(root, "artifacts");
const baseUrl = process.env.BIBLIORFID_TEST_URL || "http://127.0.0.1:4310";
fs.mkdirSync(output, { recursive: true });

const browser = await chromium.launch({ executablePath: edge, headless: true });
const errors = [];

function fulfillSnapshot(route, payload) {
  return route.fulfill({
    status: 200,
    headers: { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache" },
    body: `retry: 10000\nevent: snapshot\ndata: ${JSON.stringify(payload)}\n\n`
  });
}

async function authenticatePage(page) {
  await page.waitForSelector("#auth-screen:not(.hidden), #app-shell:not(.hidden)");
  if (await page.locator("#auth-screen").isVisible()) {
    if (await page.locator("#auth-name-field").isVisible())
      await page.fill('#auth-form input[name="name"]', "Administrateur UI");
    await page.fill('#auth-form input[name="email"]', "admin@ui.test");
    await page.fill('#auth-form input[name="password"]', "mot-de-passe-ui");
    await page.click("#auth-submit");
    await page.waitForSelector("#app-shell:not(.hidden)");
  }
  const view = new URL(page.url()).hash.slice(1) || "station";
  await page.waitForSelector(`#view-${view}.active`);
}

try {
  const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  desktop.on("pageerror", (error) => errors.push(error.message));
  desktop.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
  await desktop.goto(`${baseUrl}/#dashboard`, { waitUntil: "networkidle" });
  await authenticatePage(desktop);
  await desktop.waitForSelector("#view-dashboard.active");
  assert.equal(await desktop.title(), "Bibliotèque ZTF");
  assert.ok(await desktop.locator("svg.lucide").count() > 20, "Les icônes Lucide doivent être rendues.");
  assert.equal(await desktop.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, "Pas de débordement horizontal desktop.");
  await desktop.screenshot({ path: path.join(output, "dashboard-desktop.png"), fullPage: true });

  let catalogueBooks = [
    { id: 901, accession: "BCM-2026-000901", title: "LIVRE À SUPPRIMER 1", author: "AUTEUR 1", isbn: "", shelf: "A-01", category: "Test", status: "a_encoder" },
    { id: 902, accession: "BCM-2026-000902", title: "LIVRE À SUPPRIMER 2", author: "AUTEUR 2", isbn: "", shelf: "A-02", category: "Test", status: "encode" },
  ];
  let deletedBookIds = [];
  await desktop.route("**/api/books?*", (route) => {
    const url = new URL(route.request().url());
    const payload = url.searchParams.get("paged") === "1"
      ? { books: catalogueBooks, total: catalogueBooks.length }
      : catalogueBooks;
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(payload),
    });
  });
  await desktop.route("**/api/books", async (route) => {
    if (route.request().method() !== "DELETE") return route.continue();
    deletedBookIds = route.request().postDataJSON().ids;
    catalogueBooks = catalogueBooks.filter(
      (book) => !deletedBookIds.includes(book.id),
    );
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true, deleted: deletedBookIds.length, missing: 0 }),
    });
  });
  await desktop.click('[data-view="catalogue"]');
  await desktop.waitForSelector("#view-catalogue.active");
  assert.equal(await desktop.locator("#view-catalogue table").isVisible(), true);
  assert.equal(await desktop.locator("#import-xlsx").isVisible(), true);
  await desktop.locator(".book-select").nth(0).check();
  await desktop.locator(".book-select").nth(1).check();
  assert.match(await desktop.locator("#book-selection-count").innerText(), /2 livres sélectionnés/);
  assert.equal(await desktop.locator("#books-table tr.selected").count(), 2);
  await desktop.screenshot({ path: path.join(output, "catalogue-bulk-selection.png"), fullPage: true });
  await desktop.click("#delete-selected-books");
  await desktop.click(".swal2-confirm");
  await desktop.waitForSelector('.toast:has-text("2 livres supprimés")');
  assert.deepEqual(deletedBookIds.sort(), [901, 902]);
  assert.equal(await desktop.locator(".book-select").count(), 0);
  await desktop.route("**/api/import/xlsx", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({ ok: true, imported: 12, duplicates: 3, rejected: 0, skipped: 0, sheets: [{ name: "Feuil1", rows: 15 }] })
  }));
  await desktop.locator("#xlsx-file-input").setInputFiles({
    name: "catalogue.xlsx",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    buffer: Buffer.from("test-xlsx-interface")
  });
  await desktop.waitForSelector('.toast:has-text("12 importé(s)")');

  // --- Catalogage assisté : capture, notices, puis lot ---
  const notices = [
    {
      title: "Le vieil homme et la mer",
      subtitle: "",
      authors: [{ name: "Hemingway Ernest", role: "auteur" }],
      publisher: "Gallimard",
      publicationDate: "1972",
      collection: "Folio",
      collectionNumber: "7",
      subjects: ["Pêche -- Cuba"],
      classification: "813.52",
      summary: "Un pêcheur cubain affronte un espadon.",
      sourceNotice: "BnF",
      sourceIdentifier: "FRBNF123",
      isbn: "9782070408504",
    },
    {
      title: "Le vieil homme et la mer",
      subtitle: "",
      authors: [{ name: "Hemingway Ernest", role: "auteur" }],
      publisher: "Gallimard Jeunesse",
      publicationDate: "2003",
      collection: "",
      collectionNumber: "",
      subjects: [],
      classification: "",
      summary: "",
      sourceNotice: "Google Books",
      sourceIdentifier: "gb-1",
      isbn: "9782070408504",
    },
  ];
  await desktop.route("**/api/cataloguing/identify", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        alreadyCatalogued: false,
        books: [],
        notices,
        selected: 0,
        isbn: "9782070408504",
        searchError: "",
        unavailableSources: ["SUDOC"],
        hints: {},
        fields: {
          title: "Le vieil homme et la mer",
          author: "Hemingway Ernest",
          isbn: "9782070408504",
          publisher: "Gallimard",
          publication_year: "1972",
          dewey: "813.52",
          source_notice: "BnF",
          source_identifier: "FRBNF123",
        },
        ai: {
          used: ["arbitrate", "quality"],
          warnings: [
            {
              role: "structure",
              message: "Le rôle « structure » de l’IA a échoué : quota dépassé.",
            },
          ],
          arbitrate: { index: 0, confidence: 91, reason: "Édition Folio de 1972." },
          quality: {
            issues: [
              {
                field: "shelf",
                severity: "avertissement",
                message: "La cote n’est pas renseignée.",
              },
            ],
          },
        },
      }),
    }),
  );
  // Les enregistrements sont simulés : l'interface est éprouvée sans rien
  // écrire dans le catalogue du poste.
  await desktop.route("**/api/cataloguing/commit", (route) =>
    route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({
        book: {
          id: 950,
          accession: "BCM-2026-000950",
          title: "Le vieil homme et la mer",
          epc: "",
          status: "a_encoder",
        },
        covers: [],
      }),
    }),
  );

  await desktop.click('[data-view="cataloguing"]');
  await desktop.waitForSelector("#view-cataloguing.active");
  assert.equal(await desktop.locator("#catalog-pane-single").isVisible(), true);
  assert.equal(
    await desktop.locator("#capture-shoot").isDisabled(),
    true,
    "Pas de prise de vue sans webcam active.",
  );
  await desktop.locator("#capture-file-input").setInputFiles({
    name: "couverture.png",
    mimeType: "image/png",
    buffer: buildPng(260, 90),
  });
  await desktop.waitForSelector(".capture-thumb");
  assert.equal(await desktop.locator(".capture-thumb").count(), 1);
  await desktop.waitForFunction(
    () =>
      !/OCR en cours/.test(
        document.querySelector(".capture-thumb figcaption small")?.textContent || "",
      ),
    null,
    { timeout: 120000 },
  );

  await desktop.fill("#catalog-isbn", "9782070408504");
  await desktop.click("#catalog-identify");
  await desktop.waitForSelector(".catalog-candidate");
  assert.equal(await desktop.locator(".catalog-candidate").count(), 2);
  assert.equal(await desktop.locator(".catalog-candidate.selected").count(), 1);
  const aiNotes = await desktop.locator("#catalog-ai-notes").innerText();
  assert.match(aiNotes, /Édition Folio de 1972/, "La justification de l'IA doit être affichée.");
  assert.match(aiNotes, /quota dépassé/, "Un rôle d'IA en échec doit être signalé.");
  assert.match(aiNotes, /cote n’est pas renseignée/, "Le contrôle qualité doit être affiché.");
  assert.match(await desktop.locator("#catalog-search-hint").innerText(), /SUDOC/);
  assert.equal(
    await desktop.locator('#catalog-form [name="title"]').inputValue(),
    "Le vieil homme et la mer",
  );
  assert.equal(await desktop.locator('#catalog-form [name="dewey"]').inputValue(), "813.52");
  await desktop.screenshot({
    path: path.join(output, "cataloguing-single.png"),
    fullPage: true,
  });

  await desktop.locator('#catalog-form [name="shelf"]').fill("R HEM");
  await desktop.locator(".catalog-candidate").nth(1).click();
  assert.equal(
    await desktop.locator('#catalog-form [name="publisher"]').inputValue(),
    "Gallimard Jeunesse",
    "Changer de notice doit changer la description bibliographique.",
  );
  assert.equal(
    await desktop.locator('#catalog-form [name="shelf"]').inputValue(),
    "R HEM",
    "La cote saisie par le catalogueur est conservée.",
  );
  await desktop.click("#catalog-save");
  await desktop.waitForSelector('.toast:has-text("BCM-2026-000950")');
  assert.equal(
    await desktop.locator(".capture-thumb").count(),
    0,
    "L'atelier est vidé après enregistrement.",
  );

  await desktop.locator('#cataloguing-mode button[data-mode="batch"]').click();
  await desktop.waitForSelector("#catalog-pane-batch:not(.hidden)");
  await desktop.fill("#batch-label", "Carton interface");
  await desktop.click("#batch-new");
  await desktop.waitForSelector('.toast:has-text("Lot créé")');
  await desktop.click("#batch-add-item");
  await desktop.waitForSelector(".batch-card");
  assert.match(await desktop.locator("#capture-target-hint").innerText(), /livre 1 du lot/);
  await desktop.locator('.batch-card [data-field="title"]').fill("Livre du lot");
  await desktop.locator('.batch-card [data-field="author"]').focus();
  await desktop.waitForSelector(".batch-badge.ready");
  await desktop.locator("#capture-file-input").setInputFiles({
    name: "lot-couverture.png",
    mimeType: "image/png",
    buffer: buildPng(200, 70),
  });
  await desktop.waitForSelector(".batch-photos img", { timeout: 120000 });
  await desktop.screenshot({
    path: path.join(output, "cataloguing-batch.png"),
    fullPage: true,
  });

  const batchSession = await desktop.evaluate(async () => {
    const list = await (await fetch("/api/cataloguing/sessions")).json();
    const id = list.sessions[0].id;
    return (await (await fetch(`/api/cataloguing/sessions/${id}`)).json()).session;
  });
  assert.equal(batchSession.items.length, 1);
  assert.equal(batchSession.items[0].captures.length, 1, "La photo est rattachée au livre du lot.");
  await desktop.route("**/api/cataloguing/sessions/*/commit", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        session: {
          ...batchSession,
          items: batchSession.items.map((item) => ({ ...item, status: "enregistre" })),
        },
        saved: batchSession.items.map((item) => ({
          id: item.id,
          bookId: 951,
          accession: "BCM-2026-000951",
          title: item.fields.title,
        })),
        skipped: [],
      }),
    }),
  );
  await desktop.click("#batch-commit");
  await desktop.click(".swal2-confirm");
  await desktop.waitForSelector('.toast:has-text("brouillon")');
  await desktop.waitForSelector(".batch-badge.saved");
  // Le lot d'essai et ses photos ne restent pas sur le poste.
  await desktop.evaluate(
    (id) => fetch(`/api/cataloguing/sessions/${id}`, { method: "DELETE" }),
    batchSession.id,
  );

  await desktop.click('[data-view="settings"]');
  await desktop.waitForSelector("#view-settings.active");
  const configuredBeep = Number(await desktop.locator("#beep-duration-ms").inputValue());
  const configuredRearm = Number(await desktop.locator("#beep-rearm-seconds").inputValue());
  assert.ok(configuredBeep >= 20 && configuredBeep <= 1000);
  assert.ok(configuredRearm >= 1 && configuredRearm <= 3600);
  assert.equal(await desktop.locator("#beep-rearm-seconds").getAttribute("step"), "1");
  assert.equal(await desktop.locator('input[name="beepMode"]:checked').inputValue(), "controlled");
  await desktop.locator('label:has(input[name="beepMode"][value="native"])').click();
  assert.equal(await desktop.locator("#beep-duration-ms").isDisabled(), true);
  await desktop.locator('label:has(input[name="beepMode"][value="controlled"])').click();
  assert.equal(await desktop.locator("#beep-duration-ms").isEnabled(), true);
  assert.equal(await desktop.locator("#compile-bridge").isVisible(), true);
  assert.equal(await desktop.locator("#test-buzzer").isVisible(), true);
  await desktop.screenshot({ path: path.join(output, "settings-reader-timing.png"), fullPage: true });

  // Onglet ILMS : le paquet Angular est servi par le poste, donc le cadre
  // reste sur la même origine et ne se charge qu'à la première ouverture.
  // Le refus d'une adresse non HTTP est couvert par tests/ilms.test.js : le
  // faire ici ajouterait une erreur de console attendue à la vérification
  // finale, qui doit rester vide.
  assert.equal(await desktop.locator("#ilms-gateway-url").isVisible(), true);
  await desktop.locator("#ilms-gateway-url").fill("https://gateway.exemple.org/");
  await desktop.click("#save-ilms");
  await desktop.waitForSelector('.toast:has-text("Passerelle ILMS enregistrée")');
  assert.match(await desktop.locator("#ilms-status-detail").innerText(), /gateway\.exemple\.org/);
  await desktop.screenshot({ path: path.join(output, "settings-ilms.png"), fullPage: true });

  await desktop.click('[data-view="ilms"]');
  await desktop.waitForSelector("#view-ilms.active");
  await desktop.waitForFunction(() => Boolean(document.querySelector("#ilms-frame")?.src));
  // L'interface ILMS a son propre port local : elle y retrouve les chemins
  // d'API relatifs qu'elle attend, sans empiéter sur ceux du poste.
  assert.match(await desktop.locator("#ilms-frame").getAttribute("src"), /^http:\/\/127\.0\.0\.1:\d+\/$/);
  assert.equal(await desktop.locator("#ilms-notice").isVisible(), false, "La passerelle est renseignée : aucun avertissement.");
  assert.equal(await desktop.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, "Pas de débordement horizontal dans l'onglet ILMS.");
  assert.equal(await desktop.locator('[data-view="ilms"] svg.lucide').count(), 1, "L'icône de l'onglet ILMS doit être rendue.");
  await desktop.screenshot({ path: path.join(output, "ilms-embedded.png"), fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  mobile.on("pageerror", (error) => errors.push(error.message));
  await mobile.route("**/api/reader/events?*", (route) => fulfillSnapshot(route, {
      ok: true,
      count: 1,
      tags: [{ epc: "42434D0107EA000000018223", tid: "E28069152000502037A80875", rssi: 100, antenna: 1 }],
      book: {
        id: 999,
        accession: "BCM-2026-000001",
        title: "INNER HEALING",
        author: "ZACHARIAS TANE FOMUM",
        epc: "42434D0107EA000000018223",
        status: "encode"
      },
      reader: { connected: true, reader: "\\\\?\\hid#vid_03eb&pid_2421#test", status: "OK" }
  }));
  await mobile.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await authenticatePage(mobile);
  await mobile.waitForSelector("#view-station.active");
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, "Pas de débordement horizontal mobile.");
  await mobile.waitForSelector("#selected-book.recognized");
  assert.match(await mobile.locator("#selected-book").innerText(), /INNER HEALING/);
  assert.match(await mobile.locator("#selected-book").innerText(), /Livre reconnu par le tag/i);
  assert.equal(await mobile.locator("#reader-state strong").innerText(), "Lecteur RFID de bureau");
  assert.doesNotMatch(await mobile.locator("#reader-state").innerText(), /vid_03eb/i);
  await mobile.screenshot({ path: path.join(output, "station-mobile.png"), fullPage: true });
  await mobile.click("#menu-button");
  assert.equal(await mobile.locator("#sidebar").evaluate((element) => element.classList.contains("open")), true);

  const existing = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  existing.on("pageerror", (error) => errors.push(error.message));
  let existingSnapshot = { ok: true, count: 1, tags: [{ epc: "300833B2DDD9014000000042", tid: "E28000000000000000000042", rssi: 80 }], book: null, reader: { connected: true } };
  await existing.route("**/api/reader/events?*", (route) => fulfillSnapshot(route, existingSnapshot));
  await existing.route("**/api/books?*", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify([{ id: 77, accession: "BCM-2026-000077", title: "LIVRE EN ATTENTE", author: "AUTEUR TEST", epc: "42434D0107EA0000004D1234", status: "a_encoder" }])
  }));
  await existing.route("**/api/books/77/write-tag", (route) => {
    const book = { id: 77, accession: "BCM-2026-000077", title: "LIVRE EN ATTENTE", author: "AUTEUR TEST", epc: "42434D0107EA0000004D1234", status: "encode" };
    const tag = { epc: book.epc, tid: "E28000000000000000000042", rssi: 80 };
    existingSnapshot = { ok: true, count: 1, tags: [{ ...tag, book }], book, reader: { connected: true } };
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
      ok: true,
      verified: true,
      tag,
      book
      })
    });
  });
  await existing.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await authenticatePage(existing);
  await existing.waitForSelector("#unknown-panel:not(.hidden)");
  await existing.click("#register-tag-button");
  await existing.fill("#quick-title", "LIVRE EN ATTENTE");
  await existing.waitForSelector(".title-suggestion:not(:disabled)");
  await existing.click(".title-suggestion:not(:disabled)");
  await existing.waitForSelector("#selected-book.recognized");
  assert.match(await existing.locator("#selected-book").innerText(), /LIVRE EN ATTENTE/);

  const created = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  created.on("pageerror", (error) => errors.push(error.message));
  let createdSnapshot = { ok: true, count: 1, tags: [{ epc: "300833B2DDD9014000000099", tid: "E28000000000000000000099", rssi: 75 }], book: null, reader: { connected: true } };
  await created.route("**/api/reader/events?*", (route) => fulfillSnapshot(route, createdSnapshot));
  await created.route("**/api/books?*", (route) => route.fulfill({ status: 200, contentType: "application/json", body: "[]" }));
  await created.route("**/api/books", async (route) => {
    if (route.request().method() !== "POST") return route.continue();
    return route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({ id: 99, accession: "BCM-2026-000099", title: "NOUVEAU LIVRE", author: "NOUVEL AUTEUR", epc: "42434D0107EA000000631234", status: "a_encoder" })
    });
  });
  await created.route("**/api/books/99/write-tag", (route) => {
    const book = { id: 99, accession: "BCM-2026-000099", title: "NOUVEAU LIVRE", author: "NOUVEL AUTEUR", epc: "42434D0107EA000000631234", status: "encode" };
    const tag = { epc: book.epc, tid: "E28000000000000000000099", rssi: 75 };
    createdSnapshot = { ok: true, count: 1, tags: [{ ...tag, book }], book, reader: { connected: true } };
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
      ok: true,
      verified: true,
      tag,
      book
      })
    });
  });
  await created.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await authenticatePage(created);
  await created.waitForSelector("#unknown-panel:not(.hidden)");
  await created.click("#register-tag-button");
  await created.fill("#quick-title", "NOUVEAU LIVRE");
  await created.waitForSelector("#quick-book-fields:not(.hidden)");
  await created.fill('[name="author"]', "NOUVEL AUTEUR");
  await created.click('#quick-book-fields button[type="submit"]');
  await created.waitForSelector("#selected-book.recognized");
  assert.match(await created.locator("#selected-book").innerText(), /NOUVEAU LIVRE/);

  const multiple = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  multiple.on("pageerror", (error) => errors.push(error.message));
  await multiple.route("**/api/reader/events?*", (route) => fulfillSnapshot(route, {
      ok: true,
      count: 3,
      tags: [
        { epc: "42434D0107EA000000018223", tid: "E28000000000000000000001", rssi: 91, book: { id: 1, accession: "BCM-2026-000001", title: "INNER HEALING", author: "ZACHARIAS TANE FOMUM", status: "encode" } },
        { epc: "42434D0107EA00000002B240", tid: "E28000000000000000000002", rssi: 86, book: { id: 2, accession: "BCM-2026-000002", title: "DELIVRANCE FROM DEMONS", author: "ZACHARIAS TANE FOMUM", status: "encode" } },
        { epc: "300833B2DDD9014000000003", tid: "E28000000000000000000003", rssi: 69, book: null }
      ],
      books: [],
      unknownCount: 1,
      reader: { connected: true }
  }));
  await multiple.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await authenticatePage(multiple);
  await multiple.waitForSelector("#multiple-identification:not(.hidden)");
  assert.equal(await multiple.locator(".multiple-book-item").count(), 3);
  assert.match(await multiple.locator("#multiple-identification").innerText(), /INNER HEALING/);
  assert.match(await multiple.locator("#multiple-identification").innerText(), /DELIVRANCE FROM DEMONS/);
  assert.match(await multiple.locator("#multiple-identification").innerText(), /Livre inconnu/);
  await multiple.screenshot({ path: path.join(output, "multiple-identification.png"), fullPage: true });

  const bounce = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  bounce.on("pageerror", (error) => errors.push(error.message));
  await bounce.addInitScript(() => {
    window.BIBLIORFID_VISUAL_RELEASE_DELAY_MS = 100;
    class FakeEventSource {
      static CLOSED = 2;
      static instances = [];
      constructor() {
        this.readyState = 1;
        this.listeners = new Map();
        FakeEventSource.instances.push(this);
        queueMicrotask(() => this.onopen?.());
      }
      addEventListener(type, listener) { this.listeners.set(type, listener); }
      close() { this.readyState = FakeEventSource.CLOSED; }
      emit(type, payload) { this.listeners.get(type)?.({ data: JSON.stringify(payload) }); }
    }
    window.EventSource = FakeEventSource;
    window.emitRfidSnapshot = (payload) => FakeEventSource.instances.at(-1)?.emit("snapshot", payload);
  });
  await bounce.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await authenticatePage(bounce);
  const bouncingTag = { epc: "300833B2DDD9014000000088", tid: "E28000000000000000000088", rssi: 74 };
  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: null, reader: { connected: true } }), bouncingTag);
  await bounce.waitForSelector("#unknown-panel:not(.hidden)");
  await bounce.evaluate(() => window.emitRfidSnapshot({ ok: true, count: 0, tags: [], book: null, reader: { connected: true } }));
  await bounce.waitForTimeout(60);
  assert.equal(await bounce.locator("#unknown-panel").isVisible(), true, "Une coupure brève ne doit pas masquer le tag.");
  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: null, reader: { connected: true } }), bouncingTag);
  await bounce.waitForTimeout(250);
  assert.equal(await bounce.locator("#unknown-panel").isVisible(), true, "Le retour du tag doit annuler sa disparition visuelle.");
  await bounce.evaluate(() => window.emitRfidSnapshot({ ok: true, count: 0, tags: [], book: null, reader: { connected: true } }));
  await bounce.waitForTimeout(180);
  assert.equal(await bounce.locator("#selected-book").evaluate((element) => element.classList.contains("empty")), true, "Un retrait confirmé doit libérer l'affichage.");

  const replacementTag = {
    epc: "300833B2DDD9014000000090",
    tid: "E28000000000000000000090",
    rssi: 82,
  };
  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: null, presenceSessionId: 2, reader: { connected: true } }), bouncingTag);
  await bounce.waitForSelector("#unknown-panel:not(.hidden)");
  await bounce.evaluate(() => window.emitRfidSnapshot({ ok: true, count: 0, tags: [], book: null, presenceSessionId: 2, reader: { connected: true } }));
  await bounce.waitForTimeout(40);
  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: null, presenceSessionId: 3, reader: { connected: true } }), replacementTag);
  await bounce.waitForTimeout(40);
  assert.equal(await bounce.locator("#scan-tid").innerText(), replacementTag.tid, "Un nouveau tag doit remplacer immédiatement l'ancien affichage.");
  assert.equal(await bounce.locator("#multiple-identification").isVisible(), false, "Un remplacement séquentiel ne doit pas être présenté comme une lecture multiple.");

  const stableMultipleTags = [
    { epc: "42434D0107EA000000018223", tid: "E28000000000000000000001", rssi: 91, book: { id: 1, accession: "BCM-2026-000001", title: "INNER HEALING", author: "ZACHARIAS TANE FOMUM" } },
    { epc: "42434D0107EA00000002B240", tid: "E28000000000000000000002", rssi: 86, book: { id: 2, accession: "BCM-2026-000002", title: "DELIVRANCE FROM DEMONS", author: "ZACHARIAS TANE FOMUM" } }
  ];
  await bounce.evaluate(() => {
    window.rfidToastNotifications = 0;
    new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.ELEMENT_NODE && node.matches?.(".toast")) window.rfidToastNotifications++;
        }
      }
    }).observe(document.querySelector("#toast-region"), { childList: true });
  });
  await bounce.evaluate((tags) => window.emitRfidSnapshot({ ok: true, count: 2, tags, book: null, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags);
  await bounce.waitForSelector("#multiple-identification:not(.hidden)");
  assert.equal(await bounce.locator(".multiple-book-item").count(), 2);
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 1, "Le groupe initial doit produire une seule notification.");
  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: tag.book, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags[0]);
  await bounce.waitForTimeout(60);
  assert.equal(await bounce.locator(".multiple-book-item").count(), 2, "Un tag multiple brièvement absent doit rester affiché.");
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 1, "La perte radio ne doit pas rejouer de notification.");
  await bounce.evaluate((tags) => window.emitRfidSnapshot({ ok: true, count: 2, tags, book: null, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags);
  await bounce.waitForTimeout(250);
  assert.equal(await bounce.locator(".multiple-book-item").count(), 2, "Le retour du second tag doit annuler sa disparition.");
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 1, "Le retour du tag ne doit pas rejouer de notification.");

  await bounce.evaluate((tag) => window.emitRfidSnapshot({ ok: true, count: 1, tags: [tag], book: tag.book, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags[0]);
  await bounce.waitForTimeout(180);
  assert.equal(await bounce.locator("#multiple-identification").isVisible(), false, "Un tag durablement retiré doit quitter le groupe.");
  await bounce.evaluate((tags) => window.emitRfidSnapshot({ ok: true, count: 2, tags, book: null, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags);
  await bounce.waitForTimeout(200);
  assert.equal(await bounce.locator(".multiple-book-item").count(), 2);
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 1, "Une fluctuation longue dans le même groupe ne doit pas recréer d'alerte.");

  await bounce.evaluate(() => window.emitRfidSnapshot({ ok: true, count: 0, tags: [], book: null, presenceSessionId: 1, reader: { connected: true } }));
  await bounce.waitForTimeout(180);
  await bounce.evaluate((tags) => window.emitRfidSnapshot({ ok: true, count: 2, tags, book: null, presenceSessionId: 1, reader: { connected: true } }), stableMultipleTags);
  await bounce.waitForTimeout(200);
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 1, "Un état vide trop court ne doit pas réarmer la notification.");
  await bounce.evaluate(() => window.emitRfidSnapshot({ ok: true, count: 0, tags: [], book: null, presenceSessionId: 1, reader: { connected: true } }));
  await bounce.waitForTimeout(180);
  await bounce.evaluate((tags) => window.emitRfidSnapshot({ ok: true, count: 2, tags, book: null, presenceSessionId: 2, reader: { connected: true } }), stableMultipleTags);
  await bounce.waitForTimeout(200);
  assert.equal(await bounce.evaluate(() => window.rfidToastNotifications), 2, "Le retrait complet doit réarmer la notification du groupe.");

  assert.deepEqual(errors, []);
  console.log("Lecture automatique, anti-rebond visuel, association, création/écriture et identification multiple validés.");
} finally {
  await browser.close();
}
