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
 *   <li>rien du fonds du poste : ni livre, ni abonné, ni badge. Le poste a sa
 *       base, la passerelle a la sienne, et ce n'est pas la même vérité. La
 *       page résout ses tags auprès de la passerelle, comme elle doit.</li>
 * </ul>
 *
 * <p><b>L'écriture, ouverte le 21 octobre 2026.</b> L'agent est resté en
 * lecture seule tant qu'aucun écran n'encodait : la zone Matériel RFID de
 * l'ILMS le fait, et seul le poste parle à l'USB. Garder l'interdiction aurait
 * voulu dire encoder dans la fenêtre du poste et cataloguer dans celle de
 * l'ILMS, pour un geste unique — et l'opérateur l'aurait payé à chaque livre.
 *
 * <p>Ce que l'écriture ne relâche pas :
 *
 * <ul>
 *   <li>le contrôle d'origine reste la première chose faite, et il ne suffit
 *       plus : une écriture exige en plus la <b>clé d'appairage</b> du poste
 *       ({@link AGENT_KEY_HEADER}). Sans clé réglée, l'écriture est refusée —
 *       fermé par défaut, parce qu'un poste mis à jour sans qu'on le sache ne
 *       doit pas s'ouvrir tout seul ;</li>
 *   <li>l'agent écrit sur <b>le tag posé</b>, et seulement s'il est seul et
 *       porte un TID. Il ne choisit ni le contenu — l'EPC vient de la
 *       passerelle, qui tient la séquence — ni la connexion du lecteur, qui
 *       reste celle réglée sur le poste ;</li>
 *   <li>aucune écriture ne touche le catalogue local. Le poste dit ce que
 *       l'antenne a accepté ; c'est la passerelle qui l'enregistre.</li>
 * </ul>
 */

/** Origine servie par défaut : la passerelle, et elle seule. */
export const DEFAULT_AGENT_ORIGINS = "https://gateway.bibliotheque-ztf.org";

/** Chemin du flux de présence. */
export const AGENT_EVENTS_PATH = "/agent/reader/events";

/** Écriture d'un EPC sur le tag posé. */
export const AGENT_WRITE_PATH = "/agent/reader/write";

/** Désencodage du tag posé. */
export const AGENT_ERASE_PATH = "/agent/reader/erase";

/** En-tête qui porte la clé d'appairage du poste. */
export const AGENT_KEY_HEADER = "x-agent-key";

/**
 * Taille maximale d'un corps accepté.
 *
 * <p>4 Ko, comme l'ancien agent ILMS. Une demande d'écriture tient en une
 * cinquantaine d'octets ; au-delà, ce n'est plus une demande d'écriture.
 */
export const AGENT_MAX_BODY_BYTES = 4096;

/** EPC d'un tag désencodé : 24 zéros, comme sur le poste. */
export const AGENT_EMPTY_EPC = "0".repeat(24);

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

/**
 * Alphabet des clés d'appairage.
 *
 * <p>Ni O ni 0, ni I ni 1 : la clé se note sur un papier et se retape sur un
 * autre poste. Les mêmes exclusions que la clé de secours de la 3.0, et pour
 * la même raison — une clé recopiée de travers coûte un déplacement.
 */
const KEY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/**
 * Une clé d'appairage neuve.
 *
 * <p>24 caractères sur 32 possibles, soit 120 bits.
 *
 * <p>L'alphabet compte 32 symboles et 256 en est un multiple exact : chaque
 * octet tombe donc sur une lettre et une seule, sans biais, et le rejet
 * ci-dessous ne se déclenche jamais tel que l'alphabet est écrit aujourd'hui.
 * Il est là pour le jour où l'on retirera une lettre de plus — avec 31
 * symboles, un simple modulo rendrait les huit premières plus probables que
 * les autres, et une clé biaisée est plus courte qu'elle n'en a l'air.
 */
export function generateAgentKey(randomBytes, longueur = 24) {
  const limite = 256 - (256 % KEY_ALPHABET.length);
  let cle = "";
  while (cle.length < longueur) {
    for (const octet of randomBytes(longueur)) {
      if (octet >= limite) continue;
      cle += KEY_ALPHABET[octet % KEY_ALPHABET.length];
      if (cle.length === longueur) break;
    }
  }
  return cle;
}

/**
 * La clé d'appairage présentée est-elle celle du poste ?
 *
 * <p>Deux refus, et le premier compte autant que le second : <b>une clé non
 * réglée refuse tout</b>. Un poste mis à jour vers une version qui sait écrire
 * ne doit pas se mettre à accepter des écritures parce que personne n'a encore
 * ouvert ses réglages.
 *
 * <p>La comparaison est à durée constante. Une comparaison ordinaire s'arrête
 * au premier caractère qui diffère, et le temps de réponse laisse alors
 * deviner la clé caractère par caractère.
 */
export function agentKeyAccepted(presented, configured) {
  const attendue = String(configured ?? "").trim();
  const donnee = String(presented ?? "").trim();
  if (!attendue || !donnee) return false;
  if (attendue.length !== donnee.length) return false;
  let ecart = 0;
  for (let i = 0; i < attendue.length; i += 1) {
    ecart |= attendue.charCodeAt(i) ^ donnee.charCodeAt(i);
  }
  return ecart === 0;
}

/**
 * L'EPC à écrire, normalisé, ou "" s'il n'est pas écrivable.
 *
 * <p>96 bits, soit 24 caractères hexadécimaux : c'est le format local, et
 * écrire autre chose produirait un tag que personne ne sait relire. La valeur
 * n'est pas interprétée ici — l'agent ne sait pas ce qu'est un numéro
 * d'inventaire, et c'est la passerelle qui tient la séquence.
 */
export function normalizeEpcToWrite(value) {
  const brut = String(value ?? "").trim().toUpperCase();
  return /^[0-9A-F]{24}$/.test(brut) ? brut : "";
}

/**
 * Le tag sur lequel écrire, ou la raison de ne pas écrire.
 *
 * <p>Les trois refus de la procédure sûre, dans l'ordre où ils se présentent
 * au comptoir. Le troisième est le moins évident et le plus important : sans
 * TID, l'écriture ne peut pas être relue en filtrant la puce, donc pas
 * vérifiée — et une écriture non vérifiée associe un jour le mauvais livre.
 */
export function writeTarget(snapshot) {
  const tags = Array.isArray(snapshot?.tags) ? snapshot.tags : [];
  if (tags.length === 0) {
    return { error: "Aucun tag détecté. Posez un seul tag sur l'antenne." };
  }
  if (tags.length > 1) {
    return { error: "Plusieurs tags détectés. N'en laissez qu'un sur l'antenne." };
  }
  const tag = tags[0];
  const tid = String(tag?.tid ?? "").trim().toUpperCase();
  if (!tid) {
    return {
      error:
        "Le tag ne fournit pas de TID : l'écriture ne pourrait pas être relue, "
        + "et une écriture non vérifiée n'est jamais validée.",
    };
  }
  return { tag: { epc: String(tag?.epc ?? "").trim().toUpperCase(), tid } };
}

/**
 * Lit un corps JSON borné.
 *
 * <p>La borne est posée <b>pendant</b> la lecture et non après : attendre la
 * fin pour mesurer laisserait un client occuper la mémoire du poste avec un
 * corps sans fin.
 */
export function readAgentBody(request, limit = AGENT_MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const morceaux = [];
    let taille = 0;
    request.on("data", (morceau) => {
      taille += morceau.length;
      if (taille > limit) {
        reject(new Error("Demande trop volumineuse."));
        request.destroy();
        return;
      }
      morceaux.push(morceau);
    });
    request.on("end", () => {
      const texte = Buffer.concat(morceaux).toString("utf8").trim();
      if (!texte) return resolve({});
      try {
        const corps = JSON.parse(texte);
        resolve(corps && typeof corps === "object" ? corps : {});
      } catch {
        reject(new Error("Corps JSON invalide."));
      }
    });
    request.on("error", reject);
  });
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
