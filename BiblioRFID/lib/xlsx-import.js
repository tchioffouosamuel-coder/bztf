import { createHash } from "node:crypto";
import ExcelJS from "exceljs";

function cellText(value) {
  if (value == null) return "";
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  if (typeof value !== "object") return String(value).trim();
  if (value.richText) return value.richText.map((part) => part.text).join("").trim();
  if (value.text != null) return String(value.text).trim();
  if (value.result != null) return cellText(value.result);
  return "";
}

function headerKey(value) {
  return cellText(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toUpperCase().replace(/[^A-Z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function validYear(value) {
  const match = cellText(value).match(/\b(1\d{3}|20\d{2})\b/);
  if (!match) return "";
  const year = Number(match[1]);
  return year <= new Date().getFullYear() + 1 ? String(year) : "";
}

function importKey(sheetName, rowNumber, values) {
  return createHash("sha256").update([
    "biblio-xlsx-v1", sheetName, rowNumber, values.rawTitle, values.rawAuthor,
    values.isbn, values.image, values.shelf
  ].join("\u001f")).digest("hex");
}

export async function parseCatalogWorkbook(buffer) {
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(buffer);
  const records = [];
  const sheets = [];
  let skipped = 0;

  for (const sheet of workbook.worksheets) {
    if (sheet.rowCount < 2) continue;
    const columns = new Map();
    sheet.getRow(1).eachCell((cell, column) => columns.set(headerKey(cell.value), column));
    if (!columns.has("TITRE") || !columns.has("AUTEURS")) {
      throw new Error(`La feuille « ${sheet.name} » ne contient pas les colonnes TITRE et AUTEURS attendues.`);
    }
    if (sheet.rowCount > 100001) throw new Error(`La feuille « ${sheet.name} » dépasse la limite de 100000 lignes.`);
    let sheetRecords = 0;

    const valueAt = (row, name) => {
      const column = columns.get(name);
      return column ? cellText(row.getCell(column).value) : "";
    };
    for (let rowNumber = 2; rowNumber <= sheet.rowCount; rowNumber++) {
      const row = sheet.getRow(rowNumber);
      const rawTitle = valueAt(row, "TITRE");
      const rawAuthor = valueAt(row, "AUTEURS");
      const legacyBibleNumber = Boolean(rawAuthor && /^[\d\s./-]+$/.test(rawTitle));
      const title = legacyBibleNumber ? rawAuthor : rawTitle;
      const author = legacyBibleNumber ? "" : rawAuthor;
      if (!title) {
        skipped++;
        continue;
      }

      const building = valueAt(row, "BATIMENT");
      const room = valueAt(row, "SALLE");
      const shelfName = valueAt(row, "ETAGERE");
      const block = valueAt(row, "NUMERO_DE_BLOC");
      const shelf = [building, room, shelfName, block].filter(Boolean).join(" · ");
      const category = valueAt(row, "SOUS_CATEGORIE") || valueAt(row, "CATEGORIE") || valueAt(row, "SECTION");
      const isbn = valueAt(row, "ISBN");
      const image = valueAt(row, "IMAGE");
      const notes = [
        legacyBibleNumber && `Numéro source : ${rawTitle}`,
        valueAt(row, "SECTION") && `Section : ${valueAt(row, "SECTION")}`,
        valueAt(row, "SOUS_SECTION") && `Sous-section : ${valueAt(row, "SOUS_SECTION")}`,
        valueAt(row, "PAGES") && `Pages : ${valueAt(row, "PAGES")}`,
        valueAt(row, "TYPE_DE_DOC") && `Type : ${valueAt(row, "TYPE_DE_DOC")}`,
        valueAt(row, "LANGUE") && `Langue : ${valueAt(row, "LANGUE")}`,
        image && `Image : ${image}`,
        valueAt(row, "RESUME") && `Résumé : ${valueAt(row, "RESUME")}`
      ].filter(Boolean).join("\n");
      const values = { rawTitle, rawAuthor, isbn, image, shelf };
      records.push({
        import_key: importKey(sheet.name, rowNumber, values),
        title,
        author,
        isbn,
        publisher: valueAt(row, "EDITEUR"),
        publication_year: validYear(valueAt(row, "DATE_PUBLICATION")),
        category,
        shelf,
        notes,
        source_sheet: sheet.name,
        source_row: rowNumber
      });
      sheetRecords++;
    }
    sheets.push({ name: sheet.name, rows: sheetRecords });
  }

  if (!records.length) throw new Error("Le classeur ne contient aucune notice de livre exploitable.");
  return { records, sheets, skipped };
}
