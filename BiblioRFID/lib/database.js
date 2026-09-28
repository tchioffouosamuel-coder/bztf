import { DatabaseSync } from "node:sqlite";
import {
  createHash,
  randomBytes,
  randomUUID,
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
      CREATE TABLE IF NOT EXISTS sync_outbox (
        mutation_id TEXT PRIMARY KEY,
        operation TEXT NOT NULL,
        entity_id TEXT NOT NULL UNIQUE,
        payload TEXT,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sync_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subscribers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        member_number TEXT NOT NULL UNIQUE COLLATE NOCASE,
        name TEXT NOT NULL,
        email TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subscriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subscriber_id INTEGER NOT NULL,
        starts_at TEXT NOT NULL,
        ends_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'expired', 'suspended')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(subscriber_id) REFERENCES subscribers(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS loans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        subscriber_id INTEGER NOT NULL,
        subscription_id INTEGER,
        borrowed_at TEXT NOT NULL,
        due_at TEXT NOT NULL,
        returned_at TEXT,
        status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'returned', 'late')),
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE RESTRICT,
        FOREIGN KEY(subscriber_id) REFERENCES subscribers(id) ON DELETE RESTRICT,
        FOREIGN KEY(subscription_id) REFERENCES subscriptions(id) ON DELETE SET NULL
      );
      CREATE INDEX IF NOT EXISTS idx_subscribers_name ON subscribers(name);
      CREATE INDEX IF NOT EXISTS idx_subscriptions_subscriber ON subscriptions(subscriber_id, ends_at DESC);
      CREATE INDEX IF NOT EXISTS idx_loans_book ON loans(book_id, returned_at);
      CREATE INDEX IF NOT EXISTS idx_loans_subscriber ON loans(subscriber_id, returned_at);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_loans_active_book ON loans(book_id) WHERE returned_at IS NULL;
    `);
    const bookColumns = new Set(
      this.db
        .prepare("PRAGMA table_info(books)")
        .all()
        .map((column) => column.name),
    );
    if (!bookColumns.has("import_key"))
      this.db.exec("ALTER TABLE books ADD COLUMN import_key TEXT;");
    if (!bookColumns.has("server_id"))
      this.db.exec("ALTER TABLE books ADD COLUMN server_id TEXT;");
    if (!bookColumns.has("server_revision"))
      this.db.exec(
        "ALTER TABLE books ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0;",
      );
    if (!bookColumns.has("sync_state"))
      this.db.exec(
        "ALTER TABLE books ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending';",
      );
    this.db.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_books_import_key ON books(import_key) WHERE import_key IS NOT NULL;",
    );
    this.db.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_books_server_id ON books(server_id) WHERE server_id IS NOT NULL;",
    );
    const missingServerIds = this.db
      .prepare("SELECT id FROM books WHERE server_id IS NULL OR server_id = ''")
      .all();
    const assignServerId = this.db.prepare(
      "UPDATE books SET server_id=?, sync_state='pending' WHERE id=?",
    );
    if (missingServerIds.length) {
      this.db.exec("BEGIN IMMEDIATE");
      try {
        for (const book of missingServerIds)
          assignServerId.run(randomUUID(), book.id);
        this.db.exec("COMMIT");
      } catch (error) {
        this.db.exec("ROLLBACK");
        throw error;
      }
    }
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

  getBookDetails(id) {
    const book = this.getBook(id);
    if (!book) return null;
    return { book, activeLoan: this.activeLoanForBook(id) };
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
        this.queueBookMutation(book);
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
        .prepare("UPDATE books SET accession=?, epc=?, server_id=? WHERE id=?")
        .run(accession, epc, randomUUID(), next);
      this.addActivity(
        "catalogue",
        "succes",
        next,
        "Livre ajouté au catalogue",
        epc,
        null,
        now,
      );
      this.queueBookMutation(this.getBook(next));
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
      "UPDATE books SET accession=?, epc=?, server_id=? WHERE id=?",
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
          finalize.run(
            formatAccession(year, id),
            generateEpc(year, id),
            randomUUID(),
            id,
          );
          this.queueBookMutation(this.getBook(id));
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
    const updated = this.getBook(id);
    this.queueBookMutation(updated);
    return updated;
  }

  deleteBook(id) {
    const current = this.getBook(id);
    if (!current) return false;
    const loan = this.activeLoanForBook(id);
    if (loan)
      throw new Error(
        `Ce livre est emprunté par ${loan.subscriber_name}. Enregistrez son retour avant de le supprimer.`,
      );
    this.queueDeleteMutation(current);
    // L'historique des emprunts rendus reste tracé dans `activity`.
    this.db.prepare("DELETE FROM loans WHERE book_id = ?").run(Number(id));
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

  deleteBooks(ids) {
    const uniqueIds = [
      ...new Set(
        (Array.isArray(ids) ? ids : [])
          .map((id) => Number(id))
          .filter((id) => Number.isInteger(id) && id > 0),
      ),
    ];
    if (!uniqueIds.length) return { deleted: 0, missing: 0 };
    if (uniqueIds.length > 1000)
      throw new Error("Vous pouvez supprimer au maximum 1 000 livres à la fois.");

    let deleted = 0;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const id of uniqueIds) {
        if (this.deleteBook(id)) deleted++;
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return { deleted, missing: uniqueIds.length - deleted };
  }

  listSubscribers(search = "") {
    const term = `%${cleanText(search, 120)}%`;
    return this.db
      .prepare(
        `SELECT s.*,
          (SELECT ends_at FROM subscriptions WHERE subscriber_id=s.id AND status='active' ORDER BY ends_at DESC LIMIT 1) AS subscription_ends_at,
          (SELECT COUNT(*) FROM loans WHERE subscriber_id=s.id AND returned_at IS NULL) AS active_loans
         FROM subscribers s
         WHERE s.member_number LIKE ? OR s.name LIKE ? OR s.email LIKE ? OR s.phone LIKE ?
         ORDER BY s.name COLLATE NOCASE LIMIT 100`,
      )
      .all(term, term, term, term);
  }

  activeLoanForBook(bookId) {
    return (
      this.db
        .prepare(
          `SELECT l.*, s.member_number, s.name AS subscriber_name, s.email AS subscriber_email,
             s.phone AS subscriber_phone, sub.ends_at AS subscription_ends_at
           FROM loans l
           JOIN subscribers s ON s.id=l.subscriber_id
           LEFT JOIN subscriptions sub ON sub.id=l.subscription_id
           WHERE l.book_id=? AND l.returned_at IS NULL
           ORDER BY l.id DESC LIMIT 1`,
        )
        .get(Number(bookId)) || null
    );
  }

  borrowBook(bookId, input) {
    const book = this.getBook(bookId);
    if (!book) throw new Error("Livre introuvable.");
    if (this.activeLoanForBook(bookId))
      throw new Error("Ce livre possède déjà un emprunt actif.");
    const memberNumber = cleanText(input.member_number, 80).toUpperCase();
    const name = cleanText(input.name, 240);
    if (!memberNumber) throw new Error("Le numéro d'abonné est obligatoire.");
    if (!name) throw new Error("Le nom de l'abonné est obligatoire.");
    const now = new Date();
    const dueAt = new Date(input.due_at);
    if (Number.isNaN(dueAt.getTime()) || dueAt <= now)
      throw new Error("La date de retour doit être postérieure à aujourd'hui.");
    const subscriptionEnd = input.subscription_ends_at
      ? new Date(input.subscription_ends_at)
      : new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000);
    if (Number.isNaN(subscriptionEnd.getTime()) || subscriptionEnd < now)
      throw new Error("L'abonnement doit être actif pendant l'emprunt.");
    const timestamp = now.toISOString();
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db
        .prepare(
          `INSERT INTO subscribers (member_number, name, email, phone, active, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, ?, ?)
           ON CONFLICT(member_number) DO UPDATE SET
             name=excluded.name, email=excluded.email, phone=excluded.phone, active=1, updated_at=excluded.updated_at`,
        )
        .run(
          memberNumber,
          name,
          cleanText(input.email, 240),
          cleanText(input.phone, 80),
          timestamp,
          timestamp,
        );
      const subscriber = this.db
        .prepare("SELECT * FROM subscribers WHERE member_number=?")
        .get(memberNumber);
      let subscription = this.db
        .prepare(
          "SELECT * FROM subscriptions WHERE subscriber_id=? AND status='active' AND ends_at>=? ORDER BY ends_at DESC LIMIT 1",
        )
        .get(subscriber.id, timestamp);
      if (!subscription) {
        const subscriptionResult = this.db
          .prepare(
            `INSERT INTO subscriptions (subscriber_id, starts_at, ends_at, status, created_at, updated_at)
             VALUES (?, ?, ?, 'active', ?, ?)`,
          )
          .run(
            subscriber.id,
            timestamp,
            subscriptionEnd.toISOString(),
            timestamp,
            timestamp,
          );
        subscription = this.db
          .prepare("SELECT * FROM subscriptions WHERE id=?")
          .get(Number(subscriptionResult.lastInsertRowid));
      }
      const loanResult = this.db
        .prepare(
          `INSERT INTO loans (book_id, subscriber_id, subscription_id, borrowed_at, due_at, status, notes, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?)`,
        )
        .run(
          Number(bookId),
          subscriber.id,
          subscription.id,
          timestamp,
          dueAt.toISOString(),
          cleanText(input.notes, 1000),
          timestamp,
          timestamp,
        );
      this.db
        .prepare("UPDATE books SET status='indisponible', updated_at=? WHERE id=?")
        .run(timestamp, Number(bookId));
      this.addActivity(
        "emprunt",
        "succes",
        Number(bookId),
        `Livre emprunté par ${subscriber.name} (${subscriber.member_number})`,
        book.epc,
        book.tid,
        timestamp,
      );
      this.queueBookMutation(this.getBook(bookId));
      this.db.exec("COMMIT");
      return {
        loan: this.db
          .prepare("SELECT * FROM loans WHERE id=?")
          .get(Number(loanResult.lastInsertRowid)),
        ...this.getBookDetails(bookId),
      };
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  returnBook(bookId) {
    const book = this.getBook(bookId);
    if (!book) throw new Error("Livre introuvable.");
    const loan = this.activeLoanForBook(bookId);
    if (!loan) throw new Error("Ce livre n'a aucun emprunt actif.");
    const now = new Date().toISOString();
    const status = book.tid ? "encode" : "a_encoder";
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db
        .prepare(
          "UPDATE loans SET returned_at=?, status='returned', updated_at=? WHERE id=?",
        )
        .run(now, now, loan.id);
      this.db
        .prepare("UPDATE books SET status=?, updated_at=? WHERE id=?")
        .run(status, now, Number(bookId));
      this.addActivity(
        "retour",
        "succes",
        Number(bookId),
        `Retour enregistré pour ${loan.subscriber_name}`,
        book.epc,
        book.tid,
        now,
      );
      this.queueBookMutation(this.getBook(bookId));
      this.db.exec("COMMIT");
      return this.getBookDetails(bookId);
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
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
    const updated = this.getBook(id);
    this.queueBookMutation(updated);
    return updated;
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
    const updated = this.getBook(id);
    this.queueBookMutation(updated);
    return updated;
  }

  toSyncBook(book) {
    return {
      serverId: book.server_id,
      accession: book.accession,
      epc: book.epc,
      tid: book.tid || null,
      title: book.title,
      author: book.author || "",
      isbn: book.isbn || "",
      publisher: book.publisher || "",
      publicationYear: book.publication_year || "",
      category: book.category || "",
      shelf: book.shelf || "",
      notes: book.notes || "",
      status: book.status || "a_encoder",
      createdAt: book.created_at,
      updatedAt: book.updated_at,
      taggedAt: book.tagged_at || null,
      revision: Number(book.server_revision) || 0,
    };
  }

  queueBookMutation(book) {
    if (!book?.server_id) return;
    const now = new Date().toISOString();
    this.db
      .prepare("UPDATE books SET sync_state='pending' WHERE id=?")
      .run(book.id);
    this.db
      .prepare(
        `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at)
         VALUES (?, 'upsert', ?, ?, ?)
         ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
           operation=excluded.operation, payload=excluded.payload, created_at=excluded.created_at`,
      )
      .run(randomUUID(), book.server_id, JSON.stringify(this.toSyncBook(book)), now);
    this.onMutation?.();
  }

  queueDeleteMutation(book) {
    if (!book?.server_id) return;
    this.db
      .prepare(
        `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at)
         VALUES (?, 'delete', ?, NULL, ?)
         ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
           operation=excluded.operation, payload=NULL, created_at=excluded.created_at`,
      )
      .run(randomUUID(), book.server_id, new Date().toISOString());
    this.onMutation?.();
  }

  prepareInitialSync() {
    const books = this.db
      .prepare("SELECT * FROM books WHERE sync_state <> 'synced'")
      .all();
    if (!books.length) return;
    const markPending = this.db.prepare(
      "UPDATE books SET sync_state='pending' WHERE id=?",
    );
    const enqueue = this.db.prepare(
      `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at)
       VALUES (?, 'upsert', ?, ?, ?)
       ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
         operation=excluded.operation, payload=excluded.payload,
         created_at=excluded.created_at`,
    );
    const now = new Date().toISOString();
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const book of books) {
        markPending.run(book.id);
        enqueue.run(
          randomUUID(),
          book.server_id,
          JSON.stringify(this.toSyncBook(book)),
          now,
        );
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  pendingMutations(limit = 500) {
    return this.db
      .prepare(
        "SELECT * FROM sync_outbox ORDER BY created_at ASC LIMIT ?",
      )
      .all(Math.max(1, Math.min(Number(limit) || 500, 500)));
  }

  pendingMutationCount() {
    return Number(
      this.db.prepare("SELECT COUNT(*) AS total FROM sync_outbox").get().total,
    );
  }

  acknowledgeMutations(mutationIds) {
    const find = this.db.prepare(
      "SELECT entity_id FROM sync_outbox WHERE mutation_id=?",
    );
    const synced = this.db.prepare(
      "UPDATE books SET sync_state='synced' WHERE server_id=?",
    );
    const remove = this.db.prepare(
      "DELETE FROM sync_outbox WHERE mutation_id=?",
    );
    this.db.exec("BEGIN");
    try {
      for (const mutationId of mutationIds) {
        const mutation = find.get(mutationId);
        if (mutation) synced.run(mutation.entity_id);
        remove.run(mutationId);
      }
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  syncCursor() {
    return Number(this.getSyncMeta("cursor", "0")) || 0;
  }

  getSyncMeta(key, fallback = "") {
    return (
      this.db.prepare("SELECT value FROM sync_meta WHERE key=?").get(key)?.value ??
      fallback
    );
  }

  setSyncMeta(key, value) {
    this.db
      .prepare(
        "INSERT INTO sync_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      )
      .run(key, String(value));
  }

  applyRemoteChanges(changes, cursor) {
    const pending = this.db.prepare(
      "SELECT 1 FROM sync_outbox WHERE entity_id=? LIMIT 1",
    );
    const localByServerId = this.db.prepare(
      "SELECT id FROM books WHERE server_id=? LIMIT 1",
    );
    const removeLoans = this.db.prepare(
      "DELETE FROM loans WHERE book_id IN (SELECT id FROM books WHERE server_id=?)",
    );
    const remove = this.db.prepare("DELETE FROM books WHERE server_id=?");
    const insert = this.db.prepare(`
      INSERT INTO books(server_id, accession, epc, tid, title, author, isbn,
        publisher, publication_year, category, shelf, notes, status, created_at,
        updated_at, tagged_at, server_revision, sync_state)
      VALUES (:server_id, :accession, :epc, :tid, :title, :author, :isbn,
        :publisher, :publication_year, :category, :shelf, :notes, :status,
        :created_at, :updated_at, :tagged_at, :server_revision, 'synced')
    `);
    const update = this.db.prepare(`
      UPDATE books SET accession=:accession, epc=:epc, tid=:tid, title=:title,
        author=:author, isbn=:isbn, publisher=:publisher,
        publication_year=:publication_year, category=:category, shelf=:shelf,
        notes=:notes, status=:status, created_at=:created_at,
        updated_at=:updated_at, tagged_at=:tagged_at,
        server_revision=:server_revision, sync_state='synced'
      WHERE server_id=:server_id
    `);
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const change of Array.isArray(changes) ? changes : []) {
        const serverId = String(change?.entityId || "");
        if (!serverId || pending.get(serverId)) continue;
        if (change.operation === "delete") {
          removeLoans.run(serverId);
          remove.run(serverId);
          continue;
        }
        if (!change.book) continue;
        const book = this.remoteBookValues(change.book, serverId);
        if (localByServerId.get(serverId)) update.run(book);
        else insert.run(book);
      }
      this.setSyncMeta("cursor", cursor);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw new Error(`Conflit de synchronisation du catalogue : ${error.message}`);
    }
  }

  remoteBookValues(remote, serverId) {
    const now = new Date().toISOString();
    return {
      server_id: serverId,
      accession: cleanText(remote.accession, 240),
      epc: cleanText(remote.epc, 128).toUpperCase(),
      tid: cleanText(remote.tid, 128).toUpperCase() || null,
      title: cleanText(remote.title || "Sans titre", 240),
      author: cleanText(remote.author, 240),
      isbn: cleanText(remote.isbn, 240),
      publisher: cleanText(remote.publisher, 240),
      publication_year: cleanText(remote.publicationYear, 240),
      category: cleanText(remote.category, 240),
      shelf: cleanText(remote.shelf, 240),
      notes: cleanText(remote.notes, 2000),
      status: ["a_encoder", "encode", "indisponible"].includes(remote.status)
        ? remote.status
        : "a_encoder",
      created_at: cleanText(remote.createdAt, 100) || now,
      updated_at: cleanText(remote.updatedAt, 100) || now,
      tagged_at: cleanText(remote.taggedAt, 100) || null,
      server_revision: Number(remote.revision) || 0,
    };
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
    const rows = this.db
      .prepare("SELECT key, value FROM settings WHERE key <> 'sync_api_key'")
      .all();
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
