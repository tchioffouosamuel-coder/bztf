import path from "node:path";
import { fileURLToPath } from "node:url";
import { ReaderService } from "./lib/reader-service.js";
import { createIlmsReaderAgent } from "./lib/ilms-reader-agent.js";

const root = path.dirname(fileURLToPath(import.meta.url));
const bridgeRoot = process.env.BIBLIORFID_BRIDGE_DIR ? path.resolve(process.env.BIBLIORFID_BRIDGE_DIR) : path.join(root, "bridge");
const port = Number(process.env.ILMS_AGENT_PORT ?? 4316);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Port local invalide.");
const reader = new ReaderService(path.join(bridgeRoot, "bin", "ReaderBridge.exe"), "__RFID_JSON__");
const agent = createIlmsReaderAgent({ reader, origin: process.env.ILMS_AGENT_ORIGIN,
  token: process.env.ILMS_AGENT_TOKEN, deviceId: process.env.ILMS_AGENT_DEVICE_ID, libraryId: process.env.ILMS_AGENT_LIBRARY_ID });
agent.server.once("error", () => {
  console.error("Impossible de demarrer l'agent local ILMS.");
  process.exitCode = 1;
  void agent.close();
});
agent.server.listen(port, "127.0.0.1", () => console.log(`Agent lecteur ILMS : http://127.0.0.1:${port} (lecture uniquement)`));
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => {
  if (stopping) return;
  stopping = true;
  void agent.close().catch(() => { process.exitCode = 1; });
});
