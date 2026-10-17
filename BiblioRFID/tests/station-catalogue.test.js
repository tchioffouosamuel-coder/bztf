import test from "node:test";
import assert from "node:assert/strict";
import { StationCatalogue } from "../public/station-catalogue.js";

const tag = { epc: "AA12", tid: "BB34" };
const tick = () => new Promise(resolve => setImmediate(resolve));

function fixture() {
  const calls = [];
  let changes = 0;
  const catalogue = new StationCatalogue({
    lookup: (url, options) => new Promise((resolve, reject) => calls.push({ url, ...options, resolve, reject })),
    changed: () => changes++,
  });
  return { catalogue, calls, changes: () => changes };
}

test("la presence continue ne relance pas une recherche, les deux identifiants partent", async () => {
  const { catalogue, calls, changes } = fixture();
  catalogue.sync([tag]);
  catalogue.sync([{ ...tag, rssi: 90 }]);
  await tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/api/ilms/copies/by-tag?epc=AA12&tid=BB34");
  calls[0].resolve({ configured: true, copy: { id: "copy" } });
  await tick();
  assert.equal(catalogue.get(tag).state, "found");
  assert.equal(changes(), 1);
  catalogue.sync([tag]);
  await tick();
  assert.equal(calls.length, 1);
});

test("les cartes et badges ne declenchent aucune recherche d'exemplaire", async () => {
  const { catalogue, calls } = fixture();
  catalogue.sync([
    { ...tag, kind: "card" }, { ...tag, kind: "badge" },
    { ...tag, subscriber: {} }, { ...tag, staff: {} }, {},
  ]);
  await tick();
  assert.equal(calls.length, 0);
});

test("le retrait annule la demande et ignore sa reponse, meme si le tag revient", async () => {
  const { catalogue, calls, changes } = fixture();
  catalogue.sync([tag]);
  await tick();
  catalogue.sync([]);
  assert.equal(calls[0].signal.aborted, true);
  catalogue.sync([tag]);
  await tick();
  calls[0].resolve({ copy: { id: "obsolete" } });
  await tick();
  assert.equal(changes(), 0);
  assert.equal(catalogue.get(tag).copy, null);
  calls[1].resolve({ copy: { id: "current" } });
  await tick();
  assert.equal(catalogue.get(tag).copy.id, "current");
});

test("un EPC modifie sur le meme TID relance la recherche", async () => {
  const { catalogue, calls } = fixture();
  catalogue.sync([tag]);
  await tick();
  catalogue.sync([{ ...tag, epc: "CC56" }]);
  await tick();
  assert.equal(calls[0].signal.aborted, true);
  assert.equal(calls.length, 2);
});

test("plusieurs tags gardent leurs resultats distincts, inconnu et panne compris", async () => {
  const { catalogue, calls } = fixture();
  const other = { epc: "CC56" };
  catalogue.sync([tag, other]);
  await tick();
  calls[0].resolve({ copy: null });
  calls[1].reject(new Error("ILMS injoignable"));
  await tick();
  assert.equal(catalogue.get(tag).state, "unknown");
  assert.equal(catalogue.get(other).state, "error");
  assert.equal(catalogue.get(other).message, "ILMS injoignable");
  catalogue.sync([tag, other]);
  await tick();
  assert.equal(calls.length, 2, "une panne ne doit pas marteler la passerelle");
});

test("une reinitialisation invalide les recherches et permet une reprise explicite", async () => {
  const { catalogue, calls, changes } = fixture();
  catalogue.sync([tag]);
  await tick();
  catalogue.reset();
  calls[0].resolve({ copy: { id: "old-session" } });
  await tick();
  assert.equal(changes(), 0);
  assert.equal(catalogue.entries.size, 0);
  catalogue.sync([tag]);
  await tick();
  calls[1].resolve({ configured: false, copy: null });
  await tick();
  assert.equal(catalogue.get(tag).state, "unconfigured");
});
