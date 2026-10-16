/**
 * Report d'un pret ou d'un retour local vers ILMS.
 *
 * Le poste reste maitre de sa base : le pret local est deja enregistre quand
 * on arrive ici, et rien de ce qui suit ne peut l'annuler. Une bibliotheque
 * qui prete pendant une coupure doit pouvoir continuer, et c'est le journal
 * durable qui rattrapera le serveur ensuite.
 *
 * D'ou la forme des retours : un etat, jamais une exception. L'appelant
 * l'affiche, il n'a pas a s'en remettre.
 */
import { IlmsClientError } from "./ilms-circulation-client.js";

/** Tag natif tel que le client l'attend, ou null si rien n'est encode. */
function tagOf(epc, tid) {
  const tag = {};
  if (typeof epc === "string" && epc.trim()) tag.epc = epc.trim();
  if (typeof tid === "string" && tid.trim()) tag.tid = tid.trim();
  return tag.epc || tag.tid ? tag : null;
}

function refused(code, message, extra = {}) {
  return {status: "refused", code, message, ...extra};
}

function skipped(code, message) {
  return {status: "skipped", code, message};
}

/**
 * Etat d'une demande restee au journal.
 *
 * Ce n'est pas un echec : la demande est enregistree durablement et partira.
 * Le distinguer d'un refus evite d'alarmer pour une coupure reseau.
 */
function queued(entry, error) {
  return {
    status: "queued",
    code: error?.code ?? "network",
    message: "Demande enregistree sur ce poste. Elle partira vers ILMS a la prochaine reprise.",
    entry_id: entry?.id ?? null,
  };
}

/**
 * Reporte un pret local vers ILMS.
 *
 * `operationId` est l'identifiant durable du pret local (`server_id`) : le
 * reutiliser rend l'envoi idempotent, donc rejouer apres une coupure ne cree
 * pas un second pret chez ILMS.
 */
export async function mirrorCheckout({client, session, book, subscriber, dueAt, operationId}) {
  if (!client || !session?.session) {
    return skipped("no_session", "Aucune session ILMS : le pret reste local.");
  }
  if (!session.active) {
    return skipped("expired", "Session ILMS expiree : le pret reste local. Reconnectez-vous.");
  }

  const card = tagOf(subscriber?.card_epc, subscriber?.card_tid);
  if (!card) {
    // Sans carte encodee, ILMS ne sait pas de qui il s'agit. Le dire ici
    // plutot que d'empiler des demandes qu'il refusera une par une.
    return skipped("no_card", "Cet abonne n'a pas de carte RFID encodee : le pret reste local.");
  }
  const copy = tagOf(book?.epc, book?.tid);
  if (!copy) {
    return skipped("no_tag", "Ce livre n'a pas d'etiquette RFID : le pret reste local.");
  }

  let member;
  let resolved;
  try {
    member = await client.resolveMember(card);
    resolved = await client.resolveCopy(copy);
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
    // La resolution ne s'enfile pas : elle ne modifie rien, et la rejouer plus
    // tard sur un tag qui a pu changer de main serait pire que de l'oublier.
    return refused(safe.code, `ILMS n'a pas reconnu la carte ou l'exemplaire : ${safe.message}`,
      {ilms_status: safe.status || null});
  }

  if (!member.eligible) {
    return refused("not_eligible",
      member.blocked_reason || "ILMS refuse le pret a cet abonne. Le pret reste local.");
  }
  if (!resolved.available_for_checkout) {
    return refused("not_available",
      "ILMS donne cet exemplaire comme indisponible. Le pret reste local.");
  }

  const payload = {
    operation_id: operationId,
    card: tagOf(card.epc, card.tid),
    copy: tagOf(copy.epc, copy.tid),
    preferred_return_date: new Date(dueAt).toISOString(),
    expected_card_id: member.card_id,
    expected_member_id: member.member_id,
    expected_copy_id: resolved.copy.id,
  };

  let entry;
  try {
    entry = client.enqueue({kind: "checkout", payload});
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("storage");
    return refused(safe.code, safe.message);
  }

  try {
    const loan = await client.retry(entry.id);
    return {status: "sent", message: `Pret enregistre dans ILMS (${loan.number}).`, loan};
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
    // Un refus ferme reste au journal comme le reste : il a pu etre cause par
    // un etat serveur passager, et l'operateur tranche depuis les reglages.
    return queued(entry, safe);
  }
}

/**
 * Reporte un retour local vers ILMS.
 *
 * Le pret a rendre est celui qu'ILMS connait, pas celui du poste : les deux
 * bases ont leurs propres identifiants, et seul le tag de l'exemplaire les
 * relie.
 */
export async function mirrorReturn({client, session, book}) {
  if (!client || !session?.session) {
    return skipped("no_session", "Aucune session ILMS : le retour reste local.");
  }
  if (!session.active) {
    return skipped("expired", "Session ILMS expiree : le retour reste local. Reconnectez-vous.");
  }

  const copy = tagOf(book?.epc, book?.tid);
  if (!copy) {
    return skipped("no_tag", "Ce livre n'a pas d'etiquette RFID : le retour reste local.");
  }

  let resolved;
  try {
    resolved = await client.resolveCopy(copy);
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
    return refused(safe.code, `ILMS n'a pas reconnu l'exemplaire : ${safe.message}`,
      {ilms_status: safe.status || null});
  }

  if (!resolved.active_loan) {
    // Deja rendu cote ILMS, ou jamais prete la-bas : enfiler un retour sans
    // pret le ferait refuser indefiniment.
    return skipped("no_loan", "ILMS ne connait aucun pret en cours sur cet exemplaire.");
  }

  let entry;
  try {
    entry = client.enqueue({
      kind: "return",
      payload: {copy: tagOf(copy.epc, copy.tid), loan_id: resolved.active_loan.id},
    });
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("storage");
    return refused(safe.code, safe.message);
  }

  try {
    const loan = await client.retry(entry.id);
    return {status: "sent", message: `Retour enregistre dans ILMS (${loan.number}).`, loan};
  } catch (error) {
    const safe = error instanceof IlmsClientError ? error : new IlmsClientError("network");
    return queued(entry, safe);
  }
}
