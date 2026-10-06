/**
 * Assistance IA au catalogage, désactivée par défaut.
 *
 * Trois fournisseurs au choix dans Paramètres : Claude (SDK Anthropic officiel),
 * DeepSeek et ChatGPT (API compatibles OpenAI). Cinq rôles indépendants,
 * activables séparément :
 *  - `structure` : transformer le texte OCR en champs bibliographiques ;
 *  - `arbitrate` : choisir la bonne notice parmi plusieurs éditions ;
 *  - `complete`  : proposer catégorie, cote, Dewey, vedettes matière ;
 *  - `quality`   : signaler les incohérences avant enregistrement ;
 *  - `vision`    : lire directement les photos quand l'OCR est illisible.
 *
 * Rien n'est envoyé à un fournisseur tant que le rôle correspondant n'est pas
 * activé et qu'une clé n'est pas renseignée. L'IA ne propose jamais : le
 * catalogueur valide, et c'est sa validation qui écrit au catalogue.
 */

export const AI_PROVIDERS = ["claude", "deepseek", "chatgpt"];
export const AI_ROLES = [
  "structure",
  "arbitrate",
  "complete",
  "quality",
  "vision",
];

export const DEFAULT_AI_MODELS = {
  claude: "claude-opus-5-5",
  deepseek: "deepseek-chat",
  chatgpt: "gpt-4o",
};

/** Réponses courtes et structurées : inutile de payer un gros budget. */
const MAX_OUTPUT_TOKENS = 4096;
const REQUEST_TIMEOUT_MS = 60_000;
const VISION_PROVIDERS = new Set(["claude", "chatgpt"]);

export class AiUnavailableError extends Error {}
export class AiResponseError extends Error {}

export function normalizeAiProvider(value) {
  const provider = String(value || "").trim().toLowerCase();
  return AI_PROVIDERS.includes(provider) ? provider : "claude";
}

export function normalizeAiRoles(value) {
  const requested = Array.isArray(value)
    ? value
    : String(value || "")
        .split(/[,\s]+/)
        .filter(Boolean);
  const roles = Object.fromEntries(AI_ROLES.map((role) => [role, false]));
  for (const role of requested)
    if (role in roles) roles[String(role).trim()] = true;
  return roles;
}

export function serializeAiRoles(roles = {}) {
  return AI_ROLES.filter((role) => roles[role]).join(",");
}

/** Le modèle répond parfois dans un bloc Markdown : on récupère le JSON. */
export function parseJsonResponse(text) {
  const raw = String(text || "").trim();
  const withoutFence = raw
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();
  const candidates = [withoutFence];
  const firstBrace = withoutFence.indexOf("{");
  const lastBrace = withoutFence.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace)
    candidates.push(withoutFence.slice(firstBrace, lastBrace + 1));
  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === "object") return parsed;
    } catch {
      continue;
    }
  }
  throw new AiResponseError("La réponse de l’IA n’était pas du JSON exploitable.");
}

const FIELD_INSTRUCTIONS = `Réponds uniquement par un objet JSON, sans texte autour, avec ces clés :
{"title":"","subtitle":"","author":"","isbn":"","publisher":"","publication_year":"",
 "collection":"","collection_number":"","language":"","edition":"","page_count":"",
 "summary":"","subjects":"","confidence":0,"notes":""}
Règles : "author" liste les auteurs principaux séparés par « ; » ; "publication_year"
ne contient que quatre chiffres ; "subjects" sépare les vedettes par « ; » ;
"confidence" est un entier de 0 à 100 ; laisse une chaîne vide pour toute
information absente du document. N’invente jamais une donnée absente.`;

export class AiCataloguingService {
  constructor({
    provider = "claude",
    apiKey = "",
    model = "",
    roles = {},
    fetchImpl,
    anthropicFactory,
  } = {}) {
    this.fetchImpl = fetchImpl || ((...args) => fetch(...args));
    this.anthropicFactory = anthropicFactory || null;
    this.configure({ provider, apiKey, model, roles });
  }

  configure({ provider, apiKey, model, roles } = {}) {
    if (provider !== undefined) this.provider = normalizeAiProvider(provider);
    if (apiKey !== undefined) this.apiKey = String(apiKey || "").trim();
    if (model !== undefined) this.model = String(model || "").trim();
    if (roles !== undefined)
      this.roles = Array.isArray(roles) || typeof roles === "string"
        ? normalizeAiRoles(roles)
        : { ...normalizeAiRoles([]), ...roles };
  }

  get activeModel() {
    return this.model || DEFAULT_AI_MODELS[this.provider];
  }

  get configured() {
    return Boolean(this.apiKey);
  }

  roleEnabled(role) {
    return Boolean(this.configured && this.roles?.[role]);
  }

  get status() {
    return {
      provider: this.provider,
      model: this.activeModel,
      configured: this.configured,
      roles: { ...this.roles },
      supportsVision: VISION_PROVIDERS.has(this.provider),
    };
  }

  requireRole(role) {
    if (!this.configured)
      throw new AiUnavailableError(
        "Aucune clé API n’est renseignée pour l’assistance IA.",
      );
    if (!this.roles?.[role])
      throw new AiUnavailableError(
        `Le rôle « ${role} » de l’assistance IA est désactivé dans les paramètres.`,
      );
  }

  /** Champs bibliographiques déduits du texte OCR. */
  async structureFromOcr({ frontText = "", backText = "", otherText = "", hints = {} }) {
    this.requireRole("structure");
    const payload = await this.ask({
      system:
        "Tu es catalogueur en bibliothèque. Tu lis un texte OCR bruité provenant de photos de couverture et tu en extrais la description bibliographique exacte.",
      prompt: [
        "Texte OCR de la première de couverture :",
        frontText || "(aucun)",
        "",
        "Texte OCR de la quatrième de couverture :",
        backText || "(aucun)",
        otherText ? `\nAutres pages :\n${otherText}` : "",
        "",
        "Indices déjà extraits automatiquement (à corriger si nécessaire) :",
        JSON.stringify(hints),
        "",
        FIELD_INSTRUCTIONS,
      ].join("\n"),
    });
    return normalizeFieldResponse(payload);
  }

  /** Même sortie que `structureFromOcr`, mais en lisant les images. */
  async readImages({ images = [], hints = {} }) {
    this.requireRole("vision");
    if (!VISION_PROVIDERS.has(this.provider))
      throw new AiUnavailableError(
        "Ce fournisseur ne lit pas les images : choisissez Claude ou ChatGPT.",
      );
    if (!images.length) throw new AiUnavailableError("Aucune image à lire.");
    const payload = await this.ask({
      system:
        "Tu es catalogueur en bibliothèque. Tu décris un livre à partir des photos de ses couvertures.",
      prompt: [
        "Décris ce livre à partir des photos fournies.",
        "Indices déjà extraits automatiquement :",
        JSON.stringify(hints),
        "",
        FIELD_INSTRUCTIONS,
      ].join("\n"),
      images,
    });
    return normalizeFieldResponse(payload);
  }

  /** Index de la notice retenue parmi les candidates, et sa justification. */
  async arbitrate({ candidates = [], ocrText = "", hints = {} }) {
    this.requireRole("arbitrate");
    if (candidates.length < 2)
      return { index: 0, reason: "", confidence: 100 };
    const payload = await this.ask({
      system:
        "Tu es catalogueur en bibliothèque. Tu choisis l’édition qui correspond exactement à l’exemplaire en main.",
      prompt: [
        "Notices candidates :",
        JSON.stringify(
          candidates.map((candidate, index) => ({ index, ...candidate })),
        ),
        "",
        "Texte OCR de l’exemplaire :",
        ocrText.slice(0, 6000) || "(aucun)",
        "",
        "Indices extraits :",
        JSON.stringify(hints),
        "",
        'Réponds uniquement par {"index":0,"confidence":0,"reason":""} où "index" désigne la notice retenue,',
        '"confidence" est un entier de 0 à 100 et "reason" tient en une phrase en français.',
        "Si aucune notice ne convient, renvoie index -1.",
      ].join("\n"),
    });
    const index = Number.parseInt(payload.index, 10);
    return {
      index: Number.isInteger(index) && index < candidates.length ? index : -1,
      reason: String(payload.reason || "").slice(0, 400),
      confidence: clampPercent(payload.confidence),
    };
  }

  /** Catégorie, cote, Dewey et vedettes matière proposées. */
  async complete({ fields = {}, prefixes = {} }) {
    this.requireRole("complete");
    const payload = await this.ask({
      system:
        "Tu es bibliothécaire-catalogueur. Tu complètes l’indexation d’une notice déjà identifiée.",
      prompt: [
        "Notice :",
        JSON.stringify(fields),
        "",
        "Préfixes de cote utilisés par cette bibliothèque (genre → préfixe) :",
        JSON.stringify(prefixes),
        "",
        'Réponds uniquement par {"category":"","shelf":"","dewey":"","subjects":"","summary":"","notes":""}.',
        '"shelf" suit les préfixes ci-dessus quand l’un d’eux correspond au genre.',
        '"dewey" est un indice Dewey plausible (chiffres et point décimal).',
        '"subjects" sépare les vedettes par « ; ». "summary" fait au plus 600 caractères.',
        "Laisse vide tout champ que tu ne peux pas établir sérieusement.",
      ].join("\n"),
    });
    return {
      category: cleanField(payload.category, 120),
      shelf: cleanField(payload.shelf, 120),
      dewey: cleanField(payload.dewey, 60),
      subjects: cleanField(payload.subjects, 1000),
      summary: cleanField(payload.summary, 600),
      notes: cleanField(payload.notes, 400),
    };
  }

  /** Anomalies détectées dans la fiche avant enregistrement. */
  async quality({ fields = {} }) {
    this.requireRole("quality");
    const payload = await this.ask({
      system:
        "Tu es réviseur de notices bibliographiques. Tu signales les anomalies sans rien réécrire.",
      prompt: [
        "Notice à contrôler :",
        JSON.stringify(fields),
        "",
        'Réponds uniquement par {"issues":[{"field":"","severity":"info|avertissement|erreur","message":""}]}.',
        "Signale par exemple une année improbable, un auteur recopié dans le titre,",
        "un ISBN incohérent avec l’éditeur, un titre tronqué par l’OCR.",
        "Renvoie une liste vide si la notice est correcte.",
      ].join("\n"),
    });
    const issues = Array.isArray(payload.issues) ? payload.issues : [];
    return {
      issues: issues
        .map((issue) => ({
          field: cleanField(issue?.field, 40),
          severity: ["info", "avertissement", "erreur"].includes(issue?.severity)
            ? issue.severity
            : "info",
          message: cleanField(issue?.message, 300),
        }))
        .filter((issue) => issue.message)
        .slice(0, 12),
    };
  }

  /** Appel minimal pour vérifier la clé depuis Paramètres. */
  async test() {
    if (!this.configured)
      throw new AiUnavailableError("Renseignez d’abord une clé API.");
    const payload = await this.ask({
      system: "Tu réponds en JSON strict.",
      prompt: 'Réponds exactement {"ok":true}.',
    });
    if (payload.ok !== true)
      throw new AiResponseError("Réponse inattendue du fournisseur.");
    return { ok: true, provider: this.provider, model: this.activeModel };
  }

  async ask({ system, prompt, images = [] }) {
    if (this.provider === "claude")
      return this.askClaude({ system, prompt, images });
    return this.askOpenAiCompatible({ system, prompt, images });
  }

  async askClaude({ system, prompt, images }) {
    const client = await this.anthropicClient();
    const content = [
      ...images.map((image) => ({
        type: "image",
        source: {
          type: "base64",
          media_type: image.mediaType || "image/jpeg",
          data: image.base64,
        },
      })),
      { type: "text", text: prompt },
    ];
    let message;
    try {
      message = await client.messages.create({
        model: this.activeModel,
        max_tokens: MAX_OUTPUT_TOKENS,
        system,
        // Extraction courte et cadrée : le niveau d'effort le plus bas suffit.
        output_config: { effort: "low" },
        messages: [{ role: "user", content }],
      });
    } catch (error) {
      throw new AiUnavailableError(`Claude : ${error.message}`);
    }
    if (message.stop_reason === "refusal")
      throw new AiResponseError("Claude a refusé de traiter ces images.");
    const text = (message.content || [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    return parseJsonResponse(text);
  }

  async anthropicClient() {
    if (this.anthropicFactory) return this.anthropicFactory(this.apiKey);
    const { default: Anthropic } = await import("@anthropic-ai/sdk");
    return new Anthropic({ apiKey: this.apiKey, timeout: REQUEST_TIMEOUT_MS });
  }

  async askOpenAiCompatible({ system, prompt, images }) {
    const endpoint =
      this.provider === "deepseek"
        ? "https://api.deepseek.com/chat/completions"
        : "https://api.openai.com/v1/chat/completions";
    const content = images.length
      ? [
          ...images.map((image) => ({
            type: "image_url",
            image_url: {
              url: `data:${image.mediaType || "image/jpeg"};base64,${image.base64}`,
            },
          })),
          { type: "text", text: prompt },
        ]
      : prompt;
    let response;
    try {
      response = await this.fetchImpl(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`,
        },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        body: JSON.stringify({
          model: this.activeModel,
          max_tokens: MAX_OUTPUT_TOKENS,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: system },
            { role: "user", content },
          ],
        }),
      });
    } catch (error) {
      throw new AiUnavailableError(
        `${this.provider === "deepseek" ? "DeepSeek" : "ChatGPT"} injoignable : ${error.message}`,
      );
    }
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const message =
        payload?.error?.message || `erreur HTTP ${response.status}`;
      throw new AiUnavailableError(
        `${this.provider === "deepseek" ? "DeepSeek" : "ChatGPT"} : ${message}`,
      );
    }
    return parseJsonResponse(payload?.choices?.[0]?.message?.content || "");
  }
}

function cleanField(value, maxLength) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

function clampPercent(value) {
  const number = Number.parseInt(value, 10);
  if (!Number.isFinite(number)) return 0;
  return Math.min(100, Math.max(0, number));
}

export function normalizeFieldResponse(payload = {}) {
  const year = /(1[0-9]{3}|20[0-9]{2})/.exec(String(payload.publication_year || ""));
  return {
    fields: {
      title: cleanField(payload.title, 240),
      subtitle: cleanField(payload.subtitle, 240),
      author: cleanField(payload.author, 240),
      isbn: cleanField(payload.isbn, 32),
      publisher: cleanField(payload.publisher, 240),
      publication_year: year ? year[1] : "",
      collection: cleanField(payload.collection, 240),
      collection_number: cleanField(payload.collection_number, 60),
      language: cleanField(payload.language, 60),
      edition: cleanField(payload.edition, 120),
      page_count: cleanField(payload.page_count, 60),
      summary: cleanField(payload.summary, 4000),
      subjects: cleanField(payload.subjects, 1000),
    },
    confidence: clampPercent(payload.confidence),
    notes: cleanField(payload.notes, 400),
  };
}
