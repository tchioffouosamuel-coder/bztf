/**
 * Client de l'ILMS pour le poste.
 *
 * L'ILMS garde le catalogue ; le poste n'apporte que la chaîne RFID. Ce
 * client est le chemin par lequel le poste interroge et renseigne le
 * catalogue distant, en parlant directement à la passerelle — il tourne
 * côté serveur, il n'a donc pas la contrainte d'origine du navigateur.
 *
 * Une session operateur ouverte donne sa portee a la consultation. Sans
 * elle, le compte de service propre au poste permet la lecture non surveillee.
 * Les deux jetons restent distincts et en memoire.
 */

/** Panne réseau ou passerelle muette : distinguée d'un refus de l'API. */
export class IlmsOfflineError extends Error {
  constructor(message) {
    super(message);
    this.name = "IlmsOfflineError";
    this.offline = true;
  }
}

/** Réponse d'erreur de l'ILMS : le poste la montre telle quelle. */
export class IlmsApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "IlmsApiError";
    this.status = status;
  }
}

// Le jeton est renouvelé un peu avant l'heure, pour qu'une requête lancée
// juste avant l'échéance ne parte pas avec un jeton périmé.
const EXPIRY_MARGIN_MS = 60_000;
const DEFAULT_TIMEOUT_MS = 15_000;

export class IlmsClient {
  constructor(database, { fetchImpl, now, timeoutMs, getSession = () => null } = {}) {
    this.database = database;
    this.fetchImpl = fetchImpl || ((...args) => globalThis.fetch(...args));
    this.now = now || (() => Date.now());
    this.timeoutMs = timeoutMs || DEFAULT_TIMEOUT_MS;
    this.session = null;
    this.pendingLogin = null;
    this.getSession = getSession;
  }

  settings() {
    return {
      gatewayUrl: this.database.getSetting("ilms_gateway_url", ""),
      username: this.database.getSetting("ilms_username", ""),
      password: this.database.getSetting("ilms_password", ""),
      libraryId: this.database.getSetting("ilms_library_id", ""),
    };
  }

  get configured() {
    const { gatewayUrl, username, password, libraryId } = this.settings();
    return Boolean(gatewayUrl && username && password && libraryId);
  }

  /** À appeler quand les réglages changent : le jeton ne vaut plus. */
  reset() {
    this.session = null;
    this.pendingLogin = null;
  }

  context() {
    const operator = this.getSession();
    // Une session ouverte sans bibliotheque ou expiree ne doit pas emprunter
    // silencieusement les droits et la bibliotheque du compte de service.
    if (operator !== null) {
      if (!operator.libraryId)
        throw new IlmsApiError("Choisissez une bibliothèque dans la session ILMS.", 403);
      if (!operator.accessToken)
        throw new IlmsApiError("La session ILMS a expiré. Reconnectez-vous dans les réglages.", 401);
      return { ...operator, operator: true };
    }
    if (!this.configured)
      throw new IlmsApiError(
        "Compte ILMS du poste incomplet : adresse, identifiants et bibliothèque sont requis.",
        0,
      );
    return this.settings();
  }

  checkContext(context) {
    const current = this.context();
    if (["gatewayUrl", "libraryId", "accountId", "accessToken", "generation", "username", "password", "operator"]
      .some(key => current[key] !== context[key]))
      throw new IlmsApiError("La configuration ILMS a changé. Relancez la recherche.", 409);
  }

  async request(path, { method = "GET", body, retryOnUnauthorized = true, context = this.context() } = {}) {
    this.checkContext(context);
    const { gatewayUrl } = context;

    const token = context.operator ? context.accessToken : await this.token();
    this.checkContext(context);
    let response;
    try {
      response = await this.fetchImpl(`${gatewayUrl}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(this.timeoutMs),
        redirect: "error",
        credentials: "omit",
      });
    } catch (error) {
      throw new IlmsOfflineError(
        error?.name === "TimeoutError"
          ? "L'ILMS n'a pas répondu à temps."
          : "ILMS injoignable : vérifiez la connexion Internet.",
      );
    }

    // Jeton rejeté : une seule reprise, après l'avoir redemandé.
    this.checkContext(context);
    if (response.status === 401 && retryOnUnauthorized && !context.operator) {
      this.reset();
      return this.request(path, { method, body, retryOnUnauthorized: false, context });
    }
    return response;
  }

  /** Jeton du compte de service, renouvelé seulement quand il expire. */
  async token() {
    if (this.session && this.session.expiresAt - EXPIRY_MARGIN_MS > this.now())
      return this.session.token;
    // Plusieurs appels simultanés ne doivent provoquer qu'une connexion.
    if (!this.pendingLogin)
      this.pendingLogin = this.login().finally(() => {
        this.pendingLogin = null;
      });
    return this.pendingLogin;
  }

  async login() {
    const { gatewayUrl, username, password } = this.settings();
    let response;
    try {
      response = await this.fetchImpl(
        `${gatewayUrl}/auth-service/api/v1/auth/login`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({ username, password }),
          signal: AbortSignal.timeout(this.timeoutMs),
        },
      );
    } catch (error) {
      throw new IlmsOfflineError(
        error?.name === "TimeoutError"
          ? "L'ILMS n'a pas répondu à temps."
          : "ILMS injoignable : vérifiez la connexion Internet.",
      );
    }

    const payload = await readJson(response);
    if (!response.ok)
      throw new IlmsApiError(
        payload?.message ||
          "Connexion du poste à l'ILMS refusée : vérifiez les identifiants.",
        response.status,
      );

    const token = payload?.access_token?.token;
    if (!token)
      throw new IlmsApiError("L'ILMS n'a pas renvoyé de jeton.", response.status);

    // `expires_in` est en secondes ; sans lui, le jeton est redemandé à
    // chaque usage plutôt que gardé au-delà de sa validité.
    const seconds = Number(payload.access_token.expires_in) || 0;
    this.session = {
      token,
      expiresAt: this.now() + seconds * 1000,
    };
    return token;
  }

  /**
   * Exemplaire portant ce tag, ou `null` s'il n'est pas au catalogue — ce
   * qui est une réponse ordinaire : le portail en lit toute la journée.
   */
  async findCopyByTag({ epc = "", tid = "", includeDocument = false } = {}) {
    if (!epc && !tid)
      throw new IlmsApiError("Indiquez l'EPC ou le TID du tag.", 0);

    const context = this.context();
    const { libraryId } = context;
    const query = new URLSearchParams();
    if (epc) query.set("epc", epc);
    if (tid) query.set("tid", tid);
    const response = await this.request(
      `/library-service/api/v1/libraries/${encodeURIComponent(libraryId)}/copies/by-rfid?${query}`,
      { context },
    );

    const payload = await readJson(response);
    this.checkContext(context);
    if (!response.ok)
      throw new IlmsApiError(
        payload?.message || "Recherche de l'exemplaire impossible.",
        response.status,
      );
    if (payload === null) return null;
    if (typeof payload !== "object" || Array.isArray(payload) || typeof payload.id !== "string" || !payload.id
      || (payload.library_id && payload.library_id !== libraryId))
      throw new IlmsApiError("Réponse ILMS invalide pour cet exemplaire.", 502);
    const copy = normalizeCopy(payload);
    if (!includeDocument) return copy;
    copy.document = null;
    copy.documentError = null;
    if (copy.documentId) {
      try {
        const documentResponse = await this.request(
          `/library-service/api/v1/libraries/${encodeURIComponent(libraryId)}/documents/${encodeURIComponent(copy.documentId)}`,
          { context },
        );
        const document = await readJson(documentResponse);
        if (!documentResponse.ok || !document || document.id !== copy.documentId
          || (document.library_id && document.library_id !== libraryId))
          throw new IlmsApiError("Notice ILMS indisponible.", documentResponse.status);
        copy.document = {
          id: document.id,
          title: document.title ?? "",
          authors: Array.isArray(document.primary_authors) ? document.primary_authors.filter(name => typeof name === "string") : [],
          isbn: document.isbn13 || document.isbn || "",
        };
      } catch {
        // L'identite de l'exemplaire reste utile pendant une panne de notice.
        // Elle ne permet toutefois pas de conclure qu'un pret est autorise.
        copy.documentError = "Notice ILMS indisponible. Actualisez pour réessayer.";
      }
    }
    this.checkContext(context);
    return copy;
  }
}

async function readJson(response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new IlmsApiError("Réponse ILMS illisible.", 502);
  }
}

/** Ce que le poste retient d'un exemplaire de l'ILMS. */
function normalizeCopy(copy) {
  return {
    id: copy.id ?? null,
    number: copy.number ?? "",
    documentId: copy.document_id ?? null,
    documentNumber: copy.document_number ?? "",
    quote: copy.quote ?? "",
    epc: copy.rfid_code ?? "",
    tid: copy.rfid_tid ?? "",
    status: copy.status ?? null,
    shelf: copy.shelf_name ?? "",
    section: copy.section_name ?? "",
  };
}
