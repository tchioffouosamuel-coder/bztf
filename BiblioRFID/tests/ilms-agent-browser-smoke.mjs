import http from "node:http";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { randomBytes, randomUUID } from "node:crypto";
import { chromium } from "playwright-core";
import { createIlmsReaderAgent } from "../lib/ilms-reader-agent.js";
import { listenForBrowser as listen } from "./helpers/browser-server.js";

class Reader extends EventEmitter {
  connected = false;
  calls = 0;
  async connect() { this.calls++; this.connected = true; }
  async disconnect() { this.connected = false; }
  async shutdown() { this.connected = false; }
}
const pageServer = () => http.createServer((request, response) => {
  response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" });
  response.end('<!doctype html><html lang="fr"><title>Recette agent ILMS</title><body></body></html>');
});
const originOf = server => `http://127.0.0.1:${server.address().port}`;
const closeServer = server => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
const allowed = pageServer(); const hostile = pageServer(); const reader = new Reader();
let agent; let browser;
try {
  await listen(allowed); await listen(hostile);
  const origin = originOf(allowed); const hostileOrigin = originOf(hostile);
  const token = randomBytes(32).toString("hex");
  agent = createIlmsReaderAgent({ reader, origin, token, deviceId: randomUUID(), libraryId: randomUUID() });
  await listen(agent.server); const local = originOf(agent.server);
  browser = await chromium.launch({ channel: "msedge", headless: true });
  const context = await browser.newContext();
  await context.route("**/*", route => [origin, hostileOrigin, local].includes(new URL(route.request().url()).origin)
    ? route.continue() : route.abort());
  const page = await context.newPage(); await page.goto(origin);
  const command = (path, body, key = token) => page.evaluate(async ({ local, path, body, key }) => {
    const response = await fetch(local + path, { method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Bearer ${key}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, data: await response.json() };
  }, { local, path, body, key });
  assert.equal((await command("/v1/status")).data.connected, false);
  assert.equal((await command("/v1/status", undefined, "wrong")).status, 401);
  const connected = await command("/v1/reader/connect", { type: "usb" }); assert.equal(connected.status, 200);
  reader.emit("tag", { Epc: "AA12", Tid: "BB34" });
  const scans = await command(`/v1/reader/tags?session_id=${connected.data.session_id}&after=${connected.data.cursor}`);
  assert.equal(scans.status, 200); assert.equal(scans.data.tags[0].tid, "BB34");
  assert.equal((await command("/v1/reader/write", { epc: "CC56" })).status, 404);
  await page.goto(hostileOrigin);
  const blocked = await page.evaluate(async ({ local, token }) => {
    try { await fetch(local + "/v1/reader/connect", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ type: "usb" }) }); return false; }
    catch { return true; }
  }, { local, token });
  assert.equal(blocked, true); assert.equal(reader.calls, 1);
  console.log("Navigateur Edge : origine autorisee, preflight, lecture, cle incorrecte et origine hostile verifies. Materiel simule.");
} finally {
  await browser?.close(); await agent?.close(); await closeServer(allowed); await closeServer(hostile);
}
