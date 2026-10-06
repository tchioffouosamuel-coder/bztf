/**
 * Orchestration de la recherche de notices.
 * Port de `NoticeLookupService` (mobile) : catalogue local d'abord, puis cache,
 * puis les sources dans l'ordre jusqu'à la première réponse utile.
 *
 * Ajouts desktop : recherche par titre/auteur pour les livres sans ISBN lisible,
 * et mode « toutes les sources » quand l'arbitrage IA a besoin de candidats
 * concurrents.
 */
import { toIsbn13 } from "./isbn.js";
import {
  NoticeNetworkError,
  NoticeNotFoundError,
  normalizeNotice,
} from "./notice.js";
import { createDefaultSources } from "./sources.js";

const SOURCE_TIMEOUT_MS = 5000;

function candidateKey(notice) {
  const author = notice.authors[0]?.name || "";
  return `${notice.title}|${author}`
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function dedupe(notices) {
  const seen = new Map();
  for (const notice of notices) {
    const key = candidateKey(notice);
    if (!key) continue;
    const existing = seen.get(key);
    // À titre et auteur identiques, on garde la notice la plus complète.
    if (!existing || completeness(notice) > completeness(existing))
      seen.set(key, notice);
  }
  return [...seen.values()];
}

function completeness(notice) {
  return [
    notice.publisher,
    notice.publicationDate,
    notice.summary,
    notice.classification,
    notice.subjects.length ? "x" : "",
    notice.pageCount,
    notice.collection,
  ].filter(Boolean).length;
}

export class NoticeLookupService {
  constructor({
    sources,
    cache = null,
    localLookup = null,
    timeoutPerSource = SOURCE_TIMEOUT_MS,
    fetchImpl,
  } = {}) {
    this.sources =
      sources || createDefaultSources({ fetchImpl, timeoutMs: timeoutPerSource });
    this.cache = cache;
    this.localLookup = localLookup;
    this.timeoutPerSource = timeoutPerSource;
  }

  /**
   * @returns {{ alreadyCatalogued: boolean, books: object[], notices: object[],
   *   unavailableSources: string[] }}
   */
  async lookupByIsbn(isbn, { collectAll = false, skipLocal = false } = {}) {
    const isbn13 = toIsbn13(isbn);

    if (!skipLocal && this.localLookup) {
      const books = await this.localLookup(isbn13);
      if (books.length)
        return {
          isbn13,
          alreadyCatalogued: true,
          books,
          notices: [],
          unavailableSources: [],
        };
    }

    const cached = this.cache ? await this.cache.read(isbn13) : [];
    if (cached?.length)
      return {
        isbn13,
        alreadyCatalogued: false,
        books: [],
        notices: cached.map(normalizeNotice),
        unavailableSources: [],
        fromCache: true,
      };

    const unavailable = [];
    const collected = [];
    for (const source of this.sources) {
      let notices = [];
      try {
        notices = await source.lookupIsbn(isbn13);
      } catch (error) {
        unavailable.push(source.name);
        continue;
      }
      const usable = notices
        .map((notice) =>
          normalizeNotice({
            ...notice,
            isbn: notice.isbn || isbn13,
            sourceNotice: notice.sourceNotice || source.name,
          }),
        )
        .filter((notice) => notice.title);
      if (!usable.length) continue;
      collected.push(...usable);
      if (!collectAll) break;
    }

    const notices = dedupe(collected);
    if (notices.length) {
      if (this.cache) await this.cache.write(isbn13, notices);
      return {
        isbn13,
        alreadyCatalogued: false,
        books: [],
        notices,
        unavailableSources: unavailable,
      };
    }

    if (this.sources.length && unavailable.length === this.sources.length)
      throw new NoticeNetworkError(
        "Aucune source bibliographique n’est joignable.",
      );
    throw new NoticeNotFoundError(
      "Aucune notice bibliographique trouvée pour cet ISBN.",
    );
  }

  /** Recherche par titre/auteur : toutes les sources, candidats fusionnés. */
  async searchByText({ title = "", author = "" } = {}) {
    const cleanTitle = String(title || "").trim();
    const cleanAuthor = String(author || "").trim();
    if (cleanTitle.length < 3 && cleanAuthor.length < 3)
      throw new NoticeNotFoundError(
        "Indiquez au moins trois caractères de titre ou d’auteur.",
      );

    const unavailable = [];
    const collected = [];
    const results = await Promise.all(
      this.sources.map(async (source) => {
        try {
          return await source.searchText({
            title: cleanTitle,
            author: cleanAuthor,
          });
        } catch {
          unavailable.push(source.name);
          return [];
        }
      }),
    );
    for (const [index, notices] of results.entries()) {
      const source = this.sources[index];
      for (const notice of notices) {
        const usable = normalizeNotice({
          ...notice,
          sourceNotice: notice.sourceNotice || source.name,
        });
        if (usable.title) collected.push(usable);
      }
    }

    const notices = dedupe(collected);
    if (!notices.length && unavailable.length === this.sources.length)
      throw new NoticeNetworkError(
        "Aucune source bibliographique n’est joignable.",
      );
    return {
      alreadyCatalogued: false,
      books: [],
      notices,
      unavailableSources: unavailable,
    };
  }
}
