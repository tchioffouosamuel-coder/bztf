import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../core/epc.dart';
import '../core/password.dart';
import '../models/book.dart';
import '../models/lending.dart';
import '../models/staff.dart';
import '../models/user.dart';

class LibraryDatabase {
  LibraryDatabase._();

  static final LibraryDatabase instance = LibraryDatabase._();
  Database? _database;

  Future<Database> get database async {
    if (_database case final database?) return database;
    final directory = await getDatabasesPath();
    _database = await openDatabase(
      path.join(directory, 'biblio_rfid.db'),
      version: 8,
      onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE books (
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
            status TEXT NOT NULL DEFAULT 'a_encoder'
              CHECK(status IN ('a_encoder', 'encode', 'indisponible')),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            tagged_at TEXT,
            import_key TEXT UNIQUE
            ,server_id TEXT UNIQUE
            ,server_revision INTEGER NOT NULL DEFAULT 0
            ,sync_state TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
        await database.execute('''
          CREATE TABLE activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            result TEXT NOT NULL,
            book_id INTEGER,
            message TEXT NOT NULL,
            epc TEXT,
            tid TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE SET NULL
          )
        ''');
        await _createSyncTables(database);
        await _createLendingTables(database);
        await _addSubscriberCards(database);
        await _addSubscriberSync(database);
        await _addLendingSync(database);
        await _createUsers(database);
        await _createGateTables(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute('ALTER TABLE books ADD COLUMN server_id TEXT');
          await database.execute(
            'ALTER TABLE books ADD COLUMN server_revision INTEGER NOT NULL DEFAULT 0',
          );
          await database.execute(
            "ALTER TABLE books ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'",
          );
          await database.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_books_server_id ON books(server_id)',
          );
          final rows = await database.query('books', columns: ['id']);
          for (final row in rows) {
            await database.update(
              'books',
              {'server_id': _newId()},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          }
          await _createSyncTables(database);
        }
        if (oldVersion < 3) await _createLendingTables(database);
        if (oldVersion < 4) await _addSubscriberCards(database);
        if (oldVersion < 5) await _addSubscriberSync(database);
        if (oldVersion < 6) await _addLendingSync(database);
        if (oldVersion < 7) await _createUsers(database);
        if (oldVersion < 8) await _createGateTables(database);
      },
    );
    return _database!;
  }

  Future<List<Book>> listBooks({
    String search = '',
    String status = 'tous',
    int limit = 200,
    int offset = 0,
  }) async {
    final db = await database;
    final where = <String>[];
    final args = <Object?>[];
    if (search.trim().isNotEmpty) {
      where.add(
        '(title LIKE ? OR author LIKE ? OR isbn LIKE ? OR accession LIKE ? OR epc LIKE ?)',
      );
      final term = '%${search.trim()}%';
      args.addAll(List.filled(5, term));
    }
    if (const ['a_encoder', 'encode', 'indisponible'].contains(status)) {
      where.add('status = ?');
      args.add(status);
    }
    final rows = await db.query(
      'books',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(Book.fromMap).toList();
  }

  /// Comptes de l'appareil pour le rapport d'appareil : jamais de mot de
  /// passe ni de sel.
  Future<List<Map<String, Object?>>> reportUsers() async {
    final rows = await (await database).query(
      'users',
      columns: [
        'id',
        'name',
        'email',
        'role',
        'active',
        'created_at',
        'updated_at',
      ],
      orderBy: 'id',
    );
    return [
      for (final row in rows)
        {
          'localId': row['id'],
          'name': row['name'],
          'email': row['email'],
          'role': row['role'],
          'active': row['active'] == 1,
          'createdAt': row['created_at'],
          'updatedAt': row['updated_at'],
        },
    ];
  }

  /// Journal d'activité postérieur à [afterId], pour le rapport d'appareil.
  Future<List<Map<String, Object?>>> reportActivity(
    int afterId, {
    int limit = 1000,
  }) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT a.*, b.server_id AS book_server_id
      FROM activity a LEFT JOIN books b ON b.id = a.book_id
      WHERE a.id > ? ORDER BY a.id LIMIT ?
    ''',
      [afterId, limit],
    );
    return [
      for (final row in rows)
        {
          'localId': row['id'],
          'type': row['type'],
          'result': row['result'],
          'message': row['message'],
          'epc': row['epc'],
          'tid': row['tid'],
          'bookServerId': row['book_server_id'],
          'createdAt': row['created_at'],
        },
    ];
  }

  /// Catalogue consultable par les abonnés au poste : chaque exemplaire,
  /// son emplacement et, s'il est emprunté, son retour prévu.
  Future<List<CatalogEntry>> browseCatalog({
    String search = '',
    bool availableOnly = false,
    int limit = 100,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    final term = search.trim();
    if (term.isNotEmpty) {
      where.add(
        '(b.title LIKE ? OR b.author LIKE ? OR b.isbn LIKE ? '
        'OR b.category LIKE ? OR b.shelf LIKE ?)',
      );
      args.addAll(List.filled(5, '%$term%'));
    }
    if (availableOnly) {
      where.add("l.id IS NULL AND b.status <> 'indisponible'");
    }
    final rows = await (await database).rawQuery(
      '''
      SELECT b.*, l.due_at AS loan_due_at
      FROM books b
      LEFT JOIN loans l ON l.book_id = b.id AND l.returned_at IS NULL
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY b.title COLLATE NOCASE, b.accession
      LIMIT ?
    ''',
      [...args, limit],
    );
    return rows.map(CatalogEntry.fromMap).toList();
  }

  Future<int> countBooks({String search = '', String status = 'tous'}) async {
    final db = await database;
    final terms = <String>[];
    final args = <Object?>[];
    if (search.trim().isNotEmpty) {
      terms.add(
        '(title LIKE ? OR author LIKE ? OR isbn LIKE ? OR accession LIKE ? OR epc LIKE ?)',
      );
      final term = '%${search.trim()}%';
      args.addAll(List.filled(5, term));
    }
    if (const ['a_encoder', 'encode', 'indisponible'].contains(status)) {
      terms.add('status = ?');
      args.add(status);
    }
    final where = terms.isEmpty ? '' : ' WHERE ${terms.join(' AND ')}';
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM books$where',
      args.isEmpty ? null : args,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Map<String, int>> dashboardCounts() async {
    final db = await database;
    final row = (await db.rawQuery('''
      SELECT COUNT(*) AS total,
        SUM(CASE WHEN status='encode' THEN 1 ELSE 0 END) AS tagged,
        SUM(CASE WHEN status='a_encoder' THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN date(created_at)=date('now') THEN 1 ELSE 0 END) AS today
      FROM books
    ''')).first;
    return {
      for (final key in ['total', 'tagged', 'pending', 'today'])
        key: (row[key] as num?)?.toInt() ?? 0,
    };
  }

  Future<Book?> getBook(int id) async {
    final rows = await (await database).query(
      'books',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  Future<Book> createBook(Map<String, Object?> values) async {
    final title = _clean(values['title'], 240);
    if (title.isEmpty) throw ArgumentError('Le titre est obligatoire.');
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    return db.transaction((transaction) async {
      final placeholder = 'PENDING-${DateTime.now().microsecondsSinceEpoch}';
      final id = await transaction.insert('books', {
        'accession': '$placeholder-A',
        'epc': '$placeholder-E',
        ..._bookFields(values),
        'title': title,
        'status': 'a_encoder',
        'created_at': now,
        'updated_at': now,
        'server_id': _newId(),
        'sync_state': 'pending',
      });
      final year = DateTime.now().year;
      final accession = formatAccession(year, id);
      final epc = generateEpc(year, id);
      await transaction.update(
        'books',
        {'accession': accession, 'epc': epc},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _addActivity(
        transaction,
        'catalogue',
        'succes',
        id,
        'Livre ajouté au catalogue',
        epc,
        null,
        now,
      );
      final book = Book.fromMap(
        (await transaction.query(
          'books',
          where: 'id = ?',
          whereArgs: [id],
        )).first,
      );
      await _queueBook(transaction, book);
      return book;
    });
  }

  Future<Book> updateBook(int id, Map<String, Object?> values) async {
    final title = _clean(values['title'], 240);
    if (title.isEmpty) throw ArgumentError('Le titre est obligatoire.');
    final db = await database;
    return db.transaction((transaction) async {
      await transaction.update(
        'books',
        {
          ..._bookFields(values),
          'title': title,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'sync_state': 'pending',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      final rows = await transaction.query(
        'books',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Livre introuvable.');
      final book = Book.fromMap(rows.first);
      await _queueBook(transaction, book);
      return book;
    });
  }

  Future<void> deleteBook(Book book) async {
    final db = await database;
    final loan = await activeLoanForBook(book.id);
    if (loan != null) {
      throw StateError(
        'Ce livre est emprunté par ${loan.subscriberName}. Enregistrez son retour avant de le supprimer.',
      );
    }
    await db.transaction((transaction) async {
      await _queueDelete(transaction, book);
      // L'historique des emprunts rendus reste tracé dans `activity`.
      final loans = await transaction.query(
        'loans',
        columns: ['server_id'],
        where: 'book_id = ? AND server_id IS NOT NULL',
        whereArgs: [book.id],
      );
      for (final row in loans) {
        await _queueEntityDelete(
          transaction,
          'loan',
          row['server_id'] as String,
        );
      }
      await transaction.delete(
        'loans',
        where: 'book_id = ?',
        whereArgs: [book.id],
      );
      await transaction.delete('books', where: 'id = ?', whereArgs: [book.id]);
      await _addActivity(
        transaction,
        'catalogue',
        'succes',
        null,
        'Livre supprimé : ${book.accession}',
        book.epc,
        book.tid,
        DateTime.now().toUtc().toIso8601String(),
      );
    });
  }

  Future<int> countUsers() async =>
      Sqflite.firstIntValue(
        await (await database).rawQuery('SELECT COUNT(*) FROM users'),
      ) ??
      0;

  Future<List<AppUser>> listUsers() async {
    final rows = await (await database).query(
      'users',
      columns: ['id', 'name', 'email', 'role', 'active'],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(AppUser.fromMap).toList();
  }

  /// Crée un compte ; le premier compte de l'appareil est toujours
  /// administrateur.
  Future<AppUser> createUser({
    required String name,
    required String email,
    required String password,
    String role = 'operateur',
  }) async {
    final normalizedName = _clean(name, 120);
    final normalizedEmail = _clean(email, 240).toLowerCase();
    if (normalizedName.length < 2) {
      throw ArgumentError('Le nom doit contenir au moins 2 caractères.');
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
      throw ArgumentError('L’adresse e-mail est invalide.');
    }
    _checkPassword(password);
    final salt = newPasswordSalt();
    final hash = await hashPassword(password, salt, passwordIterations);
    final now = DateTime.now().toUtc().toIso8601String();
    final db = await database;
    final first = await countUsers() == 0;
    try {
      final id = await db.insert('users', {
        'name': normalizedName,
        'email': normalizedEmail,
        'password_hash': hash,
        'password_salt': salt,
        'password_iterations': passwordIterations,
        'role': first || role == 'admin' ? 'admin' : 'operateur',
        'created_at': now,
        'updated_at': now,
      });
      await addActivity(
        'compte',
        'succes',
        'Compte créé : $normalizedName ($normalizedEmail)',
      );
      return (await _user(id))!;
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw StateError('Un compte utilise déjà cette adresse e-mail.');
      }
      rethrow;
    }
  }

  /// Compte actif correspondant, ou `null` si l'identification échoue.
  Future<AppUser?> authenticateUser(String email, String password) async {
    final rows = await (await database).query(
      'users',
      where: 'email = ? AND active = 1',
      whereArgs: [_clean(email, 240).toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) {
      // Même coût de calcul qu'un compte existant.
      await hashPassword(password, newPasswordSalt(), passwordIterations);
      return null;
    }
    final row = rows.first;
    final hash = await hashPassword(
      password,
      row['password_salt'] as String,
      (row['password_iterations'] as num).toInt(),
    );
    return sameDigest(hash, row['password_hash'] as String)
        ? AppUser.fromMap(row)
        : null;
  }

  Future<void> changePassword(
    int userId, {
    required String current,
    required String next,
  }) async {
    final user = await _user(userId);
    if (user == null || await authenticateUser(user.email, current) == null) {
      throw StateError('Mot de passe actuel incorrect.');
    }
    _checkPassword(next);
    final salt = newPasswordSalt();
    await (await database).update(
      'users',
      {
        'password_hash': await hashPassword(next, salt, passwordIterations),
        'password_salt': salt,
        'password_iterations': passwordIterations,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Active ou désactive un compte ; le dernier administrateur actif reste.
  Future<void> setUserActive(int userId, bool active) async {
    final user = await _user(userId);
    if (user == null) throw StateError('Compte introuvable.');
    final db = await database;
    if (!active && user.isAdmin) {
      final admins = Sqflite.firstIntValue(
        await db.rawQuery(
          "SELECT COUNT(*) FROM users WHERE role = 'admin' AND active = 1",
        ),
      );
      if ((admins ?? 0) <= 1) {
        throw StateError(
          'Le dernier administrateur ne peut pas être désactivé.',
        );
      }
    }
    await db.update(
      'users',
      {
        'active': active ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<AppUser?> _user(int id) async {
    final rows = await (await database).query(
      'users',
      columns: ['id', 'name', 'email', 'role', 'active'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : AppUser.fromMap(rows.first);
  }

  static void _checkPassword(String password) {
    if (password.length < 8) {
      throw ArgumentError(
        'Le mot de passe doit contenir au moins 8 caractères.',
      );
    }
  }

  Future<List<Subscriber>> listSubscribers({String search = ''}) async {
    final term = '%${_clean(search, 120)}%';
    final rows = await (await database).rawQuery(
      '''
      SELECT s.*,
        (SELECT ends_at FROM subscriptions
          WHERE subscriber_id = s.id AND status = 'active'
          ORDER BY ends_at DESC LIMIT 1) AS subscription_ends_at,
        (SELECT COUNT(*) FROM loans
          WHERE subscriber_id = s.id AND returned_at IS NULL) AS active_loans,
        (SELECT COUNT(*) FROM loans
          WHERE subscriber_id = s.id AND returned_at IS NULL
            AND due_at < ?) AS overdue_loans
      FROM subscribers s
      WHERE s.member_number LIKE ? OR s.name LIKE ? OR s.email LIKE ? OR s.phone LIKE ?
      ORDER BY s.name COLLATE NOCASE LIMIT 100
    ''',
      [DateTime.now().toUtc().toIso8601String(), ...List.filled(4, term)],
    );
    return rows.map(Subscriber.fromMap).toList();
  }

  Future<Subscriber?> getSubscriber(int id) async {
    final rows = await (await database).query(
      'subscribers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Subscriber.fromMap(rows.first);
  }

  /// Crée l'abonné ou met à jour ses coordonnées (clé : numéro d'abonné) et
  /// lui réserve l'EPC de sa carte.
  Future<Subscriber> saveSubscriber({
    required String memberNumber,
    required String name,
    String email = '',
    String phone = '',
  }) async {
    final normalizedNumber = _clean(memberNumber, 80).toUpperCase();
    final normalizedName = _clean(name, 240);
    if (normalizedNumber.isEmpty) {
      throw ArgumentError('Le numéro d’abonné est obligatoire.');
    }
    if (normalizedName.isEmpty) {
      throw ArgumentError('Le nom de l’abonné est obligatoire.');
    }
    return (await database).transaction(
      (transaction) => _upsertSubscriber(
        transaction,
        memberNumber: normalizedNumber,
        name: normalizedName,
        email: email,
        phone: phone,
        timestamp: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// Abonné correspondant au tag lu, si c'est une carte encodée.
  Future<Subscriber?> recognizeCard(String epc, String tid) async {
    final normalizedEpc = epc.trim().toUpperCase();
    final normalizedTid = tid.trim().toUpperCase();
    if (!isCardEpc(normalizedEpc)) return null;
    final rows = await (await database).query(
      'subscribers',
      where: 'card_epc = ? AND card_tid IS NOT NULL AND active = 1',
      whereArgs: [normalizedEpc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final subscriber = Subscriber.fromMap(rows.first);
    // Un EPC recopié sur un autre tag ne suffit pas : le TID doit correspondre.
    if (normalizedTid.isNotEmpty && subscriber.cardTid != normalizedTid) {
      return null;
    }
    return subscriber;
  }

  Future<Subscriber> markCardTagged(int subscriberId, String tid) async {
    final subscriber = await getSubscriber(subscriberId);
    if (subscriber == null) throw StateError('Abonné introuvable.');
    final normalizedTid = tid.trim().toUpperCase();
    if (normalizedTid.isEmpty) {
      throw ArgumentError('Le TID de la carte est obligatoire.');
    }
    final db = await database;
    final book = await db.query(
      'books',
      columns: ['accession'],
      where: 'tid = ?',
      whereArgs: [normalizedTid],
      limit: 1,
    );
    if (book.isNotEmpty) {
      throw StateError(
        'Ce tag est déjà lié au livre ${book.first['accession']}.',
      );
    }
    final other = await db.query(
      'subscribers',
      columns: ['name'],
      where: 'card_tid = ? AND id <> ?',
      whereArgs: [normalizedTid, subscriberId],
      limit: 1,
    );
    if (other.isNotEmpty) {
      throw StateError('Ce tag est déjà la carte de ${other.first['name']}.');
    }
    final badge = await _badgeOwner(db, normalizedTid);
    if (badge != null) {
      throw StateError('Ce tag est déjà le badge de $badge.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((transaction) async {
      await transaction.update(
        'subscribers',
        {'card_tid': normalizedTid, 'card_tagged_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [subscriberId],
      );
      await _queueSubscriber(
        transaction,
        await _subscriberIn(transaction, subscriberId),
      );
      await _addActivity(
        transaction,
        'carte',
        'succes',
        null,
        'Carte encodée pour ${subscriber.name} (${subscriber.memberNumber})',
        subscriber.cardEpc,
        normalizedTid,
        now,
      );
    });
    return (await getSubscriber(subscriberId))!;
  }

  static const _loanSelect = '''
      SELECT l.*, s.member_number, s.name AS subscriber_name,
        s.email AS subscriber_email, s.phone AS subscriber_phone,
        sub.ends_at AS subscription_ends_at,
        b.title AS book_title, b.accession AS book_accession
      FROM loans l
      JOIN subscribers s ON s.id = l.subscriber_id
      LEFT JOIN subscriptions sub ON sub.id = l.subscription_id
      LEFT JOIN books b ON b.id = l.book_id
  ''';

  Future<Loan?> activeLoanForBook(int bookId) async {
    final rows = await (await database).rawQuery(
      '''
      $_loanSelect
      WHERE l.book_id = ? AND l.returned_at IS NULL
      ORDER BY l.id DESC LIMIT 1
    ''',
      [bookId],
    );
    return rows.isEmpty ? null : Loan.fromMap(rows.first);
  }

  /// Historique des emprunts pour le terminal admin.
  Future<List<Loan>> listLoans({
    LoanFilter filter = LoanFilter.all,
    String search = '',
    int? subscriberId,
    int limit = 100,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    final now = DateTime.now().toUtc().toIso8601String();
    switch (filter) {
      case LoanFilter.active:
        where.add('l.returned_at IS NULL');
      case LoanFilter.overdue:
        where.add('l.returned_at IS NULL AND l.due_at < ?');
        args.add(now);
      case LoanFilter.returned:
        where.add('l.returned_at IS NOT NULL');
      case LoanFilter.all:
        break;
    }
    if (subscriberId != null) {
      where.add('l.subscriber_id = ?');
      args.add(subscriberId);
    }
    final term = _clean(search, 120);
    if (term.isNotEmpty) {
      where.add(
        '(b.title LIKE ? OR b.accession LIKE ? OR s.name LIKE ? OR s.member_number LIKE ?)',
      );
      args.addAll(List.filled(4, '%$term%'));
    }
    final orderBy = switch (filter) {
      LoanFilter.overdue => 'l.due_at ASC',
      LoanFilter.returned => 'l.returned_at DESC',
      _ => 'COALESCE(l.returned_at, l.borrowed_at) DESC',
    };
    final rows = await (await database).rawQuery(
      '''
      $_loanSelect
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY $orderBy, l.id DESC LIMIT ? OFFSET ?
    ''',
      [...args, limit, offset],
    );
    return rows.map(Loan.fromMap).toList();
  }

  Future<LoanStats> loanStats() async {
    final row = (await (await database).rawQuery(
      '''
      SELECT COUNT(*) AS total,
        SUM(CASE WHEN returned_at IS NULL THEN 1 ELSE 0 END) AS active,
        SUM(CASE WHEN returned_at IS NULL AND due_at < ? THEN 1 ELSE 0 END) AS overdue,
        SUM(CASE WHEN date(borrowed_at) = date('now') THEN 1 ELSE 0 END) AS borrowed_today,
        SUM(CASE WHEN date(returned_at) = date('now') THEN 1 ELSE 0 END) AS returned_today
      FROM loans
    ''',
      [DateTime.now().toUtc().toIso8601String()],
    )).first;
    int value(String key) => (row[key] as num?)?.toInt() ?? 0;
    return LoanStats(
      active: value('active'),
      overdue: value('overdue'),
      borrowedToday: value('borrowed_today'),
      returnedToday: value('returned_today'),
      total: value('total'),
    );
  }

  Future<List<Loan>> _loansByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await (await database).rawQuery('''
      $_loanSelect
      WHERE l.id IN (${List.filled(ids.length, '?').join(', ')})
      ORDER BY l.id
    ''', ids);
    return rows.map(Loan.fromMap).toList();
  }

  /// Deux lecteurs ne lisent pas toujours la même longueur de TID : un
  /// préfixe commun d'au moins 8 octets identifie la même puce.
  static bool tidMatches(String? stored, String read) {
    final known = (stored ?? '').trim().toUpperCase();
    final seen = read.trim().toUpperCase();
    if (known.isEmpty || seen.isEmpty) return false;
    if (known == seen) return true;
    final common = min(known.length, seen.length);
    return common >= 16 &&
        known.substring(0, common) == seen.substring(0, common);
  }

  /// Carte d'abonné posée sur le poste d'emprunt. Le TID est obligatoire :
  /// un EPC recopié sur un autre tag ne suffit pas. Un compte désactivé est
  /// reconnu (pour expliquer le refus) mais ne sera pas éligible.
  Future<Subscriber?> cardForTag(String epc, String tid) async {
    final normalizedEpc = epc.trim().toUpperCase();
    if (!isCardEpc(normalizedEpc) || tid.trim().isEmpty) return null;
    final rows = await (await database).query(
      'subscribers',
      where: 'card_epc = ? AND card_tid IS NOT NULL',
      whereArgs: [normalizedEpc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final subscriber = Subscriber.fromMap(rows.first);
    return tidMatches(subscriber.cardTid, tid) ? subscriber : null;
  }

  /// Livre encodé posé sur le poste, qu'il soit disponible ou emprunté.
  Future<Book?> bookForTag(String epc, String tid) async {
    final normalizedEpc = epc.trim().toUpperCase();
    if (!isValidEpc(normalizedEpc)) return null;
    final rows = await (await database).query(
      'books',
      where: 'epc = ? AND tid IS NOT NULL',
      whereArgs: [normalizedEpc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final book = Book.fromMap(rows.first);
    // Sans TID (lecture partielle), l'EPC signé BCM suffit pour un livre.
    if (tid.trim().isEmpty || tidMatches(book.tid, tid)) return book;
    return null;
  }

  Future<BorrowerStatus> borrowerStatus(
    int subscriberId, {
    required int maxLoans,
  }) async => _borrowerStatus(
    await database,
    subscriberId,
    maxLoans,
    DateTime.now().toUtc(),
  );

  static Future<BorrowerStatus> _borrowerStatus(
    DatabaseExecutor database,
    int subscriberId,
    int maxLoans,
    DateTime now,
  ) async {
    final rows = await database.query(
      'subscribers',
      where: 'id = ?',
      whereArgs: [subscriberId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Abonné introuvable.');
    final timestamp = now.toIso8601String();
    final valid = await database.query(
      'subscriptions',
      where: "subscriber_id = ? AND status = 'active' AND ends_at >= ?",
      whereArgs: [subscriberId, timestamp],
      orderBy: 'ends_at DESC',
      limit: 1,
    );
    final latest = await database.query(
      'subscriptions',
      where: 'subscriber_id = ?',
      whereArgs: [subscriberId],
      orderBy: 'ends_at DESC, id DESC',
      limit: 1,
    );
    final loans = (await database.rawQuery(
      '''
      SELECT COUNT(*) AS active,
        SUM(CASE WHEN due_at < ? THEN 1 ELSE 0 END) AS overdue
      FROM loans WHERE subscriber_id = ? AND returned_at IS NULL
    ''',
      [timestamp, subscriberId],
    )).first;
    return BorrowerStatus(
      subscriber: Subscriber.fromMap(rows.first),
      subscription: valid.isEmpty ? null : Subscription.fromMap(valid.first),
      latestSubscription: latest.isEmpty
          ? null
          : Subscription.fromMap(latest.first),
      activeLoans: (loans['active'] as num?)?.toInt() ?? 0,
      overdueLoans: (loans['overdue'] as num?)?.toInt() ?? 0,
      maxLoans: maxLoans,
    );
  }

  /// Emprunt en libre-service : l'abonné identifié par sa carte emprunte
  /// plusieurs livres d'un coup. L'éligibilité est revérifiée dans la
  /// transaction ; aucun emprunt n'est créé si un livre est refusé.
  Future<List<Loan>> checkoutBooks(
    int subscriberId,
    List<int> bookIds, {
    required DateTime dueAt,
    required int maxLoans,
  }) async {
    final ids = bookIds.toSet().toList();
    if (ids.isEmpty) throw ArgumentError('Aucun livre à emprunter.');
    final now = DateTime.now().toUtc();
    if (!dueAt.toUtc().isAfter(now)) {
      throw ArgumentError(
        'La date de retour doit être postérieure à aujourd’hui.',
      );
    }
    final timestamp = now.toIso8601String();
    final loanIds = await (await database).transaction((transaction) async {
      final status = await _borrowerStatus(
        transaction,
        subscriberId,
        maxLoans,
        now,
      );
      if (!status.eligible) throw StateError(status.reasons.first);
      if (ids.length > status.remaining) {
        throw StateError(
          'Vous pouvez emprunter ${status.remaining} livre(s) de plus.',
        );
      }
      final subscriber = status.subscriber;
      final created = <int>[];
      for (final bookId in ids) {
        final rows = await transaction.query(
          'books',
          where: 'id = ?',
          whereArgs: [bookId],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('Livre introuvable.');
        final book = Book.fromMap(rows.first);
        if (book.status != 'encode') {
          throw StateError('« ${book.title} » n’est pas disponible au prêt.');
        }
        created.add(
          await _insertLoan(
            transaction,
            book: book,
            subscriberId: subscriber.id,
            subscriptionId: status.subscription!.id,
            dueAt: dueAt,
            timestamp: timestamp,
            message:
                'Emprunt au poste par ${subscriber.name} (${subscriber.memberNumber})',
          ),
        );
      }
      return created;
    });
    return _loansByIds(loanIds);
  }

  /// Retour en libre-service de plusieurs livres. Les livres sans emprunt
  /// actif sont ignorés ; renvoie les emprunts clôturés.
  Future<List<Loan>> returnBooks(List<int> bookIds) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final returnedIds = await (await database).transaction((transaction) async {
      final returned = <int>[];
      for (final bookId in bookIds.toSet()) {
        final rows = await transaction.rawQuery(
          '$_loanSelect WHERE l.book_id = ? AND l.returned_at IS NULL LIMIT 1',
          [bookId],
        );
        if (rows.isEmpty) continue;
        final loan = Loan.fromMap(rows.first);
        await _closeLoan(
          transaction,
          await _bookIn(transaction, bookId),
          loan,
          now,
          selfService: true,
        );
        returned.add(loan.id);
      }
      return returned;
    });
    return _loansByIds(returnedIds);
  }

  /// Ouvre un nouvel abonnement valable jusqu'à [endsAt].
  Future<Subscription> renewSubscription(
    int subscriberId,
    DateTime endsAt,
  ) async {
    final now = DateTime.now().toUtc();
    if (!endsAt.toUtc().isAfter(now)) {
      throw ArgumentError('La fin de l’abonnement doit être dans le futur.');
    }
    final subscriber = await getSubscriber(subscriberId);
    if (subscriber == null) throw StateError('Abonné introuvable.');
    final timestamp = now.toIso8601String();
    return (await database).transaction((transaction) async {
      final id = await transaction.insert('subscriptions', {
        'subscriber_id': subscriberId,
        'starts_at': timestamp,
        'ends_at': endsAt.toUtc().toIso8601String(),
        'status': 'active',
        'created_at': timestamp,
        'updated_at': timestamp,
        'server_id': _newId(),
      });
      await _queueSubscription(transaction, id);
      await _addActivity(
        transaction,
        'abonnement',
        'succes',
        null,
        'Abonnement de ${subscriber.name} (${subscriber.memberNumber}) '
            'valable jusqu’au ${_frenchDate(endsAt)}',
        null,
        null,
        timestamp,
      );
      return Subscription.fromMap(
        (await transaction.query(
          'subscriptions',
          where: 'id = ?',
          whereArgs: [id],
        )).first,
      );
    });
  }

  /// Suspend les abonnements actifs : l'abonné ne peut plus emprunter.
  Future<void> suspendSubscription(int subscriberId) async {
    final subscriber = await getSubscriber(subscriberId);
    if (subscriber == null) throw StateError('Abonné introuvable.');
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await (await database).transaction((transaction) async {
      final active = await transaction.query(
        'subscriptions',
        columns: ['id'],
        where: "subscriber_id = ? AND status = 'active'",
        whereArgs: [subscriberId],
      );
      if (active.isEmpty) {
        throw StateError('Cet abonné n’a aucun abonnement actif.');
      }
      for (final row in active) {
        await transaction.update(
          'subscriptions',
          {'status': 'suspended', 'updated_at': timestamp},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await _queueSubscription(transaction, row['id'] as int);
      }
      await _addActivity(
        transaction,
        'abonnement',
        'succes',
        null,
        'Abonnement suspendu : ${subscriber.name} (${subscriber.memberNumber})',
        null,
        null,
        timestamp,
      );
    });
  }

  /// Enregistre un emprunt : crée ou met à jour l'abonné, ouvre un abonnement
  /// si aucun n'est valide, puis rend le livre indisponible.
  Future<Loan> borrowBook(
    int bookId, {
    required String memberNumber,
    required String name,
    required DateTime dueAt,
    String email = '',
    String phone = '',
    DateTime? subscriptionEndsAt,
    String notes = '',
  }) async {
    final book = await getBook(bookId);
    if (book == null) throw StateError('Livre introuvable.');
    if (await activeLoanForBook(bookId) != null) {
      throw StateError('Ce livre possède déjà un emprunt actif.');
    }
    final normalizedNumber = _clean(memberNumber, 80).toUpperCase();
    final normalizedName = _clean(name, 240);
    if (normalizedNumber.isEmpty) {
      throw ArgumentError('Le numéro d’abonné est obligatoire.');
    }
    if (normalizedName.isEmpty) {
      throw ArgumentError('Le nom de l’abonné est obligatoire.');
    }
    final now = DateTime.now().toUtc();
    if (!dueAt.toUtc().isAfter(now)) {
      throw ArgumentError(
        'La date de retour doit être postérieure à aujourd’hui.',
      );
    }
    final subscriptionEnd =
        (subscriptionEndsAt ?? now.add(const Duration(days: 365))).toUtc();
    if (subscriptionEnd.isBefore(now)) {
      throw ArgumentError('L’abonnement doit être actif pendant l’emprunt.');
    }
    final timestamp = now.toIso8601String();
    final db = await database;
    final loanId = await db.transaction((transaction) async {
      final subscriberId = (await _upsertSubscriber(
        transaction,
        memberNumber: normalizedNumber,
        name: normalizedName,
        email: email,
        phone: phone,
        timestamp: timestamp,
      )).id;
      final subscriptions = await transaction.query(
        'subscriptions',
        columns: ['id'],
        where: "subscriber_id = ? AND status = 'active' AND ends_at >= ?",
        whereArgs: [subscriberId, timestamp],
        orderBy: 'ends_at DESC',
        limit: 1,
      );
      final int subscriptionId;
      if (subscriptions.isNotEmpty) {
        subscriptionId = subscriptions.first['id'] as int;
      } else {
        subscriptionId = await transaction.insert('subscriptions', {
          'subscriber_id': subscriberId,
          'starts_at': timestamp,
          'ends_at': subscriptionEnd.toIso8601String(),
          'status': 'active',
          'created_at': timestamp,
          'updated_at': timestamp,
          'server_id': _newId(),
        });
        await _queueSubscription(transaction, subscriptionId);
      }
      return _insertLoan(
        transaction,
        book: book,
        subscriberId: subscriberId,
        subscriptionId: subscriptionId,
        dueAt: dueAt,
        timestamp: timestamp,
        notes: notes,
        message: 'Livre emprunté par $normalizedName ($normalizedNumber)',
      );
    });
    final loan = await activeLoanForBook(bookId);
    if (loan == null || loan.id != loanId) {
      throw StateError('Emprunt introuvable après enregistrement.');
    }
    return loan;
  }

  Future<Book> returnBook(int bookId) async {
    final book = await getBook(bookId);
    if (book == null) throw StateError('Livre introuvable.');
    final loan = await activeLoanForBook(bookId);
    if (loan == null) throw StateError('Ce livre n’a aucun emprunt actif.');
    final now = DateTime.now().toUtc().toIso8601String();
    return (await database).transaction(
      (transaction) => _closeLoan(transaction, book, loan, now),
    );
  }

  static Future<int> _insertLoan(
    Transaction transaction, {
    required Book book,
    required int subscriberId,
    required int subscriptionId,
    required DateTime dueAt,
    required String timestamp,
    required String message,
    String notes = '',
  }) async {
    final id = await transaction.insert('loans', {
      'book_id': book.id,
      'subscriber_id': subscriberId,
      'subscription_id': subscriptionId,
      'borrowed_at': timestamp,
      'due_at': dueAt.toUtc().toIso8601String(),
      'status': 'active',
      'notes': _clean(notes, 1000),
      'created_at': timestamp,
      'updated_at': timestamp,
      'server_id': _newId(),
    });
    await _queueLoan(transaction, id);
    await transaction.update(
      'books',
      {'status': 'indisponible', 'updated_at': timestamp},
      where: 'id = ?',
      whereArgs: [book.id],
    );
    await _addActivity(
      transaction,
      'emprunt',
      'succes',
      book.id,
      message,
      book.epc,
      book.tid,
      timestamp,
    );
    await _queueBook(transaction, await _bookIn(transaction, book.id));
    return id;
  }

  static Future<Book> _closeLoan(
    Transaction transaction,
    Book book,
    Loan loan,
    String now, {
    bool selfService = false,
  }) async {
    await transaction.update(
      'loans',
      {'returned_at': now, 'status': 'returned', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [loan.id],
    );
    await _queueLoan(transaction, loan.id);
    await transaction.update(
      'books',
      {'status': book.tid == null ? 'a_encoder' : 'encode', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [book.id],
    );
    final late = DateTime.parse(now).isAfter(DateTime.parse(loan.dueAt));
    await _addActivity(
      transaction,
      'retour',
      'succes',
      book.id,
      '${late ? 'Retour en retard' : 'Retour'} '
          '${selfService ? 'au poste ' : ''}enregistré pour ${loan.subscriberName}',
      book.epc,
      book.tid,
      now,
    );
    final returned = await _bookIn(transaction, book.id);
    await _queueBook(transaction, returned);
    return returned;
  }

  static String _frenchDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  Future<Book> markTagged(int id, String tid) async {
    final db = await database;
    final book = await getBook(id);
    if (book == null) throw StateError('Livre introuvable.');
    final normalizedTid = tid.trim().toUpperCase();
    final conflict = await db.query(
      'books',
      columns: ['accession'],
      where: 'tid = ? AND id <> ?',
      whereArgs: [normalizedTid, id],
      limit: 1,
    );
    if (conflict.isNotEmpty) {
      throw StateError(
        'Ce tag est déjà lié au livre ${conflict.first['accession']}.',
      );
    }
    final card = await db.query(
      'subscribers',
      columns: ['name', 'member_number'],
      where: 'card_tid = ?',
      whereArgs: [normalizedTid],
      limit: 1,
    );
    if (card.isNotEmpty) {
      throw StateError(
        'Ce tag est la carte de l’abonné ${card.first['name']} (${card.first['member_number']}).',
      );
    }
    final badge = await _badgeOwner(db, normalizedTid);
    if (badge != null) {
      throw StateError('Ce tag est le badge de $badge.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return db.transaction((transaction) async {
      await transaction.update(
        'books',
        {
          'tid': normalizedTid,
          'status': 'encode',
          'tagged_at': now,
          'updated_at': now,
          'sync_state': 'pending',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await transaction.insert('activity', {
        'type': 'ecriture',
        'result': 'succes',
        'book_id': id,
        'message': 'Tag écrit et vérifié',
        'epc': book.epc,
        'tid': normalizedTid,
        'created_at': now,
      });
      final tagged = Book.fromMap(
        (await transaction.query(
          'books',
          where: 'id = ?',
          whereArgs: [id],
        )).first,
      );
      await _queueBook(transaction, tagged);
      return tagged;
    });
  }

  Future<Book> markUntagged(int id) async {
    final db = await database;
    final book = await getBook(id);
    if (book == null || book.status != 'encode' || book.tid == null) {
      throw StateError('Ce livre n’a pas de tag encodé associé.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return db.transaction((transaction) async {
      await transaction.update(
        'books',
        {
          'tid': null,
          'status': 'a_encoder',
          'tagged_at': null,
          'updated_at': now,
          'sync_state': 'pending',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      await transaction.insert('activity', {
        'type': 'desencodage',
        'result': 'succes',
        'book_id': id,
        'message': 'Tag désencodé et vérifié',
        'epc': book.epc,
        'tid': book.tid,
        'created_at': now,
      });
      final untagged = Book.fromMap(
        (await transaction.query(
          'books',
          where: 'id = ?',
          whereArgs: [id],
        )).first,
      );
      await _queueBook(transaction, untagged);
      return untagged;
    });
  }

  Future<Book?> recognizeTag(String epc, String tid) async {
    final db = await database;
    final normalizedEpc = epc.trim().toUpperCase();
    final normalizedTid = tid.trim().toUpperCase();
    if (normalizedTid.isNotEmpty) {
      final rows = await db.query(
        'books',
        where: "status = 'encode' AND tid = ?",
        whereArgs: [normalizedTid],
        limit: 1,
      );
      if (rows.isNotEmpty) return Book.fromMap(rows.first);
    }
    if (normalizedEpc.isEmpty) return null;
    final rows = await db.query(
      'books',
      where: normalizedTid.isEmpty
          ? "status = 'encode' AND epc = ?"
          : "status = 'encode' AND epc = ? AND tid = ?",
      whereArgs: normalizedTid.isEmpty
          ? [normalizedEpc]
          : [normalizedEpc, normalizedTid],
      limit: 1,
    );
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  Future<List<Book>> recentBooks({int limit = 6}) async {
    final rows = await (await database).query(
      'books',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(Book.fromMap).toList();
  }

  Future<List<ActivityEntry>> activity({int limit = 250}) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT activity.*, books.title, books.accession
      FROM activity LEFT JOIN books ON books.id = activity.book_id
      ORDER BY activity.id DESC LIMIT ?
    ''',
      [limit],
    );
    return rows.map(ActivityEntry.fromMap).toList();
  }

  Future<int> importBooks(List<Map<String, Object?>> records) async {
    final db = await database;
    var imported = 0;
    var duplicates = 0;
    var rejected = 0;
    await db.transaction((transaction) async {
      for (final record in records) {
        final key = _clean(record['import_key'], 128);
        if (key.isEmpty ||
            (await transaction.query(
              'books',
              columns: ['id'],
              where: 'import_key = ?',
              whereArgs: [key],
              limit: 1,
            )).isNotEmpty) {
          duplicates++;
          continue;
        }
        final title = _clean(record['title'], 240);
        if (title.isEmpty) {
          rejected++;
          continue;
        }
        try {
          final now = DateTime.now().toUtc().toIso8601String();
          final placeholder =
              'PENDING-${DateTime.now().microsecondsSinceEpoch}-$imported';
          final id = await transaction.insert('books', {
            'import_key': key,
            'accession': '$placeholder-A',
            'epc': '$placeholder-E',
            ..._bookFields(record),
            'title': title,
            'created_at': now,
            'updated_at': now,
            'server_id': _newId(),
            'sync_state': 'pending',
          });
          await transaction.update(
            'books',
            {
              'accession': formatAccession(DateTime.now().year, id),
              'epc': generateEpc(DateTime.now().year, id),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          final book = Book.fromMap(
            (await transaction.query(
              'books',
              where: 'id = ?',
              whereArgs: [id],
            )).first,
          );
          await _queueBook(transaction, book);
          imported++;
        } catch (_) {
          rejected++;
        }
      }
    });
    await (await database).insert('activity', {
      'type': 'catalogue',
      'result': 'succes',
      'message':
          'Import XLSX : $imported livre(s), $duplicates doublon(s), $rejected rejet(s)',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    return imported;
  }

  Future<void> addActivity(
    String type,
    String result,
    String message, {
    int? bookId,
    String? epc,
    String? tid,
  }) async {
    await (await database).insert('activity', {
      'type': type,
      'result': result,
      'book_id': bookId,
      'message': message,
      'epc': epc,
      'tid': tid,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> prepareInitialSync() async {
    final db = await database;
    await db.transaction((transaction) async {
      final rows = await transaction.query(
        'books',
        where: "sync_state <> 'synced'",
      );
      for (final row in rows) {
        await _queueBook(transaction, Book.fromMap(row));
      }
      final subscribers = await transaction.query(
        'subscribers',
        where: "sync_state <> 'synced'",
      );
      for (final row in subscribers) {
        await _queueSubscriber(transaction, Subscriber.fromMap(row));
      }
      // Les abonnements avant les emprunts qui les référencent.
      for (final row in await transaction.query(
        'subscriptions',
        columns: ['id'],
        where: "sync_state <> 'synced'",
        orderBy: 'id',
      )) {
        await _queueSubscription(transaction, row['id'] as int);
      }
      for (final row in await transaction.query(
        'loans',
        columns: ['id'],
        where: "sync_state <> 'synced'",
        orderBy: 'id',
      )) {
        await _queueLoan(transaction, row['id'] as int);
      }
      for (final row in await transaction.query(
        'gate_days',
        where: "sync_state <> 'synced'",
      )) {
        await _queueGateDay(transaction, row);
      }
      for (final row in await transaction.query(
        'staff_passages',
        where: "sync_state <> 'synced'",
      )) {
        await _queueStaffPassage(transaction, StaffPassage.fromMap(row));
      }
    });
  }

  /// Le serveur a perdu ses données : tout ce que possède l'appareil repart
  /// vers lui et les changements sont relus depuis le début.
  Future<void> resetSyncState() async {
    final db = await database;
    await db.transaction((transaction) async {
      for (final table in const [
        'books',
        'subscribers',
        'subscriptions',
        'loans',
        'gate_days',
        'staff_passages',
      ]) {
        await transaction.update(table, {'sync_state': 'pending'});
      }
      await transaction.insert('sync_meta', {
        'key': 'cursor',
        'value': '0',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await prepareInitialSync();
  }

  Future<void> queueBook(Book book) async {
    final db = await database;
    await db.transaction((transaction) => _queueBook(transaction, book));
  }

  Future<List<Map<String, Object?>>> pendingMutations({int limit = 500}) async {
    return (await database).query(
      'sync_outbox',
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> acknowledgeMutations(List<String> mutationIds) async {
    if (mutationIds.isEmpty) return;
    final db = await database;
    await db.transaction((transaction) async {
      for (final mutationId in mutationIds) {
        final rows = await transaction.query(
          'sync_outbox',
          columns: ['entity_id', 'entity_type'],
          where: 'mutation_id = ?',
          whereArgs: [mutationId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          final (table, key) = switch (rows.first['entity_type']) {
            'subscriber' => ('subscribers', 'member_number'),
            'subscription' => ('subscriptions', 'server_id'),
            'loan' => ('loans', 'server_id'),
            'gate_day' => ('gate_days', 'server_id'),
            'staff_passage' => ('staff_passages', 'server_id'),
            _ => ('books', 'server_id'),
          };
          await transaction.update(
            table,
            {'sync_state': 'synced'},
            where: '$key = ?',
            whereArgs: [rows.first['entity_id']],
          );
        }
        await transaction.delete(
          'sync_outbox',
          where: 'mutation_id = ?',
          whereArgs: [mutationId],
        );
      }
    });
  }

  Future<int> pendingMutationCount() async =>
      Sqflite.firstIntValue(
        await (await database).rawQuery('SELECT COUNT(*) FROM sync_outbox'),
      ) ??
      0;

  Future<int> syncCursor() async {
    final rows = await (await database).query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['cursor'],
      limit: 1,
    );
    return rows.isEmpty ? 0 : int.tryParse(rows.first['value'].toString()) ?? 0;
  }

  Future<void> applyRemoteChanges(List<Object?> changes, int cursor) async {
    final db = await database;
    // Livres et abonnés d'abord : abonnements et emprunts les référencent.
    final ordered = [
      for (final raw in changes.whereType<Map>()) raw.cast<String, Object?>(),
    ]..sort((a, b) => _priority(a).compareTo(_priority(b)));
    await db.transaction((transaction) async {
      for (final change in ordered) {
        final serverId = change['entityId']?.toString() ?? '';
        if (serverId.isEmpty) continue;
        switch (change['entityType'] ?? 'book') {
          case 'subscriber':
            await _applyRemoteSubscriber(transaction, serverId, change);
            continue;
          case 'subscription' || 'loan':
            await _applyLendingChange(transaction, change);
            continue;
          case 'staff':
            await _applyRemoteStaff(transaction, serverId, change);
            continue;
          case 'gate_day':
            await _applyRemoteGateDay(transaction, serverId, change);
            continue;
          case 'staff_passage':
            await _applyRemoteStaffPassage(transaction, serverId, change);
            continue;
          case 'book':
            break;
          default:
            continue;
        }
        if (change['operation'] == 'delete') {
          final pending = await transaction.query(
            'sync_outbox',
            where: 'entity_id = ?',
            whereArgs: [serverId],
            limit: 1,
          );
          if (pending.isEmpty) {
            await transaction.delete(
              'loans',
              where: 'book_id IN (SELECT id FROM books WHERE server_id = ?)',
              whereArgs: [serverId],
            );
            await transaction.delete(
              'books',
              where: 'server_id = ?',
              whereArgs: [serverId],
            );
          }
          continue;
        }
        final rawBook = change['book'];
        if (rawBook is! Map) continue;
        final remote = rawBook.cast<String, Object?>();
        final pending = await transaction.query(
          'sync_outbox',
          where: 'entity_id = ?',
          whereArgs: [serverId],
          limit: 1,
        );
        if (pending.isNotEmpty) continue;
        final values = _remoteBookFields(remote);
        final local = await transaction.query(
          'books',
          columns: ['id'],
          where: 'server_id = ?',
          whereArgs: [serverId],
          limit: 1,
        );
        if (local.isEmpty) {
          await transaction.insert(
            'books',
            values,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        } else {
          await transaction.update(
            'books',
            values,
            where: 'server_id = ?',
            whereArgs: [serverId],
          );
        }
      }
      await _retryDeferred(transaction);
      await transaction.insert('sync_meta', {
        'key': 'cursor',
        'value': cursor.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static int _priority(Map<String, Object?> change) =>
      switch (change['entityType'] ?? 'book') {
        'book' => 0,
        'subscriber' || 'staff' => 1,
        'subscription' => 2,
        'loan' || 'staff_passage' || 'gate_day' => 3,
        _ => 4,
      };

  /// Applique un abonnement ou un emprunt distant ; s'il référence un livre
  /// ou un abonné encore inconnu, il est mis de côté et réessayé plus tard.
  static Future<void> _applyLendingChange(
    Transaction transaction,
    Map<String, Object?> change,
  ) async {
    final type = change['entityType'].toString();
    final serverId = change['entityId'].toString();
    final applied = type == 'loan'
        ? await _applyRemoteLoan(transaction, serverId, change)
        : await _applyRemoteSubscription(transaction, serverId, change);
    if (applied) {
      await transaction.delete(
        'sync_deferred',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [type, serverId],
      );
    } else {
      await transaction.insert('sync_deferred', {
        'entity_type': type,
        'entity_id': serverId,
        'change': jsonEncode(change),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> _retryDeferred(Transaction transaction) async {
    final rows = await transaction.query('sync_deferred');
    final deferred = [
      for (final row in rows)
        (jsonDecode(row['change'] as String) as Map).cast<String, Object?>(),
    ]..sort((a, b) => _priority(a).compareTo(_priority(b)));
    for (final change in deferred) {
      await _applyLendingChange(transaction, change);
    }
  }

  static Future<bool> _hasPending(
    Transaction transaction,
    String entityId,
  ) async => (await transaction.query(
    'sync_outbox',
    columns: ['mutation_id'],
    where: 'entity_id = ?',
    whereArgs: [entityId],
    limit: 1,
  )).isNotEmpty;

  static Future<int?> _idFor(
    Transaction transaction,
    String table,
    String column,
    Object? value,
  ) async {
    final key = value?.toString().trim() ?? '';
    if (key.isEmpty) return null;
    final rows = await transaction.query(
      table,
      columns: ['id'],
      where: '$column = ?',
      whereArgs: [column == 'member_number' ? key.toUpperCase() : key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  static Future<bool> _applyRemoteSubscription(
    Transaction transaction,
    String serverId,
    Map<String, Object?> change,
  ) async {
    // Une modification locale en attente l'emporte ; le serveur renverra
    // sa version après l'envoi.
    if (await _hasPending(transaction, serverId)) return true;
    if (change['operation'] == 'delete') {
      await transaction.delete(
        'subscriptions',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      return true;
    }
    final raw = change['subscription'];
    if (raw is! Map) return true;
    final remote = raw.cast<String, Object?>();
    final subscriberId = await _idFor(
      transaction,
      'subscribers',
      'member_number',
      remote['memberNumber'],
    );
    if (subscriberId == null) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final status = remote['status']?.toString() ?? 'active';
    final values = <String, Object?>{
      'subscriber_id': subscriberId,
      'starts_at': remote['startsAt'] ?? now,
      'ends_at': remote['endsAt'] ?? now,
      'status': Subscription.statuses.contains(status) ? status : 'active',
      'updated_at': remote['updatedAt'] ?? now,
      'sync_state': 'synced',
    };
    final existing = await _idFor(
      transaction,
      'subscriptions',
      'server_id',
      serverId,
    );
    if (existing == null) {
      await transaction.insert('subscriptions', {
        ...values,
        'server_id': serverId,
        'created_at': remote['createdAt'] ?? now,
      });
    } else {
      await transaction.update(
        'subscriptions',
        values,
        where: 'id = ?',
        whereArgs: [existing],
      );
    }
    return true;
  }

  static Future<bool> _applyRemoteLoan(
    Transaction transaction,
    String serverId,
    Map<String, Object?> change,
  ) async {
    if (await _hasPending(transaction, serverId)) return true;
    if (change['operation'] == 'delete') {
      final bookId =
          (await transaction.query(
                'loans',
                columns: ['book_id'],
                where: 'server_id = ?',
                whereArgs: [serverId],
                limit: 1,
              )).firstOrNull?['book_id']
              as int?;
      await transaction.delete(
        'loans',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      if (bookId != null) await _syncBookLoanStatus(transaction, bookId);
      return true;
    }
    final raw = change['loan'];
    if (raw is! Map) return true;
    final remote = raw.cast<String, Object?>();
    final bookId = await _idFor(
      transaction,
      'books',
      'server_id',
      remote['bookServerId'],
    );
    final subscriberId = await _idFor(
      transaction,
      'subscribers',
      'member_number',
      remote['memberNumber'],
    );
    if (bookId == null || subscriberId == null) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final borrowedAt = remote['borrowedAt']?.toString() ?? now;
    final returnedAt = remote['returnedAt']?.toString();
    final existing = await _idFor(transaction, 'loans', 'server_id', serverId);
    if (returnedAt == null) {
      // Un seul emprunt en cours par livre : un autre emprunt local encore
      // ouvert a forcément été rendu avant ce nouvel emprunt.
      await transaction.update(
        'loans',
        {'returned_at': borrowedAt, 'status': 'returned', 'updated_at': now},
        where: 'book_id = ? AND returned_at IS NULL AND id <> ?',
        whereArgs: [bookId, existing ?? -1],
      );
    }
    final status = remote['status']?.toString() ?? 'active';
    final values = <String, Object?>{
      'book_id': bookId,
      'subscriber_id': subscriberId,
      'subscription_id': await _idFor(
        transaction,
        'subscriptions',
        'server_id',
        remote['subscriptionServerId'],
      ),
      'borrowed_at': borrowedAt,
      'due_at': remote['dueAt'] ?? borrowedAt,
      'returned_at': returnedAt,
      'status': Loan.statuses.contains(status) ? status : 'active',
      'notes': _clean(remote['notes'], 1000),
      'updated_at': remote['updatedAt'] ?? now,
      'sync_state': 'synced',
    };
    if (existing == null) {
      await transaction.insert('loans', {
        ...values,
        'server_id': serverId,
        'created_at': remote['createdAt'] ?? now,
      });
    } else {
      await transaction.update(
        'loans',
        values,
        where: 'id = ?',
        whereArgs: [existing],
      );
    }
    await _syncBookLoanStatus(transaction, bookId);
    return true;
  }

  /// Aligne le statut local du livre sur ses emprunts (le statut du livre
  /// est aussi synchronisé par l'appareil qui a prêté).
  static Future<void> _syncBookLoanStatus(
    Transaction transaction,
    int bookId,
  ) async {
    final active = await transaction.query(
      'loans',
      columns: ['id'],
      where: 'book_id = ? AND returned_at IS NULL',
      whereArgs: [bookId],
      limit: 1,
    );
    if (active.isNotEmpty) {
      await transaction.update(
        'books',
        {'status': 'indisponible'},
        where: 'id = ?',
        whereArgs: [bookId],
      );
    } else {
      await transaction.rawUpdate(
        '''
        UPDATE books SET status = CASE WHEN tid IS NULL THEN 'a_encoder' ELSE 'encode' END
        WHERE id = ? AND status = 'indisponible'
      ''',
        [bookId],
      );
    }
  }

  // --- Personnel et portail antivol -------------------------------------

  /// Membre actif du personnel dont le badge est lu. Le TID est obligatoire :
  /// un EPC recopié sur un autre tag ne suffit pas.
  Future<StaffMember?> staffForBadge(String epc, String tid) async {
    final normalizedEpc = epc.trim().toUpperCase();
    if (!isBadgeEpc(normalizedEpc) || tid.trim().isEmpty) return null;
    final rows = await (await database).query(
      'staff',
      where: 'badge_epc = ? AND badge_tid IS NOT NULL AND active = 1',
      whereArgs: [normalizedEpc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final staff = StaffMember.fromMap(rows.first);
    return tidMatches(staff.badgeTid, tid) ? staff : null;
  }

  /// Livre du catalogue portant cet EPC, encodé ou non : au portail, tout
  /// livre signé « BCM » appartient à la bibliothèque.
  Future<Book?> bookForEpc(String epc) async {
    final rows = await (await database).query(
      'books',
      where: 'epc = ?',
      whereArgs: [epc.trim().toUpperCase()],
      limit: 1,
    );
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  Future<List<StaffMember>> listStaff({bool activeOnly = false}) async {
    final rows = await (await database).query(
      'staff',
      where: activeOnly ? 'active = 1' : null,
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(StaffMember.fromMap).toList();
  }

  /// Compteurs d'un portail pour un jour local.
  Future<GateDayCounts> gateDay(String gateId, String day) async {
    final rows = await (await database).query(
      'gate_days',
      where: 'server_id = ?',
      whereArgs: ['$gateId:$day'],
      limit: 1,
    );
    return rows.isEmpty
        ? GateDayCounts(day: day)
        : GateDayCounts.fromMap(rows.first);
  }

  /// Ajoute aux compteurs du jour de [at] et met la journée en file de
  /// synchronisation (une seule mutation en attente par jour).
  Future<GateDayCounts> addGateCounts({
    required String gateId,
    required String gateName,
    required DateTime at,
    int entries = 0,
    int exits = 0,
    int alarms = 0,
  }) async {
    final day = GateDayCounts.dayOf(at);
    final serverId = '$gateId:$day';
    final now = DateTime.now().toUtc().toIso8601String();
    return (await database).transaction((transaction) async {
      final current = await transaction.query(
        'gate_days',
        where: 'server_id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      final values = {
        'gate_id': gateId,
        'gate_name': gateName,
        'day': day,
        'entries': (current.firstOrNull?['entries'] as int? ?? 0) + entries,
        'exits': (current.firstOrNull?['exits'] as int? ?? 0) + exits,
        'alarms': (current.firstOrNull?['alarms'] as int? ?? 0) + alarms,
        'updated_at': now,
        'sync_state': 'pending',
      };
      if (current.isEmpty) {
        await transaction.insert('gate_days', {
          ...values,
          'server_id': serverId,
        });
      } else {
        await transaction.update(
          'gate_days',
          values,
          where: 'server_id = ?',
          whereArgs: [serverId],
        );
      }
      await _queueGateDay(transaction, {...values, 'server_id': serverId});
      return GateDayCounts.fromMap(values);
    });
  }

  /// Enregistre le passage d'un membre du personnel et le synchronise.
  Future<StaffPassage> recordStaffPassage({
    required StaffMember staff,
    required PassageDirection direction,
    required DateTime at,
    required String gateId,
    required String gateName,
  }) async {
    final passage = StaffPassage(
      serverId: _newId(),
      staffServerId: staff.serverId,
      staffNumber: staff.staffNumber,
      staffName: staff.name,
      direction: direction,
      passedAt: at,
      gateId: gateId,
      gateName: gateName,
    );
    await (await database).transaction((transaction) async {
      await transaction.insert('staff_passages', {
        'server_id': passage.serverId,
        'staff_server_id': passage.staffServerId,
        'staff_number': passage.staffNumber,
        'staff_name': passage.staffName,
        'direction': direction.code,
        'passed_at': at.toUtc().toIso8601String(),
        'gate_id': gateId,
        'gate_name': gateName,
        'sync_state': 'pending',
      });
      await _queueStaffPassage(transaction, passage);
    });
    return passage;
  }

  /// Dernier passage du membre depuis [since] (tous portails synchronisés).
  Future<StaffPassage?> lastStaffPassage(
    String staffServerId, {
    required DateTime since,
  }) async {
    final rows = await (await database).query(
      'staff_passages',
      where: 'staff_server_id = ? AND passed_at >= ?',
      whereArgs: [staffServerId, since.toUtc().toIso8601String()],
      orderBy: 'passed_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : StaffPassage.fromMap(rows.first);
  }

  /// Passages du personnel d'une journée locale, du plus récent au plus ancien.
  Future<List<StaffPassage>> staffPassagesOn(
    DateTime day, {
    int limit = 200,
  }) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final rows = await (await database).query(
      'staff_passages',
      where: 'passed_at >= ? AND passed_at < ?',
      whereArgs: [
        start.toUtc().toIso8601String(),
        end.toUtc().toIso8601String(),
      ],
      orderBy: 'passed_at DESC',
      limit: limit,
    );
    return rows.map(StaffPassage.fromMap).toList();
  }

  static Future<String?> _badgeOwner(DatabaseExecutor db, String tid) async {
    final rows = await db.query(
      'staff',
      columns: ['name'],
      where: 'badge_tid = ?',
      whereArgs: [tid],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  static Future<void> _queueGateDay(
    DatabaseExecutor database,
    Map<String, Object?> row,
  ) async {
    final serverId = row['server_id'] as String;
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'upsert',
      'entity_id': serverId,
      'entity_type': 'gate_day',
      'payload': jsonEncode({
        'serverId': serverId,
        'gateId': row['gate_id'],
        'gateName': row['gate_name'],
        'day': row['day'],
        'entries': row['entries'],
        'exits': row['exits'],
        'alarms': row['alarms'],
        'updatedAt': row['updated_at'],
      }),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _queueStaffPassage(
    DatabaseExecutor database,
    StaffPassage passage,
  ) async {
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'upsert',
      'entity_id': passage.serverId,
      'entity_type': 'staff_passage',
      'payload': jsonEncode(passage.toSyncJson()),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _applyRemoteStaff(
    Transaction transaction,
    String serverId,
    Map<String, Object?> change,
  ) async {
    if (change['operation'] == 'delete') {
      await transaction.delete(
        'staff',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      return;
    }
    final rawStaff = change['staff'];
    if (rawStaff is! Map) return;
    final remote = rawStaff.cast<String, Object?>();
    String? upper(Object? value) {
      final text = value?.toString().trim().toUpperCase() ?? '';
      return text.isEmpty ? null : text;
    }

    final badgeEpc = upper(remote['badgeEpc']);
    final badgeTid = upper(remote['badgeTid']);
    // Un badge réencodé pour une autre personne quitte l'ancienne.
    if (badgeTid != null) {
      await transaction.update(
        'staff',
        {'badge_tid': null, 'badge_tagged_at': null},
        where: 'badge_tid = ? AND server_id <> ?',
        whereArgs: [badgeTid, serverId],
      );
    }
    if (badgeEpc != null) {
      await transaction.update(
        'staff',
        {'badge_epc': null},
        where: 'badge_epc = ? AND server_id <> ?',
        whereArgs: [badgeEpc, serverId],
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, Object?>{
      'staff_number': _clean(remote['staffNumber'], 80).toUpperCase(),
      'name': _clean(remote['name'] ?? remote['staffNumber'], 240),
      'position': _clean(remote['position'], 120),
      'email': _clean(remote['email'], 240),
      'phone': _clean(remote['phone'], 80),
      'active': remote['active'] == false ? 0 : 1,
      'badge_epc': badgeEpc,
      'badge_tid': badgeTid,
      'badge_tagged_at': remote['badgeTaggedAt'],
      'updated_at': remote['updatedAt'] ?? now,
    };
    final updated = await transaction.update(
      'staff',
      values,
      where: 'server_id = ?',
      whereArgs: [serverId],
    );
    if (updated == 0) {
      await transaction.insert('staff', {
        ...values,
        'server_id': serverId,
        'created_at': remote['createdAt'] ?? now,
      });
    }
  }

  /// Compteurs d'un portail : on garde le maximum de chaque valeur, un
  /// compteur local plus avancé et pas encore envoyé n'est jamais écrasé.
  static Future<void> _applyRemoteGateDay(
    Transaction transaction,
    String serverId,
    Map<String, Object?> change,
  ) async {
    if (await _hasPending(transaction, serverId)) return;
    if (change['operation'] == 'delete') {
      await transaction.delete(
        'gate_days',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      return;
    }
    final rawDay = change['gateDay'];
    if (rawDay is! Map) return;
    final remote = rawDay.cast<String, Object?>();
    final day = remote['day']?.toString() ?? '';
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) return;
    final current = (await transaction.query(
      'gate_days',
      where: 'server_id = ?',
      whereArgs: [serverId],
      limit: 1,
    )).firstOrNull;
    int count(String key) {
      final incoming = (remote[key] as num?)?.toInt() ?? 0;
      final local = (current?[key] as num?)?.toInt() ?? 0;
      return max(incoming, local);
    }

    final values = {
      'gate_id': remote['gateId']?.toString() ?? '',
      'gate_name': _clean(remote['gateName'], 120),
      'day': day,
      'entries': count('entries'),
      'exits': count('exits'),
      'alarms': count('alarms'),
      'updated_at':
          remote['updatedAt'] ?? DateTime.now().toUtc().toIso8601String(),
      'sync_state': 'synced',
    };
    if (current == null) {
      await transaction.insert('gate_days', {...values, 'server_id': serverId});
    } else {
      await transaction.update(
        'gate_days',
        values,
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
    }
  }

  static Future<void> _applyRemoteStaffPassage(
    Transaction transaction,
    String serverId,
    Map<String, Object?> change,
  ) async {
    if (await _hasPending(transaction, serverId)) return;
    if (change['operation'] == 'delete') {
      await transaction.delete(
        'staff_passages',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      return;
    }
    final rawPassage = change['staffPassage'];
    if (rawPassage is! Map) return;
    final remote = rawPassage.cast<String, Object?>();
    final direction = remote['direction']?.toString();
    if (direction != 'in' && direction != 'out') return;
    await transaction.insert('staff_passages', {
      'server_id': serverId,
      'staff_server_id': remote['staffServerId']?.toString() ?? '',
      'staff_number': _clean(remote['staffNumber'], 80),
      'staff_name': _clean(remote['staffName'], 240),
      'direction': direction,
      'passed_at':
          remote['passedAt'] ?? DateTime.now().toUtc().toIso8601String(),
      'gate_id': remote['gateId']?.toString() ?? '',
      'gate_name': _clean(remote['gateName'], 120),
      'sync_state': 'synced',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Personnel (reçu de Windows) et activité du portail antivol.
  static Future<void> _createGateTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS staff (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id TEXT NOT NULL UNIQUE,
        staff_number TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL,
        position TEXT NOT NULL DEFAULT '',
        email TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 1,
        badge_epc TEXT,
        badge_tid TEXT,
        badge_tagged_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS gate_days (
        server_id TEXT PRIMARY KEY,
        gate_id TEXT NOT NULL,
        gate_name TEXT NOT NULL DEFAULT '',
        day TEXT NOT NULL,
        entries INTEGER NOT NULL DEFAULT 0,
        exits INTEGER NOT NULL DEFAULT 0,
        alarms INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS staff_passages (
        server_id TEXT PRIMARY KEY,
        staff_server_id TEXT NOT NULL,
        staff_number TEXT NOT NULL DEFAULT '',
        staff_name TEXT NOT NULL DEFAULT '',
        direction TEXT NOT NULL CHECK(direction IN ('in', 'out')),
        passed_at TEXT NOT NULL,
        gate_id TEXT NOT NULL DEFAULT '',
        gate_name TEXT NOT NULL DEFAULT '',
        sync_state TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    for (final statement in const [
      'CREATE INDEX IF NOT EXISTS idx_staff_badge_epc ON staff(badge_epc)',
      'CREATE INDEX IF NOT EXISTS idx_staff_badge_tid ON staff(badge_tid)',
      'CREATE INDEX IF NOT EXISTS idx_gate_days_day ON gate_days(day)',
      'CREATE INDEX IF NOT EXISTS idx_staff_passages_staff ON staff_passages(staff_server_id, passed_at)',
      'CREATE INDEX IF NOT EXISTS idx_staff_passages_at ON staff_passages(passed_at)',
    ]) {
      await database.execute(statement);
    }
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  static String _clean(Object? value, int limit) => (value?.toString() ?? '')
      .trim()
      .substring(0, (value?.toString() ?? '').trim().length.clamp(0, limit));

  static Map<String, Object?> _bookFields(Map<String, Object?> values) => {
    'author': _clean(values['author'], 240),
    'isbn': _clean(values['isbn'], 240),
    'publisher': _clean(values['publisher'], 240),
    'publication_year': _clean(values['publication_year'], 240),
    'category': _clean(values['category'], 240),
    'shelf': _clean(values['shelf'], 240),
    'notes': _clean(values['notes'], 2000),
  };

  static Future<void> _createSyncTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        mutation_id TEXT PRIMARY KEY,
        operation TEXT NOT NULL,
        entity_id TEXT NOT NULL UNIQUE,
        payload TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS sync_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createLendingTables(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS subscribers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        member_number TEXT NOT NULL UNIQUE COLLATE NOCASE,
        name TEXT NOT NULL,
        email TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS subscriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subscriber_id INTEGER NOT NULL,
        starts_at TEXT NOT NULL,
        ends_at TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK(status IN ('active', 'expired', 'suspended')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(subscriber_id) REFERENCES subscribers(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        subscriber_id INTEGER NOT NULL,
        subscription_id INTEGER,
        borrowed_at TEXT NOT NULL,
        due_at TEXT NOT NULL,
        returned_at TEXT,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK(status IN ('active', 'returned', 'late')),
        notes TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE RESTRICT,
        FOREIGN KEY(subscriber_id) REFERENCES subscribers(id) ON DELETE RESTRICT,
        FOREIGN KEY(subscription_id) REFERENCES subscriptions(id) ON DELETE SET NULL
      )
    ''');
    for (final statement in const [
      'CREATE INDEX IF NOT EXISTS idx_subscribers_name ON subscribers(name)',
      'CREATE INDEX IF NOT EXISTS idx_subscriptions_subscriber ON subscriptions(subscriber_id, ends_at DESC)',
      'CREATE INDEX IF NOT EXISTS idx_loans_book ON loans(book_id, returned_at)',
      'CREATE INDEX IF NOT EXISTS idx_loans_subscriber ON loans(subscriber_id, returned_at)',
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_loans_active_book ON loans(book_id) WHERE returned_at IS NULL',
    ]) {
      await database.execute(statement);
    }
  }

  static Future<void> _addSubscriberCards(DatabaseExecutor database) async {
    for (final column in const ['card_epc', 'card_tid', 'card_tagged_at']) {
      await database.execute('ALTER TABLE subscribers ADD COLUMN $column TEXT');
    }
    await database.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_subscribers_card_epc ON subscribers(card_epc) WHERE card_epc IS NOT NULL',
    );
    await database.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_subscribers_card_tid ON subscribers(card_tid) WHERE card_tid IS NOT NULL',
    );
    final rows = await database.query('subscribers', columns: ['id']);
    for (final row in rows) {
      await database.update(
        'subscribers',
        {'card_epc': generateCardEpc()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  static Future<void> _addSubscriberSync(DatabaseExecutor database) async {
    await database.execute(
      "ALTER TABLE subscribers ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'",
    );
    await database.execute(
      "ALTER TABLE sync_outbox ADD COLUMN entity_type TEXT NOT NULL DEFAULT 'book'",
    );
  }

  /// Comptes du personnel, propres à l'appareil (comme sur Windows).
  static Future<void> _createUsers(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL UNIQUE COLLATE NOCASE,
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_iterations INTEGER NOT NULL,
        role TEXT NOT NULL DEFAULT 'operateur'
          CHECK(role IN ('admin', 'operateur')),
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  /// Emprunts et abonnements synchronisés : identifiant global (UUID) et
  /// file des changements distants en attente de leurs références.
  static Future<void> _addLendingSync(DatabaseExecutor database) async {
    for (final table in const ['subscriptions', 'loans']) {
      await database.execute('ALTER TABLE $table ADD COLUMN server_id TEXT');
      await database.execute(
        "ALTER TABLE $table ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'pending'",
      );
      final rows = await database.query(table, columns: ['id']);
      for (final row in rows) {
        await database.update(
          table,
          {'server_id': _newId()},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
      await database.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_${table}_server_id ON $table(server_id)',
      );
    }
    await database.execute('''
      CREATE TABLE IF NOT EXISTS sync_deferred (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        change TEXT NOT NULL,
        PRIMARY KEY(entity_type, entity_id)
      )
    ''');
  }

  static Future<Subscriber> _subscriberIn(
    DatabaseExecutor database,
    int id,
  ) async => Subscriber.fromMap(
    (await database.query(
      'subscribers',
      where: 'id = ?',
      whereArgs: [id],
    )).first,
  );

  /// L'identifiant d'entité d'un abonné est son numéro d'abonné.
  static Future<void> _queueSubscriber(
    DatabaseExecutor database,
    Subscriber subscriber,
  ) async {
    await database.update(
      'subscribers',
      {'sync_state': 'pending'},
      where: 'id = ?',
      whereArgs: [subscriber.id],
    );
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'upsert',
      'entity_id': subscriber.memberNumber,
      'entity_type': 'subscriber',
      'payload': jsonEncode(subscriber.toSyncJson()),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _applyRemoteSubscriber(
    Transaction transaction,
    String memberNumber,
    Map<String, Object?> change,
  ) async {
    final number = memberNumber.trim().toUpperCase();
    final pending = await transaction.query(
      'sync_outbox',
      where: 'entity_id = ?',
      whereArgs: [number],
      limit: 1,
    );
    if (pending.isNotEmpty) return;
    if (change['operation'] == 'delete') {
      // Les emprunts référencent l'abonné : on le désactive sans le supprimer.
      await transaction.update(
        'subscribers',
        {'active': 0, 'card_tid': null, 'sync_state': 'synced'},
        where: 'member_number = ?',
        whereArgs: [number],
      );
      return;
    }
    final rawSubscriber = change['subscriber'];
    if (rawSubscriber is! Map) return;
    final remote = rawSubscriber.cast<String, Object?>();
    String? upper(Object? value) {
      final text = value?.toString().trim().toUpperCase() ?? '';
      return text.isEmpty ? null : text;
    }

    final cardEpc = upper(remote['cardEpc']);
    final cardTid = upper(remote['cardTid']);
    // Une carte réencodée ailleurs pour un autre abonné quitte l'ancien.
    if (cardTid != null) {
      await transaction.update(
        'subscribers',
        {'card_tid': null, 'card_tagged_at': null},
        where: 'card_tid = ? AND member_number <> ?',
        whereArgs: [cardTid, number],
      );
    }
    if (cardEpc != null) {
      await transaction.update(
        'subscribers',
        {'card_epc': null},
        where: 'card_epc = ? AND member_number <> ?',
        whereArgs: [cardEpc, number],
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, Object?>{
      'name': _clean(remote['name'] ?? number, 240),
      'email': _clean(remote['email'], 240),
      'phone': _clean(remote['phone'], 80),
      'active': remote['active'] == false ? 0 : 1,
      'card_tid': cardTid,
      'card_tagged_at': remote['cardTaggedAt'],
      'updated_at': remote['updatedAt'] ?? now,
      'sync_state': 'synced',
      'card_epc': ?cardEpc,
    };
    final existing = await transaction.query(
      'subscribers',
      columns: ['id'],
      where: 'member_number = ?',
      whereArgs: [number],
      limit: 1,
    );
    if (existing.isEmpty) {
      await transaction.insert('subscribers', {
        ...values,
        'member_number': number,
        'card_epc': cardEpc ?? generateCardEpc(),
        'created_at': remote['createdAt'] ?? now,
      });
    } else {
      await transaction.update(
        'subscribers',
        values,
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
  }

  static Future<Subscriber> _upsertSubscriber(
    DatabaseExecutor database, {
    required String memberNumber,
    required String name,
    required String email,
    required String phone,
    required String timestamp,
  }) async {
    final values = {
      'name': name,
      'email': _clean(email, 240),
      'phone': _clean(phone, 80),
      'active': 1,
      'updated_at': timestamp,
    };
    final existing = await database.query(
      'subscribers',
      where: 'member_number = ?',
      whereArgs: [memberNumber],
      limit: 1,
    );
    final int id;
    String? cardEpc;
    if (existing.isEmpty) {
      id = await database.insert('subscribers', {
        ...values,
        'member_number': memberNumber,
        'created_at': timestamp,
      });
    } else {
      id = existing.first['id'] as int;
      cardEpc = existing.first['card_epc'] as String?;
      await database.update(
        'subscribers',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    if (cardEpc == null) {
      await database.update(
        'subscribers',
        {'card_epc': generateCardEpc()},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    final saved = await _subscriberIn(database, id);
    await _queueSubscriber(database, saved);
    return saved;
  }

  static Future<Book> _bookIn(DatabaseExecutor database, int id) async =>
      Book.fromMap(
        (await database.query('books', where: 'id = ?', whereArgs: [id])).first,
      );

  static Future<void> _queueBook(DatabaseExecutor database, Book book) async {
    final serverId = book.serverId;
    if (serverId == null || serverId.isEmpty) return;
    await database.update(
      'books',
      {'sync_state': 'pending'},
      where: 'id = ?',
      whereArgs: [book.id],
    );
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'upsert',
      'entity_id': serverId,
      'payload': jsonEncode(book.toSyncJson()),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _queueSubscription(
    DatabaseExecutor database,
    int subscriptionId,
  ) async {
    final rows = await database.rawQuery(
      '''
      SELECT sub.*, s.member_number FROM subscriptions sub
      JOIN subscribers s ON s.id = sub.subscriber_id
      WHERE sub.id = ?
    ''',
      [subscriptionId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final serverId = row['server_id'] as String?;
    if (serverId == null) return;
    await _queueEntity(
      database,
      'subscriptions',
      subscriptionId,
      'subscription',
      serverId,
      {
        'serverId': serverId,
        'memberNumber': row['member_number'],
        'startsAt': row['starts_at'],
        'endsAt': row['ends_at'],
        'status': row['status'],
        'createdAt': row['created_at'],
        'updatedAt': row['updated_at'],
      },
    );
  }

  static Future<void> _queueLoan(DatabaseExecutor database, int loanId) async {
    final rows = await database.rawQuery(
      '''
      SELECT l.*, s.member_number, b.server_id AS book_server_id,
        sub.server_id AS subscription_server_id
      FROM loans l
      JOIN subscribers s ON s.id = l.subscriber_id
      JOIN books b ON b.id = l.book_id
      LEFT JOIN subscriptions sub ON sub.id = l.subscription_id
      WHERE l.id = ?
    ''',
      [loanId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final serverId = row['server_id'] as String?;
    if (serverId == null || row['book_server_id'] == null) return;
    await _queueEntity(database, 'loans', loanId, 'loan', serverId, {
      'serverId': serverId,
      'bookServerId': row['book_server_id'],
      'memberNumber': row['member_number'],
      'subscriptionServerId': row['subscription_server_id'],
      'borrowedAt': row['borrowed_at'],
      'dueAt': row['due_at'],
      'returnedAt': row['returned_at'],
      'status': row['status'],
      'notes': row['notes'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
    });
  }

  static Future<void> _queueEntity(
    DatabaseExecutor database,
    String table,
    int id,
    String entityType,
    String serverId,
    Map<String, Object?> payload,
  ) async {
    await database.update(
      table,
      {'sync_state': 'pending'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'upsert',
      'entity_id': serverId,
      'entity_type': entityType,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _queueEntityDelete(
    DatabaseExecutor database,
    String entityType,
    String serverId,
  ) async {
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'delete',
      'entity_id': serverId,
      'entity_type': entityType,
      'payload': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _queueDelete(DatabaseExecutor database, Book book) async {
    final serverId = book.serverId;
    if (serverId == null || serverId.isEmpty) return;
    await database.insert('sync_outbox', {
      'mutation_id': _newId(),
      'operation': 'delete',
      'entity_id': serverId,
      'payload': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Map<String, Object?> _remoteBookFields(Map<String, Object?> remote) =>
      {
        'server_id': remote['serverId'],
        'accession': remote['accession'] ?? '',
        'epc': remote['epc'] ?? '',
        'tid': remote['tid'],
        'title': remote['title'] ?? 'Sans titre',
        'author': remote['author'] ?? '',
        'isbn': remote['isbn'] ?? '',
        'publisher': remote['publisher'] ?? '',
        'publication_year': remote['publicationYear'] ?? '',
        'category': remote['category'] ?? '',
        'shelf': remote['shelf'] ?? '',
        'notes': remote['notes'] ?? '',
        'status': remote['status'] ?? 'a_encoder',
        'created_at':
            remote['createdAt'] ?? DateTime.now().toUtc().toIso8601String(),
        'updated_at':
            remote['updatedAt'] ?? DateTime.now().toUtc().toIso8601String(),
        'tagged_at': remote['taggedAt'],
        'server_revision': remote['revision'] ?? 0,
        'sync_state': 'synced',
      };

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static Future<void> _addActivity(
    Transaction transaction,
    String type,
    String result,
    int? bookId,
    String message,
    String? epc,
    String? tid,
    String createdAt,
  ) async {
    await transaction.insert('activity', {
      'type': type,
      'result': result,
      'book_id': bookId,
      'message': message,
      'epc': epc,
      'tid': tid,
      'created_at': createdAt,
    });
  }
}
