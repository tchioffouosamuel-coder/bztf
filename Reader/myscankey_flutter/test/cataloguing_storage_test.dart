import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/services/cataloguing_preferences.dart';
import 'package:myscankey_flutter/services/cote_label.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final database = LibraryDatabase.instance;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('cataloguing-test-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await database.close();
    await databaseFactory.deleteDatabase(
      path.join(directory.path, 'biblio_rfid.db'),
    );
  });
  tearDownAll(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('migration v9 vers v10 conserve livres, accession et EPC', () async {
    final original = await database.createBook({
      'title': 'Livre v9',
      'summary': 'Résumé à conserver',
    });
    await database.close();
    final oldDb = await databaseFactory.openDatabase(
      path.join(directory.path, 'biblio_rfid.db'),
    );
    for (final column in ['document_type', 'location', 'item_status']) {
      await oldDb.execute('ALTER TABLE books DROP COLUMN $column');
    }
    await oldDb.execute('PRAGMA user_version = 9');
    await oldDb.close();
    final migrated = (await database.getBook(original.id))!;
    expect(migrated.accession, original.accession);
    expect(migrated.epc, original.epc);
    expect(migrated.summary, 'Résumé à conserver');
    expect(migrated.itemStatus, 'Disponible');
    expect(await (await database.database).getVersion(), 11);
  });

  test(
    'enregistrement local et édition partielle conservent les champs enrichis',
    () async {
      final book = await database.createBook({
        'title': 'Livre local',
        'document_type': 'Documentaire',
        'location': 'Salle A',
        'item_status': 'Consultation sur place',
        'shelf': '966.71 NGO',
        'source_notice': 'SUDOC',
        'summary': 'Résumé',
        'page_count': '120',
      });
      final updated = await database.updateBook(book.id, {
        'title': 'Titre corrigé',
      });
      expect(updated.documentType, 'Documentaire');
      expect(updated.location, 'Salle A');
      expect(updated.itemStatus, 'Consultation sur place');
      expect(updated.shelf, '966.71 NGO');
      expect(updated.sourceNotice, 'SUDOC');
      expect(updated.summary, 'Résumé');
      expect(updated.epc, book.epc);
      expect(updated.status, 'a_encoder');
    },
  );

  test(
    'un serveur ancien ne supprime pas les champs qu’il ne connaît pas',
    () async {
      final book = await database.createBook({
        'title': 'Titre',
        'location': 'Salle A',
        'document_type': 'Fiction',
        'source_notice': 'BnF',
        'summary': 'Résumé',
      });
      final remote = book.toSyncJson();
      remote['title'] = 'Titre distant';
      await (await database.database).delete(
        'sync_outbox',
        where: 'entity_id = ?',
        whereArgs: [book.serverId],
      );
      for (final field in [
        'location',
        'documentType',
        'itemStatus',
        'sourceNotice',
        'summary',
      ]) {
        remote.remove(field);
      }
      await database.applyRemoteChanges([
        {
          'operation': 'upsert',
          'entityId': book.serverId,
          'entityType': 'book',
          'book': remote,
        },
      ], 1);
      final updated = (await database.getBook(book.id))!;
      expect(updated.title, 'Titre distant');
      expect(updated.location, 'Salle A');
      expect(updated.documentType, 'Fiction');
      expect(updated.sourceNotice, 'BnF');
      expect(updated.summary, 'Résumé');
    },
  );

  test('préfixes et dimensions d’étiquette sont persistés', () async {
    await const CataloguingPreferences(
      prefixes: {'Roman': 'ROM'},
      labelWidthMm: 70,
      labelHeightMm: 30,
    ).save();
    final settings = await CataloguingPreferences.load();
    expect(settings.prefixes['Roman'], 'ROM');
    expect(settings.labelWidthMm, 70);
    expect(settings.labelHeightMm, 30);
    await expectLater(
      const CataloguingPreferences(labelWidthMm: -1).save(),
      throwsFormatException,
    );
  });

  test(
    'PDF de cote créé avec une police locale et dimensions personnalisées',
    () async {
      final book = await database.createBook({
        'title': 'L’Étranger',
        'author': 'Camus',
        'shelf': 'R CAM',
      });
      final bytes = await buildCoteLabel(
        book,
        const CataloguingPreferences(labelWidthMm: 60, labelHeightMm: 40),
      );
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      expect(bytes.length, greaterThan(1000));
      final small = await buildCoteLabel(
        book,
        const CataloguingPreferences(labelWidthMm: 20, labelHeightMm: 20),
      );
      expect(small, isNotEmpty);
    },
  );
}
