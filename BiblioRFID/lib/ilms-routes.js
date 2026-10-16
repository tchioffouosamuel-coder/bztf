/**
 * Routes HTTP de la session ILMS du poste. Montees par `server.js` derriere la
 * meme session utilisateur que le reste de l'API : se connecter a ILMS depuis
 * ce poste suppose d'abord d'etre entre dans le poste.
 *
 * Le jeton ILMS ne sort jamais d'ici. Aucune reponse ne le porte, et l'UI n'en
 * a pas besoin : les demandes partent du serveur local, pas du navigateur.
 */
import { IlmsClientError } from "./ilms-circulation-client.js";

/**
 * Code HTTP d'un refus natif.
 *
 * Un code ILMS porte deja la distinction qui compte pour l'operateur : ce qui
 * se reessaie, ce qui demande une correction, et ce qui ne passera jamais. On
 * la rend au lieu de tout aplatir sur 500.
 */
function statusFor(error) {
  if (!(error instanceof IlmsClientError)) return 500;
  switch (error.code) {
    case "input":
      return 400;
    case "auth":
    case "password_change":
      return 401;
    case "no_library":
    case "scope":
      return 403;
    case "signin":
      return error.status >= 400 && error.status <= 599 ? error.status : 502;
    case "capacity":
      return 409;
    case "busy":
      return 423;
    case "storage":
      return 503;
    default:
      // `denied` porte le code rendu par ILMS ; `network` et `response` n'en
      // ont pas et valent 502 : la demande reste au journal.
      return error.status >= 400 && error.status <= 599 ? error.status : 502;
  }
}

function fail(json, response, error) {
  const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
  return json(response, statusFor(safe), {
    error: safe.message,
    code: safe.code,
    // Laquelle des trois etapes a refuse : le jeton client, la connexion de
    // l'utilisateur, ou la liste des bibliotheques. Absent hors connexion.
    ...(safe.stage ? {stage: safe.stage} : {}),
    ...(safe.status ? {ilms_status: safe.status} : {}),
  });
}

/**
 * Etat complet rendu a l'interface : la session et le journal ensemble.
 *
 * Les deux se lisent toujours cote a cote — une session valable avec un
 * journal qui s'accumule est le cas qu'il faut voir, et deux appels separes
 * laisseraient l'ecran afficher un instant l'un sans l'autre.
 */
function overview(session, client) {
  const state = session.state;
  if (!client) return {...state, journal: null, journal_error: true};
  if (!session.session) return {...state, journal: null};
  try {
    const entries = client.list();
    return {
      ...state,
      journal: {
        total: entries.length,
        pending: entries.filter(entry => entry.state === "pending").length,
        blocked: entries.filter(entry => entry.state === "blocked").length,
        entries: entries.map(entry => ({
          id: entry.id,
          kind: entry.kind,
          state: entry.state,
          attempts: entry.attempts,
          last_status: entry.last_status ?? null,
          created_at: entry.created_at,
          updated_at: entry.updated_at,
        })),
      },
    };
  } catch {
    // Un journal illisible n'efface pas la session : l'ecran doit pouvoir le
    // dire plutot que de paraitre deconnecte.
    return {...state, journal: null, journal_error: true};
  }
}

export async function handleIlmsRequest({request, response, url, session, client, json, readBody}) {
  const pathname = url.pathname;
  const method = request.method;

  // Sans journal, rien ne peut etre acquitte : seules les routes de session
  // restent utiles, et elles disent la panne via `journal_error`.
  const needsJournal = pathname.startsWith("/api/ilms/journal");
  if (!client && needsJournal) return fail(json, response, new IlmsClientError("storage"));

  if (method === "GET" && pathname === "/api/ilms/session") {
    return json(response, 200, overview(session, client));
  }

  if (method === "POST" && pathname === "/api/ilms/session") {
    const input = await readBody(request);
    try {
      await session.signIn({
        gatewayUrl: input.gateway_url,
        username: input.username,
        password: input.password,
        clientId: input.client_id,
        clientSecret: input.client_secret,
      });
    } catch (error) {
      return fail(json, response, error);
    }
    return json(response, 200, overview(session, client));
  }

  if (method === "DELETE" && pathname === "/api/ilms/session") {
    session.signOut();
    return json(response, 200, overview(session, client));
  }

  if (method === "PUT" && pathname === "/api/ilms/session/library") {
    const input = await readBody(request);
    try {
      session.selectLibrary(input.library_id);
    } catch (error) {
      return fail(json, response, error);
    }
    return json(response, 200, overview(session, client));
  }

  const retry = pathname.match(/^\/api\/ilms\/journal\/([^/]+)\/retry$/);
  if (retry && method === "POST") {
    try {
      const loan = await client.retry(decodeURIComponent(retry[1]));
      return json(response, 200, {loan, ...overview(session, client)});
    } catch (error) {
      return fail(json, response, error);
    }
  }

  const discard = pathname.match(/^\/api\/ilms\/journal\/([^/]+)$/);
  if (discard && method === "DELETE") {
    // Abandonner une demande ne l'annule pas chez ILMS : elle a pu y etre
    // enregistree avant que la reponse se perde. La confirmation explicite
    // evite qu'un clic fasse disparaitre un pret qui existe.
    if (url.searchParams.get("confirm") !== "local-discard") {
      return json(response, 400, {
        error: "Abandon local a confirmer : la demande peut deja exister dans ILMS.",
        code: "input",
      });
    }
    try {
      client.discard(decodeURIComponent(discard[1]));
      return json(response, 200, {removed_locally: true, cancelled_in_ilms: false, ...overview(session, client)});
    } catch (error) {
      return fail(json, response, error);
    }
  }

  return json(response, 404, {error: "Route ILMS inconnue."});
}
