import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase, localDay } from "../lib/database.js";
import {
  generateBadgeEpc,
  generateCardEpc,
  isBadgeEpc,
  isCardEpc,
  isValidEpc,
} from "../lib/epc.js";

function freshDatabase() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-staff-"));
  return {
    database: new LibraryDatabase(path.join(directory, "test.db")),
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

const outbox = (database) =>
  database.pendingMutations().map((row) => `${row.entity_type}:${row.operation}`);

test("les badges du personnel ont leur propre format EPC", () => {
  const badge = generateBadgeEpc();
  assert.equal(isBadgeEpc(badge), true);
  assert.equal(isCardEpc(badge), false);
  assert.equal(isValidEpc(badge), false);
  assert.equal(isBadgeEpc(generateCardEpc()), false);
  assert.match(badge, /^42434D03[0-9A-F]{16}$/);
});

test("personnel : fiche, badge distinct des livres et des cartes, synchronisation", () => {
  const { database, cleanup } = freshDatabase();
  try {
    const alice = database.createStaff({
      staff_number: "p-01",
      name: "Alice Mbarga",
      position: "Bibliothécaire",
    });
    assert.equal(alice.staff_number, "P-01");
    assert.equal(isBadgeEpc(alice.badge_epc), true);
    assert.throws(
      () => database.createStaff({ staff_number: "P-01", name: "Doublon" }),
      /déjà attribué/,
    );
    assert.deepEqual(outbox(database), ["staff:upsert"]);
    const payload = JSON.parse(database.pendingMutations()[0].payload);
    assert.equal(payload.serverId, alice.server_id);
    assert.equal(payload.position, "Bibliothécaire");

    // Le TID d'un livre ou d'une carte ne peut pas devenir un badge.
    const book = database.createBook({ title: "Livre" });
    database.markTagged(book.id, "E28011112222333344445555");
    assert.throws(
      () => database.markBadgeTagged(alice.id, "E28011112222333344445555"),
      /livre/,
    );
    const subscriber = database.createSubscriber({ member_number: "AB-1", name: "Abonné" });
    database.markCardTagged(subscriber.id, "E280AAAABBBBCCCCDDDDEEEE");
    assert.throws(
      () => database.markBadgeTagged(alice.id, "E280AAAABBBBCCCCDDDDEEEE"),
      /carte/,
    );

    const tagged = database.markBadgeTagged(alice.id, "e2800000badge0001");
    assert.equal(tagged.badge_tid, "E2800000BADGE0001");
    assert.equal(
      database.recognizeBadge(alice.badge_epc, "E2800000BADGE0001")?.id,
      alice.id,
    );
    // EPC recopié sur un autre tag : refusé.
    assert.equal(database.recognizeBadge(alice.badge_epc, "E2800000FFFF"), null);
    // Un badge ne peut pas devenir un livre ou une carte.
    const other = database.createBook({ title: "Autre livre" });
    assert.throws(
      () => database.markTagged(other.id, "E2800000BADGE0001"),
      /badge/,
    );
    assert.throws(
      () => database.markCardTagged(subscriber.id, "E2800000BADGE0001"),
      /badge/,
    );

    const updated = database.updateStaff(alice.id, { name: "Alice M.", active: false });
    assert.equal(updated.active, 0);
    assert.equal(database.recognizeBadge(alice.badge_epc, "E2800000BADGE0001"), null);

    const acknowledged = database
      .pendingMutations()
      .filter((row) => row.entity_type === "staff")
      .map((row) => row.mutation_id);
    database.acknowledgeMutations(acknowledged);
    assert.equal(database.getStaff(alice.id).sync_state, "synced");

    assert.equal(database.deleteStaff(alice.id), true);
    assert.equal(
      database.pendingMutations().some(
        (row) => row.entity_type === "staff" && row.operation === "delete",
      ),
      true,
    );
  } finally {
    database.close();
    cleanup();
  }
});

test("reçoit le personnel, les passages et la fréquentation des portails", () => {
  const { database, cleanup } = freshDatabase();
  try {
    const now = new Date();
    const today = localDay(now);
    const badgeEpc = generateBadgeEpc();
    database.applyRemoteChanges(
      [
        {
          entityType: "staff_passage",
          operation: "upsert",
          entityId: "pass-1",
          staffPassage: {
            serverId: "pass-1",
            staffServerId: "staff-1",
            staffNumber: "P-01",
            staffName: "Bruno",
            direction: "in",
            passedAt: new Date(now.getTime() - 3600_000).toISOString(),
            gateId: "gate-1",
            gateName: "Entrée principale",
          },
        },
        {
          entityType: "staff",
          operation: "upsert",
          entityId: "staff-1",
          staff: {
            serverId: "staff-1",
            staffNumber: "p-01",
            name: "Bruno",
            badgeEpc,
            badgeTid: "E2800000BADGE0002",
            createdAt: now.toISOString(),
            updatedAt: now.toISOString(),
          },
        },
        {
          entityType: "gate_day",
          operation: "upsert",
          entityId: `gate-1:${today}`,
          gateDay: {
            serverId: `gate-1:${today}`,
            gateId: "gate-1",
            gateName: "Entrée principale",
            day: today,
            entries: 42,
            exits: 40,
            alarms: 2,
            updatedAt: now.toISOString(),
          },
        },
        {
          entityType: "gate_day",
          operation: "upsert",
          entityId: `gate-2:${today}`,
          gateDay: {
            serverId: `gate-2:${today}`,
            gateId: "gate-2",
            gateName: "Sortie jardin",
            day: today,
            entries: 3,
            exits: 5,
            alarms: 0,
            updatedAt: now.toISOString(),
          },
        },
      ],
      10,
    );
    const [bruno] = database.listStaff("");
    assert.equal(bruno.staff_number, "P-01");
    assert.equal(bruno.last_direction, "in");
    assert.equal(database.recognizeBadge(badgeEpc, "E2800000BADGE0002")?.name, "Bruno");
    // Les changements reçus ne repartent pas vers le serveur.
    assert.deepEqual(outbox(database), []);

    const { passages, presence } = {
      passages: database.listStaffPassages({ day: today }),
      presence: database.staffPresence(today),
    };
    assert.equal(passages.length, 1);
    assert.equal(passages[0].staff_id, bruno.id);
    assert.equal(presence[0].last_direction, "in");

    const stats = database.gateStats({ from: today, to: today });
    assert.deepEqual(
      [stats.today.entries, stats.today.exits, stats.today.alarms],
      [45, 45, 2],
    );
    assert.equal(stats.today.gates.length, 2);
  } finally {
    database.close();
    cleanup();
  }
});
