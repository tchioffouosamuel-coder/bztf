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
import {
  formatAccession,
  generateBadgeEpc,
  generateCardEpc,
  generateEpc,
  isBadgeEpc,
  isCardEpc,
} from "./epc.js";

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

function formatDay(value) {
  return new Intl.DateTimeFormat("fr-FR").format(new Date(value));
}

/** Ordre d'application : les références avant ce qui les utilise. */
function changePriority(change) {
  return (
    {
      book: 0,
      subscriber: 1,
      staff: 1,
      subscription: 2,
      loan: 3,
      staff_passage: 3,
      gate_day: 3,
    }[change?.entityType || "book"] ?? 4
  );
}

/** Bornes UTC d'une journée locale `AAAA-MM-JJ`. */
function localDayRange(day) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ""));
  const start = match
    ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
    : new Date(new Date().setHours(0, 0, 0, 0));
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { from: start.toISOString(), to: end.toISOString() };
}

/** Date locale `AAAA-MM-JJ`. */
export function localDay(date = new Date()) {
  const value = new Date(date);
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}

/**
 * node:sqlite refuse un paramètre nommé absent de la requête : seuls ceux
 * qu'elle référence (`@nom`) sont transmis.
 */
function allNamed(db, sql, params) {
  const used = Object.fromEntries(
    Object.entries(params).filter(([key]) => sql.includes(`@${key}`)),
  );
  return db.prepare(sql).all(used);
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

    const subscriberColumns = new Set(
      this.db
        .prepare("PRAGMA table_info(subscribers)")
        .all()
        .map((column) => column.name),
    );
    for (const column of ["card_epc", "card_tid", "card_tagged_at"])
      if (!subscriberColumns.has(column))
        this.db.exec(`ALTER TABLE subscribers ADD COLUMN ${column} TEXT;`);
    if (!subscriberColumns.has("sync_state"))
      this.db.exec(
        "ALTER TABLE subscribers ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending';",
      );
    const outboxColumns = new Set(
      this.db
        .prepare("PRAGMA table_info(sync_outbox)")
        .all()
        .map((column) => column.name),
    );
    if (!outboxColumns.has("entity_type"))
      this.db.exec(
        "ALTER TABLE sync_outbox ADD COLUMN entity_type TEXT NOT NULL DEFAULT 'book';",
      );
    // Emprunts et abonnements synchronisés : identifiant global (UUID).
    for (const table of ["subscriptions", "loans"]) {
      const columns = new Set(
        this.db
          .prepare(`PRAGMA table_info(${table})`)
          .all()
          .map((column) => column.name),
      );
      if (!columns.has("server_id"))
        this.db.exec(`ALTER TABLE ${table} ADD COLUMN server_id TEXT;`);
      if (!columns.has("sync_state"))
        this.db.exec(
          `ALTER TABLE ${table} ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending';`,
        );
      const assignId = this.db.prepare(
        `UPDATE ${table} SET server_id=? WHERE id=?`,
      );
      for (const row of this.db
        .prepare(`SELECT id FROM ${table} WHERE server_id IS NULL`)
        .all())
        assignId.run(randomUUID(), row.id);
      this.db.exec(
        `CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_server_id ON ${table}(server_id);`,
      );
    }
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sync_deferred (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        change TEXT NOT NULL,
        PRIMARY KEY(entity_type, entity_id)
      );
    `);
    this.db.exec(`
      CREATE UNIQUE INDEX IF NOT EXISTS idx_subscribers_card_epc ON subscribers(card_epc) WHERE card_epc IS NOT NULL;
      CREATE UNIQUE INDEX IF NOT EXISTS idx_subscribers_card_tid ON subscribers(card_tid) WHERE card_tid IS NOT NULL;
    `);
    const withoutCard = this.db
      .prepare("SELECT id FROM subscribers WHERE card_epc IS NULL")
      .all();
    const assignCard = this.db.prepare(
      "UPDATE subscribers SET card_epc=? WHERE id=?",
    );
    for (const subscriber of withoutCard)
      assignCard.run(generateCardEpc(), subscriber.id);

    // Personnel (badge « BCM » 3) et activité des portails antivol. Le
    // matricule n'est pas unique en base : deux postes peuvent l'avoir saisi
    // avant de se synchroniser, l'identifiant est le server_id.
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS staff (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id TEXT NOT NULL UNIQUE,
        staff_number TEXT NOT NULL COLLATE NOCASE,
        name TEXT NOT NULL,
        position TEXT NOT NULL DEFAULT '',
        email TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 1,
        badge_epc TEXT UNIQUE,
        badge_tid TEXT UNIQUE,
        badge_tagged_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
      );
      CREATE INDEX IF NOT EXISTS idx_staff_name ON staff(name);
      CREATE INDEX IF NOT EXISTS idx_staff_number ON staff(staff_number);
      CREATE TABLE IF NOT EXISTS gate_days (
        server_id TEXT PRIMARY KEY,
        gate_id TEXT NOT NULL,
        gate_name TEXT NOT NULL DEFAULT '',
        day TEXT NOT NULL,
        entries INTEGER NOT NULL DEFAULT 0,
        exits INTEGER NOT NULL DEFAULT 0,
        alarms INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_gate_days_day ON gate_days(day);
      CREATE TABLE IF NOT EXISTS staff_passages (
        server_id TEXT PRIMARY KEY,
        staff_server_id TEXT NOT NULL,
        staff_number TEXT NOT NULL DEFAULT '',
        staff_name TEXT NOT NULL DEFAULT '',
        direction TEXT NOT NULL CHECK(direction IN ('in', 'out')),
        passed_at TEXT NOT NULL,
        gate_id TEXT NOT NULL DEFAULT '',
        gate_name TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS idx_staff_passages_at ON staff_passages(passed_at);
      CREATE INDEX IF NOT EXISTS idx_staff_passages_staff ON staff_passages(staff_server_id, passed_at);
    `);
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
    for (const loan of this.db
      .prepare(
        "SELECT server_id FROM loans WHERE book_id=? AND server_id IS NOT NULL",
      )
      .all(Number(id)))
      this.queueEntityDelete("loan", loan.server_id);
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
          (SELECT status FROM subscriptions WHERE subscriber_id=s.id ORDER BY ends_at DESC, id DESC LIMIT 1) AS latest_subscription_status,
          (SELECT COUNT(*) FROM loans WHERE subscriber_id=s.id AND returned_at IS NULL) AS active_loans,
          (SELECT COUNT(*) FROM loans WHERE subscriber_id=s.id AND returned_at IS NULL AND due_at < ?) AS overdue_loans
         FROM subscribers s
         WHERE s.member_number LIKE ? OR s.name LIKE ? OR s.email LIKE ? OR s.phone LIKE ?
         ORDER BY s.name COLLATE NOCASE LIMIT ?`,
      )
      .all(new Date().toISOString(), term, term, term, term, 500);
  }

  /** Fiche d'un abonné : abonnements, emprunts en cours et historique. */
  getSubscriberDetails(id) {
    const subscriber = this.getSubscriber(id);
    if (!subscriber) return null;
    const subscriptions = this.db
      .prepare(
        `SELECT sub.*, (SELECT COUNT(*) FROM loans WHERE subscription_id=sub.id) AS loan_count
         FROM subscriptions sub WHERE subscriber_id=? ORDER BY ends_at DESC, id DESC`,
      )
      .all(subscriber.id);
    const loans = this.db
      .prepare(
        `SELECT l.*, b.title AS book_title, b.accession AS book_accession
         FROM loans l LEFT JOIN books b ON b.id=l.book_id
         WHERE l.subscriber_id=? ORDER BY COALESCE(l.returned_at, l.borrowed_at) DESC LIMIT 100`,
      )
      .all(subscriber.id);
    return { subscriber, subscriptions, loans };
  }

  /** Comptes du poste pour le rapport d'appareil : jamais de mot de passe. */
  reportUsers() {
    return this.db
      .prepare(
        "SELECT id, name, email, role, active, created_at, updated_at FROM users ORDER BY id",
      )
      .all()
      .map((user) => ({
        localId: user.id,
        name: user.name,
        email: user.email,
        role: user.role,
        active: Boolean(user.active),
        createdAt: user.created_at,
        updatedAt: user.updated_at,
      }));
  }

  /** Journal d'activité postérieur à [afterId], pour le rapport d'appareil. */
  reportActivity(afterId, limit = 1000) {
    return this.db
      .prepare(
        `SELECT a.*, b.server_id AS book_server_id FROM activity a
         LEFT JOIN books b ON b.id=a.book_id
         WHERE a.id > ? ORDER BY a.id LIMIT ?`,
      )
      .all(Number(afterId) || 0, limit)
      .map((entry) => ({
        localId: entry.id,
        type: entry.type,
        result: entry.result,
        message: entry.message,
        epc: entry.epc || null,
        tid: entry.tid || null,
        bookServerId: entry.book_server_id || null,
        createdAt: entry.created_at,
      }));
  }

  /** Registre des emprunts : en cours, en retard, rendus ou tous. */
  listLoans({ filter = "active", search = "" } = {}) {
    const term = `%${cleanText(search, 120)}%`;
    const now = new Date().toISOString();
    const condition =
      {
        active: "l.returned_at IS NULL",
        overdue: "l.returned_at IS NULL AND l.due_at < @now",
        returned: "l.returned_at IS NOT NULL",
      }[filter] || "1=1";
    return allNamed(
      this.db,
      `SELECT l.*, b.title AS book_title, b.accession AS book_accession,
          s.name AS subscriber_name, s.member_number
         FROM loans l
         LEFT JOIN books b ON b.id=l.book_id
         JOIN subscribers s ON s.id=l.subscriber_id
         WHERE ${condition}
           AND (b.title LIKE @term OR b.accession LIKE @term OR s.name LIKE @term OR s.member_number LIKE @term)
         ORDER BY CASE WHEN l.returned_at IS NULL THEN l.due_at END ASC,
           l.returned_at DESC, l.id DESC
         LIMIT 500`,
      { now, term },
    );
  }

  /** Registre des abonnements avec leur abonné. */
  listSubscriptions({ filter = "tous", search = "" } = {}) {
    const term = `%${cleanText(search, 120)}%`;
    const now = new Date();
    const soon = new Date(now.getTime() + 30 * 24 * 3600 * 1000);
    const running =
      "sub.status='active' AND sub.starts_at <= @now AND sub.ends_at >= @now";
    const condition =
      {
        actifs: running,
        bientot: `${running} AND sub.ends_at <= @soon`,
        expires:
          "sub.status<>'suspended' AND (sub.status='expired' OR sub.ends_at < @now)",
        suspendus: "sub.status='suspended'",
      }[filter] || "1=1";
    return allNamed(
      this.db,
      `SELECT sub.*, s.name AS subscriber_name, s.member_number, s.active AS subscriber_active,
          (SELECT COUNT(*) FROM loans WHERE subscription_id=sub.id) AS loan_count
         FROM subscriptions sub JOIN subscribers s ON s.id=sub.subscriber_id
         WHERE ${condition}
           AND (s.name LIKE @term OR s.member_number LIKE @term)
         ORDER BY sub.ends_at DESC, sub.id DESC
         LIMIT 500`,
      { now: now.toISOString(), soon: soon.toISOString(), term },
    );
  }

  createSubscriber(input) {
    const memberNumber = cleanText(input.member_number, 80).toUpperCase();
    if (
      memberNumber &&
      this.db
        .prepare("SELECT 1 FROM subscribers WHERE member_number=?")
        .get(memberNumber)
    )
      throw new Error(`Le numéro d'abonné ${memberNumber} existe déjà.`);
    const subscriber = this.upsertSubscriber(input);
    this.addActivity(
      "abonne",
      "succes",
      null,
      `Abonné créé : ${subscriber.name} (${subscriber.member_number})`,
    );
    return subscriber;
  }

  /**
   * Modifie les coordonnées et l'état d'un abonné. Le numéro d'abonné est
   * son identifiant de synchronisation : il ne change pas.
   */
  updateSubscriber(id, input) {
    const current = this.getSubscriber(id);
    if (!current) return null;
    const name = cleanText(input.name, 240);
    if (!name) throw new Error("Le nom de l'abonné est obligatoire.");
    const active = input.active === undefined ? current.active : input.active ? 1 : 0;
    const now = new Date().toISOString();
    this.db
      .prepare(
        "UPDATE subscribers SET name=?, email=?, phone=?, active=?, updated_at=? WHERE id=?",
      )
      .run(
        name,
        cleanText(input.email, 240),
        cleanText(input.phone, 80),
        active,
        now,
        current.id,
      );
    const updated = this.getSubscriber(current.id);
    this.queueSubscriberMutation(updated);
    this.addActivity(
      "abonne",
      "succes",
      null,
      `Abonné modifié : ${updated.name} (${updated.member_number})${
        current.active && !active ? " — désactivé" : ""
      }`,
    );
    return updated;
  }

  /**
   * Supprime un abonné sans historique d'emprunt. Avec un historique, il faut
   * le désactiver : ses emprunts passés restent traçables.
   */
  deleteSubscriber(id) {
    const subscriber = this.getSubscriber(id);
    if (!subscriber) return false;
    const loans = Number(
      this.db
        .prepare("SELECT COUNT(*) AS total FROM loans WHERE subscriber_id=?")
        .get(subscriber.id).total,
    );
    if (loans)
      throw new Error(
        `${subscriber.name} a ${loans} emprunt(s) enregistré(s). Désactivez l'abonné au lieu de le supprimer.`,
      );
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const row of this.db
        .prepare(
          "SELECT server_id FROM subscriptions WHERE subscriber_id=? AND server_id IS NOT NULL",
        )
        .all(subscriber.id))
        this.queueEntityDelete("subscription", row.server_id);
      this.db
        .prepare("DELETE FROM subscriptions WHERE subscriber_id=?")
        .run(subscriber.id);
      this.db.prepare("DELETE FROM subscribers WHERE id=?").run(subscriber.id);
      this.queueEntityDelete("subscriber", subscriber.member_number);
      this.addActivity(
        "abonne",
        "succes",
        null,
        `Abonné supprimé : ${subscriber.name} (${subscriber.member_number})`,
        subscriber.card_epc,
        subscriber.card_tid,
      );
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return true;
  }

  getSubscription(id) {
    return (
      this.db
        .prepare(
          `SELECT sub.*, s.name AS subscriber_name, s.member_number
           FROM subscriptions sub JOIN subscribers s ON s.id=sub.subscriber_id
           WHERE sub.id=?`,
        )
        .get(Number(id)) || null
    );
  }

  subscriptionValues(input, current = {}) {
    const startsAt = new Date(input.starts_at ?? current.starts_at);
    const endsAt = new Date(input.ends_at ?? current.ends_at);
    if (Number.isNaN(startsAt.getTime()))
      throw new Error("La date de début de l'abonnement est invalide.");
    if (Number.isNaN(endsAt.getTime()))
      throw new Error("La date de fin de l'abonnement est invalide.");
    if (endsAt <= startsAt)
      throw new Error("La fin de l'abonnement doit suivre son début.");
    const status = cleanText(input.status ?? current.status ?? "active", 20);
    if (!["active", "expired", "suspended"].includes(status))
      throw new Error("Statut d'abonnement inconnu.");
    return {
      startsAt: startsAt.toISOString(),
      endsAt: endsAt.toISOString(),
      status,
    };
  }

  createSubscription(subscriberId, input) {
    const subscriber = this.getSubscriber(subscriberId);
    if (!subscriber) throw new Error("Abonné introuvable.");
    const values = this.subscriptionValues(input);
    const now = new Date().toISOString();
    const result = this.db
      .prepare(
        `INSERT INTO subscriptions (subscriber_id, starts_at, ends_at, status, created_at, updated_at, server_id)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        subscriber.id,
        values.startsAt,
        values.endsAt,
        values.status,
        now,
        now,
        randomUUID(),
      );
    const id = Number(result.lastInsertRowid);
    this.queueSubscriptionMutation(id);
    this.addActivity(
      "abonnement",
      "succes",
      null,
      `Abonnement de ${subscriber.name} (${subscriber.member_number}) jusqu'au ${formatDay(values.endsAt)}`,
    );
    return this.getSubscription(id);
  }

  updateSubscription(id, input) {
    const current = this.getSubscription(id);
    if (!current) return null;
    const values = this.subscriptionValues(input, current);
    this.db
      .prepare(
        "UPDATE subscriptions SET starts_at=?, ends_at=?, status=?, updated_at=? WHERE id=?",
      )
      .run(
        values.startsAt,
        values.endsAt,
        values.status,
        new Date().toISOString(),
        current.id,
      );
    this.queueSubscriptionMutation(current.id);
    this.addActivity(
      "abonnement",
      "succes",
      null,
      `Abonnement de ${current.subscriber_name} modifié : ${values.status}, jusqu'au ${formatDay(values.endsAt)}`,
    );
    return this.getSubscription(current.id);
  }

  /** Les emprunts faits sous cet abonnement restent, sans abonnement lié. */
  deleteSubscription(id) {
    const current = this.getSubscription(id);
    if (!current) return false;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const loans = this.db
        .prepare("SELECT id FROM loans WHERE subscription_id=?")
        .all(current.id);
      this.db.prepare("DELETE FROM subscriptions WHERE id=?").run(current.id);
      if (current.server_id)
        this.queueEntityDelete("subscription", current.server_id);
      for (const loan of loans) this.queueLoanMutation(loan.id);
      this.addActivity(
        "abonnement",
        "succes",
        null,
        `Abonnement de ${current.subscriber_name} supprimé`,
      );
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return true;
  }

  getSubscriber(id) {
    return (
      this.db.prepare("SELECT * FROM subscribers WHERE id=?").get(Number(id)) ||
      null
    );
  }

  /**
   * Crée l'abonné ou met à jour ses coordonnées (clé : numéro d'abonné) et lui
   * attribue l'EPC de sa carte. N'ouvre pas de transaction : l'appelant peut
   * l'inclure dans la sienne.
   */
  upsertSubscriber(input, timestamp = new Date().toISOString()) {
    const memberNumber = cleanText(input.member_number, 80).toUpperCase();
    const name = cleanText(input.name, 240);
    if (!memberNumber) throw new Error("Le numéro d'abonné est obligatoire.");
    if (!name) throw new Error("Le nom de l'abonné est obligatoire.");
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
    if (!subscriber.card_epc)
      this.db
        .prepare("UPDATE subscribers SET card_epc=? WHERE id=?")
        .run(generateCardEpc(), subscriber.id);
    const saved = this.getSubscriber(subscriber.id);
    this.queueSubscriberMutation(saved);
    return saved;
  }

  /** Abonné correspondant au tag lu, si c'est une carte encodée. */
  recognizeCard(epc, tid) {
    const normalizedEpc = cleanText(epc, 128).toUpperCase();
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    if (!isCardEpc(normalizedEpc)) return null;
    const subscriber = this.db
      .prepare(
        "SELECT * FROM subscribers WHERE card_epc=? AND card_tid IS NOT NULL AND active=1",
      )
      .get(normalizedEpc);
    // Un EPC recopié sur un autre tag ne suffit pas : le TID doit correspondre.
    if (!subscriber || (normalizedTid && subscriber.card_tid !== normalizedTid))
      return null;
    return subscriber;
  }

  markCardTagged(subscriberId, tid) {
    const subscriber = this.getSubscriber(subscriberId);
    if (!subscriber) throw new Error("Abonné introuvable.");
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    if (!normalizedTid) throw new Error("Le TID de la carte est obligatoire.");
    const book = this.db
      .prepare("SELECT accession FROM books WHERE tid=?")
      .get(normalizedTid);
    if (book) throw new Error(`Ce tag est déjà lié au livre ${book.accession}.`);
    const other = this.db
      .prepare("SELECT name FROM subscribers WHERE card_tid=? AND id<>?")
      .get(normalizedTid, subscriber.id);
    if (other) throw new Error(`Ce tag est déjà la carte de ${other.name}.`);
    const badge = this.db
      .prepare("SELECT name FROM staff WHERE badge_tid=?")
      .get(normalizedTid);
    if (badge) throw new Error(`Ce tag est déjà le badge de ${badge.name}.`);
    const now = new Date().toISOString();
    this.db
      .prepare(
        "UPDATE subscribers SET card_tid=?, card_tagged_at=?, updated_at=? WHERE id=?",
      )
      .run(normalizedTid, now, now, subscriber.id);
    this.queueSubscriberMutation(this.getSubscriber(subscriber.id));
    this.addActivity(
      "carte",
      "succes",
      null,
      `Carte encodée pour ${subscriber.name} (${subscriber.member_number})`,
      subscriber.card_epc,
      normalizedTid,
      now,
    );
    return this.getSubscriber(subscriber.id);
  }

  // --- Personnel -------------------------------------------------------

  /** Personnel, avec son dernier passage au portail. */
  listStaff(search = "") {
    const term = `%${cleanText(search, 120)}%`;
    return this.db
      .prepare(
        `SELECT st.*,
          (SELECT direction FROM staff_passages WHERE staff_server_id=st.server_id ORDER BY passed_at DESC LIMIT 1) AS last_direction,
          (SELECT passed_at FROM staff_passages WHERE staff_server_id=st.server_id ORDER BY passed_at DESC LIMIT 1) AS last_passed_at
         FROM staff st
         WHERE st.staff_number LIKE ? OR st.name LIKE ? OR st.position LIKE ? OR st.email LIKE ? OR st.phone LIKE ?
         ORDER BY st.name COLLATE NOCASE LIMIT 500`,
      )
      .all(term, term, term, term, term);
  }

  getStaff(id) {
    return (
      this.db.prepare("SELECT * FROM staff WHERE id=?").get(Number(id)) || null
    );
  }

  /** Fiche d'un membre du personnel et ses derniers passages. */
  getStaffDetails(id) {
    const staff = this.getStaff(id);
    if (!staff) return null;
    const passages = this.db
      .prepare(
        "SELECT * FROM staff_passages WHERE staff_server_id=? ORDER BY passed_at DESC LIMIT 200",
      )
      .all(staff.server_id);
    return { staff, passages };
  }

  staffValues(input, current = {}) {
    const staffNumber = cleanText(
      input.staff_number ?? current.staff_number,
      80,
    ).toUpperCase();
    const name = cleanText(input.name ?? current.name, 240);
    if (!staffNumber) throw new Error("Le matricule est obligatoire.");
    if (!name) throw new Error("Le nom est obligatoire.");
    const duplicate = this.db
      .prepare("SELECT name FROM staff WHERE staff_number=? AND id<>?")
      .get(staffNumber, Number(current.id) || -1);
    if (duplicate)
      throw new Error(
        `Le matricule ${staffNumber} est déjà attribué à ${duplicate.name}.`,
      );
    return {
      staffNumber,
      name,
      position: cleanText(input.position ?? current.position, 120),
      email: cleanText(input.email ?? current.email, 240),
      phone: cleanText(input.phone ?? current.phone, 80),
      active:
        input.active === undefined
          ? (current.active ?? 1)
          : input.active
            ? 1
            : 0,
    };
  }

  createStaff(input) {
    const values = this.staffValues(input);
    const now = new Date().toISOString();
    const result = this.db
      .prepare(
        `INSERT INTO staff (server_id, staff_number, name, position, email, phone, active,
           badge_epc, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        randomUUID(),
        values.staffNumber,
        values.name,
        values.position,
        values.email,
        values.phone,
        values.active,
        generateBadgeEpc(),
        now,
        now,
      );
    const staff = this.getStaff(Number(result.lastInsertRowid));
    this.queueStaffMutation(staff);
    this.addActivity(
      "personnel",
      "succes",
      null,
      `Personnel ajouté : ${staff.name} (${staff.staff_number})`,
    );
    return staff;
  }

  updateStaff(id, input) {
    const current = this.getStaff(id);
    if (!current) return null;
    const values = this.staffValues(input, current);
    this.db
      .prepare(
        `UPDATE staff SET staff_number=?, name=?, position=?, email=?, phone=?, active=?, updated_at=?
         WHERE id=?`,
      )
      .run(
        values.staffNumber,
        values.name,
        values.position,
        values.email,
        values.phone,
        values.active,
        new Date().toISOString(),
        current.id,
      );
    const updated = this.getStaff(current.id);
    this.queueStaffMutation(updated);
    this.addActivity(
      "personnel",
      "succes",
      null,
      `Personnel modifié : ${updated.name} (${updated.staff_number})${
        current.active && !values.active ? " — désactivé" : ""
      }`,
    );
    return updated;
  }

  /** Les passages déjà enregistrés gardent le nom de la personne. */
  deleteStaff(id) {
    const staff = this.getStaff(id);
    if (!staff) return false;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db.prepare("DELETE FROM staff WHERE id=?").run(staff.id);
      this.queueEntityDelete("staff", staff.server_id);
      this.addActivity(
        "personnel",
        "succes",
        null,
        `Personnel supprimé : ${staff.name} (${staff.staff_number})`,
        staff.badge_epc,
        staff.badge_tid,
      );
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return true;
  }

  /** Membre actif du personnel correspondant au badge lu. */
  recognizeBadge(epc, tid) {
    const normalizedEpc = cleanText(epc, 128).toUpperCase();
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    if (!isBadgeEpc(normalizedEpc)) return null;
    const staff = this.db
      .prepare(
        "SELECT * FROM staff WHERE badge_epc=? AND badge_tid IS NOT NULL AND active=1",
      )
      .get(normalizedEpc);
    // Un EPC recopié sur un autre tag ne suffit pas : le TID doit correspondre.
    if (!staff || (normalizedTid && staff.badge_tid !== normalizedTid))
      return null;
    return staff;
  }

  /** Ce que désigne déjà ce TID (livre, carte ou badge), pour refuser un doublon. */
  tidOwner(tid, { staffId = null, subscriberId = null } = {}) {
    const book = this.db
      .prepare("SELECT accession FROM books WHERE tid=?")
      .get(tid);
    if (book) return `le livre ${book.accession}`;
    const card = this.db
      .prepare("SELECT name FROM subscribers WHERE card_tid=? AND id<>?")
      .get(tid, Number(subscriberId) || -1);
    if (card) return `la carte d'abonné de ${card.name}`;
    const badge = this.db
      .prepare("SELECT name FROM staff WHERE badge_tid=? AND id<>?")
      .get(tid, Number(staffId) || -1);
    if (badge) return `le badge de ${badge.name}`;
    return null;
  }

  markBadgeTagged(staffId, tid) {
    const staff = this.getStaff(staffId);
    if (!staff) throw new Error("Membre du personnel introuvable.");
    const normalizedTid = cleanText(tid, 128).toUpperCase();
    if (!normalizedTid) throw new Error("Le TID du badge est obligatoire.");
    const owner = this.tidOwner(normalizedTid, { staffId: staff.id });
    if (owner) throw new Error(`Ce tag est déjà ${owner}.`);
    const now = new Date().toISOString();
    this.db
      .prepare(
        "UPDATE staff SET badge_tid=?, badge_tagged_at=?, updated_at=? WHERE id=?",
      )
      .run(normalizedTid, now, now, staff.id);
    this.queueStaffMutation(this.getStaff(staff.id));
    this.addActivity(
      "badge",
      "succes",
      null,
      `Badge encodé pour ${staff.name} (${staff.staff_number})`,
      staff.badge_epc,
      normalizedTid,
      now,
    );
    return this.getStaff(staff.id);
  }

  toSyncStaff(staff) {
    return {
      serverId: staff.server_id,
      staffNumber: staff.staff_number,
      name: staff.name,
      position: staff.position || "",
      email: staff.email || "",
      phone: staff.phone || "",
      active: Boolean(staff.active),
      badgeEpc: staff.badge_epc || null,
      badgeTid: staff.badge_tid || null,
      badgeTaggedAt: staff.badge_tagged_at || null,
      createdAt: staff.created_at,
      updatedAt: staff.updated_at,
    };
  }

  queueStaffMutation(staff) {
    if (!staff?.server_id) return;
    this.queueEntity(
      "staff",
      staff.id,
      "staff",
      staff.server_id,
      this.toSyncStaff(staff),
    );
  }

  /** Passages du personnel d'une journée locale (aujourd'hui par défaut). */
  listStaffPassages({ day = "", search = "" } = {}) {
    const { from, to } = localDayRange(day);
    const term = `%${cleanText(search, 120)}%`;
    return this.db
      .prepare(
        `SELECT p.*, st.id AS staff_id, st.position
         FROM staff_passages p LEFT JOIN staff st ON st.server_id=p.staff_server_id
         WHERE p.passed_at >= ? AND p.passed_at < ?
           AND (p.staff_name LIKE ? OR p.staff_number LIKE ? OR p.gate_name LIKE ?)
         ORDER BY p.passed_at DESC LIMIT 1000`,
      )
      .all(from, to, term, term, term);
  }

  /**
   * Présence du jour : pour chaque membre passé au portail, premier passage,
   * dernier passage et dernier sens (entré = présent).
   */
  staffPresence(day = "") {
    const { from, to } = localDayRange(day);
    return this.db
      .prepare(
        `SELECT p.staff_server_id, MAX(p.staff_name) AS staff_name, MAX(p.staff_number) AS staff_number,
           MIN(p.passed_at) AS first_passed_at, MAX(p.passed_at) AS last_passed_at,
           SUM(CASE WHEN p.direction='in' THEN 1 ELSE 0 END) AS entries,
           SUM(CASE WHEN p.direction='out' THEN 1 ELSE 0 END) AS exits,
           (SELECT direction FROM staff_passages last
            WHERE last.staff_server_id=p.staff_server_id AND last.passed_at >= ? AND last.passed_at < ?
            ORDER BY last.passed_at DESC LIMIT 1) AS last_direction
         FROM staff_passages p
         WHERE p.passed_at >= ? AND p.passed_at < ?
         GROUP BY p.staff_server_id
         ORDER BY staff_name COLLATE NOCASE`,
      )
      .all(from, to, from, to);
  }

  /** Fréquentation par jour (tous portails confondus) et détail par portail. */
  gateStats({ from = "", to = "" } = {}) {
    const end = /^\d{4}-\d{2}-\d{2}$/.test(to) ? to : localDay();
    const start = /^\d{4}-\d{2}-\d{2}$/.test(from)
      ? from
      : localDay(new Date(Date.now() - 29 * 24 * 3600 * 1000));
    const rows = this.db
      .prepare(
        "SELECT * FROM gate_days WHERE day >= ? AND day <= ? ORDER BY day DESC, gate_name",
      )
      .all(start, end);
    const days = new Map();
    for (const row of rows) {
      const entry = days.get(row.day) || {
        day: row.day,
        entries: 0,
        exits: 0,
        alarms: 0,
        gates: [],
      };
      entry.entries += row.entries;
      entry.exits += row.exits;
      entry.alarms += row.alarms;
      entry.gates.push({
        gateId: row.gate_id,
        gateName: row.gate_name || "Portail",
        entries: row.entries,
        exits: row.exits,
        alarms: row.alarms,
        updatedAt: row.updated_at,
      });
      days.set(row.day, entry);
    }
    const list = [...days.values()];
    const today = days.get(localDay()) || {
      day: localDay(),
      entries: 0,
      exits: 0,
      alarms: 0,
      gates: [],
    };
    return {
      from: start,
      to: end,
      today,
      days: list,
      totals: list.reduce(
        (sum, day) => ({
          entries: sum.entries + day.entries,
          exits: sum.exits + day.exits,
          alarms: sum.alarms + day.alarms,
        }),
        { entries: 0, exits: 0, alarms: 0 },
      ),
    };
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
      const subscriber = this.upsertSubscriber(input, timestamp);
      let subscription = this.db
        .prepare(
          "SELECT * FROM subscriptions WHERE subscriber_id=? AND status='active' AND ends_at>=? ORDER BY ends_at DESC LIMIT 1",
        )
        .get(subscriber.id, timestamp);
      if (!subscription) {
        const subscriptionResult = this.db
          .prepare(
            `INSERT INTO subscriptions (subscriber_id, starts_at, ends_at, status, created_at, updated_at, server_id)
             VALUES (?, ?, ?, 'active', ?, ?, ?)`,
          )
          .run(
            subscriber.id,
            timestamp,
            subscriptionEnd.toISOString(),
            timestamp,
            timestamp,
            randomUUID(),
          );
        this.queueSubscriptionMutation(Number(subscriptionResult.lastInsertRowid));
        subscription = this.db
          .prepare("SELECT * FROM subscriptions WHERE id=?")
          .get(Number(subscriptionResult.lastInsertRowid));
      }
      const loanResult = this.db
        .prepare(
          `INSERT INTO loans (book_id, subscriber_id, subscription_id, borrowed_at, due_at, status, notes, created_at, updated_at, server_id)
           VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)`,
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
          randomUUID(),
        );
      this.queueLoanMutation(Number(loanResult.lastInsertRowid));
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
      this.queueLoanMutation(loan.id);
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
    const card = this.db
      .prepare("SELECT name, member_number FROM subscribers WHERE card_tid=?")
      .get(normalizedTid);
    if (card)
      throw new Error(
        `Ce tag est la carte de l'abonné ${card.name} (${card.member_number}).`,
      );
    const badge = this.db
      .prepare("SELECT name, staff_number FROM staff WHERE badge_tid=?")
      .get(normalizedTid);
    if (badge)
      throw new Error(
        `Ce tag est le badge de ${badge.name} (${badge.staff_number}).`,
      );
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

  toSyncSubscriber(subscriber) {
    return {
      memberNumber: subscriber.member_number,
      name: subscriber.name,
      email: subscriber.email || "",
      phone: subscriber.phone || "",
      active: Boolean(subscriber.active),
      cardEpc: subscriber.card_epc || null,
      cardTid: subscriber.card_tid || null,
      cardTaggedAt: subscriber.card_tagged_at || null,
      createdAt: subscriber.created_at,
      updatedAt: subscriber.updated_at,
    };
  }

  /** L'identifiant d'entité d'un abonné est son numéro d'abonné. */
  queueSubscriberMutation(subscriber) {
    if (!subscriber) return;
    this.db
      .prepare("UPDATE subscribers SET sync_state='pending' WHERE id=?")
      .run(subscriber.id);
    this.db
      .prepare(
        `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at, entity_type)
         VALUES (?, 'upsert', ?, ?, ?, 'subscriber')
         ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
           operation=excluded.operation, payload=excluded.payload,
           created_at=excluded.created_at, entity_type=excluded.entity_type`,
      )
      .run(
        randomUUID(),
        subscriber.member_number,
        JSON.stringify(this.toSyncSubscriber(subscriber)),
        new Date().toISOString(),
      );
    this.onMutation?.();
  }

  queueSubscriptionMutation(subscriptionId) {
    const row = this.db
      .prepare(
        `SELECT sub.*, s.member_number FROM subscriptions sub
         JOIN subscribers s ON s.id=sub.subscriber_id WHERE sub.id=?`,
      )
      .get(Number(subscriptionId));
    if (!row?.server_id) return;
    this.queueEntity("subscriptions", row.id, "subscription", row.server_id, {
      serverId: row.server_id,
      memberNumber: row.member_number,
      startsAt: row.starts_at,
      endsAt: row.ends_at,
      status: row.status,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  }

  queueLoanMutation(loanId) {
    const row = this.db
      .prepare(
        `SELECT l.*, s.member_number, b.server_id AS book_server_id,
           sub.server_id AS subscription_server_id
         FROM loans l
         JOIN subscribers s ON s.id=l.subscriber_id
         JOIN books b ON b.id=l.book_id
         LEFT JOIN subscriptions sub ON sub.id=l.subscription_id
         WHERE l.id=?`,
      )
      .get(Number(loanId));
    if (!row?.server_id || !row.book_server_id) return;
    this.queueEntity("loans", row.id, "loan", row.server_id, {
      serverId: row.server_id,
      bookServerId: row.book_server_id,
      memberNumber: row.member_number,
      subscriptionServerId: row.subscription_server_id || null,
      borrowedAt: row.borrowed_at,
      dueAt: row.due_at,
      returnedAt: row.returned_at || null,
      status: row.status,
      notes: row.notes || "",
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  }

  queueEntity(table, id, entityType, serverId, payload) {
    this.db
      .prepare(`UPDATE ${table} SET sync_state='pending' WHERE id=?`)
      .run(id);
    this.db
      .prepare(
        `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at, entity_type)
         VALUES (?, 'upsert', ?, ?, ?, ?)
         ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
           operation=excluded.operation, payload=excluded.payload,
           created_at=excluded.created_at, entity_type=excluded.entity_type`,
      )
      .run(
        randomUUID(),
        serverId,
        JSON.stringify(payload),
        new Date().toISOString(),
        entityType,
      );
    this.onMutation?.();
  }

  queueEntityDelete(entityType, serverId) {
    this.db
      .prepare(
        `INSERT INTO sync_outbox(mutation_id, operation, entity_id, payload, created_at, entity_type)
         VALUES (?, 'delete', ?, NULL, ?, ?)
         ON CONFLICT(entity_id) DO UPDATE SET mutation_id=excluded.mutation_id,
           operation=excluded.operation, payload=NULL,
           created_at=excluded.created_at, entity_type=excluded.entity_type`,
      )
      .run(randomUUID(), serverId, new Date().toISOString(), entityType);
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
    const subscribers = this.db
      .prepare("SELECT * FROM subscribers WHERE sync_state <> 'synced'")
      .all();
    const subscriptions = this.db
      .prepare("SELECT id FROM subscriptions WHERE sync_state <> 'synced' ORDER BY id")
      .all();
    const loans = this.db
      .prepare("SELECT id FROM loans WHERE sync_state <> 'synced' ORDER BY id")
      .all();
    const staff = this.db
      .prepare("SELECT * FROM staff WHERE sync_state <> 'synced'")
      .all();
    if (
      !books.length &&
      !subscribers.length &&
      !subscriptions.length &&
      !loans.length &&
      !staff.length
    )
      return;
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
      for (const subscriber of subscribers)
        this.queueSubscriberMutation(subscriber);
      for (const subscription of subscriptions)
        this.queueSubscriptionMutation(subscription.id);
      for (const loan of loans) this.queueLoanMutation(loan.id);
      for (const member of staff) this.queueStaffMutation(member);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  /**
   * Le serveur a perdu ses données (base recréée) : tout ce que ce poste
   * possède repart vers lui, et les changements sont relus depuis le début.
   */
  resetSyncState() {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      for (const table of ["books", "subscribers", "subscriptions", "loans", "staff"])
        this.db.exec(`UPDATE ${table} SET sync_state='pending'`);
      this.setSyncMeta("cursor", 0);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    this.setSettings({ sync_report_activity_id: "0" });
    this.prepareInitialSync();
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
      "SELECT entity_id, entity_type FROM sync_outbox WHERE mutation_id=?",
    );
    const bookSynced = this.db.prepare(
      "UPDATE books SET sync_state='synced' WHERE server_id=?",
    );
    const subscriberSynced = this.db.prepare(
      "UPDATE subscribers SET sync_state='synced' WHERE member_number=?",
    );
    const lendingSynced = {
      subscription: this.db.prepare(
        "UPDATE subscriptions SET sync_state='synced' WHERE server_id=?",
      ),
      loan: this.db.prepare(
        "UPDATE loans SET sync_state='synced' WHERE server_id=?",
      ),
      staff: this.db.prepare(
        "UPDATE staff SET sync_state='synced' WHERE server_id=?",
      ),
    };
    const remove = this.db.prepare(
      "DELETE FROM sync_outbox WHERE mutation_id=?",
    );
    this.db.exec("BEGIN");
    try {
      for (const mutationId of mutationIds) {
        const mutation = find.get(mutationId);
        if (mutation?.entity_type === "subscriber")
          subscriberSynced.run(mutation.entity_id);
        else if (lendingSynced[mutation?.entity_type])
          lendingSynced[mutation.entity_type].run(mutation.entity_id);
        else if (mutation) bookSynced.run(mutation.entity_id);
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
      // Livres et abonnés d'abord : abonnements et emprunts les référencent.
      const ordered = (Array.isArray(changes) ? changes : [])
        .filter(Boolean)
        .sort((a, b) => changePriority(a) - changePriority(b));
      for (const change of ordered) {
        const serverId = String(change?.entityId || "");
        if (!serverId || pending.get(serverId)) continue;
        const entityType = change.entityType || "book";
        if (entityType === "subscriber") {
          this.applyRemoteSubscriber(change, serverId);
          continue;
        }
        if (entityType === "subscription" || entityType === "loan") {
          this.applyLendingChange(change);
          continue;
        }
        if (entityType === "staff") {
          this.applyRemoteStaff(change, serverId);
          continue;
        }
        if (entityType === "gate_day") {
          this.applyRemoteGateDay(change, serverId);
          continue;
        }
        if (entityType === "staff_passage") {
          this.applyRemoteStaffPassage(change, serverId);
          continue;
        }
        if (entityType !== "book") continue;
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
      this.retryDeferred();
      this.setSyncMeta("cursor", cursor);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw new Error(`Conflit de synchronisation du catalogue : ${error.message}`);
    }
  }

  /**
   * Applique un abonnement ou un emprunt distant ; s'il référence un livre ou
   * un abonné encore inconnu, il est mis de côté et réessayé plus tard.
   */
  applyLendingChange(change) {
    const entityType = change.entityType;
    const serverId = String(change.entityId);
    const applied =
      entityType === "loan"
        ? this.applyRemoteLoan(change, serverId)
        : this.applyRemoteSubscription(change, serverId);
    if (applied)
      this.db
        .prepare(
          "DELETE FROM sync_deferred WHERE entity_type=? AND entity_id=?",
        )
        .run(entityType, serverId);
    else
      this.db
        .prepare(
          `INSERT INTO sync_deferred(entity_type, entity_id, change) VALUES (?, ?, ?)
           ON CONFLICT(entity_type, entity_id) DO UPDATE SET change=excluded.change`,
        )
        .run(entityType, serverId, JSON.stringify(change));
  }

  retryDeferred() {
    const deferred = this.db
      .prepare("SELECT change FROM sync_deferred")
      .all()
      .map((row) => JSON.parse(row.change))
      .sort((a, b) => changePriority(a) - changePriority(b));
    for (const change of deferred) this.applyLendingChange(change);
  }

  localId(table, column, value) {
    const key = cleanText(value, 200);
    if (!key) return null;
    return (
      this.db
        .prepare(`SELECT id FROM ${table} WHERE ${column}=? LIMIT 1`)
        .get(column === "member_number" ? key.toUpperCase() : key)?.id ?? null
    );
  }

  applyRemoteSubscription(change, serverId) {
    if (change.operation === "delete") {
      this.db.prepare("DELETE FROM subscriptions WHERE server_id=?").run(serverId);
      return true;
    }
    const remote = change.subscription;
    if (!remote) return true;
    const subscriberId = this.localId(
      "subscribers",
      "member_number",
      remote.memberNumber,
    );
    if (!subscriberId) return false;
    const now = new Date().toISOString();
    const status = ["active", "expired", "suspended"].includes(remote.status)
      ? remote.status
      : "active";
    this.db
      .prepare(
        `INSERT INTO subscriptions (server_id, subscriber_id, starts_at, ends_at, status,
           created_at, updated_at, sync_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'synced')
         ON CONFLICT(server_id) DO UPDATE SET subscriber_id=excluded.subscriber_id,
           starts_at=excluded.starts_at, ends_at=excluded.ends_at, status=excluded.status,
           updated_at=excluded.updated_at, sync_state='synced'`,
      )
      .run(
        serverId,
        subscriberId,
        remote.startsAt || now,
        remote.endsAt || now,
        status,
        remote.createdAt || now,
        remote.updatedAt || now,
      );
    return true;
  }

  applyRemoteLoan(change, serverId) {
    if (change.operation === "delete") {
      const loan = this.db
        .prepare("SELECT book_id FROM loans WHERE server_id=?")
        .get(serverId);
      this.db.prepare("DELETE FROM loans WHERE server_id=?").run(serverId);
      if (loan) this.syncBookLoanStatus(loan.book_id);
      return true;
    }
    const remote = change.loan;
    if (!remote) return true;
    const bookId = this.localId("books", "server_id", remote.bookServerId);
    const subscriberId = this.localId(
      "subscribers",
      "member_number",
      remote.memberNumber,
    );
    if (!bookId || !subscriberId) return false;
    const now = new Date().toISOString();
    const borrowedAt = remote.borrowedAt || now;
    const returnedAt = remote.returnedAt || null;
    const existing = this.localId("loans", "server_id", serverId);
    // Un seul emprunt en cours par livre : un autre emprunt local encore
    // ouvert a forcément été rendu avant ce nouvel emprunt.
    if (!returnedAt)
      this.db
        .prepare(
          `UPDATE loans SET returned_at=?, status='returned', updated_at=?
           WHERE book_id=? AND returned_at IS NULL AND id<>?`,
        )
        .run(borrowedAt, now, bookId, existing ?? -1);
    const status = ["active", "returned", "late"].includes(remote.status)
      ? remote.status
      : "active";
    this.db
      .prepare(
        `INSERT INTO loans (server_id, book_id, subscriber_id, subscription_id, borrowed_at,
           due_at, returned_at, status, notes, created_at, updated_at, sync_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
         ON CONFLICT(server_id) DO UPDATE SET book_id=excluded.book_id,
           subscriber_id=excluded.subscriber_id, subscription_id=excluded.subscription_id,
           borrowed_at=excluded.borrowed_at, due_at=excluded.due_at,
           returned_at=excluded.returned_at, status=excluded.status, notes=excluded.notes,
           updated_at=excluded.updated_at, sync_state='synced'`,
      )
      .run(
        serverId,
        bookId,
        subscriberId,
        this.localId("subscriptions", "server_id", remote.subscriptionServerId),
        borrowedAt,
        remote.dueAt || borrowedAt,
        returnedAt,
        status,
        cleanText(remote.notes, 1000),
        remote.createdAt || now,
        remote.updatedAt || now,
      );
    this.syncBookLoanStatus(bookId);
    return true;
  }

  /** Aligne le statut local du livre sur ses emprunts. */
  syncBookLoanStatus(bookId) {
    const active = this.db
      .prepare("SELECT 1 FROM loans WHERE book_id=? AND returned_at IS NULL LIMIT 1")
      .get(bookId);
    if (active)
      this.db
        .prepare("UPDATE books SET status='indisponible' WHERE id=?")
        .run(bookId);
    else
      this.db
        .prepare(
          `UPDATE books SET status=CASE WHEN tid IS NULL THEN 'a_encoder' ELSE 'encode' END
           WHERE id=? AND status='indisponible'`,
        )
        .run(bookId);
  }

  applyRemoteSubscriber(change, memberNumber) {
    const number = cleanText(memberNumber, 80).toUpperCase();
    if (change.operation === "delete") {
      // Les emprunts référencent l'abonné : on le désactive sans le supprimer.
      this.db
        .prepare(
          "UPDATE subscribers SET active=0, card_tid=NULL, sync_state='synced' WHERE member_number=?",
        )
        .run(number);
      return;
    }
    const remote = change.subscriber;
    if (!remote) return;
    const cardEpc = cleanText(remote.cardEpc, 128).toUpperCase() || null;
    const cardTid = cleanText(remote.cardTid, 128).toUpperCase() || null;
    // Une carte réencodée ailleurs pour un autre abonné quitte l'ancien.
    if (cardTid)
      this.db
        .prepare(
          "UPDATE subscribers SET card_tid=NULL, card_tagged_at=NULL WHERE card_tid=? AND member_number<>?",
        )
        .run(cardTid, number);
    if (cardEpc)
      this.db
        .prepare(
          "UPDATE subscribers SET card_epc=NULL WHERE card_epc=? AND member_number<>?",
        )
        .run(cardEpc, number);
    const now = new Date().toISOString();
    this.db
      .prepare(
        `INSERT INTO subscribers (member_number, name, email, phone, active, card_epc,
           card_tid, card_tagged_at, created_at, updated_at, sync_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
         ON CONFLICT(member_number) DO UPDATE SET
           name=excluded.name, email=excluded.email, phone=excluded.phone,
           active=excluded.active, card_epc=COALESCE(excluded.card_epc, subscribers.card_epc),
           card_tid=excluded.card_tid, card_tagged_at=excluded.card_tagged_at,
           updated_at=excluded.updated_at, sync_state='synced'`,
      )
      .run(
        number,
        cleanText(remote.name || number, 240),
        cleanText(remote.email, 240),
        cleanText(remote.phone, 80),
        remote.active === false ? 0 : 1,
        cardEpc ?? generateCardEpc(),
        cardTid,
        cleanText(remote.cardTaggedAt, 100) || null,
        cleanText(remote.createdAt, 100) || now,
        cleanText(remote.updatedAt, 100) || now,
      );
  }

  applyRemoteStaff(change, serverId) {
    if (change.operation === "delete") {
      this.db.prepare("DELETE FROM staff WHERE server_id=?").run(serverId);
      return;
    }
    const remote = change.staff;
    if (!remote) return;
    const badgeEpc = cleanText(remote.badgeEpc, 128).toUpperCase() || null;
    const badgeTid = cleanText(remote.badgeTid, 128).toUpperCase() || null;
    // Un badge réencodé ailleurs pour une autre personne quitte l'ancienne.
    if (badgeTid)
      this.db
        .prepare(
          "UPDATE staff SET badge_tid=NULL, badge_tagged_at=NULL WHERE badge_tid=? AND server_id<>?",
        )
        .run(badgeTid, serverId);
    if (badgeEpc)
      this.db
        .prepare(
          "UPDATE staff SET badge_epc=NULL WHERE badge_epc=? AND server_id<>?",
        )
        .run(badgeEpc, serverId);
    const now = new Date().toISOString();
    this.db
      .prepare(
        `INSERT INTO staff (server_id, staff_number, name, position, email, phone, active,
           badge_epc, badge_tid, badge_tagged_at, created_at, updated_at, sync_state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
         ON CONFLICT(server_id) DO UPDATE SET staff_number=excluded.staff_number,
           name=excluded.name, position=excluded.position, email=excluded.email,
           phone=excluded.phone, active=excluded.active,
           badge_epc=COALESCE(excluded.badge_epc, staff.badge_epc),
           badge_tid=excluded.badge_tid, badge_tagged_at=excluded.badge_tagged_at,
           updated_at=excluded.updated_at, sync_state='synced'`,
      )
      .run(
        serverId,
        cleanText(remote.staffNumber, 80).toUpperCase() || serverId.slice(0, 8),
        cleanText(remote.name || remote.staffNumber, 240),
        cleanText(remote.position, 120),
        cleanText(remote.email, 240),
        cleanText(remote.phone, 80),
        remote.active === false ? 0 : 1,
        badgeEpc ?? generateBadgeEpc(),
        badgeTid,
        cleanText(remote.badgeTaggedAt, 100) || null,
        cleanText(remote.createdAt, 100) || now,
        cleanText(remote.updatedAt, 100) || now,
      );
  }

  applyRemoteGateDay(change, serverId) {
    if (change.operation === "delete") {
      this.db.prepare("DELETE FROM gate_days WHERE server_id=?").run(serverId);
      return;
    }
    const remote = change.gateDay;
    if (!remote || !/^\d{4}-\d{2}-\d{2}$/.test(remote.day || "")) return;
    this.db
      .prepare(
        `INSERT INTO gate_days (server_id, gate_id, gate_name, day, entries, exits, alarms, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(server_id) DO UPDATE SET gate_name=excluded.gate_name,
           entries=excluded.entries, exits=excluded.exits, alarms=excluded.alarms,
           updated_at=excluded.updated_at`,
      )
      .run(
        serverId,
        cleanText(remote.gateId, 120),
        cleanText(remote.gateName, 120),
        remote.day,
        Math.max(0, Number(remote.entries) || 0),
        Math.max(0, Number(remote.exits) || 0),
        Math.max(0, Number(remote.alarms) || 0),
        cleanText(remote.updatedAt, 100) || new Date().toISOString(),
      );
  }

  applyRemoteStaffPassage(change, serverId) {
    if (change.operation === "delete") {
      this.db
        .prepare("DELETE FROM staff_passages WHERE server_id=?")
        .run(serverId);
      return;
    }
    const remote = change.staffPassage;
    if (!remote || !["in", "out"].includes(remote.direction)) return;
    this.db
      .prepare(
        `INSERT INTO staff_passages (server_id, staff_server_id, staff_number, staff_name,
           direction, passed_at, gate_id, gate_name)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(server_id) DO UPDATE SET staff_server_id=excluded.staff_server_id,
           staff_number=excluded.staff_number, staff_name=excluded.staff_name,
           direction=excluded.direction, passed_at=excluded.passed_at,
           gate_id=excluded.gate_id, gate_name=excluded.gate_name`,
      )
      .run(
        serverId,
        cleanText(remote.staffServerId, 120),
        cleanText(remote.staffNumber, 80),
        cleanText(remote.staffName, 240),
        remote.direction,
        cleanText(remote.passedAt, 100) || new Date().toISOString(),
        cleanText(remote.gateId, 120),
        cleanText(remote.gateName, 120),
      );
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
