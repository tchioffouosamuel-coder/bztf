import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { ReaderService } from "../lib/reader-service.js";

const marker = "__RFID_JSON__";
function child() {
  const process = new EventEmitter();
  process.stdout = new PassThrough(); process.stderr = new PassThrough(); process.stdin = new PassThrough();
  process.killed = false;
  process.kill = () => { process.killed = true; process.emit("exit", 1); };
  return process;
}
function reader(process, ready = true) {
  return new ReaderService("bridge/ReaderBridge.exe", marker, { startupTimeoutMs: 30, spawnProcess: (file, args, options) => {
    assert.deepEqual(args, ["daemon"]); assert.equal(options.windowsHide, true);
    if (ready) queueMicrotask(() => process.stdout.write(marker + '{"type":"ready"}\n'));
    return process;
  } });
}

test("pont sans message ready expire et ferme le processus", async () => {
  const process = child(); const service = reader(process, false);
  await assert.rejects(service.start(), /demarrage/); assert.equal(process.killed, true); assert.equal(service.process, null);
});
test("sortie avant ready rejette immediatement le demarrage", async () => {
  const process = child(); const service = reader(process, false); const ready = service.start();
  process.emit("exit", 2); await assert.rejects(ready, /code 2/); assert.equal(service.connected, false);
});
test("executable absent rejette et permet un redemarrage", async () => {
  const first = child(); const service = reader(first, false); const ready = service.start();
  first.emit("error", new Error("ENOENT")); await assert.rejects(ready, /ENOENT/); assert.equal(service.process, null);
  const second = child(); service.spawnProcess = () => { queueMicrotask(() => second.stdout.write(marker + '{"type":"ready"}\n')); return second; };
  await service.start(); const tags = []; service.on("tag", tag => tags.push(tag));
  first.stdout.write(marker + '{"type":"tag","tag":{"Epc":"AA12"}}\n');
  first.emit("exit", 1); assert.equal(service.process, second); assert.deepEqual(tags, []); second.kill();
});
test("pont pret relaye commandes et tags sans changer le protocole", async () => {
  const process = child(); const service = reader(process);
  process.stdin.on("data", chunk => {
    const command = JSON.parse(chunk.toString()); assert.equal(command.action, "connect"); assert.equal(command.connectionType, "usb");
    process.stdout.write(marker + JSON.stringify({ type: "response", id: command.id, ok: true }) + "\n");
  });
  await service.connect({ type: "usb", endpoint: "" }); assert.equal(service.connected, true);
  const tags = []; service.on("tag", tag => tags.push(tag));
  process.stdout.write(marker + '{"type":"tag","tag":{"Epc":"AA12","Tid":"BB34"}}\n');
  assert.deepEqual(tags, [{ Epc: "AA12", Tid: "BB34" }]); process.kill(); assert.equal(service.connected, false);
});
test("arret du pont rejette les commandes en attente et vide leurs minuteries", async () => {
  const process = child(); const service = reader(process); await service.start();
  const operation = service.command("status"); await new Promise(resolve => setImmediate(resolve));
  process.kill(); await assert.rejects(operation, /arrete/); assert.equal(service.pending.size, 0);
});
