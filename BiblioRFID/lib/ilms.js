import fs from "node:fs";
import http from "node:http";
import path from "node:path";

/**
 * Interface ILMS embarquée dans l'application.
 *
 * L'application Angular appelle son API par des chemins relatifs à sa propre
 * origine (`/api/library-service/...`, `/api/auth-service/...`), jamais par
 * une adresse absolue : en production, un proxy placé devant elle sert le
 * paquet et relaie `/api/**` vers la passerelle. Le poste reproduit
 * exactement ce montage sur un second serveur local, lié à la seule boucle
 * locale : le paquet est servi à la racine de ce port et les appels d'API
 * sont relayés vers la passerelle.
 *
 * C'est ce qui permet d'embarquer l'ILMS sans modifier une seule ligne de son
 * code, et sans empiéter sur l'API du poste, qui occupe déjà `/api/`.
 */

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const CONTENT_TYPES = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".map": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".eot": "application/vnd.ms-fontobject",
  ".txt": "text/plain",
  ".wasm": "application/wasm",
  ".pdf": "application/pdf",
};

// `ng build` hache les noms des fichiers qu'il produit ; ceux copiés depuis
// `src/assets` gardent le leur et peuvent changer sans changer d'URL.
const HASHED_NAME = /-[A-Z0-9]{8,}\.[a-z0-9]+$/;

/** Préfixes que l'application Angular adresse à son API, et non au paquet. */
export const RELAYED_PREFIXES = ["/api/", "/ilms-auth-service/"];

/**
 * Emplacement du paquet Angular, dans cet ordre : variable d'environnement,
 * ressources de l'application empaquetée, puis dossier `ilms/` du dépôt.
 * Renvoie `null` tant qu'aucun `index.html` n'est présent.
 */
export function resolveIlmsRoot({
  root = "",
  resourcesPath = "",
  override = "",
} = {}) {
  const candidates = [];
  if (override) candidates.push(path.resolve(override));
  if (resourcesPath) candidates.push(path.join(resourcesPath, "ilms"));
  if (root) candidates.push(path.join(root, "ilms"));
  for (const candidate of candidates) {
    try {
      if (fs.statSync(path.join(candidate, "index.html")).isFile())
        return candidate;
    } catch {
      // Candidat absent ou illisible : on essaie le suivant.
    }
  }
  return null;
}

function contentTypeOf(file) {
  const extension = path.extname(file).toLowerCase();
  const type = CONTENT_TYPES[extension] || "application/octet-stream";
  const textual =
    type.startsWith("text/") ||
    type === "application/json" ||
    type === "image/svg+xml";
  return textual ? `${type}; charset=utf-8` : type;
}

function cacheControlOf(file) {
  if (path.extname(file).toLowerCase() === ".html")
    return "no-cache, no-store, must-revalidate";
  return HASHED_NAME.test(path.basename(file))
    ? "public, max-age=31536000, immutable"
    : "no-cache";
}

/** Page affichée quand l'exécutable a été produit sans le paquet ILMS. */
export function missingBundlePage() {
  return `<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<title>Module ILMS absent</title>
<style>
  body { margin: 0; display: grid; place-items: center; min-height: 100vh;
    font: 15px/1.6 "Segoe UI", system-ui, sans-serif; color: #153047;
    background: #f4f7fa; }
  div { max-width: 34rem; padding: 2rem; text-align: center; }
  h1 { font-size: 1.25rem; margin: 0 0 0.75rem; }
  code { background: #e6edf4; padding: 0.1rem 0.35rem; border-radius: 4px; }
</style></head>
<body><div>
  <h1>Module ILMS absent de cette version</h1>
  <p>Cet exécutable a été produit sans l'interface ILMS. Les fonctions RFID
  du poste restent disponibles.</p>
  <p>Pour l'ajouter, placer le résultat de la compilation de l'ILMS dans
  <code>ilms/</code> avant l'empaquetage, ou indiquer son dossier par
  <code>BIBLIORFID_ILMS_DIR</code>.</p>
</div></body></html>`;
}

/** Corps renvoyé au cadre ILMS lorsque la passerelle est injoignable. */
export function offlinePayload(message) {
  return { error: message, offline: true };
}

/**
 * Normalise l'adresse de la passerelle ILMS. Renvoie une chaîne vide quand le
 * champ est vidé, et refuse tout ce qui n'est pas une adresse HTTP(S).
 */
export function normalizeGatewayUrl(value) {
  const text = String(value ?? "").trim();
  if (!text) return "";
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new Error("Adresse de la passerelle ILMS invalide.");
  }
  if (url.protocol !== "https:" && url.protocol !== "http:")
    throw new Error("La passerelle ILMS doit être une adresse HTTP ou HTTPS.");
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

/** Sert un fichier du paquet. Renvoie `false` si le chemin n'en est pas un. */
function serveBundleFile(response, pathname, ilmsRoot, method) {
  const base = path.resolve(ilmsRoot);
  let relative = "";
  try {
    relative = decodeURIComponent(pathname.slice(1));
  } catch {
    relative = "";
  }
  const file = path.resolve(base, relative || "index.html");
  // Un chemin sortant du paquet n'est jamais servi.
  if (file !== base && !file.startsWith(base + path.sep)) return false;
  let stats = null;
  try {
    const candidate = fs.statSync(file);
    if (candidate.isFile()) stats = candidate;
  } catch {
    stats = null;
  }
  if (!stats) return false;

  response.writeHead(200, {
    "Content-Type": contentTypeOf(file),
    "Content-Length": stats.size,
    "Cache-Control": cacheControlOf(file),
  });
  if (method === "HEAD") response.end();
  else fs.createReadStream(file).pipe(response);
  return true;
}

/** Sert l'`index.html` du paquet : liens profonds de l'application Angular. */
function serveBundleIndex(response, ilmsRoot, method) {
  const index = path.join(path.resolve(ilmsRoot), "index.html");
  const stats = fs.statSync(index);
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": stats.size,
    "Cache-Control": "no-cache, no-store, must-revalidate",
  });
  if (method === "HEAD") response.end();
  else fs.createReadStream(index).pipe(response);
}

function forwardedRequestHeaders(headers) {
  const result = {};
  for (const [name, value] of Object.entries(headers)) {
    const key = name.toLowerCase();
    if (HOP_BY_HOP.has(key)) continue;
    // L'origine du poste n'a pas de sens pour la passerelle, et la laisser
    // passer déclencherait un contrôle CORS inutile.
    if (key === "host" || key === "origin" || key === "referer") continue;
    if (key === "content-length") continue;
    if (value !== undefined) result[key] = value;
  }
  return result;
}

/**
 * Adresse visée sur la passerelle. Le préfixe `/api` que l'application ajoute
 * à ses appels est retiré : les routes de la passerelle sont nommées d'après
 * le service (`/library-service/**`), comme le fait le proxy de production.
 */
export function gatewayTarget(baseUrl, pathname, search = "") {
  const suffix = pathname.startsWith("/api/")
    ? pathname.slice("/api".length)
    : pathname;
  return `${baseUrl}${suffix}${search}`;
}

/**
 * Relaie un appel d'API vers la passerelle ILMS. Le jeton d'authentification
 * circule inchangé ; rien n'est journalisé.
 */
export function createGatewayProxy({
  baseUrl = () => "",
  timeoutMs = 30000,
  fetchImpl = (...args) => globalThis.fetch(...args),
} = {}) {
  return async function proxy(request, response, url) {
    const target = typeof baseUrl === "function" ? baseUrl() : baseUrl;
    if (!target) {
      response.writeHead(503, {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      });
      return response.end(
        JSON.stringify(
          offlinePayload(
            "Passerelle ILMS non configurée : renseignez son adresse dans Paramètres.",
          ),
        ),
      );
    }

    const destination = gatewayTarget(target, url.pathname, url.search);
    const hasBody = request.method !== "GET" && request.method !== "HEAD";
    try {
      const upstream = await fetchImpl(destination, {
        method: request.method,
        headers: forwardedRequestHeaders(request.headers),
        body: hasBody ? request : undefined,
        duplex: hasBody ? "half" : undefined,
        redirect: "manual",
        signal: AbortSignal.timeout(timeoutMs),
      });
      const headers = {};
      upstream.headers.forEach((value, name) => {
        const key = name.toLowerCase();
        if (HOP_BY_HOP.has(key)) return;
        // `fetch` a déjà décompressé le corps : conserver ces en-têtes
        // donnerait une réponse illisible au navigateur.
        if (key === "content-encoding" || key === "content-length") return;
        headers[name] = value;
      });
      response.writeHead(upstream.status, headers);
      if (!upstream.body) {
        response.end();
        return undefined;
      }
      for await (const chunk of upstream.body) response.write(chunk);
      response.end();
      return undefined;
    } catch (error) {
      if (response.headersSent) {
        response.end();
        return undefined;
      }
      const timedOut = error?.name === "TimeoutError";
      response.writeHead(504, {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      });
      return response.end(
        JSON.stringify(
          offlinePayload(
            timedOut
              ? "La passerelle ILMS n'a pas répondu à temps."
              : "Passerelle ILMS injoignable : vérifiez la connexion Internet.",
          ),
        ),
      );
    }
  };
}

/**
 * Gestionnaire du serveur ILMS local : un fichier du paquet, sinon un appel
 * d'API relayé, sinon l'`index.html` pour les liens profonds d'Angular.
 */
export function createIlmsHandler({ ilmsRoot = null, proxy = null } = {}) {
  return async function handle(request, response) {
    const url = new URL(request.url, "http://localhost");
    const method = request.method || "GET";

    const relayed = RELAYED_PREFIXES.some((prefix) =>
      url.pathname.startsWith(prefix),
    );
    if (relayed && proxy) return proxy(request, response, url);

    if (!ilmsRoot) {
      const page = missingBundlePage();
      response.writeHead(503, {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": Buffer.byteLength(page),
        "Cache-Control": "no-store",
      });
      return response.end(method === "HEAD" ? undefined : page);
    }
    if (method !== "GET" && method !== "HEAD") {
      const body = JSON.stringify({ error: "Méthode non autorisée." });
      response.writeHead(405, {
        "Content-Type": "application/json; charset=utf-8",
        Allow: "GET, HEAD",
      });
      return response.end(body);
    }
    if (serveBundleFile(response, url.pathname, ilmsRoot, method)) return;
    return serveBundleIndex(response, ilmsRoot, method);
  };
}

/**
 * Démarre le serveur local de l'interface ILMS. Il n'écoute que sur la boucle
 * locale : le relais de la passerelle ne doit pas être joignable depuis le
 * réseau, contrairement au serveur du poste.
 */
export function startIlmsServer({
  ilmsRoot = null,
  baseUrl = () => "",
  port = 4311,
  maxPort = 4320,
  host = "127.0.0.1",
} = {}) {
  const proxy = createGatewayProxy({ baseUrl });
  const server = http.createServer((request, response) => {
    createIlmsHandler({ ilmsRoot, proxy })(request, response).catch(() => {
      if (!response.headersSent) response.writeHead(500);
      response.end();
    });
  });

  return new Promise((resolve) => {
    let candidate = port;
    const attempt = () => {
      server.once("error", (error) => {
        if (error.code === "EADDRINUSE" && candidate < maxPort) {
          candidate += 1;
          attempt();
          return;
        }
        // L'onglet ILMS est accessoire : son indisponibilité ne doit jamais
        // empêcher le poste de démarrer.
        resolve({ server: null, port: null, origin: "" });
      });
      server.listen(candidate, host, () => {
        // `port: 0` laisse le système choisir : lire le port réellement ouvert.
        const actual = server.address().port;
        resolve({ server, port: actual, origin: `http://${host}:${actual}` });
      });
    };
    attempt();
  });
}
