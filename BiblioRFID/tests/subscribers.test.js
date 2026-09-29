import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase } from "../lib/database.js";

function freshDatabase() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-subscribers-"));
  return {
    database: new LibraryDatabase(path.join(directory, "test.db")),
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

const outbox = (database) =>
  database.pendingMutations().map((row) => `${row.entity_type}:${row.operation}`);

test("CRUD des abonnés avec synchronisation", () => {
  const { database, cleanup } = freshDatabase();
  try {
    const created = database.createSubscriber({
      member_number: "ab-10",
      name: "Awa Nkolo",
      phone: "690000000",
    });
    assert.equal(created.member_number, "AB-10");
    assert.throws(
      () => database.createSubscriber({ member_number: "AB-10", name: "Doublon" }),
      /existe déjà/,
    );
    assert.throws(
      () => database.createSubscriber({ member_number: "AB-11", name: "" }),
      /nom/,
    );

    const updated = database.updateSubscriber(created.id, {
      name: "Awa N.",
      email: "awa@bztf.org",
      phone: "",
      active: false,
    });
    assert.equal(updated.name, "Awa N.");
    assert.equal(updated.active, 0);
    assert.equal(updated.member_number, "AB-10");
    assert.equal(database.updateSubscriber(9999, { name: "X" }), null);
    const payload = JSON.parse(
      database.pendingMutations().find((row) => row.entity_type === "subscriber")
        .payload,
    );
    assert.equal(payload.active, false);
    assert.equal(payload.email, "awa@bztf.org");

    const found = database.listSubscribers("awa");
    assert.equal(found.length, 1);
    assert.equal(found[0].overdue_loans, 0);

    assert.equal(database.deleteSubscriber(created.id), true);
    assert.equal(database.getSubscriber(created.id), null);
    assert.ok(outbox(database).includes("subscriber:delete"));
  } finally {
    database.close();
    cleanup();
  }
});

test("CRUD des abonnements et règles de suppression", () => {
  const { database, cleanup } = freshDatabase();
  try {
    const subscriber = database.createSubscriber({ member_number: "AB-20", name: "Paul" });
    assert.throws(
      () =>
        database.createSubscription(subscriber.id, {
          starts_at: "2026-10-01",
          ends_at: "2026-09-01",
        }),
      /suivre son début/,
    );
    assert.throws(
      () =>
        database.createSubscription(subscriber.id, {
          starts_at: "2026-01-01",
          ends_at: "2027-01-01",
          status: "gratuit",
        }),
      /Statut/,
    );
    const subscription = database.createSubscription(subscriber.id, {
      starts_at: "2026-01-01T00:00:00Z",
      ends_at: "2027-01-01T00:00:00Z",
    });
    assert.equal(subscription.status, "active");
    assert.ok(subscription.server_id);
    assert.ok(outbox(database).includes("subscription:upsert"));

    const suspended = database.updateSubscription(subscription.id, {
      status: "suspended",
    });
    assert.equal(suspended.status, "suspended");
    assert.equal(suspended.ends_at, "2027-01-01T00:00:00.000Z");
    const syncPayload = JSON.parse(
      database
        .pendingMutations()
        .find((row) => row.entity_type === "subscription").payload,
    );
    assert.equal(syncPayload.status, "suspended");
    assert.equal(syncPayload.memberNumber, "AB-20");

    // Un abonné avec un emprunt ne peut pas être supprimé.
    const book = database.createBook({ title: "Livre" });
    database.borrowBook(book.id, {
      member_number: "AB-20",
      name: "Paul",
      due_at: new Date(Date.now() + 86400000).toISOString(),
    });
    assert.throws(() => database.deleteSubscriber(subscriber.id), /Désactivez/);

    const details = database.getSubscriberDetails(subscriber.id);
    assert.equal(details.subscriptions.length, 2);
    assert.equal(details.loans.length, 1);
    assert.equal(details.loans[0].book_title, "Livre");

    // Supprimer l'abonnement d'un emprunt garde l'emprunt, sans abonnement.
    const loanSubscription = details.loans[0].subscription_id;
    assert.equal(database.deleteSubscription(loanSubscription), true);
    assert.equal(
      database.getSubscriberDetails(subscriber.id).loans[0].subscription_id,
      null,
    );
    assert.ok(outbox(database).includes("subscription:delete"));
    const loanPayload = JSON.parse(
      database.pendingMutations().find((row) => row.entity_type === "loan").payload,
    );
    assert.equal(loanPayload.subscriptionServerId, null);
  } finally {
    database.close();
    cleanup();
  }
});
