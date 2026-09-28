import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { _electron as electron } from "playwright-core";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const packageInfo = JSON.parse(
  fs.readFileSync(path.join(root, "package.json"), "utf8"),
);
const executable = path.join(
  root,
  process.env.BIBLIORFID_DESKTOP_DIR || "dist-desktop",
  "win-unpacked",
  "Bibliotèque ZTF.exe",
);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "bibliorfid-desktop-"));

assert.equal(fs.existsSync(executable), true, "L’exécutable Windows doit exister.");

const launchEnvironment = { ...process.env };
delete launchEnvironment.ELECTRON_RUN_AS_NODE;

const application = await electron.launch({
  executablePath: executable,
  args: [`--user-data-dir=${path.join(profile, "chromium")}`],
  env: {
    ...launchEnvironment,
    APPDATA: profile,
    BIBLIORFID_DESKTOP_PORT: "4391",
  },
});

try {
  const window = await application.firstWindow();
  await window.waitForLoadState("networkidle");
  await window.waitForSelector("#auth-screen:not(.hidden)");
  assert.equal(
    fs.existsSync(
      path.join(
        profile,
        "chromium",
        "native",
        packageInfo.version,
        "bridge",
        "bin",
        "ReaderBridge.exe",
      ),
    ),
    true,
    "Le pont RFID doit être extrait dans le profil persistant.",
  );
  assert.match(window.url(), /^http:\/\/127\.0\.0\.1:4391/);
  assert.equal(await window.locator("#app-shell").isHidden(), true);
  assert.equal(
    await window.evaluate(() => document.documentElement.classList.contains("desktop")),
    true,
  );

  await window.fill('#auth-form input[name="name"]', "Administrateur Test");
  await window.fill('#auth-form input[name="email"]', "admin@desktop.test");
  await window.fill('#auth-form input[name="password"]', "mot-de-passe-test");
  await window.click("#auth-submit");
  await window.waitForSelector("#app-shell:not(.hidden)");
  assert.equal(await window.locator("#user-name").innerText(), "Administrateur Test");
  assert.equal(await window.locator("#user-role").innerText(), "Administrateur");
  const bridgeProbe = await window.evaluate(async () => {
    const response = await fetch("/api/devices");
    return { status: response.status, body: await response.json() };
  });
  assert.equal(
    bridgeProbe.status,
    200,
    `Le pont RFID empaqueté doit démarrer: ${bridgeProbe.body.error || "erreur inconnue"}`,
  );
  const bridgeCompile = await window.evaluate(async () => {
    const timing = await (await fetch("/api/reader/timing")).json();
    if (timing.rearmDelayMs !== 10000)
      throw new Error(`Migration anti-rebond incorrecte : ${timing.rearmDelayMs} ms.`);
    const response = await fetch("/api/reader/timing", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        beepMode: timing.beepMode,
        beepDurationMs: timing.beepDurationMs,
        rearmDelayMs: timing.rearmDelayMs,
      }),
    });
    return { status: response.status, body: await response.json() };
  });
  assert.equal(
    bridgeCompile.status,
    200,
    `Le pont RFID extrait doit être recompilable: ${bridgeCompile.body.error || "erreur inconnue"}`,
  );
  console.log("Fenêtre native et authentification desktop validées.");
} finally {
  await application.close();
  fs.rmSync(profile, { recursive: true, force: true });
}
