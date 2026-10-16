import { ILMS_DEFAULT_GATEWAY_URL, ILMS_UUID, IlmsClientError, nativeUuid } from "./ilms-circulation-client.js";

/**
 * Session ILMS du poste.
 *
 * Meme contrat que `IlmsAuthService` du mobile : jeton OAuth client, puis
 * connexion utilisateur, puis liste des bibliotheques. Trois appels, dans cet
 * ordre, parce que chacun fournit l'autorisation du suivant.
 *
 * Le mot de passe n'est jamais conserve et le jeton ne quitte pas la memoire
 * de ce processus : le poste est partage, et un jeton ecrit sur disque y
 * survivrait a la fermeture de la session de son porteur. Seuls l'origine et
 * la bibliotheque choisie sont rendus au serveur, qui peut les ranger dans ses
 * reglages.
 *
 * La liste des bibliotheques n'est pas une autorisation : chaque appel metier
 * reste porte par une bibliotheque et verifie par le serveur. Aucune portee
 * « toutes les bibliotheques » n'est fabriquee ici.
 */

/** Origine valide, sans identifiants ni chemin : meme regle que `nativeScope`. */
function gatewayOrigin(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new IlmsClientError("scope");
  }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && local)) || url.username || url.password
    || url.href !== url.origin + "/" || /[\x00-\x20\x7f]/.test(String(value).trim())) throw new IlmsClientError("scope");
  return url.origin;
}

function bearer(value) {
  if (typeof value !== "string" || value.length > 8192 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(value)) {
    throw new IlmsClientError("response");
  }
  return value;
}

function object(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new IlmsClientError("response");
  return value;
}

/**
 * Echeance portee par le jeton lui-meme.
 *
 * Le `expires_in` de l'etape OAuth vaut pour le jeton d'amorce, pas pour celui
 * de l'utilisateur : seule la revendication `exp` du jeton final dit quand la
 * session cesse. La lire evite d'envoyer des demandes qu'ILMS refusera.
 */
function expiry(token, now) {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some(part => part === "")) throw new IlmsClientError("response");
  let claims;
  try {
    claims = object(JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")));
  } catch {
    throw new IlmsClientError("response");
  }
  const exp = claims.exp;
  if (!Number.isInteger(exp) || exp <= 0 || exp > 8640000000000) throw new IlmsClientError("response");
  const expiresAt = exp * 1000;
  if (expiresAt <= now()) throw new IlmsClientError("auth", 401);
  return expiresAt;
}

export class IlmsSessionStore {

  constructor({fetchImpl = fetch, timeoutMs = 30000, now = Date.now} = {}) {
    if (typeof fetchImpl !== "function" || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000) {
      throw new IlmsClientError("input");
    }
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.now = now;
    this.clear();
  }

  clear() {
    // Incremente a chaque deconnexion et a chaque nouvelle connexion : une
    // reponse arrivant apres coup appartient a une session revolue et ne doit
    // pas la ressusciter.
    this.generation = (this.generation ?? 0) + 1;
    this.gatewayUrl = null;
    this.accountId = null;
    this.token = null;
    this.expiresAt = null;
    this.libraryId = null;
    this.libraries = [];
  }

  signOut() {
    this.clear();
  }

  get signedIn() {
    return this.accountId !== null;
  }

  /** Vrai quand le jeton est encore valable : une session expiree reste affichee, mais ne sert plus. */
  get active() {
    return this.signedIn && this.expiresAt !== null && this.expiresAt > this.now();
  }

  /**
   * Portee attendue par `IlmsCirculationClient.getSession`. Null tant qu'une
   * bibliotheque n'est pas choisie : le client refuserait une portee
   * incomplete, autant ne pas la lui presenter.
   */
  get session() {
    if (!this.signedIn || !this.libraryId) return null;
    return {
      gatewayUrl: this.gatewayUrl,
      accountId: this.accountId,
      libraryId: this.libraryId,
      accessToken: this.active ? this.token : "",
    };
  }

  /** Etat affichable. Ne porte jamais le jeton. */
  get state() {
    return {
      signed_in: this.signedIn,
      active: this.active,
      gateway_url: this.gatewayUrl,
      account_id: this.accountId,
      library_id: this.libraryId,
      libraries: this.libraries.map(library => ({...library})),
      expires_at: this.expiresAt === null ? null : new Date(this.expiresAt).toISOString(),
    };
  }

  selectLibrary(id) {
    const wanted = nativeUuid(id, "scope");
    if (!this.signedIn || !this.libraries.some(library => library.id === wanted)) throw new IlmsClientError("scope");
    this.libraryId = wanted;
  }

  async signIn({gatewayUrl, username, password, clientId, clientSecret}) {
    const gateway = gatewayOrigin(gatewayUrl || ILMS_DEFAULT_GATEWAY_URL);
    if (typeof username !== "string" || !username.trim() || username.length > 255
      || typeof password !== "string" || !password || password.length > 4096
      || typeof clientId !== "string" || !clientId || clientId.length > 255
      || typeof clientSecret !== "string" || !clientSecret || clientSecret.length > 4096
      || clientId.includes(":") || /[\x00-\x1f\x7f]/.test(clientId)) throw new IlmsClientError("input");

    this.clear();
    const generation = this.generation;

    const oauth = object(await this.request(generation, gateway, "POST", "/auth-service/oauth/token", {
      stage: "oauth",
      authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`, "utf8").toString("base64")}`,
      contentType: "application/x-www-form-urlencoded",
      body: "grant_type=client_credentials&scope=read+write",
    }));
    if (typeof oauth.token_type !== "string" || oauth.token_type.toLowerCase() !== "bearer"
      || !Number.isInteger(oauth.expires_in) || oauth.expires_in <= 0) throw new IlmsClientError("response");

    const login = object(await this.request(generation, gateway, "POST", "/auth-service/api/v1/auth/login", {
      stage: "login",
      authorization: `Bearer ${bearer(oauth.access_token)}`,
      body: JSON.stringify({username: username.trim(), password}),
    }));
    const access = object(login.access_token);
    const user = object(login.user);
    // Un mot de passe a renouveler rend un jeton qui ne sert a rien d'autre :
    // le dire, plutot que de laisser le poste echouer appel apres appel.
    if (access.type === "Password-Token" || user.password_change_required === true) {
      throw Object.assign(new IlmsClientError("password_change", 401), {stage: "login"});
    }
    if (access.type !== "Bearer") throw new IlmsClientError("response");

    const accountId = nativeUuid(user.id, "response");
    const token = bearer(access.token);
    const expiresAt = expiry(token, this.now);

    const raw = await this.request(generation, gateway, "GET", "/library-service/api/v1/libraries", {
      stage: "libraries",
      authorization: `Bearer ${token}`,
    });
    if (!Array.isArray(raw) || raw.length > 1000) throw new IlmsClientError("response");
    const libraries = [];
    const seen = new Set();
    for (const entry of raw) {
      const library = object(entry);
      const id = nativeUuid(library.id, "response");
      if (typeof library.name !== "string" || !library.name.trim() || library.name.length > 255 || seen.has(id)) {
        throw new IlmsClientError("response");
      }
      seen.add(id);
      libraries.push({id, name: library.name});
    }

    this.check(generation);
    if (libraries.length === 0) throw Object.assign(new IlmsClientError("no_library", 403), {stage: "libraries"});

    this.gatewayUrl = gateway;
    this.accountId = accountId;
    this.token = token;
    this.expiresAt = expiresAt;
    this.libraries = libraries;
    // Une seule bibliotheque : la choisir evite un ecran de selection a un
    // seul bouton. Plusieurs : l'operateur tranche, le poste ne devine pas.
    this.libraryId = libraries.length === 1 ? libraries[0].id : null;
    return this.state;
  }

  /** Une reponse d'une session revolue ne doit rien ecrire. */
  check(generation) {
    if (generation !== this.generation) throw new IlmsClientError("scope");
  }

  async request(generation, gateway, method, path, {authorization, contentType, body, stage} = {}) {
    this.check(generation);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const headers = {Authorization: authorization, Accept: "application/json"};
      if (body !== undefined) headers["Content-Type"] = contentType ?? "application/json";
      const response = await this.fetch(`${gateway}${path}`, {
        method,
        // Une redirection pendant la connexion mene a une page de login HTML :
        // la suivre echangerait le refus contre une reponse 200 trompeuse.
        redirect: "error",
        credentials: "omit",
        cache: "no-store",
        signal: controller.signal,
        headers,
        ...(body === undefined ? {} : {body}),
      });
      this.check(generation);
      if (!Number.isInteger(response.status) || response.status < 100 || response.status > 599) {
        await response.body?.cancel();
        throw new IlmsClientError("response");
      }
      if (response.status < 200 || response.status >= 300) {
        await response.body?.cancel();
        // `denied` parle du journal, qui n'existe pas pendant une connexion :
        // un refus de connexion a son propre code et son propre message.
        throw new IlmsClientError(response.status === 401 || response.status === 403 ? "auth" : "signin", response.status);
      }
      if (response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
        await response.body?.cancel();
        throw new IlmsClientError("response");
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body ?? []) {
        size += chunk.byteLength;
        if (size > 262144) {
          controller.abort();
          throw new IlmsClientError("response");
        }
        chunks.push(Buffer.from(chunk));
      }
      this.check(generation);
      try {
        return JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        throw new IlmsClientError("response");
      }
    } catch (error) {
      controller.abort();
      const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
      // Trois etapes se ressemblent dans un journal : dire laquelle a refuse
      // evite de soupconner la passerelle quand c'est le mot de passe, et
      // l'inverse. Ce chantier a deja perdu deux tranches a cette confusion.
      safe.stage ??= stage;
      throw safe;
    } finally {
      clearTimeout(timer);
    }
  }
}

export { ILMS_DEFAULT_GATEWAY_URL, ILMS_UUID };
