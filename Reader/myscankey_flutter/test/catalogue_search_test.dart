import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';

void main() {
  final database = LibraryDatabase.instance;
  late Directory directory;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('catalogue-search-test-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'critères existants, sujets, cote et Dewey sans accents ni casse',
    () async {
      final book = await database.createBook({
        'title': 'L’Étranger',
        'author': 'NGOË',
        'isbn': '2-07-036002-4',
        'subjects': 'Histoire du Cameroun ; Économie',
        'shelf': '966.71 NGO',
        'dewey': '966.71',
      });
      for (final term in [
        'ETRANGER',
        'ngoE',
        'économie',
        'CAMEROUN',
        '966.71 NGO',
        '966.71',
        '9782070360024',
        '2070360024',
        book.accession.toLowerCase(),
        book.epc.toLowerCase(),
        'NG',
      ]) {
        expect((await database.listBooks(search: term)).map((b) => b.id), [
          book.id,
        ], reason: term);
        expect(await database.countBooks(search: term), 1);
      }
      expect(await database.listBooks(search: '%'), isEmpty);
      await database.updateBook(book.id, {
        'title': 'Titre corrigé',
        'subjects': 'Géographie',
      });
      expect(await database.listBooks(search: 'etranger'), isEmpty);
      expect(await database.listBooks(search: 'GEOGRAPHIE'), hasLength(1));
    },
  );

  test(
    'listes incomplètes, brouillons et non encodés correspondent au comptage',
    () async {
      final complete = await database.createBook({
        'title': 'Complet',
        'author': 'Auteur',
        'publisher': 'Éditeur',
        'publication_year': '2026',
        'document_type': 'Fiction',
      });
      await database.markTagged(complete.id, 'TID1');
      final incomplete = await database.createBook({'title': 'Incomplet'});
      final draft = await database.createBook({
        'title': 'Brouillon',
        'author': 'Auteur',
        'publisher': 'Éditeur',
        'publication_year': '2026',
        'document_type': 'Fiction',
        'catalog_draft': 1,
      });
      expect(
        (await database.listBooks(workList: 'incomplete')).single.id,
        incomplete.id,
      );
      expect(
        (await database.listBooks(workList: 'drafts')).single.id,
        draft.id,
      );
      expect(await database.countBooks(workList: 'unencoded'), 2);
      expect(await database.listBooks(workList: 'unencoded'), hasLength(2));
      await database.updateBook(draft.id, {
        'title': 'Brouillon vérifié',
        'catalog_draft': 0,
      });
      expect(await database.listBooks(workList: 'drafts'), isEmpty);
    },
  );

  test(
    'migration additive v10→v11 conserve livres, prêts et activités et reconstruit les index',
    () async {
      final book = await database.createBook({
        'title': 'Étude locale',
        'author': 'NGOË',
        'isbn': '9782070360024',
      });
      final loan = await database.borrowBook(
        book.id,
        memberNumber: 'MIG',
        name: 'Lecteur',
        dueAt: DateTime.now().add(const Duration(days: 7)),
      );
      final activities = await (await database.database).query('activity');
      await database.close();
      final old = await databaseFactory.openDatabase(
        path.join(directory.path, 'biblio_rfid.db'),
      );
      try {
        for (final index in [
          'idx_books_isbn13',
          'idx_books_incomplete_id',
          'idx_books_draft_id',
          'idx_books_status_id',
        ]) {
          await old.execute('DROP INDEX $index');
        }
        for (final table in [
          'isbn_import_rows',
          'isbn_import_jobs',
          'catalog_duplicate_ignored',
          'catalog_search_grams',
        ]) {
          await old.execute('DROP TABLE $table');
        }
        for (final column in [
          'search_text',
          'isbn13',
          'catalog_incomplete',
          'catalog_draft',
        ]) {
          await old.execute('ALTER TABLE books DROP COLUMN $column');
        }
        await old.execute('PRAGMA user_version = 10');
      } finally {
        await old.close();
      }
      final migrated = (await database.listBooks(search: 'ETUDE')).single;
      expect(migrated.id, book.id);
      expect(migrated.accession, book.accession);
      expect(migrated.epc, book.epc);
      expect((await database.activeLoanForBook(book.id))!.id, loan.id);
      expect(await (await database.database).query('activity'), activities);
      expect(await database.findBooksByIsbn('9782070360024'), hasLength(1));
      expect(await (await database.database).getVersion(), 11);
    },
  );

  test(
    'recherche mesurée et plans d’index sur 5 000 livres',
    () async {
      final db = await database.database;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < 5000; i++) {
          batch.insert('books', {
            'accession': 'PERF-$i',
            'epc': 'PERF-EPC-$i',
            'title': 'Étude historique région $i',
            'author': 'NGOË',
            'subjects': 'Économie ; Cameroun',
            'publisher': 'Éditeur local',
            'publication_year': '2026',
            'document_type': 'Documentaire',
            'shelf': '966.71 NGO $i',
            'dewey': '966.71',
            'created_at': '',
            'updated_at': '',
          });
        }
        await batch.commit(noResult: true);
        for (final row in await txn.query('books')) {
          await LibraryDatabase.indexCatalogueBook(txn, Book.fromMap(row));
        }
      });
      final times = <String, int>{};
      for (final term in ['region 4321', 'ECONOMIE', '966.71 NGO', '966.71']) {
        final stopwatch = Stopwatch()..start();
        final results = await database.listBooks(search: term);
        final count = await database.countBooks(search: term);
        stopwatch.stop();
        times[term] = stopwatch.elapsedMilliseconds;
        expect(count, term == 'region 4321' ? 1 : 5000);
        expect(results, isNotEmpty);
        expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      }
      final (where, args) = LibraryDatabase.catalogueFilter(
        search: 'region 4321',
      );
      final plans = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT id FROM books WHERE ${where.join(' AND ')}',
        args,
      );
      expect(
        plans.map((row) => row['detail']).join(' '),
        contains('USING COVERING INDEX sqlite_autoindex_catalog_search_grams'),
      );
      final statusPlan = await db.rawQuery(
        "EXPLAIN QUERY PLAN SELECT id FROM books WHERE status='a_encoder' ORDER BY id DESC",
      );
      expect(
        statusPlan.map((row) => row['detail']).join(' '),
        contains('idx_books_status_id'),
      );
      // Mesure reproduisible dans le journal de flutter test ; aucun accès réseau.
      debugPrint('Catalogue 5 000 lignes — recherche + comptage (ms) : $times');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
