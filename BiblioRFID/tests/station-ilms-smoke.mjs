import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { LibraryDatabase } from "../lib/database.js";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const output = path.join(root, "artifacts");
fs.mkdirSync(output, { recursive: true });
const dataRoot = fs.mkdtempSync(path.join(os.tmpdir(), "bibliorfid-station-ilms-"));
const db = new LibraryDatabase(path.join(dataRoot, "library.db"));
db.setSettings({ connection_type: "simulation", sync_server_url: "" });
db.close();
const library = "11111111-1111-4111-8111-111111111111";
const otherLibrary = "22222222-2222-4222-8222-222222222222";
const token = `header.${Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 })).toString("base64url")}.signature`;
const calls = [];
const delayed = [];
let mode = "found";
let unsafeTitle = false;
const reply = (response, status, body) => {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(body === null ? "" : JSON.stringify(body));
};
const gateway = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  calls.push({ path: url.pathname, epc: url.searchParams.get("epc"), method: request.method });
  if (url.pathname === "/auth-service/oauth/token")
    return reply(response, 200, { token_type: "bearer", access_token: "bootstrap", expires_in: 3600 });
  if (url.pathname === "/auth-service/api/v1/auth/login")
    return reply(response, 200, { user: { id: library }, access_token: { type: "Bearer", token } });
  assert.equal(request.headers.authorization, `Bearer ${token}`);
  if (url.pathname === "/library-service/api/v1/libraries")
    return reply(response, 200, [{ id: library, name: "Bibliothèque de recette" }, { id: otherLibrary, name: "Autre bibliothèque" }]);
  if (url.pathname === `/library-service/api/v1/libraries/${library}/copies/by-rfid`) {
    const epc = url.searchParams.get("epc");
    const body = { id: `copy-${epc}`, number: `EX-${epc}`, document_id: `doc-${epc}`, library_id: library, quote: "R HEM", shelf_name: "Rayon 3", status: 1 };
    if (mode === "delayed") { delayed.push(() => reply(response, 200, body)); return; }
    if (mode === "offline") { response.destroy(); return; }
    if (mode === "unauthorized") return reply(response, 401, { message: "Session ILMS refusée" });
    return reply(response, 200, mode === "unknown" ? null : body);
  }
  if (url.pathname.startsWith(`/library-service/api/v1/libraries/${library}/documents/`)) {
    if (mode === "document-error") return reply(response, 503, { message: "Notice indisponible" });
    const id = url.pathname.split("/").at(-1);
    const title = unsafeTitle ? `Notice ${id} <img src=x onerror=alert(1)>`
      : id === "doc-AA12" ? "Le vieil homme et la mer" : `Notice ${id}`;
    return reply(response, 200, { id, title, primary_authors: ["Ernest Hemingway"], isbn13: "9782070408504" });
  }
  return reply(response, 404, { message: "Route inattendue" });
});
await new Promise(resolve => gateway.listen(0, "127.0.0.1", resolve));
const gatewayUrl = `http://127.0.0.1:${gateway.address().port}`;
const server = spawn(process.execPath, ["server.js"], {
  cwd: root,
  env: { ...process.env, BIBLIORFID_DATA_DIR: dataRoot, BIBLIORFID_HOST: "127.0.0.1", PORT: "4316", BIBLIORFID_ILMS_PORT: "0" },
  windowsHide: true,
  stdio: ["ignore", "pipe", "pipe"],
});
let serverLog = "";
server.stdout.on("data", chunk => { serverLog += chunk; });
server.stderr.on("data", chunk => { serverLog += chunk; });
let browser;
try {
  for (let attempt = 0; !serverLog.includes("Bibliotèque ZTF disponible sur") && attempt < 100; attempt++) {
    if (server.exitCode !== null) throw new Error(serverLog);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const baseUrl = serverLog.match(/Bibliotèque ZTF disponible sur (http:\/\/127\.0\.0\.1:\d+)/)?.[1];
  assert.ok(baseUrl, serverLog);
  browser = await chromium.launch({ executablePath: "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe", headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.route("**/*", route => new URL(route.request().url()).hostname === "127.0.0.1" ? route.continue() : route.abort());
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.addInitScript(() => {
    window.BIBLIORFID_VISUAL_RELEASE_DELAY_MS = 20;
    class FakeEventSource {
      static CLOSED = 2;
      constructor() { this.listeners = new Map(); window.readerEvents = this; }
      addEventListener(type, listener) { this.listeners.set(type, listener); }
      close() {}
    }
    window.EventSource = FakeEventSource;
    window.scan = tags => window.readerEvents.listeners.get("snapshot")({ data: JSON.stringify({ ok: true, tags, count: tags.length, reader: { connected: true } }) });
  });
  const setup = await context.request.post(`${baseUrl}/api/auth/setup`, { data: { name: "Recette station", email: "station@ui.test", password: "mot-de-passe-recette" } });
  assert.equal(setup.status(), 201);
  await page.goto(`${baseUrl}/#station`, { waitUntil: "networkidle" });
  await page.waitForSelector("#view-station.active");
  const tag = { epc: "AA12", tid: "BB34", kind: "book", rssi: 80 };
  const scan = tags => page.evaluate(tags => window.scan(tags), tags);
  await scan([tag]);
  await page.waitForSelector('#station-ilms:has-text("non connecté")');
  assert.equal(calls.length, 0, "aucun appel ILMS sans configuration");

  const login = await context.request.post(`${baseUrl}/api/ilms/session`, { data: { gateway_url: gatewayUrl, username: "recette", password: "fictif", client_id: "client-recette", client_secret: "fictif" } });
  assert.equal(login.status(), 200);
  assert.equal(JSON.stringify(await login.json()).includes(token), false, "le jeton ne sort pas du serveur");
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#station-ilms:has-text("Choisissez une bibliothèque")');
  assert.equal(calls.filter(call => call.epc).length, 0);
  assert.equal((await context.request.put(`${baseUrl}/api/ilms/session/library`, { data: { library_id: library } })).status(), 200);
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#selected-book:has-text("Le vieil homme et la mer")');
  assert.equal(await page.locator("#unknown-panel").isVisible(), false);
  assert.equal(await page.locator("#erase-foreign-tag").count(), 0);
  assert.match(await page.locator("#station-ilms").innerText(), /R HEM.*Rayon 3.*9782070408504/);
  await scan([tag]);
  await page.waitForTimeout(100);
  assert.equal(calls.filter(call => call.epc === "AA12").length, 1);
  await page.screenshot({ path: path.join(output, "station-ilms-desktop.png"), fullPage: true });
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({ path: path.join(output, `station-ilms-${width}.png`), fullPage: true });
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  unsafeTitle = true;
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#selected-book:has-text("<img")');
  assert.equal(await page.locator("#selected-book img").count(), 0, "le titre distant est du texte");
  unsafeTitle = false;
  await scan([tag, { epc: "CC56", tid: "DD78", rssi: 75 }]);
  await page.waitForSelector('#multiple-book-list:has-text("Notice doc-CC56")');
  assert.equal(await page.locator("#station-ilms-results article").count(), 2);

  mode = "unknown";
  await scan([{ epc: "EE90", tid: "FF12" }]);
  await page.waitForSelector('#station-ilms:has-text("Tag absent")');
  await page.waitForSelector("#unknown-panel:not(.hidden)");
  mode = "offline";
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#station-ilms:has-text("injoignable")');
  assert.equal(await page.locator("#unknown-panel").isVisible(), true);
  await scan([{ epc: "EE90", tid: "FF12", book: { id: 99, title: "Livre local", author: "Auteur local", accession: "LOCAL-99", status: "encode" } }]);
  await page.waitForSelector('#selected-book:has-text("Livre local")');
  assert.match(await page.locator("#station-ilms").innerText(), /injoignable/);
  await scan([{ epc: "EE90", tid: "FF12" }]);
  mode = "unauthorized";
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#station-ilms:has-text("Session ILMS refusée")');
  assert.equal(await page.locator("#auth-screen").isVisible(), false, "un refus ILMS ne ferme pas la session locale");
  mode = "document-error";
  await page.click("#station-ilms-refresh");
  await page.waitForSelector('#station-ilms:has-text("Notice ILMS indisponible")');
  assert.match(await page.locator("#selected-book").innerText(), /EX-EE90/);

  mode = "delayed";
  await scan([{ epc: "AA99", tid: "BB99" }]);
  for (let attempt = 0; delayed.length === 0 && attempt < 100; attempt++) await page.waitForTimeout(20);
  assert.equal(delayed.length, 1);
  assert.equal(await page.locator("#unknown-panel").isVisible(), false);
  await scan([]);
  await page.waitForSelector("#selected-book.empty");
  delayed.shift()();
  await page.waitForTimeout(150);
  assert.equal(await page.locator("#station-ilms").isVisible(), false, "la reponse tardive ne ressuscite pas le tag retire");
  mode = "found";
  await scan([{ epc: "AA12", tid: "BB34" }]);
  await page.waitForSelector('#selected-book:has-text("Le vieil homme et la mer")');
  await scan([{ epc: "CC56", tid: "BB34" }]);
  await page.waitForSelector('#selected-book:has-text("Notice doc-CC56")');
  assert.deepEqual(errors, []);
  assert.ok(calls.every(call => call.method === "GET" || call.path.startsWith("/auth-service/")), "aucune ecriture metier ILMS");
  console.log("Station ILMS : connexion locale simulee, choix de bibliotheque, notice, lecture multiple, inconnus, pannes, refus, retrait tardif et affichages 1440/390/320 px valides.");
} finally {
  await browser?.close();
  server.kill();
  if (server.exitCode === null) await once(server, "exit");
  gateway.closeAllConnections();
  await new Promise(resolve => gateway.close(resolve));
  fs.writeFileSync(path.join(output, "station-ilms-server.log"), serverLog);
}
