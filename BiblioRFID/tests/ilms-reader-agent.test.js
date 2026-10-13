import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { randomBytes, randomUUID } from "node:crypto";
import http from "node:http";
import { createIlmsReaderAgent } from "../lib/ilms-reader-agent.js";
import { listenForBrowser } from "./helpers/browser-server.js";

class FakeReader extends EventEmitter {
  connected = false;
  calls = [];
  async connect(connection) { this.calls.push(connection); this.connected = true; }
  async disconnect() { this.connected = false; }
  async shutdown() { this.connected = false; }
}

const origin = "http://127.0.0.1:4200";
function config(reader = new FakeReader()) {
  return { reader, origin, token: randomBytes(32).toString("hex"), deviceId: randomUUID(), libraryId: randomUUID() };
}
async function fixture(t, options = {}) {
  const settings = { ...config(), ...options };
  const agent = createIlmsReaderAgent(settings);
  await listenForBrowser(agent.server);
  t.after(() => agent.close());
  const url = `http://127.0.0.1:${agent.server.address().port}`;
  const request = (route, { headers = {}, ...init } = {}) => fetch(url + route, { ...init,
    headers: { Origin: origin, Authorization: `Bearer ${settings.token}`, ...headers } });
  const post = (route, value, extra = {}) => request(route, { method: "POST", body: JSON.stringify(value),
    ...extra, headers: { "Content-Type": "application/json", ...extra.headers } });
  const connect = async () => {
    const response = await post("/v1/reader/connect", { type: "usb" });
    assert.equal(response.status, 200); return response.json();
  };
  const tags = (status, after = status.cursor) => request(`/v1/reader/tags?session_id=${status.session_id}&after=${after}`);
  return { agent, reader: settings.reader, settings, request, post, connect, tags };
}

test("agent exige origine exacte, cle locale et UUID sans repli permissif", () => {
  for (const override of [{ origin: "http://example.com" }, { origin: "https://ilms.test/path" },
    { origin: "null" }, { origin: "https://ilms.test/" }, { token: "weak" }, { token: undefined },
    { deviceId: "station" }, { libraryId: "all" }]) {
    assert.throws(() => createIlmsReaderAgent({ ...config(), ...override }));
  }
  const agent = createIlmsReaderAgent({ ...config(), origin: "https://ilms.test" });
  assert.equal(agent.status().connected, false);
});

test("statut sans demarrage materiel ni divulgation de cle", async t => {
  const f = await fixture(t);
  const response = await f.request("/v1/status");
  assert.equal(response.status, 200); assert.equal(response.headers.get("cache-control"), "no-store");
  const text = await response.text(); const status = JSON.parse(text);
  assert.equal(status.device_id, f.settings.deviceId); assert.equal(status.library_id, f.settings.libraryId);
  assert.equal(status.connected, false); assert.deepEqual(status.capabilities, ["read"]);
  assert.ok(!text.includes(f.settings.token)); assert.equal(f.reader.calls.length, 0);
});

test("origine absente ou etrangere bloquee avant toute commande", async t => {
  const f = await fixture(t);
  for (const Origin of ["", "https://attacker.test", "null", "http://localhost:4200"]) {
    const response = await f.post("/v1/reader/connect", { type: "usb" }, { headers: { Origin } });
    assert.equal(response.status, 403); assert.equal(response.headers.get("access-control-allow-origin"), null);
  }
  assert.equal(f.reader.calls.length, 0);
});

test("cle absente incorrecte ou passee en URL refusee", async t => {
  const f = await fixture(t);
  for (const Authorization of ["", "Bearer wrong", `Bearer ${"0".repeat(64)}`]) {
    const response = await f.request(`/v1/status?token=${f.settings.token}`, { headers: { Authorization } });
    assert.equal(response.status, 401);
  }
});

test("Host hostile bloque meme avec origine et cle valides", async t => {
  const f = await fixture(t);
  const status = await new Promise((resolve, reject) => {
    const request = http.request({ hostname: "127.0.0.1", port: f.agent.server.address().port, path: "/v1/reader/connect", method: "POST",
      headers: { Host: "rebind.test", Origin: origin, Authorization: `Bearer ${f.settings.token}`, "Content-Type": "application/json" } },
    response => { response.resume(); response.once("end", () => resolve(response.statusCode)); });
    request.once("error", reject); request.end('{"type":"usb"}');
  });
  assert.equal(status, 403); assert.equal(f.reader.calls.length, 0);
});

test("preflight limite a origine, methodes et en-tetes autorises", async t => {
  const f = await fixture(t);
  const response = await f.request("/v1/reader/connect", { method: "OPTIONS", headers: { Authorization: "",
    "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization, content-type",
    "Access-Control-Request-Private-Network": "true" } });
  assert.equal(response.status, 204); assert.equal(response.headers.get("access-control-allow-origin"), origin);
  assert.equal(response.headers.get("access-control-allow-private-network"), "true");
  assert.equal(response.headers.get("access-control-allow-credentials"), null);
  for (const headers of [{ "Access-Control-Request-Method": "DELETE" },
    { "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "X-Anything" }]) {
    assert.equal((await f.request("/v1/status", { method: "OPTIONS", headers })).status, 403);
  }
  assert.equal(f.reader.calls.length, 0);
});

test("connexion USB explicite cree une session de lecture", async t => {
  const f = await fixture(t); const status = await f.connect();
  assert.equal(status.connected, true); assert.equal(status.busy, false); assert.ok(status.session_id);
  assert.deepEqual(f.reader.calls, [{ type: "usb", endpoint: "" }]);
});

test("ports serie et TCP LAN valides uniquement", async t => {
  const f = await fixture(t);
  for (const connection of [{ type: "serial", endpoint: "com12" }, { type: "tcp", endpoint: "192.168.1.10:6000" },
    { type: "tcp", endpoint: "10.0.0.1:6000" }, { type: "tcp", endpoint: "172.16.0.1:6000" }]) {
    assert.equal((await f.post("/v1/reader/connect", connection)).status, 200);
  }
  assert.equal(f.reader.calls[0].endpoint, "COM12");
  for (const connection of [{ type: "serial", endpoint: "COM0" }, { type: "serial", endpoint: "COM1\n" },
    { type: "tcp", endpoint: "8.8.8.8:80" }, { type: "tcp", endpoint: "metadata.test:80" },
    { type: "tcp", endpoint: "169.254.169.254:80" }, { type: "tcp", endpoint: "192.168.300.1:6000" },
    { type: "tcp", endpoint: "192.168.1.10:0" }, { type: "tcp", endpoint: "192.168.1.10:65536" },
    { type: "sim" }, { type: "usb", epc: "AA12" }, { type: "usb", endpoint: "x".repeat(513) }]) {
    assert.equal((await f.post("/v1/reader/connect", connection)).status, 400);
  }
  assert.equal(f.reader.calls.length, 4);
});

test("aucune ecriture effacement bip ni operation metier exposee", async t => {
  const f = await fixture(t);
  for (const path of ["write", "erase", "beep", "checkout", "shutdown"]) {
    assert.equal((await f.post(`/v1/reader/${path}`, { epc: "AA12" })).status, 404);
  }
  assert.equal(f.reader.calls.length, 0);
});

test("JSON invalide volumineux ou mauvais type refuse sans materiel", async t => {
  const f = await fixture(t);
  assert.equal((await f.request("/v1/reader/connect", { method: "POST", body: "x", headers: { "Content-Type": "text/plain" } })).status, 415);
  assert.equal((await f.request("/v1/reader/connect", { method: "POST", body: "{", headers: { "Content-Type": "application/json" } })).status, 400);
  assert.equal((await f.post("/v1/reader/connect", { type: "usb", endpoint: "x".repeat(5000) })).status, 413);
  assert.equal(f.reader.calls.length, 0);
});

test("scans C# normalises, horodates et lus avec curseur", async t => {
  const f = await fixture(t, { now: () => 1700000000000 }); const status = await f.connect();
  f.reader.emit("tag", { Epc: " aa12 ", Tid: "bb34", Rssi: 62, Antenna: 1 });
  const response = await f.tags(status); assert.equal(response.status, 200);
  const result = await response.json(); assert.equal(result.tags.length, 1);
  assert.deepEqual(result.tags[0], { sequence: 1, epc: "AA12", tid: "BB34", rssi: 62, antenna: 1, received_at: "2023-11-14T22:13:20.000Z" });
  assert.deepEqual((await (await f.tags(result)).json()).tags, []);
  assert.equal((await f.tags(status)).status, 200); // Reading is replayable, not destructive.
});

test("lectures malformees ignorees et doublons temporaires filtres", async t => {
  let time = 1000; const f = await fixture(t, { now: () => time }); const status = await f.connect();
  for (const tag of [{}, { epc: "ABC" }, { tid: "zz" }, { epc: "AA".repeat(128) }]) f.reader.emit("tag", tag);
  const tag = { epc: "AA12", tid: "BB34", rssi: Infinity, antenna: "1" };
  f.reader.emit("tag", tag); f.reader.emit("tag", tag); time += 750; f.reader.emit("tag", tag);
  const result = await (await f.tags(status)).json(); assert.equal(result.tags.length, 2);
  assert.equal(result.tags[0].rssi, null); assert.equal(result.tags[0].antenna, null);
});

test("plusieurs tags restent distincts sans selection implicite du premier", async t => {
  const f = await fixture(t); const status = await f.connect();
  for (const tid of ["AA12", "BB34"]) f.reader.emit("tag", { epc: "CC56", tid });
  assert.equal((await (await f.tags(status)).json()).tags.length, 2);
});

test("tags sans session et curseurs invalides refuses", async t => {
  const f = await fixture(t);
  assert.equal((await f.request("/v1/reader/tags?after=0")).status, 409);
  const status = await f.connect();
  assert.equal((await f.request("/v1/reader/tags?after=0")).status, 409);
  for (const cursor of ["-1", "1.5", "01", "NaN", "9007199254740992", ""]) assert.equal((await f.tags(status, cursor)).status, 400);
  assert.equal((await f.tags(status, 10)).status, 409);
});

test("fenetre de scans bornee et perte de curseur explicite", async t => {
  const f = await fixture(t); const status = await f.connect();
  for (let index = 0; index < 300; index++) f.reader.emit("tag", { tid: index.toString(16).padStart(4, "0") });
  const old = await f.tags(status); assert.equal(old.status, 409); assert.equal((await old.json()).error, "scan_window_lost");
  const result = await (await f.tags(status, 44)).json(); assert.equal(result.tags.length, 256); assert.equal(result.cursor, 300);
});

test("scans expires ne peuvent pas devenir des operations tardives", async t => {
  let time = 1000; const f = await fixture(t, { now: () => time }); const status = await f.connect();
  f.reader.emit("tag", { epc: "AA12" }); time += 30001;
  assert.equal((await f.tags(status)).status, 409);
  assert.deepEqual((await (await f.tags(status, 1)).json()).tags, []);
});

test("reconnexion et panne invalident les anciens scans", async t => {
  const f = await fixture(t); const old = await f.connect(); f.reader.emit("tag", { epc: "AA12" });
  const fresh = await f.connect(); assert.notEqual(old.session_id, fresh.session_id);
  assert.equal((await f.tags(old)).status, 409); assert.deepEqual((await (await f.tags(fresh)).json()).tags, []);
  f.reader.connected = false; f.reader.emit("disconnected"); assert.equal(f.agent.status().session_id, null);
  assert.equal((await f.tags(fresh)).status, 409);
});

test("deconnexion explicite exige objet vide et supprime la session", async t => {
  const f = await fixture(t); await f.connect();
  for (const input of [null, [], 1, "", { extra: true }]) assert.equal((await f.post("/v1/reader/disconnect", input)).status, 400);
  assert.equal((await f.post("/v1/reader/disconnect", {})).status, 200); assert.equal(f.agent.status().connected, false);
});

test("erreur du pont expurge les details locaux et permet une nouvelle tentative", async t => {
  const f = await fixture(t); f.reader.connect = async () => { throw new Error("private usb path secret"); };
  const response = await f.post("/v1/reader/connect", { type: "usb" }); assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "reader_unavailable" }); assert.equal(f.agent.status().busy, false);
  f.reader.connect = FakeReader.prototype.connect; await f.connect();
});

test("commandes concurrentes refusees sans ouvrir deux connexions", async t => {
  const f = await fixture(t); let release; let started;
  const waiting = new Promise(resolve => { started = resolve; });
  f.reader.connect = async () => { started(); await new Promise(resolve => { release = resolve; }); f.reader.connected = true; };
  const first = f.post("/v1/reader/connect", { type: "usb" }); await waiting;
  assert.equal((await f.post("/v1/reader/connect", { type: "usb" })).status, 409);
  f.reader.emit("tag", { epc: "AA12" }); release();
  assert.equal((await first).status, 200); assert.equal(f.agent.status().cursor, 0);
});

test("arret retire les ecouteurs et ferme uniquement son lecteur", async t => {
  const f = await fixture(t); await f.connect(); let shutdowns = 0;
  f.reader.shutdown = async () => { shutdowns++; f.reader.connected = false; };
  await f.agent.close(); await f.agent.close(); assert.equal(shutdowns, 1);
  assert.equal(f.reader.listenerCount("tag"), 0); assert.equal(f.reader.listenerCount("disconnected"), 0);
  assert.equal(f.reader.connected, false); assert.equal(f.agent.server.listening, false);
});
