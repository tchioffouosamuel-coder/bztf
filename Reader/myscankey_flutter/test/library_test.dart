import 'dart:async';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:myscankey_flutter/core/epc.dart';
import 'package:myscankey_flutter/data/catalog_importer.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/reader_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'catalogue local, écriture/désencodage et import XLSX dédupliqué',
    () async {
      final directory = await getDatabasesPath();
      final filePath = path.join(directory, 'biblio_rfid.db');
      await LibraryDatabase.instance.close();
      await databaseFactory.deleteDatabase(filePath);
      final database = LibraryDatabase.instance;

      final created = await database.createBook({'title': 'Le livre test'});
      expect(created.accession.startsWith('BCM-'), isTrue);
      expect(created.status, 'a_encoder');
      expect(
        await database.recognizeTag(created.epc, 'E28068940000500A12AB0099'),
        isNull,
      );
      expect((await database.getBook(created.id))!.status, 'a_encoder');

      final tagged = await database.markTagged(
        created.id,
        'E28068940000500A12AB0001',
      );
      expect(tagged.status, 'encode');
      expect(
        await database.recognizeTag(tagged.epc, 'E28068940000500A12AB0099'),
        isNull,
      );
      expect(
        (await database.recognizeTag(tagged.epc, tagged.tid!))?.id,
        tagged.id,
      );
      final untagged = await database.markUntagged(created.id);
      expect(untagged.status, 'a_encoder');
      expect(untagged.tid, isNull);

      final workbook = Excel.createExcel();
      final sheet = workbook['Books'];
      sheet.appendRow([
        TextCellValue('TITRE'),
        TextCellValue('AUTEURS'),
        TextCellValue('BATIMENT'),
        TextCellValue('SALLE'),
        TextCellValue('ETAGERE'),
        TextCellValue('NUMERO DE BLOC'),
        TextCellValue('SECTION'),
      ]);
      sheet.appendRow([
        TextCellValue('Notice importée'),
        TextCellValue('Auteur test'),
        TextCellValue('A'),
        TextCellValue('Salle 1'),
        TextCellValue('Etagère 2'),
        IntCellValue(3),
        TextCellValue('Roman'),
      ]);
      final bytes = workbook.encode()!;
      final importer = CatalogImporter(database);
      expect(await importer.importBytes(bytes), 1);
      expect(await importer.importBytes(bytes), 0);
      expect(await database.countBooks(), 2);
      expect(await database.pendingMutationCount(), 2);
      final imported = await database.listBooks(search: 'Notice importée');
      expect(imported.single.shelf, 'A · Salle 1 · Etagère 2 · 3');
      expect(imported.single.category, 'Roman');

      await database.close();
      await databaseFactory.deleteDatabase(filePath);
    },
  );

  test('emprunt, retour et abonnés', () async {
    final directory = await getDatabasesPath();
    await LibraryDatabase.instance.close();
    await databaseFactory.deleteDatabase(
      path.join(directory, 'biblio_rfid.db'),
    );
    final database = LibraryDatabase.instance;
    final book = await database.createBook({'title': 'Livre à prêter'});
    final dueAt = DateTime.now().add(const Duration(days: 14));

    await expectLater(
      database.borrowBook(
        book.id,
        memberNumber: 'ab-1',
        name: 'Lecteur',
        dueAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
      throwsArgumentError,
    );

    final loan = await database.borrowBook(
      book.id,
      memberNumber: 'ab-1',
      name: 'Lecteur',
      phone: '600000000',
      dueAt: dueAt,
    );
    expect(loan.memberNumber, 'AB-1');
    expect(loan.subscriberName, 'Lecteur');
    expect(loan.subscriptionEndsAt, isNotNull);
    expect((await database.getBook(book.id))!.status, 'indisponible');
    await expectLater(
      database.borrowBook(
        book.id,
        memberNumber: 'AB-2',
        name: 'Autre',
        dueAt: dueAt,
      ),
      throwsStateError,
    );
    await expectLater(database.deleteBook(book), throwsStateError);

    final subscribers = await database.listSubscribers(search: 'ab-1');
    expect(subscribers.single.activeLoans, 1);

    final returned = await database.returnBook(book.id);
    expect(returned.status, 'a_encoder');
    expect(await database.activeLoanForBook(book.id), isNull);

    // Un second emprunt réutilise l'abonné et son abonnement encore valide.
    final second = await database.borrowBook(
      book.id,
      memberNumber: 'AB-1',
      name: 'Lecteur',
      dueAt: dueAt,
    );
    expect(second.subscriberId, loan.subscriberId);
    expect(second.subscriptionId, loan.subscriptionId);
    await database.returnBook(book.id);

    await database.deleteBook(returned);
    expect(await database.getBook(book.id), isNull);
  });

  test('encode la carte d’un abonné puis l’identifie par lecture', () async {
    final directory = await getDatabasesPath();
    await LibraryDatabase.instance.close();
    await databaseFactory.deleteDatabase(
      path.join(directory, 'biblio_rfid.db'),
    );
    final reader = _FakeReaderService();
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: reader,
    );
    const blankTid = 'E2806894000050CA4D000001';
    try {
      await controller.setView('catalogue');
      reader.tagsOnStart = const [
        ReaderTag(epc: 'E2806894000050CA4D000001', tid: blankTid, rssi: 70),
      ];
      final subscriber = await controller.encodeSubscriberCard(
        memberNumber: 'ab-9',
        name: 'Carte Mobile',
      );
      expect(isCardEpc(subscriber.cardEpc!), isTrue);
      expect(subscriber.cardTid, blankTid);
      expect(reader.writtenEpcs, [subscriber.cardEpc]);
      expect(reader.reading, isFalse);
      expect(controller.view, 'catalogue');

      reader.tagsOnStart = [
        ReaderTag(epc: subscriber.cardEpc!, tid: blankTid, rssi: 70),
      ];
      final read = await controller.readSubscriberCard();
      expect(read.id, subscriber.id);
      expect(read.memberNumber, 'AB-9');

      // Une carte ne peut pas devenir un livre.
      final book = await controller.database.createBook({'title': 'Livre'});
      await expectLater(
        controller.database.markTagged(book.id, blankTid),
        throwsStateError,
      );

      // Deux tags sur le lecteur : lecture refusée.
      reader.tagsOnStart = [
        ReaderTag(epc: subscriber.cardEpc!, tid: blankTid, rssi: 70),
        const ReaderTag(
          epc: 'E2806894000050CA4D000002',
          tid: 'E2806894000050CA4D000002',
          rssi: 60,
        ),
      ];
      await expectLater(controller.readSubscriberCard(), throwsStateError);
    } finally {
      controller.dispose();
      await LibraryDatabase.instance.close();
    }
  });

  test('conserve la pile des écrans pour le bouton système', () async {
    final controller = LibraryController(database: LibraryDatabase.instance);

    try {
      await controller.setView('catalogue');
      await controller.setView('station');
      await controller.setView('history');
      expect(controller.view, 'history');
      expect(controller.canNavigateBack, isTrue);

      expect(await controller.navigateBack(), isTrue);
      expect(controller.view, 'station');

      expect(await controller.navigateBack(), isTrue);
      expect(controller.view, 'catalogue');

      expect(await controller.navigateBack(), isTrue);
      expect(controller.view, 'dashboard');
      expect(controller.canNavigateBack, isFalse);
      expect(await controller.navigateBack(), isFalse);
    } finally {
      controller.dispose();
      await LibraryDatabase.instance.close();
    }
  });

  test('le lecteur intégré attend la gâchette dans la station', () async {
    final reader = _FakeReaderService();
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: reader,
    );

    try {
      controller.transport = 'serial';
      await controller.setView('station');
      expect(reader.startCount, 0);
      expect(reader.reading, isFalse);

      await controller.setView('dashboard');
      controller.transport = 'tcp';
      await controller.setView('station');
      expect(reader.startCount, 1);
      expect(reader.reading, isTrue);

      await controller.setView('dashboard');
      controller.transport = 'serial';
      await controller.setView('inventory');
      await expectLater(controller.startInventory(), throwsStateError);
      expect(reader.reading, isFalse);
      reader.emitKey('down');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(reader.reading, isTrue);
      expect(reader.lastPower, controller.inventoryPower);
      reader.emitKey('up');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(reader.reading, isFalse);
    } finally {
      controller.dispose();
      await LibraryDatabase.instance.close();
    }
  });

  test(
    'l’inventaire conserve une ligne par EPC lorsque le TID arrive',
    () async {
      final directory = await getDatabasesPath();
      final filePath = path.join(directory, 'biblio_rfid.db');
      await LibraryDatabase.instance.close();
      await databaseFactory.deleteDatabase(filePath);
      final database = LibraryDatabase.instance;
      final book = await database.createBook({'title': 'Livre inventorié'});
      const tid = 'E28068940000500A12AB0002';
      await database.markTagged(book.id, tid);
      final reader = _FakeReaderService();
      final controller = LibraryController(database: database, reader: reader);

      try {
        await controller.setView('inventory');
        reader.emit(ReaderTag(epc: book.epc, tid: '', rssi: -48));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        reader.emit(ReaderTag(epc: book.epc, tid: tid, rssi: -45));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(controller.inventoryRecords, hasLength(1));
        expect(
          controller.inventoryRecords.single.book?.title,
          'Livre inventorié',
        );
        expect(controller.inventoryRecords.single.tag.tid, tid);
        expect(controller.inventoryRecognizedCount, 1);
        expect(controller.referencedInventoryRecords, hasLength(1));

        reader.emit(
          ReaderTag(epc: book.epc, tid: 'E28068940000500A12AB0099', rssi: -44),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller.inventoryRecords, hasLength(1));
        expect(controller.inventoryRecords.single.book, isNull);
        expect(controller.inventoryUnknownCount, 1);
        expect(controller.referencedInventoryRecords, isEmpty);
      } finally {
        controller.dispose();
        await database.close();
        await databaseFactory.deleteDatabase(filePath);
      }
    },
  );

  test(
    'la station conserve la dernière lecture jusqu’au scan suivant',
    () async {
      final reader = _FakeReaderService()
        ..resolvedTid = 'E28068940000500A12AB0010';
      final controller = LibraryController(
        database: LibraryDatabase.instance,
        reader: reader,
      );

      try {
        controller.transport = 'serial';
        await controller.setView('station');
        await controller.startInventory();
        reader.emit(
          const ReaderTag(epc: '110002010010012003000010', tid: '', rssi: -30),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await controller.stopInventory();
        await Future<void>.delayed(const Duration(milliseconds: 1550));

        expect(controller.observedTags, hasLength(1));
        expect(controller.observedTags.single.tid, reader.resolvedTid);

        await controller.startInventory();
        expect(controller.observedTags, isEmpty);
      } finally {
        controller.dispose();
        await LibraryDatabase.instance.close();
      }
    },
  );

  test(
    'la station conserve le TID et nomme les livres en lecture multiple',
    () async {
      final directory = await getDatabasesPath();
      final filePath = path.join(directory, 'biblio_rfid.db');
      await LibraryDatabase.instance.close();
      await databaseFactory.deleteDatabase(filePath);
      final database = LibraryDatabase.instance;
      final first = await database.createBook({'title': 'Premier livre'});
      final second = await database.createBook({'title': 'Deuxième livre'});
      const firstTid = 'E28068940000500A12AB0011';
      const secondTid = 'E28068940000500A12AB0012';
      await database.markTagged(first.id, firstTid);
      await database.markTagged(second.id, secondTid);
      final reader = _FakeReaderService();
      final controller = LibraryController(database: database, reader: reader);

      try {
        controller.transport = 'serial';
        await controller.setView('station');
        await controller.startInventory();
        reader.emit(ReaderTag(epc: first.epc, tid: firstTid, rssi: -30));
        reader.emit(ReaderTag(epc: second.epc, tid: secondTid, rssi: -32));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        reader.emit(ReaderTag(epc: first.epc, tid: '', rssi: -31));
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(controller.observedTags, hasLength(2));
        expect(
          controller.observedTags
              .singleWhere((tag) => tag.epc == first.epc)
              .tid,
          firstTid,
        );
        expect(
          controller
              .recognizedBook(
                controller.observedTags.singleWhere(
                  (tag) => tag.epc == first.epc,
                ),
              )
              ?.title,
          'Premier livre',
        );
        expect(
          controller
              .recognizedBook(
                controller.observedTags.singleWhere(
                  (tag) => tag.epc == second.epc,
                ),
              )
              ?.title,
          'Deuxième livre',
        );
      } finally {
        controller.dispose();
        await database.close();
        await databaseFactory.deleteDatabase(filePath);
      }
    },
  );

  test('la localisation UHF ignore les tags qui ne sont pas ciblés', () async {
    final reader = _FakeReaderService();
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: reader,
    );
    const target = Book(
      id: 42,
      accession: 'BCM-2026-000042',
      epc: '110002010010012003000042',
      tid: 'E28068940000500A12AB0042',
      title: 'Livre à localiser',
      status: 'encode',
      createdAt: '2026-09-27T00:00:00Z',
      updatedAt: '2026-09-27T00:00:00Z',
    );

    try {
      controller.transport = 'serial';
      await controller.locateBook(target);
      await controller.startInventory();
      expect(reader.lastTargetEpc, target.epc);

      reader.emit(
        const ReaderTag(
          epc: '110002010010012003000099',
          tid: 'E28068940000500A12AB0099',
          rssi: -20,
        ),
      );
      reader.emit(
        const ReaderTag(
          epc: '110002010010012003000042',
          tid: 'E28068940000500A12AB0099',
          rssi: -18,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.locatorTag, isNull);

      reader.emit(
        const ReaderTag(epc: '110002010010012003000042', tid: '', rssi: -36),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.locatorTag?.epc, target.epc);
      expect(controller.locatorTag?.rssi, -36);
      expect(controller.locatorSignalLive, isTrue);

      await controller.stopInventory();
      expect(controller.locatorTag?.epc, target.epc);
      expect(controller.locatorSignalLive, isFalse);

      await controller.startInventory();
      expect(controller.locatorTag, isNull);
    } finally {
      controller.dispose();
      await LibraryDatabase.instance.close();
    }
  });
}

class _FakeReaderService extends ReaderService {
  final StreamController<ReaderTag> _events = StreamController.broadcast();
  final StreamController<String> _keyEvents = StreamController.broadcast();
  bool _reading = false;
  int startCount = 0;
  int? lastPower;
  String? lastTargetEpc;
  String resolvedTid = '';

  /// Tags émis automatiquement à chaque démarrage de lecture.
  List<ReaderTag> tagsOnStart = const [];
  final List<String> writtenEpcs = [];

  @override
  bool get connected => true;

  @override
  bool get reading => _reading;

  @override
  Stream<ReaderTag> get tags => _events.stream;

  @override
  Stream<String> get nativeRfidKeyEvents => _keyEvents.stream;

  void emit(ReaderTag tag) => _events.add(tag);

  void emitKey(String action) => _keyEvents.add(action);

  @override
  Future<void> playScanBeep() async {}

  @override
  Future<String> resolveTid(String epc) async => resolvedTid;

  @override
  Future<void> startInventory({int? power, String? targetEpc}) async {
    startCount++;
    lastPower = power;
    lastTargetEpc = targetEpc;
    _reading = true;
    for (final tag in tagsOnStart) {
      scheduleMicrotask(() => _events.add(tag));
    }
  }

  @override
  Future<Map<Object?, Object?>> writeEpc(
    String epc,
    String tid, {
    required String currentEpc,
    int? writePower,
    int? restorePower,
  }) async {
    writtenEpcs.add(epc);
    return {'verified': true, 'epc': epc, 'tid': tid};
  }

  @override
  Future<void> stopInventory() async {
    _reading = false;
  }
}
