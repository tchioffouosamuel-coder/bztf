/**
 * Extraction d'indices bibliographiques dans le texte OCR brut.
 * Ces heuristiques servent de point de départ : l'ISBN est vérifié par sa clé
 * de contrôle, le reste est une proposition que le catalogueur — ou l'IA, si
 * elle est activée — corrige avant enregistrement.
 */
import { isValidIsbn, normalizeIsbn, toIsbn13 } from "./isbn.js";

const PUBLISHERS = [
  "Gallimard",
  "Hachette",
  "Le Seuil",
  "Seuil",
  "Flammarion",
  "Fayard",
  "Albin Michel",
  "Grasset",
  "Robert Laffont",
  "Actes Sud",
  "Nathan",
  "Hatier",
  "Belin",
  "Bordas",
  "Dunod",
  "Eyrolles",
  "Larousse",
  "Armand Colin",
  "La Découverte",
  "L'Harmattan",
  "Karthala",
  "Présence Africaine",
  "Éditions du Rocher",
  "Odile Jacob",
  "Pocket",
  "Folio",
  "J'ai lu",
  "Minuit",
  "PUF",
  "Clé",
  "CLE International",
  "Edicef",
  "Éditions CLÉ",
  "Springer",
  "Elsevier",
  "Pearson",
  "Wiley",
  "O'Reilly",
  "Oxford University Press",
  "Cambridge University Press",
];

const STOP_LINES =
  /^(isbn|ean|www\.|http|prix|tva|imprim|d[ée]p[ôo]t l[ée]gal|tous droits|achev[ée] d|©|code|barres?)\b/i;

export function textLines(text) {
  return String(text ?? "")
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean);
}

/**
 * ISBN valides trouvés dans le texte, en ISBN-13, les mentions explicitement
 * étiquetées « ISBN » d'abord.
 */
export function extractIsbns(text) {
  const raw = String(text ?? "");
  const found = [];
  const push = (value, labelled) => {
    const normalized = normalizeIsbn(value);
    if (!isValidIsbn(normalized)) return;
    let isbn13;
    try {
      isbn13 = toIsbn13(normalized);
    } catch {
      return;
    }
    const existing = found.find((entry) => entry.isbn13 === isbn13);
    if (existing) {
      existing.labelled = existing.labelled || labelled;
      return;
    }
    found.push({ isbn13, raw: normalized, labelled });
  };

  const labelled = /isbn[^0-9a-z]{0,12}((?:97[89][\s-]?)?[\d][\d\s-]{7,17}[\dXx])/gi;
  for (const match of raw.matchAll(labelled)) push(match[1], true);

  // Codes-barres EAN-13 et ISBN-10 isolés, souvent sans l'étiquette « ISBN ».
  for (const match of raw.matchAll(/\b97[89][\s-]?[\d][\d\s-]{8,14}\d\b/g))
    push(match[0], false);
  for (const match of raw.matchAll(/\b\d(?:[\d\s-]{8,13})[\dXx]\b/g))
    push(match[0], false);

  return found
    .sort((left, right) => Number(right.labelled) - Number(left.labelled))
    .map((entry) => entry.isbn13);
}

export function extractYear(text) {
  const now = new Date().getFullYear();
  const years = [...String(text ?? "").matchAll(/\b(1[5-9]\d{2}|20\d{2})\b/g)]
    .map((match) => Number(match[1]))
    .filter((year) => year >= 1500 && year <= now + 1);
  if (!years.length) return "";
  // Le millésime d'édition est en général la date la plus récente imprimée.
  return String(Math.max(...years));
}

export function extractPublisher(text) {
  const haystack = String(text ?? "").toLowerCase();
  for (const publisher of PUBLISHERS) {
    if (haystack.includes(publisher.toLowerCase())) return publisher;
  }
  const match = /(?:[ée]ditions?|[ée]d\.)\s+([A-ZÉÈÀÂÎÔÛÇ][\wÀ-ÿ'’\-]*(?:\s+[A-ZÉÈÀÂÎÔÛÇ][\wÀ-ÿ'’\-]*){0,2})/.exec(
    String(text ?? ""),
  );
  return match ? match[1].trim() : "";
}

export function extractCollection(text) {
  const match = /(?:collection|coll\.)\s*:?\s*([^\n]{2,60})/i.exec(
    String(text ?? ""),
  );
  return match ? match[1].replace(/\s+/g, " ").trim() : "";
}

function looksLikeAuthorLine(line) {
  if (/^(par|de|by|auteurs?)\s+/i.test(line)) return true;
  const words = line.split(" ").filter(Boolean);
  if (words.length < 2 || words.length > 5) return false;
  // Deux à cinq mots, chacun capitalisé : signature d'une ligne d'auteur.
  return words.every((word) => /^[A-ZÉÈÀÂÎÔÛÇ][\p{L}'’\-.]*$/u.test(word));
}

function titleScore(line) {
  const words = line.split(" ").filter(Boolean).length;
  const upperRatio =
    line.replace(/[^A-Za-zÀ-ÿ]/g, "").length > 0
      ? line.replace(/[^A-ZÀ-Þ]/g, "").length /
        line.replace(/[^A-Za-zÀ-ÿ]/g, "").length
      : 0;
  // Un titre de couverture est assez long et souvent en capitales.
  return words * 2 + upperRatio * 6 + Math.min(line.length, 60) / 10;
}

/** Titre et auteur probables d'une première de couverture. */
export function extractTitleAndAuthor(text) {
  const lines = textLines(text)
    .filter((line) => !STOP_LINES.test(line))
    .filter((line) => line.replace(/[^\p{L}]/gu, "").length >= 3)
    .slice(0, 25);
  if (!lines.length) return { title: "", author: "" };

  const authorIndex = lines.findIndex(looksLikeAuthorLine);
  const titleCandidates = lines
    .map((line, index) => ({ line, index }))
    .filter((entry) => entry.index !== authorIndex)
    .sort((left, right) => titleScore(right.line) - titleScore(left.line));

  const title = titleCandidates[0]?.line || lines[0];
  const author =
    authorIndex >= 0
      ? lines[authorIndex].replace(/^(par|de|by|auteurs?)\s+/i, "").trim()
      : "";
  return { title, author };
}

/**
 * Agrège les textes OCR d'un livre (couverture, dos, page de titre) en un jeu
 * d'indices : les ISBN et la date viennent surtout de la 4e de couverture,
 * le titre et l'auteur de la première.
 */
export function extractHints({ front = "", back = "", other = "" } = {}) {
  const everything = [front, back, other].filter(Boolean).join("\n");
  const { title, author } = extractTitleAndAuthor(front || everything);
  return {
    isbns: extractIsbns(everything),
    title,
    author,
    publisher: extractPublisher(everything),
    publicationYear: extractYear(back || everything),
    collection: extractCollection(everything),
    summary: summaryFromBack(back),
  };
}

/** La 4e de couverture fournit un résumé exploitable si elle est assez longue. */
function summaryFromBack(back) {
  const lines = textLines(back).filter(
    (line) => !STOP_LINES.test(line) && line.length > 40,
  );
  const summary = lines.join(" ").trim();
  return summary.length >= 80 ? summary.slice(0, 4000) : "";
}
