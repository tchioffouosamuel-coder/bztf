/**
 * Chaîne de catalogage : photo → OCR → indices → notice → (IA) → fiche.
 *
 * Deux usages :
 *  - unitaire : un livre sur le lecteur, la fiche validée puis le tag encodé
 *    immédiatement par la station existante ;
 *  - en lot : un lot de livres photographiés à la chaîne, enregistrés en
 *    brouillons « à encoder ». Aucune écriture de tag n'est possible en lot :
 *    l'encodage suppose un tag posé seul sur le lecteur, livre par livre.
 *
 * L'IA et l'OCR sont facultatifs. Sans eux, la recherche par ISBN ou par
 * titre/auteur reste disponible, et le catalogage manuel n'est pas modifié.
 */
import fs from "node:fs";
import path from "node:path";

import {
  AiCataloguingService,
  AiUnavailableError,
  AI_ROLES,
  DEFAULT_AI_MODELS,
  normalizeAiProvider,
  normalizeAiRoles,
  serializeAiRoles,
} from "./ai.js";
import { extractHints } from "./extract.js";
import { NoticeLookupService } from "./lookup.js";
import { noticeToBookFields } from "./notice.js";
import { OcrService, normalizeOcrEngine, normalizeOcrLanguages } from "./ocr.js";
import { captureImageUrl, CaptureStore } from "./store.js";

const BOOK_FIELD_NAMES = [
  "title",
  "subtitle",
  "author",
  "isbn",
  "publisher",
  "publication_year",
  "collection",
  "collection_number",
  "language",
  "original_language",
  "summary",
  "subjects",
  "dewey",
  "edition",
  "page_count",
  "document_type",
  "category",
  "shelf",
  "notes",
  "source_notice",
  "source_identifier",
  "retrieved_at",
];

/** En dessous, l'OCR n'a rien donné d'exploitable : la vision IA peut aider. */
const OCR_TEXT_FLOOR = 40;

export const DEFAULT_COTE_PREFIXES = {
  Roman: "R",
  Documentaire: "D",
  Jeunesse: "J",
  "Bande dessinée": "BD",
  Périodique: "P",
  Référence: "REF",
};

function emptyFields() {
  return Object.fromEntries(BOOK_FIELD_NAMES.map((field) => [field, ""]));
}

/** Ne remplit que les champs encore vides : une saisie humaine prime. */
export function mergeFields(base, extra = {}) {
  const merged = { ...base };
  for (const [field, value] of Object.entries(extra)) {
    if (!BOOK_FIELD_NAMES.includes(field)) continue;
    const text = String(value ?? "").trim();
    if (!text) continue;
    if (!String(merged[field] ?? "").trim()) merged[field] = text;
  }
  return merged;
}

export class CataloguingService {
  constructor(database, { dataRoot, fetchImpl, ocrService, aiService } = {}) {
    this.database = database;
    this.coversRoot = path.join(dataRoot, "covers");
    fs.mkdirSync(this.coversRoot, { recursive: true });
    this.store = new CaptureStore(this.coversRoot);
    this.fetchImpl = fetchImpl;
    this.ocr = ocrService || new OcrService({ fetchImpl });
    this.ai = aiService || new AiCataloguingService({ fetchImpl });
    this.lookup = new NoticeLookupService({
      fetchImpl,
      localLookup: (isbn13) => this.database.findBooksByIsbn(isbn13),
      cache: {
        read: (isbn13) => this.database.readNoticeCache(isbn13),
        write: (isbn13, notices) => this.database.writeNoticeCache(isbn13, notices),
      },
    });
    this.reload();
  }

  reload() {
    const get = (key, fallback = "") => this.database.getSetting(key, fallback);
    this.ocrEnabled = get("cataloguing_ocr_enabled", "1") !== "0";
    this.aiEnabled = get("cataloguing_ai_enabled", "0") === "1";
    this.ocr.configure({
      engine: normalizeOcrEngine(get("cataloguing_ocr_engine", "tesseract")),
      languages: normalizeOcrLanguages(get("cataloguing_ocr_languages", "fra+eng")),
      visionApiKey: get("cataloguing_vision_api_key", ""),
    });
    this.ai.configure({
      provider: normalizeAiProvider(get("cataloguing_ai_provider", "claude")),
      apiKey: this.aiEnabled ? get("cataloguing_ai_key", "") : "",
      model: get("cataloguing_ai_model", ""),
      roles: normalizeAiRoles(get("cataloguing_ai_roles", "")),
    });
    return this.settings();
  }

  settings() {
    return {
      ocr: {
        enabled: this.ocrEnabled,
        engine: this.ocr.engine,
        languages: this.ocr.languages,
        available: this.ocrEnabled && this.ocr.available,
        unavailableReason: this.ocrEnabled ? this.ocr.unavailableReason : "",
        visionKeySet: Boolean(this.database.getSetting("cataloguing_vision_api_key", "")),
      },
      ai: {
        enabled: this.aiEnabled,
        ...this.ai.status,
        keySet: Boolean(this.database.getSetting("cataloguing_ai_key", "")),
        defaultModels: DEFAULT_AI_MODELS,
        roleNames: AI_ROLES,
      },
      cotePrefixes: this.cotePrefixes(),
    };
  }

  cotePrefixes() {
    try {
      const stored = JSON.parse(
        this.database.getSetting("cataloguing_cote_prefixes", "") || "null",
      );
      if (stored && typeof stored === "object") return stored;
    } catch {
      // Préférences illisibles : on repart des préfixes par défaut.
    }
    return DEFAULT_COTE_PREFIXES;
  }

  updateSettings(input = {}) {
    const values = {};
    if ("ocrEnabled" in input)
      values.cataloguing_ocr_enabled = input.ocrEnabled ? "1" : "0";
    if ("ocrEngine" in input)
      values.cataloguing_ocr_engine = normalizeOcrEngine(input.ocrEngine);
    if ("ocrLanguages" in input)
      values.cataloguing_ocr_languages = normalizeOcrLanguages(input.ocrLanguages);
    if ("visionApiKey" in input)
      values.cataloguing_vision_api_key = String(input.visionApiKey || "").trim();
    if ("aiEnabled" in input)
      values.cataloguing_ai_enabled = input.aiEnabled ? "1" : "0";
    if ("aiProvider" in input)
      values.cataloguing_ai_provider = normalizeAiProvider(input.aiProvider);
    if ("aiModel" in input)
      values.cataloguing_ai_model = String(input.aiModel || "").trim().slice(0, 120);
    if ("aiKey" in input)
      values.cataloguing_ai_key = String(input.aiKey || "").trim();
    if ("aiRoles" in input)
      values.cataloguing_ai_roles = serializeAiRoles(normalizeAiRoles(input.aiRoles));
    if ("cotePrefixes" in input) {
      const serialized = JSON.stringify(input.cotePrefixes || {});
      if (serialized.length > 480)
        throw new Error("La liste des préfixes de cote est trop longue.");
      values.cataloguing_cote_prefixes = serialized;
    }
    if (Object.keys(values).length) this.database.setSettings(values);
    return this.reload();
  }

  // --- Captures et OCR -----------------------------------------------------

  addCapture({ buffer, thumbBuffer, contentType, kind = "front", source = "webcam", itemId = null }) {
    const stored = this.store.save({ buffer, thumbBuffer, contentType });
    return this.database.createCapture({
      uuid: stored.uuid,
      kind,
      path: stored.relativePath,
      thumbPath: stored.thumbRelativePath,
      bytes: stored.bytes,
      source,
      itemId,
    });
  }

  removeCapture(id) {
    const capture = this.database.deleteCapture(id);
    if (!capture) return false;
    this.store.remove(capture.path);
    if (capture.thumb_path) this.store.remove(capture.thumb_path);
    return true;
  }

  /** Supprime les captures abandonnées (fenêtre fermée avant validation). */
  purgeStaleCaptures(hours = 24) {
    let removed = 0;
    for (const capture of this.database.staleCaptures(hours)) {
      this.store.remove(capture.path);
      if (capture.thumb_path) this.store.remove(capture.thumb_path);
      this.database.deleteCapture(capture.id);
      removed += 1;
    }
    return removed;
  }

  async ocrCapture(id) {
    const capture = this.database.getCapture(id);
    if (!capture) throw new Error("Capture introuvable.");
    if (!this.ocrEnabled) throw new Error("L’OCR est désactivé dans les paramètres.");
    const buffer = this.store.read(capture.path);
    if (!buffer) throw new Error("Le fichier image est introuvable sur le poste.");
    const result = await this.ocr.recognize(buffer);
    return {
      capture: this.database.saveCaptureOcr(capture.id, {
        text: result.text,
        engine: result.engine,
        confidence: result.confidence,
      }),
      ...result,
    };
  }

  /** Texte OCR regroupé par face, tel que les extracteurs l'attendent. */
  textsFromCaptures(captures = []) {
    const texts = { front: "", back: "", other: "" };
    for (const capture of captures) {
      const text = String(capture.ocr_text || "").trim();
      if (!text) continue;
      if (capture.kind === "front") texts.front = [texts.front, text].filter(Boolean).join("\n");
      else if (capture.kind === "back") texts.back = [texts.back, text].filter(Boolean).join("\n");
      else texts.other = [texts.other, text].filter(Boolean).join("\n");
    }
    return texts;
  }

  hintsFromTexts(texts) {
    return extractHints(texts);
  }

  // --- Recherche de notices ------------------------------------------------

  async search({ isbn = "", title = "", author = "", collectAll = null }) {
    const wantsAll = collectAll === null ? this.ai.roleEnabled("arbitrate") : collectAll;
    if (String(isbn || "").trim())
      return this.lookup.lookupByIsbn(isbn, { collectAll: wantsAll });
    return this.lookup.searchByText({ title, author });
  }

  /**
   * Identification complète d'un exemplaire à partir de ses captures.
   * Chaque étape IA est facultative et sans effet de bord en cas d'échec.
   */
  async identify({ captures = [], isbn = "", title = "", author = "" }) {
    const texts = this.textsFromCaptures(captures);
    const combined = [texts.front, texts.back, texts.other].filter(Boolean).join("\n");
    const ai = { used: [], warnings: [], notes: "" };
    let hints = this.hintsFromTexts(texts);

    // Vision : l'OCR n'a presque rien rendu, les photos parlent mieux.
    if (
      combined.trim().length < OCR_TEXT_FLOOR &&
      captures.length &&
      this.ai.roleEnabled("vision")
    ) {
      try {
        const read = await this.ai.readImages({
          images: this.imagesFor(captures),
          hints,
        });
        hints = {
          ...hints,
          title: hints.title || read.fields.title,
          author: hints.author || read.fields.author,
          publisher: hints.publisher || read.fields.publisher,
          publicationYear: hints.publicationYear || read.fields.publication_year,
          isbns: hints.isbns.length
            ? hints.isbns
            : [read.fields.isbn].filter(Boolean),
        };
        ai.used.push("vision");
        ai.vision = read;
      } catch (error) {
        ai.warnings.push(this.aiWarning("vision", error));
      }
    }

    let fields = emptyFields();

    if (this.ai.roleEnabled("structure") && combined.trim().length >= OCR_TEXT_FLOOR) {
      try {
        const structured = await this.ai.structureFromOcr({
          frontText: texts.front,
          backText: texts.back,
          otherText: texts.other,
          hints,
        });
        fields = mergeFields(fields, structured.fields);
        ai.used.push("structure");
        ai.structure = { confidence: structured.confidence, notes: structured.notes };
      } catch (error) {
        ai.warnings.push(this.aiWarning("structure", error));
      }
    }

    // Les indices OCR complètent ce que l'IA n'a pas rempli.
    fields = mergeFields(fields, {
      title: hints.title,
      author: hints.author,
      publisher: hints.publisher,
      publication_year: hints.publicationYear,
      collection: hints.collection,
      summary: hints.summary,
    });

    const searchIsbn =
      String(isbn || "").trim() || fields.isbn || hints.isbns[0] || "";
    let result = { alreadyCatalogued: false, books: [], notices: [], unavailableSources: [] };
    let searchError = "";
    try {
      result = await this.search({
        isbn: searchIsbn,
        title: title || fields.title,
        author: author || fields.author,
      });
    } catch (error) {
      searchError = error.message;
    }

    if (result.alreadyCatalogued)
      return {
        alreadyCatalogued: true,
        books: result.books,
        notices: [],
        selected: null,
        fields,
        hints,
        ai,
        isbn: result.isbn13 || searchIsbn,
        searchError: "",
      };

    const notices = result.notices || [];
    let selectedIndex = notices.length ? 0 : -1;

    if (notices.length > 1 && this.ai.roleEnabled("arbitrate")) {
      try {
        const verdict = await this.ai.arbitrate({
          candidates: notices,
          ocrText: combined,
          hints,
        });
        if (verdict.index >= 0) selectedIndex = verdict.index;
        ai.used.push("arbitrate");
        ai.arbitrate = verdict;
      } catch (error) {
        ai.warnings.push(this.aiWarning("arbitrate", error));
      }
    }

    if (selectedIndex >= 0) {
      const notice = notices[selectedIndex];
      // La notice d'une source bibliographique prime sur la lecture OCR.
      fields = mergeFields(
        noticeToBookFields(notice, { isbn: searchIsbn || notice.isbn }),
        fields,
      );
    }

    if (this.ai.roleEnabled("complete")) {
      try {
        const completion = await this.ai.complete({
          fields,
          prefixes: this.cotePrefixes(),
        });
        fields = mergeFields(fields, completion);
        ai.used.push("complete");
        ai.complete = completion;
      } catch (error) {
        ai.warnings.push(this.aiWarning("complete", error));
      }
    }

    if (this.ai.roleEnabled("quality")) {
      try {
        const review = await this.ai.quality({ fields });
        ai.used.push("quality");
        ai.quality = review;
      } catch (error) {
        ai.warnings.push(this.aiWarning("quality", error));
      }
    }

    return {
      alreadyCatalogued: false,
      books: [],
      notices,
      selected: selectedIndex,
      fields: { ...fields, isbn: fields.isbn || searchIsbn },
      hints,
      ai,
      isbn: searchIsbn,
      searchError,
      unavailableSources: result.unavailableSources || [],
    };
  }

  imagesFor(captures = []) {
    const images = [];
    for (const capture of captures.slice(0, 4)) {
      // La vignette suffit au modèle et coûte beaucoup moins de jetons.
      const buffer =
        this.store.read(capture.thumb_path || capture.path) ||
        this.store.read(capture.path);
      if (!buffer) continue;
      images.push({
        kind: capture.kind,
        base64: buffer.toString("base64"),
        mediaType: capture.path.endsWith(".png")
          ? "image/png"
          : capture.path.endsWith(".webp")
            ? "image/webp"
            : "image/jpeg",
      });
    }
    return images;
  }

  aiWarning(role, error) {
    const message =
      error instanceof AiUnavailableError
        ? error.message
        : `Le rôle « ${role} » de l’IA a échoué : ${error.message}`;
    return { role, message };
  }

  // --- Enregistrement ------------------------------------------------------

  /**
   * Crée la fiche et y rattache les photos.
   * `draft` laisse la fiche en brouillon : c'est le cas du catalogage en lot,
   * où l'encodage du tag reste à faire livre par livre à la station.
   */
  commit({ fields = {}, captureIds = [], draft = false, itemId = null }) {
    const payload = Object.fromEntries(
      BOOK_FIELD_NAMES.filter((field) => field in fields).map((field) => [
        field,
        fields[field],
      ]),
    );
    const book = this.database.createBook({ ...payload, catalog_draft: draft });
    if (captureIds.length)
      this.database.attachCaptures(captureIds, { bookId: book.id, itemId });
    return this.database.getBook(book.id);
  }

  coversFor(bookId) {
    return this.database.capturesForBook(bookId).map((capture) => ({
      id: capture.id,
      kind: capture.kind,
      url: captureImageUrl(capture),
      thumbUrl: captureImageUrl(capture, { thumb: true }),
      ocrEngine: capture.ocr_engine,
      ocrConfidence: capture.ocr_confidence,
    }));
  }

  captureImage(id, { thumb = false } = {}) {
    const capture = this.database.getCapture(id);
    if (!capture) return null;
    const relativePath = thumb && capture.thumb_path ? capture.thumb_path : capture.path;
    const buffer = this.store.read(relativePath);
    return buffer ? { buffer, relativePath } : null;
  }

  // --- Catalogage en lot ---------------------------------------------------

  /**
   * Déroule la chaîne complète pour un livre du lot : OCR des photos non
   * encore reconnues, extraction, recherche, IA, puis mémorisation du résultat.
   * Le lot n'écrit jamais de tag : les fiches partent en brouillon.
   */
  async processItem(itemId) {
    const item = this.database.getCatalogItem(itemId);
    if (!item) throw new Error("Livre du lot introuvable.");
    if (!item.captures.length)
      return this.database.updateCatalogItem(itemId, {
        status: "echec",
        message: "Aucune photo n’a été prise pour ce livre.",
      });

    this.database.updateCatalogItem(itemId, { status: "ocr", message: "" });
    if (this.ocrEnabled && this.ocr.available) {
      for (const capture of item.captures) {
        if (capture.ocr_at) continue;
        try {
          await this.ocrCapture(capture.id);
        } catch (error) {
          this.database.updateCatalogItem(itemId, {
            message: `OCR partiel : ${error.message}`,
          });
        }
      }
    }

    const captures = this.database.capturesForItem(itemId);
    this.database.updateCatalogItem(itemId, { status: "recherche" });
    let identification;
    try {
      identification = await this.identify({ captures });
    } catch (error) {
      return this.database.updateCatalogItem(itemId, {
        status: "echec",
        message: error.message,
      });
    }

    const texts = this.textsFromCaptures(captures);
    return this.database.updateCatalogItem(itemId, {
      status: identification.fields.title ? "pret" : "echec",
      ocr_text: [texts.front, texts.back, texts.other].filter(Boolean).join("\n\n"),
      hints: identification.hints,
      candidates: identification.notices,
      fields: identification.fields,
      ai: identification.ai,
      message: identification.fields.title
        ? identification.searchError || ""
        : identification.searchError ||
          "Aucun titre n’a pu être identifié : complétez la fiche à la main.",
    });
  }

  /** Enregistre en brouillons tous les livres prêts du lot. */
  commitSession(sessionId) {
    const session = this.database.getCatalogSession(sessionId);
    if (!session) throw new Error("Lot introuvable.");
    const saved = [];
    const skipped = [];
    for (const item of session.items) {
      if (item.status === "enregistre") continue;
      if (item.status !== "pret" || !item.fields?.title) {
        skipped.push({ id: item.id, position: item.position, reason: item.message || "Fiche incomplète." });
        continue;
      }
      const book = this.commit({
        fields: item.fields,
        captureIds: item.captures.map((capture) => capture.id),
        draft: true,
        itemId: item.id,
      });
      this.database.updateCatalogItem(item.id, {
        status: "enregistre",
        book_id: book.id,
        message: "",
      });
      saved.push({ id: item.id, bookId: book.id, accession: book.accession, title: book.title });
    }
    return { session: this.database.getCatalogSession(sessionId), saved, skipped };
  }

  async close() {
    await this.ocr.close();
  }
}
