import { DatabaseSync } from "node:sqlite";
import {
  createHash,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { formatAccession, generateEpc } from "./epc.js";

const BOOK_FIELDS = [
  "title",
  "author",
  "isbn",
  "publisher",
  "publication_year",
  "category",
  "shelf",
  "notes",
];

function cleanText(value, maxLength = 500) {
  return String(value ?? "")
    .trim()
    .slice(0, maxLength);
}

export class LibraryDatabase {
  constructor(filePath) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    this.db = new DatabaseSync(filePath);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
    this.migrate();
  }

  migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        accession TEXT NOT NULL UNIQUE,
        epc TEXT NOT NULL UNIQUE,
        tid TEXT UNIQUE,
        title TEXT NOT NULL,
        author TEXT NOT NULL DEFAULT '',
        isbn TEXT NOT NULL DEFAULT '',
        publisher TEXT NOT NULL DEFAULT '',
        publication_year TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '',
        shelf TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'a_encoder' CHECK(status IN ('a_encoder', 'encode', 'indisponible')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        tagged_at TEXT
      );
      CREATE TABLE IF NOT EXISTS activity (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        result TEXT NOT NULL,
        book_id INTEGER,
        message TEXT NOT NULL,
        epc TEXT,
        tid TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE SET NULL
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL UNIQUE COLLATE NOCASE,
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'operateur' CHECK(role IN ('admin', 'operateur')),
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS user_sessions (
        token_hash TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_books_title ON books(title);
      CREATE INDEX IF NOT EXISTS idx_activity_created ON activity(created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_user_sessions_expiry ON user_sessions(expires_at);
    `);
    const bookColumns = new Set(
      this.db
        .prepare("PRAGMA table_info(books)")
        .all()
        .map((column) => column.name),
    );
    if (!bookColumns.has("import_key"))
      this.db.exec("ALTER TABLE books ADD COLUMN import_key TEXT;");
    this.db.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_books_import_key ON books(import_key) WHERE import_key IS NOT NULL;",
    );
    this.db.exec("UPDATE books SET tid = NULL WHERE tid = '';");
  }

  listBooks({ search = "", status = "tous", limit = null, offset = 0 } = {}) {
    const terms = [`1 = 1`];
    const params = {};
    if (search.trim()) {
      terms.push(
        `(title LIKE :search OR author LIKE :search OR isbn LIKE :search OR accession LIKE :search OR epc LIKE :search)`,
      );
      params.search = `%${search.trim()}%`;
    }
    if (["a_encoder", "encode", "indisponible"].includes(status)) {
      terms.push("status = :status");
      params.status = status;
    }
    const pagination = limit == null ? "" : " LIMIT :limit OFFSET :offset";
    if (limit != null) {
      params.limit = Math.max(1, Math.min(Number(limit) || 200, 1000));
      params.offset = Math.max(0, Number(offset) || 0);
    }
    return this.db
      .prepare(
        `SELECT * FROM books WHERE ${terms.join(" AND ")} ORDER BY id DESC${pagination}`,
      )
      .all(params);
  }

  countBooks({ search = "", status = "tous" } = {}) {
    const terms = ["1 = 1"];
    const params = {};
    if (search.trim()) {
      terms.push(
        `(title LIKE :search OR author LIKE :search OR isbn LIKE :search OR accession LIKE :search OR epc LIKE :search)`,
      );
      params.search = `%${search.trim()}%`;
    }
    if (["a_encoder", "encode", "indisponible"].includes(status)) {
      terms.push("status = :status");
      params.status = status;
    }
    return Number(
      this.db
        .prepare(
          `SELECT COUNT(*) AS total FROM books WHERE ${terms.join(" AND ")}`,
        )
        .get(params).total,
    );
  }

  getBook(id) {
    return this.db.prepare("SELECT * FROM books WHERE id = ?").get(Number(id));
  }

  recognizeTag(epc, tid) {
    const normalizedEpc = cleanText(epc, 128).toUpperCase();
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    let book = normalizedEpc
      ? this.db.prepare("SELECT * FROM books WHERE epc = ?").get(normalizedEpc)
      : null;
    if (!book && normalizedTid)
      book = this.db
        .prepare("SELECT * FROM books WHERE tid = ?")
        .get(normalizedTid);
    if (!book) return null;

    if (normalizedTid && !book.tid) {
      const conflict = this.db
        .prepare("SELECT id FROM books WHERE tid = ? AND id <> ?")
        .get(normalizedTid, book.id);
      if (!conflict) {
        const now = new Date().toISOString();
        this.db
          .prepare(
            `
          UPDATE books SET tid=?, status='encode', tagged_at=COALESCE(tagged_at, ?), updated_at=? WHERE id=?
        `,
          )
          .run(normalizedTid, now, now, book.id);
        book = this.getBook(book.id);
      }
    }
    return book;
  }

  createBook(input) {
    const title = cleanText(input.title, 240);
    if (!title) throw new Error("Le titre est obligatoire.");
    const now = new Date().toISOString();
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const year = new Date().getFullYear();
      const values = Object.fromEntries(
        BOOK_FIELDS.map((field) => [
          field,
          cleanText(input[field], field === "notes" ? 2000 : 240),
        ]),
      );
      values.title = title;
      const result = this.db
        .prepare(
          `
        INSERT INTO books (accession, epc, title, author, isbn, publisher, publication_year, category, shelf, notes, created_at, updated_at)
        VALUES (:accession, :epc, :title, :author, :isbn, :publisher, :publication_year, :category, :shelf, :notes, :created_at, :updated_at)
      `,
        )
        .run({
          accession: `PENDING-${Date.now()}-${Math.random()}`,
          epc: `PENDING-${Date.now()}-${Math.random()}`,
          ...values,
          created_at: now,
          updated_at: now,
        });
      const next = Number(result.lastInsertRowid);
      const accession = formatAccession(year, next);
      const epc = generateEpc(year, next);
      this.db
        .prepare("UPDATE books SET accession=?, epc=? WHERE id=?")
        .run(accession, epc, next);
      this.addActivity(
        "catalogue",
        "succes",
        next,
        "Livre ajouté au catalogue",
        epc,
        null,
        now,
      );
      this.db.exec("COMMIT");
      return this.getBook(next);
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  importBooks(records) {
    const exists = this.db.prepare("SELECT id FROM books WHERE import_key = ?");
    const insert = this.db.prepare(`
      INSERT INTO books (import_key, accession, epc, title, author, isbn, publisher, publication_year,
        category, shelf, notes, created_at, updated_at)
      VALUES (:import_key, :accession, :epc, :title, :author, :isbn, :publisher, :publication_year,
        :category, :shelf, :notes, :created_at, :updated_at)
    `);
    const finalize = this.db.prepare(
      "UPDATE books SET accession=?, epc=? WHERE id=?",
    );
    const now = new Date().toISOString();
    let imported = 0;
    let duplicates = 0;
    let rejected = 0;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const record of records) {
        const key = cleanText(record.import_key, 128);
        if (!key || exists.get(key)) {
          duplicates++;
          continue;
        }
        const title = cleanText(record.title, 240);
        if (!title) {
          rejected++;
          continue;
        }
        try {
          const result = insert.run({
            import_key: key,
            accession: `PENDING-${Date.now()}-${Math.random()}`,
            epc: `PENDING-${Date.now()}-${Math.random()}`,
            title,
            author: cleanText(record.author, 240),
            isbn: cleanText(record.isbn, 240),
            publisher: cleanText(record.publisher, 240),
            publication_year: cleanText(record.publication_year, 240),
            category: cleanText(record.category, 240),
            shelf: cleanText(record.shelf, 240),
            notes: cleanText(record.notes, 2000),
            created_at: now,
            updated_at: now,
          });
          const id = Number(result.lastInsertRowid);
          const year = new Date().getFullYear();
          finalize.run(formatAccession(year, id), generateEpc(year, id), id);
          imported++;
        } catch {
          rejected++;
        }
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    this.addActivity(
      "catalogue",
      "succes",
      null,
      `Import XLSX : ${imported} livre(s), ${duplicates} doublon(s), ${rejected} rejet(s)`,
    );
    return { imported, duplicates, rejected };
  }

  updateBook(id, input) {
    const current = this.getBook(id);
    if (!current) return null;
    const title = cleanText(input.title, 240);
    if (!title) throw new Error("Le titre est obligatoire.");
    const values = Object.fromEntries(
      BOOK_FIELDS.map((field) => [
        field,
        cleanText(input[field], field === "notes" ? 2000 : 240),
      ]),
    );
    values.title = title;
    this.db
      .prepare(
        `
      UPDATE books SET title=:title, author=:author, isbn=:isbn, publisher=:publisher,
        publication_year=:publication_year, category=:category, shelf=:shelf, notes=:notes, updated_at=:updated_at
      WHERE id=:id
    `,
      )
      .run({ ...values, updated_at: new Date().toISOString(), id: Number(id) });
    return this.getBook(id);
  }

  deleteBook(id) {
    const current = this.getBook(id);
    if (!current) return false;
    this.db.prepare("DELETE FROM books WHERE id = ?").run(Number(id));
    this.addActivity(
      "catalogue",
      "succes",
      null,
      `Livre supprimé : ${current.accession}`,
      current.epc,
      current.tid,
    );
    return true;
  }

  markTagged(id, tid) {
    const book = this.getBook(id);
    if (!book) throw new Error("Livre introuvable.");
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    const existing = this.db
      .prepare("SELECT id, accession FROM books WHERE tid=? AND id<>?")
      .get(normalizedTid, Number(id));
    if (existing)
      throw new Error(`Ce tag est déjà lié au livre ${existing.accession}.`);
    const now = new Date().toISOString();
    this.db
      .prepare(
        "UPDATE books SET tid=?, status='encode', tagged_at=?, updated_at=? WHERE id=?",
      )
      .run(normalizedTid, now, now, Number(id));
    this.addActivity(
      "ecriture",
      "succes",
      Number(id),
      "Tag écrit et vérifié",
      book.epc,
      tid,
      now,
    );
    return this.getBook(id);
  }

  markUntagged(id) {
    const book = this.getBook(id);
    if (!book) throw new Error("Livre introuvable.");
    if (book.status !== "encode" || !book.tid)
      throw new Error("Ce livre n'a pas de tag encodé associé.");
    const now = new Date().toISOString();
    this.db
      .prepare(
        "UPDATE books SET tid=NULL, status='a_encoder', tagged_at=NULL, updated_at=? WHERE id=?",
      )
      .run(now, Number(id));
    this.addActivity(
      "desencodage",
      "succes",
      Number(id),
      "Tag désencodé et vérifié",
      book.epc,
      book.tid,
      now,
    );
    return this.getBook(id);
  }

  addActivity(
    type,
    result,
    bookId,
    message,
    epc = null,
    tid = null,
    createdAt = new Date().toISOString(),
  ) {
    this.db
      .prepare(
        `INSERT INTO activity (type, result, book_id, message, epc, tid, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(type, result, bookId, cleanText(message, 500), epc, tid, createdAt);
  }

  activity(limit = 100) {
    return this.db
      .prepare(
        `
      SELECT activity.*, books.title, books.accession
      FROM activity LEFT JOIN books ON books.id = activity.book_id
      ORDER BY activity.id DESC LIMIT ?
    `,
      )
      .all(Math.max(1, Math.min(Number(limit) || 100, 500)));
  }

  dashboard() {
    const counts = this.db
      .prepare(
        `
      SELECT COUNT(*) AS total,
        SUM(CASE WHEN status='encode' THEN 1 ELSE 0 END) AS tagged,
        SUM(CASE WHEN status='a_encoder' THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN date(created_at)=date('now') THEN 1 ELSE 0 END) AS today
      FROM books
    `,
      )
      .get();
    return {
      counts,
      recentBooks: this.db
        .prepare("SELECT * FROM books ORDER BY id DESC LIMIT 6")
        .all(),
      recentActivity: this.activity(8),
    };
  }

  getSetting(key, fallback = "") {
    return (
      this.db.prepare("SELECT value FROM settings WHERE key = ?").get(key)
        ?.value ?? fallback
    );
  }

  setSettings(settings) {
    const statement = this.db.prepare(
      "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    );
    this.db.exec("BEGIN");
    try {
      for (const [key, value] of Object.entries(settings))
        statement.run(key, cleanText(value, 500));
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  settings() {
    const rows = this.db.prepare("SELECT key, value FROM settings").all();
    return Object.fromEntries(rows.map((row) => [row.key, row.value]));
  }

  authStatus() {
    return {
      setupRequired:
        Number(this.db.prepare("SELECT COUNT(*) AS total FROM users").get().total) === 0,
    };
  }

  createUser({ name, email, password, role = "operateur" }) {
    const normalizedName = cleanText(name, 120);
    const normalizedEmail = cleanText(email, 240).toLowerCase();
    const normalizedRole = role === "admin" ? "admin" : "operateur";
    if (normalizedName.length < 2) throw new Error("Le nom doit contenir au moins 2 caractères.");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail))
      throw new Error("L’adresse e-mail est invalide.");
    if (String(password || "").length < 8)
      throw new Error("Le mot de passe doit contenir au moins 8 caractères.");

    const salt = randomBytes(16);
    const passwordHash = scryptSync(String(password), salt, 64);
    const now = new Date().toISOString();
    let result;
    try {
      result = this.db
        .prepare(
          `INSERT INTO users(name, email, password_hash, password_salt, role, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          normalizedName,
          normalizedEmail,
          passwordHash.toString("hex"),
          salt.toString("hex"),
          normalizedRole,
          now,
          now,
        );
    } catch (error) {
      if (String(error.message).includes("UNIQUE"))
        throw new Error("Un compte utilise déjà cette adresse e-mail.");
      throw error;
    }
    return this.getUser(Number(result.lastInsertRowid));
  }

  authenticateUser(email, password) {
    const normalizedEmail = cleanText(email, 240).toLowerCase();
    const user = this.db
      .prepare("SELECT * FROM users WHERE email = ? AND active = 1")
      .get(normalizedEmail);
    if (!user) return null;
    const expected = Buffer.from(user.password_hash, "hex");
    const actual = scryptSync(
      String(password || ""),
      Buffer.from(user.password_salt, "hex"),
      expected.length,
    );
    if (!timingSafeEqual(expected, actual)) return null;
    return this.safeUser(user);
  }

  createSession(userId, lifetimeMs = 12 * 60 * 60 * 1000) {
    const token = randomBytes(32).toString("base64url");
    const tokenHash = createHash("sha256").update(token).digest("hex");
    const now = new Date();
    const expiresAt = new Date(now.getTime() + lifetimeMs);
    this.db
      .prepare(
        "INSERT INTO user_sessions(token_hash, user_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
      )
      .run(tokenHash, Number(userId), expiresAt.toISOString(), now.toISOString());
    return { token, expiresAt: expiresAt.toISOString() };
  }

  userForSession(token) {
    if (!token) return null;
    this.db
      .prepare("DELETE FROM user_sessions WHERE expires_at <= ?")
      .run(new Date().toISOString());
    const tokenHash = createHash("sha256").update(String(token)).digest("hex");
    const user = this.db
      .prepare(
        `SELECT users.* FROM user_sessions
         JOIN users ON users.id = user_sessions.user_id
         WHERE user_sessions.token_hash = ? AND user_sessions.expires_at > ? AND users.active = 1`,
      )
      .get(tokenHash, new Date().toISOString());
    return user ? this.safeUser(user) : null;
  }

  deleteSession(token) {
    if (!token) return;
    const tokenHash = createHash("sha256").update(String(token)).digest("hex");
    this.db.prepare("DELETE FROM user_sessions WHERE token_hash = ?").run(tokenHash);
  }

  getUser(id) {
    const user = this.db.prepare("SELECT * FROM users WHERE id = ?").get(Number(id));
    return user ? this.safeUser(user) : null;
  }

  safeUser(user) {
    return {
      id: Number(user.id),
      name: user.name,
      email: user.email,
      role: user.role,
    };
  }

  close() {
    this.db.close();
  }
}
