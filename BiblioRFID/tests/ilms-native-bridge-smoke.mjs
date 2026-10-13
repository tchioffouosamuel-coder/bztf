import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ReaderService } from "../lib/reader-service.js";

if (process.platform !== "win32") throw new Error("Recette du pont natif reservee a Windows.");
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bridgeRoot = process.env.BIBLIORFID_BRIDGE_DIR ? path.resolve(process.env.BIBLIORFID_BRIDGE_DIR) : path.join(root, "bridge");
const reader = new ReaderService(path.join(bridgeRoot, "bin", "ReaderBridge.exe"), "__RFID_JSON__");
try {
  const ready = await reader.start(); assert.equal(ready.type, "ready");
  const status = await reader.command("status"); assert.equal(status.ok, true); assert.equal(status.connected, false);
  console.log("Pont natif : demarrage et protocole JSON verifies, sans connexion au lecteur ni ecriture.");
} finally { await reader.shutdown(); }
