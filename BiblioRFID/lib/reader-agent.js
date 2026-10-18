/**
 * L'agent lecteur local.
 *
 * <p>Le poste n'est plus qu'un service matériel, mais il reste le seul à
 * pouvoir parler au lecteur : une page servie par la passerelle ne touche pas
 * l'USB. L'agent est ce par quoi cette page voit l'antenne, et rien d'autre.
 *
 * <p>C'est une surface <b>publique</b> — elle n'a pas la session du poste,
 * puisque l'opérateur est authentifié par la passerelle, pas ici. Elle est
 * donc réduite au strict minimum et gardée à l'entrée :
 *
 * <ul>
 *   <li>une origine autorisée, et une seule à la fois : HTTPS exacte, ou HTTP
 *       <b>uniquement</b> en local. Un agent ouvert à n'importe quelle origine
 *       devient le relais de n'importe qui ;</li>
 *   <li>en lecture seule : la présence des tags, l'état du lecteur. Aucune
 *       écriture, aucun encodage, aucun accès au catalogue local ;</li>
 *   <li>rien du fonds du poste : ni livre, ni abonné, ni badge. Le poste a sa
 *       base, la passerelle a la sienne, et ce n'est pas la même vérité. La
 *       page résout ses tags auprès de la passerelle, comme elle doit.</li>
 * </ul>
 */

/** Origine servie par défaut : la passerelle, et elle seule. */
export const DEFAULT_AGENT_ORIGINS = "https://gateway.bibliotheque-ztf.org";

/** Chemin du flux de présence. */
export const AGENT_EVENTS_PATH = "/agent/reader/events";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

/**
 * Normalise une origine, ou la refuse.
 *
 * <p>HTTPS passe ; HTTP ne passe qu'en local, parce qu'un flux en clair sur le
 * réseau laisserait lire les identifiants de tags de toute la bibliothèque.
 * Une URL qui porte un chemin, une requête, un fragment ou des identifiants
 * n'est pas une origine : la refuser évite qu'un `https://passerelle/..%2f`
 * se fasse passer pour l'origine attendue.
 *
 * @returns {string} l'origine normalisée, ou "" si elle est refusée.
 */
export function normalizeAgentOrigin(value) {
  const brut = String(value ?? "").trim();
  if (!brut || CONTROL_CHARACTERS.test(brut)) return "";

  let url;
  try {
    url = new URL(brut);
  } catch {
    return "";
  }

  if (url.username || url.password) return "";
  if (url.pathname !== "/" || url.search || url.hash) return "";
  if (url.protocol === "https:") return url.origin;
  if (url.protocol === "http:" && LOCAL_HOSTS.has(url.hostname)) return url.origin;
  return "";
}

/**
 * La liste des origines autorisées, telle qu'elle est réglée.
 *
 * <p>Séparées par des virgules ou des espaces. Une entrée refusée est écartée
 * en silence : un réglage abîmé ne doit pas fermer l'agent pour les autres,
 * mais il ne doit sûrement pas ouvrir celle-là.
 */
export function parseAgentOrigins(raw) {
  const liste = String(raw ?? "")
    .split(/[\s,;]+/)
    .map(normalizeAgentOrigin)
    .filter(Boolean);
  return [...new Set(liste)];
}

/**
 * L'origine à renvoyer pour cette demande, ou "" si elle n'est pas autorisée.
 *
 * <p>On renvoie l'origine demandée, jamais `*` : avec `*`, n'importe quelle
 * page du web lirait le flux.
 */
export function allowOrigin(requestOrigin, allowed) {
  const origine = normalizeAgentOrigin(requestOrigin);
  if (!origine) return "";
  return allowed.includes(origine) ? origine : "";
}

/**
 * L'instantané, réduit aux faits matériels.
 *
 * <p>C'est la frontière : le poste dit ce que l'antenne voit, la passerelle dit
 * ce que cela signifie. Laisser passer le livre reconnu par la base locale
 * ferait apparaître à l'écran un titre que la passerelle ignore, ou pire, un
 * titre périmé — le poste n'est plus la référence du catalogue.
 */
export function publicSnapshot(snapshot) {
  const tags = Array.isArray(snapshot?.tags) ? snapshot.tags : [];
  return {
    ok: true,
    count: tags.length,
    tags: tags.map((tag) => ({
      epc: String(tag?.epc ?? ""),
      tid: String(tag?.tid ?? ""),
      rssi: Number(tag?.rssi ?? 0),
      antenna: Number(tag?.antenna ?? 0),
    })),
    reader: {
      connected: snapshot?.reader?.connected === true,
      status: String(snapshot?.reader?.status ?? ""),
      reader: String(snapshot?.reader?.reader ?? ""),
    },
    presenceSessionId: String(snapshot?.presenceSessionId ?? ""),
  };
}

/** Les en-têtes d'une réponse de l'agent à une origine autorisée. */
export function agentHeaders(origin, contentType) {
  return {
    "Content-Type": contentType,
    "Cache-Control": "no-cache, no-store",
    // L'origine exacte, et `Vary` pour qu'un cache intermédiaire ne serve pas
    // à l'une la réponse préparée pour l'autre.
    "Access-Control-Allow-Origin": origin,
    Vary: "Origin",
  };
}
