/**
 * Éprouve l'écriture de l'agent contre un vrai poste.
 *
 * Un serveur complet est démarré sur une base jetable, en connexion
 * « simulation » — le seul mode qui pose un tag unique avec un TID sans
 * matériel. Ce qui est vérifié ici ne se lit pas dans le code : les gardes
 * d'origine et de clé, l'écriture relue, et le refus d'un tag absent.
 *
 *   node tests/agent-write-smoke.mjs
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const racine = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const donnees = fs.mkdtempSync(path.join(os.tmpdir(), "bztf-agent-"));
const PORT = Number(process.env.PORT_SMOKE || 4318);
const BASE = `http://127.0.0.1:${PORT}`;
const ORIGINE = "http://127.0.0.1:5599";

const poste = spawn(process.execPath, ["--no-warnings", "server.js"], {
  cwd: racine,
  env: { ...process.env, PORT: String(PORT), BIBLIORFID_DATA_DIR: donnees, BIBLIORFID_HOST: "127.0.0.1" },
  stdio: ["ignore", "pipe", "pipe"],
});
poste.stdout.on("data", () => {});
poste.stderr.on("data", (c) => process.stderr.write(c));

async function attendre() {
  for (let essai = 0; essai < 60; essai += 1) {
    try {
      const reponse = await fetch(`${BASE}/api/auth/status`);
      if (reponse.ok) return;
    } catch {
      /* pas encore là */
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("Le poste n'a pas démarré.");
}

let cookie = "";
async function appel(chemin, options = {}) {
  const entetes = { "Content-Type": "application/json", ...(options.headers || {}) };
  if (cookie) entetes.Cookie = cookie;
  const reponse = await fetch(`${BASE}${chemin}`, { ...options, headers: entetes });
  const posee = reponse.headers.get("set-cookie");
  if (posee) cookie = posee.split(";")[0];
  const texte = await reponse.text();
  return { statut: reponse.status, corps: texte ? JSON.parse(texte) : null, entetes: reponse.headers };
}

try {
  await attendre();

  // Mise en place : un administrateur, la connexion simulée, l'origine servie.
  await appel("/api/auth/setup", {
    method: "POST",
    body: JSON.stringify({ name: "Essai", email: "essai@poste.test", password: "motdepasse1" }),
  });
  const reglages = await appel("/api/settings", {
    method: "PUT",
    body: JSON.stringify({ type: "simulation", agent_origins: ORIGINE }),
  });
  assert.equal(reglages.statut, 200);
  assert.equal(reglages.corps.agent_origins, ORIGINE);

  // --- 1. une origine inconnue n'écrit pas --------------------------------
  const etrangere = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: "https://ailleurs.example" },
    body: JSON.stringify({ epc: "A".repeat(24) }),
  });
  assert.equal(etrangere.statut, 403, "Une origine non réglée doit être refusée.");
  console.log("1. origine inconnue : refusée                            OK");

  // --- 2. sans clé réglée, l'écriture est fermée --------------------------
  const sansCle = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: ORIGINE },
    body: JSON.stringify({ epc: "42434D0120260000000100AB" }),
  });
  assert.equal(sansCle.statut, 403, "Fermé par défaut : aucune clé réglée, aucune écriture.");
  assert.match(sansCle.corps.error, /clé d'appairage/i);
  console.log("2. aucune clé réglée : écriture fermée                   OK");

  // --- 3. la clé n'est remise qu'une fois ---------------------------------
  const creation = await appel("/api/agent/key", { method: "POST" });
  assert.equal(creation.statut, 200);
  const cle = creation.corps.key;
  assert.match(cle, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{24}$/);
  const relecture = await appel("/api/settings");
  assert.equal(relecture.corps.agent_key, undefined, "La clé ne doit plus se relire.");
  assert.equal(relecture.corps.agent_key_set, true, "Seule sa présence sort.");
  console.log("3. clé remise une seule fois, présence seule ensuite     OK");

  // --- 4. une mauvaise clé ne passe pas -----------------------------------
  const mauvaise = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": "MAUVAISECLEMAUVAISECLE24" },
    body: JSON.stringify({ epc: "42434D0120260000000100AB" }),
  });
  assert.equal(mauvaise.statut, 403);
  console.log("4. mauvaise clé : refusée                                OK");

  // --- 5. un EPC qui n'est pas 96 bits est refusé avant l'antenne ---------
  const court = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": cle },
    body: JSON.stringify({ epc: "42434D01" }),
  });
  assert.equal(court.statut, 400);
  assert.match(court.corps.error, /24 caractères/);
  console.log("5. EPC qui n'est pas 96 bits : refusé                    OK");

  // --- 6. l'écriture passe, et elle est relue ------------------------------
  const vise = "42434D0120260000000100AB";
  const ecriture = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": cle },
    body: JSON.stringify({ epc: vise }),
  });
  assert.equal(ecriture.statut, 200, JSON.stringify(ecriture.corps));
  assert.equal(ecriture.corps.verified, true, "Une écriture non relue n'est jamais validée.");
  assert.equal(ecriture.corps.tag.epc, vise);
  assert.ok(ecriture.corps.tag.tid, "Le TID de la puce écrite doit revenir.");
  assert.equal(
    ecriture.entetes.get("access-control-allow-origin"),
    ORIGINE,
    "L'origine demandée est renvoyée telle quelle, jamais « * ».",
  );
  console.log("6. écriture vérifiée par relecture                       OK");

  // --- 7. désencoder le tag attendu, et seulement lui ---------------------
  const autreTid = await appel("/agent/reader/erase", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": cle },
    body: JSON.stringify({ tid: "E280000000000000FFFFFFFF" }),
  });
  assert.equal(autreTid.statut, 409, "Effacer le tag voisin rendrait un livre introuvable.");

  const efface = await appel("/agent/reader/erase", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": cle },
    body: JSON.stringify({ tid: ecriture.corps.tag.tid }),
  });
  assert.equal(efface.statut, 200, JSON.stringify(efface.corps));
  assert.equal(efface.corps.tag.epc, "0".repeat(24));
  console.log("7. désencodage du tag attendu, refus d'un autre          OK");

  // --- 8. retirer la clé referme l'écriture -------------------------------
  await appel("/api/agent/key", { method: "DELETE" });
  const referme = await appel("/agent/reader/write", {
    method: "POST",
    headers: { Origin: ORIGINE, "X-Agent-Key": cle },
    body: JSON.stringify({ epc: vise }),
  });
  assert.equal(referme.statut, 403, "Retirer la clé doit refermer l'écriture tout de suite.");
  console.log("8. clé retirée : écriture refermée                       OK");

  // --- 9. le flux de présence reste ouvert sans clé ------------------------
  const flux = await fetch(`${BASE}/agent/reader/events`, { headers: { Origin: ORIGINE } });
  assert.equal(flux.status, 200, "Lire n'abîme rien : le flux ne demande que l'origine.");
  assert.match(flux.headers.get("content-type"), /text\/event-stream/);
  await flux.body.cancel();
  console.log("9. le flux de présence reste libre d'accès               OK");

  console.log("");
  console.log("9 essais, 9 passes.");
} finally {
  poste.kill();
  await new Promise((r) => setTimeout(r, 300));
  fs.rmSync(donnees, { recursive: true, force: true });
}
