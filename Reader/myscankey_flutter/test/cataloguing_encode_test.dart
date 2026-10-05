import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/services/cataloguing_preferences.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/notice/notice_lookup_service.dart';
import 'package:myscankey_flutter/services/notice/notice_source.dart';
import 'package:myscankey_flutter/services/reader_service.dart';
import 'package:myscankey_flutter/widgets/book_editor.dart';

class _Cache implements NoticeLookupCache {
  @override
  Future<List<NoticeResult>> read(String isbn13) async => [];
  @override
  Future<void> write(String isbn13, List<NoticeResult> results) async {}
}

class _Reader extends ReaderService {
  final _tags = StreamController<ReaderTag>.broadcast();
  bool _reading = false;
  int failedWrites = 0;
  int writes = 0;
  ReaderTag tag = const ReaderTag(
    epc: '300000000000000000000001',
    tid: '',
    rssi: 60,
  );
  @override
  bool get connected => true;
  @override
  bool get reading => _reading;
  @override
  Stream<ReaderTag> get tags => _tags.stream;
  @override
  Stream<String> get nativeRfidKeyEvents => const Stream.empty();
  @override
  Future<void> startInventory({int? power, String? targetEpc}) async {
    _reading = true;
    scheduleMicrotask(() => _tags.add(tag));
  }

  @override
  Future<void> stopInventory() async => _reading = false;
  @override
  Future<String> resolveTid(String epc) async => 'E280000000000001';
  @override
  Future<Map<Object?, Object?>> writeEpc(
    String epc,
    String tid, {
    required String currentEpc,
    int? writePower,
    int? restorePower,
  }) async {
    writes++;
    if (failedWrites > 0) {
      failedWrites--;
      throw StateError('Écriture interrompue');
    }
    tag = ReaderTag(epc: epc, tid: tid, rssi: 60);
    return {'verified': true, 'epc': epc, 'tid': tid};
  }

  @override
  Future<void> dispose() async {
    await _tags.close();
    await super.dispose();
  }
}

Finder _field(String name) => find.byKey(ValueKey('field_$name'));
String _value(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(_field(key)).controller!.text;
final _next = find.text('Enregistrer, encoder et cataloguer le suivant');

Future<void> _enter(WidgetTester tester, String key, String value) async {
  await tester.ensureVisible(_field(key));
  await tester.pumpAndSettle();
  await tester.enterText(_field(key), value);
  await tester.pump();
}

// Le lecteur utilise l’horloge de test ; SQLite FFI utilise une boucle réelle.
Future<void> _finishSave(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('L’enregistrement ne se termine pas.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final database = LibraryDatabase.instance;
  late Directory directory;
  late _Reader reader;
  late LibraryController controller;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('cataloguing-encode-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await database.close();
    await databaseFactory.deleteDatabase(
      path.join(directory.path, 'biblio_rfid.db'),
    );
    await database.database;
    reader = _Reader();
    controller = LibraryController(database: database, reader: reader)
      ..view = 'catalogue';
  });
  tearDown(() async {
    controller.dispose();
    await database.close();
  });
  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: BookEditor(
          controller: controller,
          manageSaving: true,
          lookupService: NoticeLookupService(
            sources: [],
            localLookup: (_) async => [],
            cache: _Cache(),
          ),
          preferences: const CataloguingPreferences(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('RFID connecté'), findsOneWidget);
    await tester.tap(find.text('Saisie manuelle / sans ISBN'));
    await tester.pumpAndSettle();
    for (final entry in {
      'title': 'Livre à encoder',
      'author': 'Dumas',
      'publisher': 'Local',
      'publication_year': '2026',
      'document_type': 'Fiction',
      'location': 'Salle A',
    }.entries) {
      await _enter(tester, entry.key, entry.value);
    }
  }

  testWidgets(
    'enregistre et encode puis conserve localisation et type pour le suivant',
    (tester) async {
      await open(tester);
      await tester.tap(_next);
      await _finishSave(tester);
      expect(find.byKey(const ValueKey('isbn_input')), findsOneWidget);
      final books = (await tester.runAsync(() => database.listBooks()))!;
      expect(books, hasLength(1));
      expect(books.single.status, 'encode');
      expect(books.single.tid, 'E280000000000001');
      expect(reader.writes, 1);
      await tester.tap(find.text('Saisie manuelle / sans ISBN'));
      await tester.pumpAndSettle();
      expect(_value(tester, 'document_type'), 'Fiction');
      expect(_value(tester, 'location'), 'Salle A');
      expect(_value(tester, 'title'), isEmpty);
      expect(_value(tester, 'author'), isEmpty);
      expect(_value(tester, 'isbn'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('échec RFID puis reprise : un seul livre et la même accession', (
    tester,
  ) async {
    reader.failedWrites = 1;
    await open(tester);
    await tester.tap(_next);
    await _finishSave(tester);
    expect(
      find.textContaining('L’encodage peut être réessayé'),
      findsOneWidget,
    );
    final first = (await tester.runAsync(() => database.listBooks()))!.single;
    expect(first.status, 'a_encoder');
    await tester.tap(_next);
    await _finishSave(tester);
    final books = (await tester.runAsync(() => database.listBooks()))!;
    expect(books, hasLength(1));
    expect(books.single.accession, first.accession);
    expect(books.single.epc, first.epc);
    expect(books.single.status, 'encode');
    expect(reader.writes, 2);
    expect(find.byKey(const ValueKey('isbn_input')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
