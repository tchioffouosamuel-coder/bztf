/**
 * Notice bibliographique normalisée, commune aux quatre sources.
 * Les noms de champs reprennent `NoticeResult` du mobile afin que les deux
 * applications décrivent une même notice de la même façon.
 */

const AUTHOR_ROLES = {
  "070": "auteur",
  "730": "traducteur",
  "440": "illustrateur",
};

const KNOWN_ROLES = new Set(Object.values(AUTHOR_ROLES));

/**
 * Accepte le code UNIMARC de la sous-zone 4 comme le rôle déjà résolu :
 * normaliser une notice déjà normalisée ne doit pas transformer un
 * traducteur en auteur.
 */
export function authorRole(code) {
  const value = String(code ?? "").trim();
  if (KNOWN_ROLES.has(value)) return value;
  return AUTHOR_ROLES[value] || "auteur";
}

function text(value, maxLength = 2000) {
  if (value === null || value === undefined) return "";
  return String(value).replace(/\s+/g, " ").trim().slice(0, maxLength);
}

export function normalizeNotice(raw = {}) {
  const authors = (Array.isArray(raw.authors) ? raw.authors : [])
    .map((author) =>
      typeof author === "string"
        ? { name: text(author, 240), role: "auteur" }
        : { name: text(author?.name, 240), role: authorRole(author?.role) },
    )
    .filter((author) => author.name);
  return {
    title: text(raw.title, 240),
    subtitle: text(raw.subtitle, 240),
    authors,
    publisher: text(raw.publisher, 240),
    publicationPlace: text(raw.publicationPlace, 120),
    publicationDate: text(raw.publicationDate, 60),
    edition: text(raw.edition, 120),
    pageCount: text(raw.pageCount, 60),
    illustrations: text(raw.illustrations, 120),
    dimensions: text(raw.dimensions, 60),
    collection: text(raw.collection, 240),
    collectionNumber: text(raw.collectionNumber, 60),
    language: text(raw.language, 60),
    originalLanguage: text(raw.originalLanguage, 60),
    summary: text(raw.summary, 4000),
    subjects: (Array.isArray(raw.subjects) ? raw.subjects : [])
      .map((subject) => text(subject, 240))
      .filter(Boolean),
    classification: text(raw.classification, 60),
    isbn: text(raw.isbn, 32),
    sourceNotice: text(raw.sourceNotice, 60),
    sourceIdentifier: text(raw.sourceIdentifier, 120),
    retrievedAt: raw.retrievedAt || new Date().toISOString(),
  };
}

/** Année sur quatre chiffres : la colonne `publication_year` ne stocke que ça. */
export function publicationYear(value) {
  const match = /(1[0-9]{3}|20[0-9]{2})/.exec(String(value ?? ""));
  return match ? match[1] : "";
}

/** Champs du livre tels que la base desktop les attend. */
export function noticeToBookFields(notice, { isbn = "" } = {}) {
  const value = normalizeNotice(notice);
  return {
    title: value.title,
    subtitle: value.subtitle,
    author: value.authors
      .filter((author) => author.role === "auteur")
      .map((author) => author.name)
      .join("; "),
    isbn: isbn || value.isbn,
    publisher: value.publisher,
    publication_year: publicationYear(value.publicationDate),
    collection: value.collection,
    collection_number: value.collectionNumber,
    language: value.language,
    original_language: value.originalLanguage,
    summary: value.summary,
    subjects: value.subjects.join("; "),
    dewey: value.classification,
    edition: value.edition,
    page_count: value.pageCount,
    source_notice: value.sourceNotice,
    source_identifier: value.sourceIdentifier,
    retrieved_at: value.retrievedAt,
  };
}

export class NoticeSourceUnavailableError extends Error {}
export class NoticeNotFoundError extends Error {}
export class NoticeNetworkError extends Error {}
