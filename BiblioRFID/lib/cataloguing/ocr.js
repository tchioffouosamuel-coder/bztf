/**
 * OCR des photos de couverture.
 *
 * Deux moteurs, choisis dans Paramètres :
 *  - `tesseract` : tesseract.js (WebAssembly) embarqué, données de langue dans
 *    `vendor/tessdata`. Fonctionne sans Internet et sans installation.
 *  - `google_vision` : API Cloud Vision, plus précise sur les couvertures
 *    stylisées, nécessite une clé et une connexion.
 *
 * Les reconnaissances sont sérialisées : un seul moteur travaille à la fois,
 * ce qui garde la station RFID réactive pendant un catalogage en lot.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const OCR_ENGINES = ["tesseract", "google_vision"];
export const DEFAULT_OCR_LANGUAGES = "fra+eng";

const moduleRoot = path.dirname(fileURLToPath(import.meta.url));
const WORKER_IDLE_MS = 120_000;
const VISION_MAX_BYTES = 10 * 1024 * 1024;

/** `vendor/tessdata` reste lisible hors de l'archive asar de l'application. */
export function defaultTessdataPath() {
  const packaged = path.resolve(moduleRoot, "..", "..", "vendor", "tessdata");
  return packaged.includes(`${path.sep}app.asar${path.sep}`)
    ? packaged.replace(`${path.sep}app.asar${path.sep}`, `${path.sep}app.asar.unpacked${path.sep}`)
    : packaged;
}

export function normalizeOcrEngine(value) {
  const engine = String(value || "").trim();
  return OCR_ENGINES.includes(engine) ? engine : "tesseract";
}

export function normalizeOcrLanguages(value) {
  const languages = String(value || "")
    .split(/[+,\s]+/)
    .map((language) => language.trim().toLowerCase())
    .filter((language) => /^[a-z]{3}$/.test(language));
  return languages.length ? [...new Set(languages)].join("+") : DEFAULT_OCR_LANGUAGES;
}

function visionLanguageHints(languages) {
  const map = { fra: "fr", eng: "en", spa: "es", deu: "de", ita: "it", por: "pt", ara: "ar" };
  return normalizeOcrLanguages(languages)
    .split("+")
    .map((language) => map[language] || language.slice(0, 2));
}

export class OcrError extends Error {}

export class OcrService {
  constructor({
    engine = "tesseract",
    visionApiKey = "",
    languages = DEFAULT_OCR_LANGUAGES,
    tessdataPath = defaultTessdataPath(),
    fetchImpl,
    createWorkerImpl,
  } = {}) {
    this.configure({ engine, visionApiKey, languages });
    this.tessdataPath = tessdataPath;
    this.fetchImpl = fetchImpl || ((...args) => fetch(...args));
    this.createWorkerImpl = createWorkerImpl || null;
    this.worker = null;
    this.workerLanguages = "";
    this.workerIdleTimer = null;
    this.queue = Promise.resolve();
  }

  configure({ engine, visionApiKey, languages }) {
    if (engine !== undefined) this.engine = normalizeOcrEngine(engine);
    if (visionApiKey !== undefined) this.visionApiKey = String(visionApiKey || "").trim();
    if (languages !== undefined) {
      const normalized = normalizeOcrLanguages(languages);
      if (normalized !== this.languages) this.releaseWorker();
      this.languages = normalized;
    }
  }

  get available() {
    if (this.engine === "google_vision") return Boolean(this.visionApiKey);
    return fs.existsSync(this.tessdataPath);
  }

  /** Raison lisible d'une indisponibilité, pour l'afficher dans Paramètres. */
  get unavailableReason() {
    if (this.available) return "";
    return this.engine === "google_vision"
      ? "La clé API Google Vision n’est pas renseignée."
      : "Les données de langue Tesseract sont introuvables.";
  }

  /**
   * @param {Buffer} image
   * @returns {Promise<{ text: string, engine: string, confidence: number,
   *   durationMs: number, languages: string }>}
   */
  async recognize(image) {
    if (!Buffer.isBuffer(image) || !image.length)
      throw new OcrError("Aucune image à analyser.");
    if (!this.available) throw new OcrError(this.unavailableReason);
    const run = this.queue.then(
      () => this.recognizeNow(image),
      () => this.recognizeNow(image),
    );
    this.queue = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  async recognizeNow(image) {
    const startedAt = Date.now();
    const result =
      this.engine === "google_vision"
        ? await this.recognizeWithVision(image)
        : await this.recognizeWithTesseract(image);
    return {
      ...result,
      engine: this.engine,
      languages: this.languages,
      durationMs: Date.now() - startedAt,
    };
  }

  async ensureWorker() {
    if (this.worker && this.workerLanguages === this.languages) return this.worker;
    this.releaseWorker();
    const createWorker =
      this.createWorkerImpl ||
      (await import("tesseract.js").then((module) => module.createWorker));
    this.worker = await createWorker(this.languages, 1, {
      langPath: this.tessdataPath,
      gzip: true,
      cacheMethod: "none",
      legacyCore: false,
      legacyLang: false,
      logger: () => {},
    });
    this.workerLanguages = this.languages;
    return this.worker;
  }

  releaseWorker() {
    if (this.workerIdleTimer) clearTimeout(this.workerIdleTimer);
    this.workerIdleTimer = null;
    const worker = this.worker;
    this.worker = null;
    this.workerLanguages = "";
    if (worker) Promise.resolve(worker.terminate()).catch(() => {});
  }

  scheduleWorkerRelease() {
    if (this.workerIdleTimer) clearTimeout(this.workerIdleTimer);
    this.workerIdleTimer = setTimeout(() => this.releaseWorker(), WORKER_IDLE_MS);
    this.workerIdleTimer.unref?.();
  }

  async recognizeWithTesseract(image) {
    let worker;
    try {
      worker = await this.ensureWorker();
    } catch (error) {
      throw new OcrError(`Tesseract n’a pas pu démarrer : ${error.message}`);
    }
    try {
      const { data } = await worker.recognize(image);
      this.scheduleWorkerRelease();
      return {
        text: String(data?.text || "").trim(),
        confidence: Number(data?.confidence || 0),
      };
    } catch (error) {
      this.releaseWorker();
      throw new OcrError(`La reconnaissance a échoué : ${error.message}`);
    }
  }

  async recognizeWithVision(image) {
    if (image.length > VISION_MAX_BYTES)
      throw new OcrError("L’image dépasse la limite de 10 Mo de Google Vision.");
    const url = `https://vision.googleapis.com/v1/images:annotate?key=${encodeURIComponent(this.visionApiKey)}`;
    let response;
    try {
      response = await this.fetchImpl(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: AbortSignal.timeout(30_000),
        body: JSON.stringify({
          requests: [
            {
              image: { content: image.toString("base64") },
              features: [{ type: "DOCUMENT_TEXT_DETECTION" }],
              imageContext: { languageHints: visionLanguageHints(this.languages) },
            },
          ],
        }),
      });
    } catch (error) {
      throw new OcrError(`Google Vision injoignable : ${error.message}`);
    }
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const message = payload?.error?.message || `erreur HTTP ${response.status}`;
      throw new OcrError(`Google Vision a refusé la requête : ${message}`);
    }
    const annotation = payload?.responses?.[0];
    if (annotation?.error?.message)
      throw new OcrError(`Google Vision : ${annotation.error.message}`);
    return {
      text: String(annotation?.fullTextAnnotation?.text || "").trim(),
      // Vision ne renvoie pas de score global : on expose celui des pages.
      confidence: Math.round(
        (annotation?.fullTextAnnotation?.pages?.[0]?.confidence || 0) * 100,
      ),
    };
  }

  async close() {
    this.releaseWorker();
  }
}
