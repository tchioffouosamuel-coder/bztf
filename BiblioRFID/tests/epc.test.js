import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { formatAccession, generateEpc, isValidEpc } from "../lib/epc.js";
import { LibraryDatabase } from "../lib/database.js";

test("génère un EPC 96 bits stable et vérifiable", () => {
  const epc = generateEpc(2026, 42);
  assert.equal(epc.length, 24);
  assert.match(epc, /^[0-9A-F]+$/);
  assert.equal(isValidEpc(epc), true);
  assert.equal(isValidEpc(`${epc.slice(0, -1)}0`), false);
  assert.equal(formatAccession(2026, 42), "BCM-2026-000042");
});

test("catalogue, modifie et associe un tag à un livre", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-rfid-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "test.db"));
    const created = database.createBook({
      title: "Une si longue lettre",
      author: "Mariama Bâ",
      shelf: "LIT-001",
    });
    assert.equal(created.status, "a_encoder");
    assert.equal(created.accession.endsWith("000001"), true);
    assert.equal(isValidEpc(created.epc), true);

    const updated = database.updateBook(created.id, {
      ...created,
      shelf: "LIT-042",
    });
    assert.equal(updated.shelf, "LIT-042");

    const tagged = database.markTagged(created.id, "E28068940000500A12AB0001");
    assert.equal(tagged.status, "encode");
    assert.equal(database.dashboard().counts.tagged, 1);
    assert.equal(
      database.activity().some((item) => item.type === "ecriture"),
      true,
    );

    const second = database.createBook({
      title: "Le Vieux Nègre et la médaille",
    });
    assert.throws(() => database.markTagged(second.id, tagged.tid), /déjà lié/);
    const recognized = database.recognizeTag(
      second.epc.toLowerCase(),
      "E28068940000500A12AB0002",
    );
    assert.equal(recognized.id, second.id);
    assert.equal(recognized.tid, "E28068940000500A12AB0002");
    assert.equal(recognized.status, "encode");

    const untagged = database.markUntagged(created.id);
    assert.equal(untagged.status, "a_encoder");
    assert.equal(untagged.tid, null);
    assert.equal(untagged.tagged_at, null);
    assert.equal(database.dashboard().counts.tagged, 1);
    assert.equal(
      database.activity().some((item) => item.type === "desencodage"),
      true,
    );
    database.deleteBook(created.id);
    const third = database.createBook({ title: "Sous l'orage" });
    assert.equal(
      third.accession.endsWith("000003"),
      true,
      "Un numéro supprimé ne doit pas être réutilisé.",
    );
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
