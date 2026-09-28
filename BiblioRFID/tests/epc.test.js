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

test("supprime plusieurs livres dans une seule opération", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-rfid-bulk-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "test.db"));
    const first = database.createBook({ title: "Premier livre" });
    const second = database.createBook({ title: "Deuxième livre" });
    const preserved = database.createBook({ title: "Livre conservé" });

    const result = database.deleteBooks([first.id, second.id, second.id, 999999]);

    assert.deepEqual(result, { deleted: 2, missing: 1 });
    assert.equal(database.getBook(first.id), undefined);
    assert.equal(database.getBook(second.id), undefined);
    assert.equal(database.getBook(preserved.id).title, "Livre conservé");
    assert.equal(
      database.activity().filter((item) =>
        item.message.startsWith("Livre supprimé"),
      ).length,
      2,
    );
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("gère l'abonné, son abonnement et le cycle d'emprunt", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-rfid-loan-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "test.db"));
    const created = database.createBook({ title: "Livre empruntable" });
    const tagged = database.markTagged(created.id, "E28068940000500A12AB0042");
    const dueAt = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString();
    const result = database.borrowBook(tagged.id, {
      member_number: "AB-0001",
      name: "Abonné Test",
      email: "abonne@example.test",
      phone: "+237600000000",
      due_at: dueAt,
    });

    assert.equal(result.book.status, "indisponible");
    assert.equal(result.activeLoan.subscriber_name, "Abonné Test");
    assert.equal(database.listSubscribers("AB-0001")[0].active_loans, 1);
    assert.throws(
      () => database.borrowBook(tagged.id, {
        member_number: "AB-0002",
        name: "Autre Abonné",
        due_at: dueAt,
      }),
      /déjà un emprunt actif/,
    );
    assert.throws(() => database.deleteBook(tagged.id), /retour/);

    const returned = database.returnBook(tagged.id);
    assert.equal(returned.book.status, "encode");
    assert.equal(returned.activeLoan, null);
    assert.equal(
      database.activity().some((item) => item.type === "retour"),
      true,
    );
    assert.equal(database.deleteBook(tagged.id), true);
    assert.equal(database.getBook(tagged.id), undefined);
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
