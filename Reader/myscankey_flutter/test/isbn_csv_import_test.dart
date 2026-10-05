import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/services/isbn_csv_import.dart';
import 'package:myscankey_flutter/services/notice/notice_lookup_service.dart';
import 'package:myscankey_flutter/services/notice/notice_source.dart';
import 'package:myscankey_flutter/services/notice/rate_limited_client.dart';

class _Cache implements NoticeLookupCache {
  @override
  Future<List<NoticeResult>> read(String isbn13) async => [];
  @override
  Future<void> write(String isbn13, List<NoticeResult> results) async {}
}

class _Lookup extends NoticeLookupService {
  _Lookup(this.callback)
    : super(sources: [], localLookup: (_) async => [], cache: _Cache());
  final Future<List<NoticeResult>> Function(String) callback;
  final calls = <String>[];
  @override
  Future<List<NoticeResult>> lookup(
    String isbn, {
    bool Function()? isCancelled,
  }) {
    calls.add(isbn);
    return callback(isbn);
  }
}

const _notice = NoticeResult(
  title: 'Livre récupéré',
  sourceNotice: 'SUDOC',
  auteurs: [NoticeAuthor(nom: 'Camus')],
  editeur: 'Gallimard',
  datePublication: '1942',
  resume: 'Résumé',
);

void main() {
  late Directory directory;
  final database = LibraryDatabase.instance;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('isbn-csv-test-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'CSV valide : en-tête, autres colonnes ignorées, création de brouillons',
    () async {
      final lookup = _Lookup((_) async => [_notice]);
      final importer = IsbnCsvImport(
        database,
        lookupService: lookup,
        batchSize: 1,
      );
      await importer.createJob(
        utf8.encode(
          '\uFEFFISBN;Notes\r\n9782070360024;Une note\r\n9782070408504;Autre',
        ),
        'livres.csv',
      );
      await importer.run();
      expect(importer.count('found'), 2);
      expect(lookup.calls, ['9782070360024', '9782070408504']);
      final books = await database.listBooks();
      expect(books, hasLength(2));
      expect(
        books.every(
          (book) =>
              book.catalogDraft &&
              book.status == 'a_encoder' &&
              book.documentType.isEmpty,
        ),
        isTrue,
      );
      expect(books.first.summary, 'Résumé');
      expect(importer.reportCsvBytes().take(3), [0xEF, 0xBB, 0xBF]);
      final report = Csv.excel().decode(utf8.decode(importer.reportCsvBytes()));
      expect(report, hasLength(3));
      expect(report[1][0], '2');
      importer.dispose();
    },
  );

  test(
    'ISBN invalides, lignes vides et doublons ISBN-10/13 sans requête',
    () async {
      await database.createBook({'title': 'Existant', 'isbn': '9782070360024'});
      final lookup = _Lookup((_) async => [_notice]);
      final importer = IsbnCsvImport(database, lookupService: lookup);
      await importer.createJob(
        utf8.encode(
          'ISBN\n\nINVALIDE\n2070360024\n9782070408504\n9782070408504',
        ),
        'isbn.csv',
      );
      await importer.run();
      expect(importer.count('empty'), 1);
      expect(importer.count('error'), 1);
      expect(importer.count('duplicate'), 2);
      expect(importer.count('found'), 1);
      expect(lookup.calls, ['9782070408504']);
      expect(await database.countBooks(), 2);
      importer.dispose();
    },
  );

  test(
    'rapport distingue non trouvés et erreurs joignabilité ; erreurs peuvent être reprises',
    () async {
      var offline = true;
      final lookup = _Lookup((isbn) async {
        if (isbn == '9782070360024') {
          throw const NoticeNotFoundException('vide');
        }
        if (offline) throw const NoticeNetworkException('hors ligne');
        return [_notice];
      });
      final importer = IsbnCsvImport(database, lookupService: lookup);
      await importer.createJob(
        utf8.encode('9782070360024\n9782070408504'),
        'isbn.csv',
      );
      await importer.run();
      expect(importer.count('not_found'), 1);
      expect(importer.count('error'), 1);
      offline = false;
      await importer.retryErrors();
      await importer.run();
      expect(importer.count('found'), 1);
      expect(importer.count('not_found'), 1);
      importer.dispose();
    },
  );

  test(
    'annulation pendant une requête puis reprise durable sans doublon',
    () async {
      final pending = Completer<List<NoticeResult>>(),
          started = Completer<void>();
      final lookup = _Lookup((_) {
        started.complete();
        return pending.future;
      });
      final importer = IsbnCsvImport(database, lookupService: lookup);
      await importer.createJob(
        utf8.encode('9782070360024\n9782070408504'),
        'isbn.csv',
      );
      final run = importer.run();
      await started.future;
      importer.cancel();
      pending.complete([_notice]);
      await run;
      expect(importer.count('pending'), 2);
      expect(await database.countBooks(), 0);
      importer.dispose();
      await database.close();
      final resumed = IsbnCsvImport(
        database,
        lookupService: _Lookup((_) async => [_notice]),
      );
      await resumed.loadLatest();
      await resumed.run();
      expect(resumed.count('found'), 2);
      await resumed.run();
      expect(await database.countBooks(), 2);
      await resumed.createJob(
        utf8.encode('9782070360024\n9782070408504'),
        'isbn.csv',
      );
      await resumed.run();
      expect(await database.countBooks(), 2);
      resumed.dispose();
    },
  );

  test(
    'requêtes d’un même hôte espacées d’au moins 300 ms, même simultanées',
    () async {
      final calls = <DateTime>[];
      final client = NoticeRateLimitedClient(
        inner: MockClient((request) async {
          calls.add(DateTime.now());
          return http.Response('ok', 200);
        }),
      );
      await Future.wait([
        client.get(Uri.parse('https://rate-test.invalid/isbn2ppn')),
        client.get(Uri.parse('https://rate-test.invalid/notice.xml')),
        client.get(Uri.parse('https://rate-test.invalid/second.xml')),
      ]);
      expect(calls, hasLength(3));
      for (var i = 1; i < calls.length; i++) {
        expect(
          calls[i].difference(calls[i - 1]),
          greaterThanOrEqualTo(const Duration(milliseconds: 300)),
        );
      }
      client.close();
    },
  );
}
