/**
 * Sources bibliographiques : BnF SRU, SUDOC, Open Library, Google Books.
 * Port des sources mobiles (`lib/services/notice/*.dart`), avec en plus la
 * recherche par titre/auteur dont l'OCR a besoin quand aucun ISBN n'est lisible.
 *
 * Chaque source lève `NoticeSourceUnavailableError` lorsqu'elle est injoignable
 * et rend un tableau vide lorsqu'elle répond mais ne connaît pas le document :
 * l'orchestrateur distingue « rien trouvé » de « réseau coupé ».
 */
import { toIsbn10 } from "./isbn.js";
import { NoticeSourceUnavailableError, normalizeNotice } from "./notice.js";
import { parseUnimarcNotices } from "./unimarc.js";

const MIN_HOST_INTERVAL_MS = 300;
const hostSchedule = new Map();

/** Deux requêtes vers un même hôte restent espacées de 300 ms. */
async function throttle(host) {
  const now = Date.now();
  const earliest = Math.max(now, hostSchedule.get(host) || 0);
  hostSchedule.set(host, earliest + MIN_HOST_INTERVAL_MS);
  const wait = earliest - now;
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
}

export function clearSourceThrottle() {
  hostSchedule.clear();
}

class HttpSource {
  constructor({ fetchImpl, timeoutMs = 5000 } = {}) {
    this.fetchImpl = fetchImpl || ((...args) => fetch(...args));
    this.timeoutMs = timeoutMs;
  }

  async request(url, { accept = "application/json" } = {}) {
    const target = new URL(url);
    await throttle(target.host);
    let response;
    try {
      response = await this.fetchImpl(target.toString(), {
        headers: { Accept: accept, "User-Agent": "BiblioRFID/catalogage" },
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      throw new NoticeSourceUnavailableError(
        `${this.name} injoignable : ${error.message}`,
      );
    }
    return response;
  }

  async requestText(url, options) {
    const response = await this.request(url, options);
    if (response.status === 404) return null;
    // 429 : quota public épuisé (fréquent sur Google Books sans clé).
    if (response.status === 429)
      throw new NoticeSourceUnavailableError(
        `${this.name} : quota de requêtes atteint, réessayez plus tard.`,
      );
    if (!response.ok)
      throw new NoticeSourceUnavailableError(
        `${this.name} indisponible (erreur HTTP ${response.status}).`,
      );
    return response.text();
  }

  async requestJson(url) {
    const body = await this.requestText(url);
    if (body === null) return null;
    try {
      return JSON.parse(body);
    } catch {
      throw new NoticeSourceUnavailableError(
        `${this.name} a renvoyé une réponse illisible.`,
      );
    }
  }
}

export class BnfSource extends HttpSource {
  name = "BnF";

  sruUrl(query) {
    const url = new URL("https://catalogue.bnf.fr/api/SRU");
    url.searchParams.set("version", "1.2");
    url.searchParams.set("operation", "searchRetrieve");
    url.searchParams.set("query", query);
    url.searchParams.set("recordSchema", "unimarcxchange");
    url.searchParams.set("maximumRecords", "5");
    return url.toString();
  }

  async lookupIsbn(isbn13) {
    // Vérifié côté mobile : la forme ISBN-13 renvoie numberOfRecords=0,
    // l'ISBN-10 avec `adj` renvoie la notice.
    const isbn10 = toIsbn10(isbn13);
    if (!isbn10) return [];
    return this.notices(this.sruUrl(`bib.isbn adj "${isbn10}"`));
  }

  async searchText({ title = "", author = "" }) {
    const clauses = [];
    if (title) clauses.push(`bib.title all "${escapeCql(title)}"`);
    if (author) clauses.push(`bib.author all "${escapeCql(author)}"`);
    if (!clauses.length) return [];
    return this.notices(this.sruUrl(clauses.join(" and ")));
  }

  async notices(url) {
    const xml = await this.requestText(url, { accept: "application/xml" });
    if (!xml) return [];
    return parseUnimarcNotices(xml, { sourceNotice: this.name });
  }
}

export class SudocSource extends HttpSource {
  name = "SUDOC";

  async lookupIsbn(isbn13) {
    const xml = await this.requestText(
      `https://www.sudoc.fr/services/isbn2ppn/${encodeURIComponent(isbn13)}`,
      { accept: "application/xml" },
    );
    if (!xml) return [];
    const ppns = parsePpns(xml);
    const notices = [];
    for (const ppn of ppns.slice(0, 3)) {
      const record = await this.requestText(
        `https://www.sudoc.fr/${encodeURIComponent(ppn)}.xml`,
        { accept: "application/xml" },
      );
      if (!record) continue;
      for (const notice of parseUnimarcNotices(record, {
        sourceNotice: this.name,
      }))
        notices.push(
          notice.sourceIdentifier
            ? notice
            : { ...notice, sourceIdentifier: ppn },
        );
    }
    return notices;
  }

  /** Le SUDOC n'expose pas de recherche titre/auteur publique exploitable ici. */
  async searchText() {
    return [];
  }
}

export class OpenLibrarySource extends HttpSource {
  name = "Open Library";

  async lookupIsbn(isbn13) {
    const payload = await this.requestJson(
      `https://openlibrary.org/isbn/${encodeURIComponent(isbn13)}.json`,
    );
    if (!payload) return [];
    const title = String(payload.title || "").trim();
    if (!title) return [];
    return [
      normalizeNotice({
        title,
        subtitle: payload.subtitle,
        authors: (payload.authors || [])
          .map((author) => author?.name)
          .filter(Boolean),
        publisher: (payload.publishers || [])[0],
        publicationDate: payload.publish_date,
        pageCount: payload.number_of_pages,
        isbn: isbn13,
        sourceNotice: this.name,
        sourceIdentifier: payload.key,
      }),
    ];
  }

  async searchText({ title = "", author = "" }) {
    if (!title && !author) return [];
    const url = new URL("https://openlibrary.org/search.json");
    if (title) url.searchParams.set("title", title);
    if (author) url.searchParams.set("author", author);
    url.searchParams.set("limit", "5");
    url.searchParams.set(
      "fields",
      "key,title,subtitle,author_name,publisher,first_publish_year,number_of_pages_median,isbn",
    );
    const payload = await this.requestJson(url.toString());
    return (payload?.docs || [])
      .map((doc) =>
        normalizeNotice({
          title: doc.title,
          subtitle: doc.subtitle,
          authors: doc.author_name || [],
          publisher: (doc.publisher || [])[0],
          publicationDate: doc.first_publish_year,
          pageCount: doc.number_of_pages_median,
          isbn: (doc.isbn || [])[0],
          sourceNotice: this.name,
          sourceIdentifier: doc.key,
        }),
      )
      .filter((notice) => notice.title);
  }
}

export class GoogleBooksSource extends HttpSource {
  name = "Google Books";

  async volumes(query) {
    const url = new URL("https://www.googleapis.com/books/v1/volumes");
    url.searchParams.set("q", query);
    url.searchParams.set("maxResults", "5");
    const payload = await this.requestJson(url.toString());
    return (payload?.items || [])
      .map((item) => {
        const volume = item?.volumeInfo || {};
        const identifiers = volume.industryIdentifiers || [];
        return normalizeNotice({
          title: volume.title,
          subtitle: volume.subtitle,
          authors: volume.authors || [],
          publisher: volume.publisher,
          publicationDate: volume.publishedDate,
          summary: volume.description,
          pageCount: volume.pageCount,
          subjects: volume.categories || [],
          language: volume.language,
          isbn: (
            identifiers.find((entry) => entry.type === "ISBN_13") ||
            identifiers[0] ||
            {}
          ).identifier,
          sourceNotice: this.name,
          sourceIdentifier: item?.id,
        });
      })
      .filter((notice) => notice.title);
  }

  async lookupIsbn(isbn13) {
    return this.volumes(`isbn:${isbn13}`);
  }

  async searchText({ title = "", author = "" }) {
    const parts = [];
    if (title) parts.push(`intitle:"${title.replace(/"/g, " ")}"`);
    if (author) parts.push(`inauthor:"${author.replace(/"/g, " ")}"`);
    if (!parts.length) return [];
    return this.volumes(parts.join(" "));
  }
}

function escapeCql(value) {
  return String(value).replace(/["\\]/g, " ").trim();
}

/** `<error>` du SUDOC = ISBN inconnu, pas une panne. */
function parsePpns(xmlText) {
  if (/<\s*error\b/i.test(xmlText)) return [];
  return [...String(xmlText).matchAll(/<\s*ppn[^>]*>([^<]+)<\s*\/\s*ppn\s*>/gi)]
    .map((match) => match[1].trim())
    .filter(Boolean);
}

export function createDefaultSources(options = {}) {
  return [
    new BnfSource(options),
    new SudocSource(options),
    new OpenLibrarySource(options),
    new GoogleBooksSource(options),
  ];
}
