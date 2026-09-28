import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

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
