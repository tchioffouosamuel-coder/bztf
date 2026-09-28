import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import path from "node:path";
import test from "node:test";

const marker = "__RFID_JSON__";
const executable = path.resolve("bridge", "bin", "ReaderBridge.exe");

test("le pont RFID émet ses messages en UTF-8", async () => {
  const output = await new Promise((resolve) => {
    execFile(executable, ["write"], { encoding: "utf8" }, (_, stdout, stderr) =>
      resolve(`${stdout || ""}\n${stderr || ""}`),
    );
  });
  const line = output
    .split(/\r?\n/)
    .find((entry) => entry.startsWith(marker));
  assert.ok(line, "Le pont doit renvoyer une réponse JSON.");
  const payload = JSON.parse(line.slice(marker.length));
  assert.equal(payload.error, "Paramètres d'écriture manquants.");
  assert.equal(payload.error.includes("\uFFFD"), false);
});
