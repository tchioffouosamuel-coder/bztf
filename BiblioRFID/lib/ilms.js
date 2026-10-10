import fs from "node:fs";
import path from "node:path";

/**
 * Interface ILMS embarquée dans l'application : le paquet Angular est servi
 * par le serveur local sous `/ilms/`, et ses appels d'API passent par le
 * proxy `/gateway/`. Les deux partagent ainsi l'origine du poste, ce qui
 * évite toute question de CORS et donne un seul endroit pour signaler une
 * coupure réseau.
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
 * Sert `/ilms/**` depuis [ilmsRoot]. Un chemin inconnu retombe sur
 * l'`index.html` du paquet — et non sur celui du poste — pour que les liens
 * profonds de l'application Angular fonctionnent.
 */
export function serveIlms(response, pathname, ilmsRoot, method = "GET") {
  if (pathname === "/ilms") {
    response.writeHead(302, { Location: "/ilms/" });
    response.end();
    return true;
  }
  if (!pathname.startsWith("/ilms/")) return false;
  if (method !== "GET" && method !== "HEAD") {
    const body = JSON.stringify({ error: "Méthode non autorisée." });
    response.writeHead(405, {
      "Content-Type": "application/json; charset=utf-8",
      Allow: "GET, HEAD",
    });
    response.end(body);
    return true;
  }
  if (!ilmsRoot) {
    const page = missingBundlePage();
    response.writeHead(503, {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Length": Buffer.byteLength(page),
      "Cache-Control": "no-store",
    });
    response.end(method === "HEAD" ? undefined : page);
    return true;
  }

  const base = path.resolve(ilmsRoot);
  const index = path.join(base, "index.html");
  let relative = "";
  try {
    relative = decodeURIComponent(pathname.slice("/ilms/".length));
  } catch {
    relative = "";
  }
  let file = path.resolve(base, relative || "index.html");
  // Un chemin sortant du paquet est traité comme introuvable, jamais servi.
  if (file !== base && !file.startsWith(base + path.sep)) file = index;
  let stats = null;
  try {
    const candidate = fs.statSync(file);
    if (candidate.isFile()) stats = candidate;
  } catch {
    stats = null;
  }
  if (!stats) {
    file = index;
    stats = fs.statSync(file);
  }

  response.writeHead(200, {
    "Content-Type": contentTypeOf(file),
    "Content-Length": stats.size,
    "Cache-Control": cacheControlOf(file),
  });
  if (method === "HEAD") {
    response.end();
    return true;
  }
  fs.createReadStream(file).pipe(response);
  return true;
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
 * Relaie `/gateway/**` vers la passerelle ILMS. Le jeton d'authentification
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

    const suffix = url.pathname.slice("/gateway".length) || "/";
    const destination = `${target}${suffix}${url.search}`;
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
