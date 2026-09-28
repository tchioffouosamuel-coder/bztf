import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import ExcelJS from "exceljs";
import { LibraryDatabase } from "../lib/database.js";
import { parseCatalogWorkbook } from "../lib/xlsx-import.js";

const headers = [
  "BATIMENT", "SALLE", "SECTION", "ETAGERE", "NUMERO DE BLOC", "CATEGORIE", "TITRE",
  "NUMERO D'EXEMPLAIRE", "AUTEURS", "SOUS_CATEGORIE", "SOUS_SECTION", "DATE_PUBLICATION",
  "EDITEUR", "PAGES", "ISBN", "IMAGE", "TYPE DE DOC", "LANGUE", "RESUME", "RFID"
];

async function sampleWorkbook() {
  const workbook = new ExcelJS.Workbook();
  const sheet = workbook.addWorksheet("Feuil1");
  sheet.addRow(headers);
  sheet.addRow([
    "Bâtiment A", "Salle 1", "Bible", "Étagère 2", "Bloc 3", "Bible", 291, 1,
    "The New Testament", "Nouveau Testament", "", 1998, "Bible Society", 480,
    "9780000000001", "bible.jpg", "Livre", "Français", "Édition d'étude", ""
  ]);
  sheet.addRow([
    "Bâtiment B", "Salle 2", "Bible and exegese", "Étagère 4", "Bloc 5", "Exégèse",
    "Commentaire sur Jean", 1, "Jean Dupont", "Commentaire", "Jean", 2015,
    "Éditions Test", 320, "9780000000002", "jean.jpg", "Livre", "Français", "Résumé", ""
  ]);
  return Buffer.from(await workbook.xlsx.writeBuffer());
}

test("convertit le format du catalogue XLSX fourni", async () => {
  const parsed = await parseCatalogWorkbook(await sampleWorkbook());
  assert.equal(parsed.records.length, 2);
  assert.equal(parsed.skipped, 0);
  assert.deepEqual(parsed.sheets, [{ name: "Feuil1", rows: 2 }]);

  const bible = parsed.records[0];
  assert.equal(bible.title, "The New Testament");
  assert.equal(bible.author, "");
  assert.equal(bible.category, "Nouveau Testament");
  assert.equal(bible.shelf, "Bâtiment A · Salle 1 · Étagère 2 · Bloc 3");
  assert.match(bible.notes, /Numéro source : 291/);
  assert.equal(bible.publication_year, "1998");

  const exegesis = parsed.records[1];
  assert.equal(exegesis.title, "Commentaire sur Jean");
  assert.equal(exegesis.author, "Jean Dupont");
  assert.equal(exegesis.publisher, "Éditions Test");
  assert.equal(exegesis.isbn, "9780000000002");
});

test("réimporter le même classeur ne duplique pas les livres", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-xlsx-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "catalogue.db"));
    const parsed = await parseCatalogWorkbook(await sampleWorkbook());
    assert.deepEqual(database.importBooks(parsed.records), { imported: 2, duplicates: 0, rejected: 0 });
    assert.deepEqual(database.importBooks(parsed.records), { imported: 0, duplicates: 2, rejected: 0 });
    assert.equal(database.countBooks(), 2);
    assert.equal(database.listBooks({ limit: 1, offset: 1 }).length, 1);
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
