/**
 * Lecture des notices UNIMARC-XML (BnF SRU, SUDOC).
 * Port de `lib/core/unimarc.dart` : mêmes zones, mêmes sous-zones, même
 * jointure ` -- ` des vedettes matière.
 */
import { XMLParser } from "fast-xml-parser";

import { normalizeNotice } from "./notice.js";

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@",
  removeNSPrefix: true,
  trimValues: true,
  parseTagValue: false,
  parseAttributeValue: false,
  textNodeName: "#text",
  isArray: (name) =>
    ["record", "datafield", "controlfield", "subfield"].includes(name),
});

function nodeText(node) {
  if (node === null || node === undefined) return "";
  if (typeof node !== "object") return String(node).replace(/\s+/g, " ").trim();
  if (Array.isArray(node)) return node.map(nodeText).join(" ").trim();
  return String(node["#text"] ?? "")
    .replace(/\s+/g, " ")
    .trim();
}

/** Les `record` peuvent être à n'importe quelle profondeur de l'enveloppe SRU. */
function collectRecords(node, found = []) {
  if (!node || typeof node !== "object") return found;
  if (Array.isArray(node)) {
    for (const item of node) collectRecords(item, found);
    return found;
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === "record") {
      for (const record of Array.isArray(value) ? value : [value])
        if (record && typeof record === "object") found.push(record);
    }
    if (value && typeof value === "object") collectRecords(value, found);
  }
  return found;
}

function datafields(record, tag) {
  const fields = Array.isArray(record?.datafield) ? record.datafield : [];
  return tag ? fields.filter((field) => field["@tag"] === tag) : fields;
}

function datafield(record, tag) {
  return datafields(record, tag)[0] || null;
}

function controlfield(record, tag) {
  const fields = Array.isArray(record?.controlfield) ? record.controlfield : [];
  for (const field of fields) {
    if (field["@tag"] !== tag) continue;
    const value = nodeText(field);
    if (value) return value;
  }
  return "";
}

function subfield(field, code) {
  if (!field) return "";
  const subfields = Array.isArray(field.subfield) ? field.subfield : [];
  for (const entry of subfields) {
    if (entry["@code"] !== code) continue;
    const value = nodeText(entry);
    if (value) return value;
  }
  return "";
}

function joinSubfields(field, codes) {
  return codes
    .map((code) => subfield(field, code))
    .filter(Boolean)
    .join(" -- ");
}

function parseAuthor(field) {
  const name = [subfield(field, "a"), subfield(field, "b")]
    .filter(Boolean)
    .join(" ");
  return { name, role: subfield(field, "4") };
}

function parseRecord(record, { sourceNotice, retrievedAt }) {
  const title = datafield(record, "200");
  const publication = datafield(record, "214") || datafield(record, "210");
  const physical = datafield(record, "215");
  const collection = datafield(record, "225");
  const language = datafield(record, "101");
  return normalizeNotice({
    title: subfield(title, "a"),
    subtitle: subfield(title, "e"),
    authors: [
      ...datafields(record, "700"),
      ...datafields(record, "701"),
      ...datafields(record, "702"),
    ].map(parseAuthor),
    publisher: subfield(publication, "c"),
    publicationPlace: subfield(publication, "a"),
    publicationDate: subfield(publication, "d"),
    edition: subfield(datafield(record, "205"), "a"),
    pageCount: subfield(physical, "a"),
    illustrations: subfield(physical, "c"),
    dimensions: subfield(physical, "d"),
    collection: subfield(collection, "a"),
    collectionNumber: subfield(collection, "v"),
    language: subfield(language, "a"),
    originalLanguage: subfield(language, "c"),
    summary: subfield(datafield(record, "330"), "a"),
    subjects: datafields(record, "606").map((field) =>
      joinSubfields(field, ["a", "x", "y", "z"]),
    ),
    classification: subfield(datafield(record, "676"), "a"),
    isbn: subfield(datafield(record, "010"), "a"),
    sourceNotice,
    sourceIdentifier: controlfield(record, "001") || controlfield(record, "003"),
    retrievedAt,
  });
}

export function parseUnimarcNotices(
  xmlText,
  { sourceNotice = "", retrievedAt = new Date().toISOString() } = {},
) {
  let document;
  try {
    document = parser.parse(String(xmlText ?? ""));
  } catch {
    return [];
  }
  return collectRecords(document)
    .filter((record) => datafields(record).length > 0)
    .map((record) => parseRecord(record, { sourceNotice, retrievedAt }))
    .filter((notice) => notice.title);
}
