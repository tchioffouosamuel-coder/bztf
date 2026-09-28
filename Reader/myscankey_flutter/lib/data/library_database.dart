import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../core/epc.dart';
import '../models/book.dart';
import '../models/lending.dart';

class LibraryDatabase {
  LibraryDatabase._();

  static final LibraryDatabase instance = LibraryDatabase._();
  Database? _database;

  Future<Database> get database async {
    if (_database case final database?) return database;
    final directory = await getDatabasesPath();
    _database = await openDatabase(
      path.join(directory, 'biblio_rfid.db'),
      version: 4,
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

  Future<List<Subscriber>> listSubscribers({String search = ''}) async {
    final term = '%${_clean(search, 120)}%';
    final rows = await (await database).rawQuery('''
      SELECT s.*,
        (SELECT ends_at FROM subscriptions
          WHERE subscriber_id = s.id AND status = 'active'
          ORDER BY ends_at DESC LIMIT 1) AS subscription_ends_at,
        (SELECT COUNT(*) FROM loans
          WHERE subscriber_id = s.id AND returned_at IS NULL) AS active_loans
      FROM subscribers s
      WHERE s.member_number LIKE ? OR s.name LIKE ? OR s.email LIKE ? OR s.phone LIKE ?
      ORDER BY s.name COLLATE NOCASE LIMIT 100
    ''', List.filled(4, term));
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
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((transaction) async {
      await transaction.update(
        'subscribers',
        {'card_tid': normalizedTid, 'card_tagged_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [subscriberId],
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

  Future<Loan?> activeLoanForBook(int bookId) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT l.*, s.member_number, s.name AS subscriber_name,
        s.email AS subscriber_email, s.phone AS subscriber_phone,
        sub.ends_at AS subscription_ends_at
      FROM loans l
      JOIN subscribers s ON s.id = l.subscriber_id
      LEFT JOIN subscriptions sub ON sub.id = l.subscription_id
      WHERE l.book_id = ? AND l.returned_at IS NULL
      ORDER BY l.id DESC LIMIT 1
    ''',
      [bookId],
    );
    return rows.isEmpty ? null : Loan.fromMap(rows.first);
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
      final subscriptionId = subscriptions.isNotEmpty
          ? subscriptions.first['id'] as int
          : await transaction.insert('subscriptions', {
              'subscriber_id': subscriberId,
              'starts_at': timestamp,
              'ends_at': subscriptionEnd.toIso8601String(),
              'status': 'active',
              'created_at': timestamp,
              'updated_at': timestamp,
            });
      final id = await transaction.insert('loans', {
        'book_id': bookId,
        'subscriber_id': subscriberId,
        'subscription_id': subscriptionId,
        'borrowed_at': timestamp,
        'due_at': dueAt.toUtc().toIso8601String(),
        'status': 'active',
        'notes': _clean(notes, 1000),
        'created_at': timestamp,
        'updated_at': timestamp,
      });
      await transaction.update(
        'books',
        {'status': 'indisponible', 'updated_at': timestamp},
        where: 'id = ?',
        whereArgs: [bookId],
      );
      await _addActivity(
        transaction,
        'emprunt',
        'succes',
        bookId,
        'Livre emprunté par $normalizedName ($normalizedNumber)',
        book.epc,
        book.tid,
        timestamp,
      );
      await _queueBook(transaction, await _bookIn(transaction, bookId));
      return id;
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
    return (await database).transaction((transaction) async {
      await transaction.update(
        'loans',
        {'returned_at': now, 'status': 'returned', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [loan.id],
      );
      await transaction.update(
        'books',
        {
          'status': book.tid == null ? 'a_encoder' : 'encode',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [bookId],
      );
      await _addActivity(
        transaction,
        'retour',
        'succes',
        bookId,
        'Retour enregistré pour ${loan.subscriberName}',
        book.epc,
        book.tid,
        now,
      );
      final returned = await _bookIn(transaction, bookId);
      await _queueBook(transaction, returned);
      return returned;
    });
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
    });
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
          columns: ['entity_id'],
          where: 'mutation_id = ?',
          whereArgs: [mutationId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          await transaction.update(
            'books',
            {'sync_state': 'synced'},
            where: 'server_id = ?',
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
    await db.transaction((transaction) async {
      for (final raw in changes.whereType<Map>()) {
        final change = raw.cast<String, Object?>();
        final serverId = change['entityId']?.toString() ?? '';
        if (serverId.isEmpty) continue;
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
      await transaction.insert('sync_meta', {
        'key': 'cursor',
        'value': cursor.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
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
    final rows = await database.query(
      'subscribers',
      columns: ['id', 'created_at'],
    );
    for (final row in rows) {
      await database.update(
        'subscribers',
        {
          'card_epc': _cardEpcFor(
            row['id'] as int,
            row['created_at'] as String,
          ),
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  static String _cardEpcFor(int id, String createdAt) => generateCardEpc(
    DateTime.tryParse(createdAt)?.year ?? DateTime.now().year,
    id,
  );

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
      final createdAt = existing.isEmpty
          ? timestamp
          : existing.first['created_at'] as String;
      await database.update(
        'subscribers',
        {'card_epc': _cardEpcFor(id, createdAt)},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    return Subscriber.fromMap(
      (await database.query(
        'subscribers',
        where: 'id = ?',
        whereArgs: [id],
      )).first,
    );
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
