import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { LibraryDatabase } from "../lib/database.js";

test("crée un administrateur et authentifie une session sans exposer le hash", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-auth-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "test.db"));
    assert.equal(database.authStatus().setupRequired, true);

    const user = database.createUser({
      name: "Administrateur BCM",
      email: "ADMIN@BCM.TEST",
      password: "mot-de-passe-solide",
      role: "admin",
    });
    assert.deepEqual(user, {
      id: 1,
      name: "Administrateur BCM",
      email: "admin@bcm.test",
      role: "admin",
    });
    assert.equal(database.authStatus().setupRequired, false);
    assert.equal(database.authenticateUser("admin@bcm.test", "incorrect"), null);
    assert.equal(
      database.authenticateUser("ADMIN@BCM.TEST", "mot-de-passe-solide")?.id,
      user.id,
    );

    const session = database.createSession(user.id);
    const sessionUser = database.userForSession(session.token);
    assert.equal(sessionUser.email, "admin@bcm.test");
    assert.equal("password_hash" in sessionUser, false);

    database.deleteSession(session.token);
    assert.equal(database.userForSession(session.token), null);
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("refuse les comptes faibles ou dupliqués", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "biblio-auth-"));
  let database;
  try {
    database = new LibraryDatabase(path.join(directory, "test.db"));
    assert.throws(
      () => database.createUser({ name: "A", email: "x", password: "court" }),
      /nom doit contenir/,
    );
    database.createUser({
      name: "Utilisateur Test",
      email: "user@bcm.test",
      password: "mot-de-passe-solide",
    });
    assert.throws(
      () =>
        database.createUser({
          name: "Autre utilisateur",
          email: "USER@BCM.TEST",
          password: "autre-mot-de-passe",
        }),
      /déjà cette adresse/,
    );
  } finally {
    database?.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
