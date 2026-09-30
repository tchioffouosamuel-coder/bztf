import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:myscankey_flutter/core/epc.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/models/lending.dart';
import 'package:myscankey_flutter/services/desk_reader_service.dart';
import 'package:myscankey_flutter/services/kiosk_controller.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/reader_service.dart';
import 'package:myscankey_flutter/screens/admin_screen.dart';
import 'package:myscankey_flutter/screens/device_role_screen.dart';
import 'package:myscankey_flutter/screens/kiosk_screen.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Base distincte de library_test.dart : les fichiers de test tournent
    // en parallèle.
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('bibliorfid_kiosk_')).path,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryDatabase.instance.close();
    await databaseFactory.deleteDatabase(
      path.join(await getDatabasesPath(), 'biblio_rfid.db'),
    );
  });

  tearDown(() => LibraryDatabase.instance.close());

  test('normalise les adresses du lecteur de bureau', () {
    expect(
      DeskReaderService.normalizeEndpoint('tcp', '192.168.1.168'),
      '192.168.1.168:8160',
    );
    expect(
      DeskReaderService.normalizeEndpoint('tcp', '10.0.0.5:9000'),
      '10.0.0.5:9000',
    );
    expect(
      DeskReaderService.normalizeEndpoint('serial', 'ttyS1'),
      '/dev/ttyS1:115200',
    );
    expect(
      DeskReaderService.normalizeEndpoint('serial', '/dev/ttyUSB0:57600'),
      '/dev/ttyUSB0:57600',
    );
    expect(
      () => DeskReaderService.normalizeEndpoint('tcp', ' '),
      throwsArgumentError,
    );
  });

  test('éligibilité, emprunt groupé et retour en libre-service', () async {
    final database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    final cardTid = member.cardTid!;

    // Carte : TID obligatoire, préfixe de 8 octets accepté.
    expect(
      (await database.cardForTag(member.cardEpc!, cardTid))?.id,
      member.id,
    );
    expect(
      (await database.cardForTag(
        member.cardEpc!,
        cardTid.substring(0, 16),
      ))?.id,
      member.id,
    );
    expect(await database.cardForTag(member.cardEpc!, ''), isNull);
    expect(
      await database.cardForTag(member.cardEpc!, 'E2801170200000000000FFFF'),
      isNull,
    );

    var status = await database.borrowerStatus(member.id, maxLoans: 2);
    expect(status.eligible, isFalse);
    expect(status.reasons.single, contains('Aucun abonnement'));

    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 30)),
    );
    status = await database.borrowerStatus(member.id, maxLoans: 2);
    expect(status.eligible, isTrue);
    expect(status.remaining, 2);

    final first = await _taggedBook(database, 'Premier', 'B001');
    final second = await _taggedBook(database, 'Second', 'B002');
    final third = await _taggedBook(database, 'Troisième', 'B003');
    expect((await database.bookForTag(first.epc, first.tid!))?.id, first.id);
    expect((await database.bookForTag(first.epc, ''))?.id, first.id);
    expect(
      await database.bookForTag(first.epc, 'E2000000000000000000FFFF'),
      isNull,
    );

    // Au-delà du quota : rien n'est enregistré.
    await expectLater(
      database.checkoutBooks(
        member.id,
        [first.id, second.id, third.id],
        dueAt: DateTime.now().add(const Duration(days: 14)),
        maxLoans: 2,
      ),
      throwsStateError,
    );
    expect(await database.listLoans(filter: LoanFilter.active), isEmpty);

    final loans = await database.checkoutBooks(
      member.id,
      [first.id, second.id],
      dueAt: DateTime.now().add(const Duration(days: 14)),
      maxLoans: 2,
    );
    expect(loans.map((loan) => loan.bookTitle), ['Premier', 'Second']);
    expect((await database.getBook(first.id))!.status, 'indisponible');
    // Un livre emprunté reste reconnu pour son retour.
    expect((await database.bookForTag(first.epc, first.tid!))?.id, first.id);

    status = await database.borrowerStatus(member.id, maxLoans: 2);
    expect(status.eligible, isFalse);
    expect(status.reasons.single, contains('Limite de 2'));
    await expectLater(
      database.checkoutBooks(
        member.id,
        [third.id],
        dueAt: DateTime.now().add(const Duration(days: 14)),
        maxLoans: 2,
      ),
      throwsStateError,
    );

    // Le premier livre passe en retard.
    await (await database.database).update(
      'loans',
      {
        'due_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 2))
            .toIso8601String(),
      },
      where: 'book_id = ?',
      whereArgs: [first.id],
    );
    status = await database.borrowerStatus(member.id, maxLoans: 5);
    expect(status.overdueLoans, 1);
    expect(status.reasons.single, contains('en retard'));
    expect(await database.listLoans(filter: LoanFilter.overdue), hasLength(1));
    expect(
      (await database.listSubscribers(search: 'AB-1')).single.overdueLoans,
      1,
    );
    var stats = await database.loanStats();
    expect(stats.active, 2);
    expect(stats.overdue, 1);
    expect(stats.borrowedToday, 2);

    // Le troisième livre n'était pas emprunté : il est ignoré.
    final returned = await database.returnBooks([
      first.id,
      second.id,
      third.id,
    ]);
    expect(returned.map((loan) => loan.bookId), [first.id, second.id]);
    expect(returned.every((loan) => loan.returned), isTrue);
    expect(returned.first.late, isTrue);
    expect(returned.last.late, isFalse);
    expect((await database.getBook(first.id))!.status, 'encode');
    expect(
      await database.listLoans(filter: LoanFilter.returned, search: 'Prem'),
      hasLength(1),
    );
    stats = await database.loanStats();
    expect(stats.active, 0);
    expect(stats.returnedToday, 2);
    final messages = (await database.activity()).map((entry) => entry.message);
    expect(
      messages,
      contains('Retour en retard au poste enregistré pour ab-1'),
    );

    await database.suspendSubscription(member.id);
    status = await database.borrowerStatus(member.id, maxLoans: 2);
    expect(status.reasons.single, 'Abonnement suspendu.');
  });

  test('emprunts et abonnements synchronisés entre appareils', () async {
    // Appareil A : abonnement puis emprunt au poste.
    var database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 30)),
    );
    final book = await _taggedBook(database, 'Partagé', 'B001');
    await database.checkoutBooks(
      member.id,
      [book.id],
      dueAt: DateTime.now().add(const Duration(days: 14)),
      maxLoans: 3,
    );
    final outbox = {
      for (final row in await database.pendingMutations())
        row['entity_type']: row,
    };
    final loanPayload =
        jsonDecode(outbox['loan']!['payload']! as String) as Map;
    final subscriptionPayload =
        jsonDecode(outbox['subscription']!['payload']! as String) as Map;
    expect(loanPayload['bookServerId'], book.serverId);
    expect(loanPayload['memberNumber'], 'AB-1');
    expect(
      loanPayload['subscriptionServerId'],
      subscriptionPayload['serverId'],
    );
    final syncedBook = (await database.getBook(book.id))!;
    final syncedMember = (await database.getSubscriber(member.id))!;

    // Appareil B, vierge.
    await database.close();
    await databaseFactory.deleteDatabase(
      path.join(await getDatabasesPath(), 'biblio_rfid.db'),
    );
    database = LibraryDatabase.instance;
    Map<String, Object?> change(String type, String id, Object? payload) => {
      'operation': 'upsert',
      'entityType': type,
      'entityId': id,
      type: payload,
    };
    final loanId = loanPayload['serverId'] as String;

    // L'emprunt arrive avant son livre : il attend.
    await database.applyRemoteChanges([change('loan', loanId, loanPayload)], 1);
    expect(await database.listLoans(), isEmpty);
    await database.applyRemoteChanges([
      change(
        'subscription',
        subscriptionPayload['serverId'] as String,
        subscriptionPayload,
      ),
      change('book', syncedBook.serverId!, syncedBook.toSyncJson()),
      change('subscriber', 'AB-1', syncedMember.toSyncJson()),
    ], 2);
    final localBook = (await database.listBooks()).single;
    final loan = await database.activeLoanForBook(localBook.id);
    expect(loan?.memberNumber, 'AB-1');
    expect(localBook.status, 'indisponible');
    final localMember = (await database.listSubscribers()).single;
    final status = await database.borrowerStatus(localMember.id, maxLoans: 3);
    expect(status.eligible, isTrue);
    expect(status.activeLoans, 1);

    // Retour sur B : l'emprunt part vers le serveur avec sa date de retour.
    await database.returnBooks([localBook.id]);
    final returned = (await database.pendingMutations()).singleWhere(
      (row) => row['entity_type'] == 'loan',
    );
    expect(returned['entity_id'], loanId);
    expect(
      (jsonDecode(returned['payload']! as String) as Map)['returnedAt'],
      isNotNull,
    );
    await database.acknowledgeMutations([
      for (final row in await database.pendingMutations())
        row['mutation_id']! as String,
    ]);

    // Nouvel emprunt fait ailleurs, abonnement suspendu ailleurs.
    await database.applyRemoteChanges([
      change('loan', 'loan-remote', {
        ...loanPayload,
        'serverId': 'loan-remote',
        'borrowedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      change('subscription', subscriptionPayload['serverId'] as String, {
        ...subscriptionPayload,
        'status': 'suspended',
      }),
    ], 3);
    expect(
      (await database.activeLoanForBook(localBook.id))?.id,
      isNot(loan!.id),
    );
    expect((await database.getBook(localBook.id))!.status, 'indisponible');
    expect(
      (await database.borrowerStatus(localMember.id, maxLoans: 3)).reasons,
      contains('Abonnement suspendu.'),
    );

    await database.applyRemoteChanges([
      {'operation': 'delete', 'entityType': 'loan', 'entityId': 'loan-remote'},
    ], 4);
    expect(await database.activeLoanForBook(localBook.id), isNull);
    expect((await database.getBook(localBook.id))!.status, 'encode');
  });

  test('poste d’emprunt : carte, livres, reçu puis retour', () async {
    final database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 365)),
    );
    final unsubscribed = await _subscriberWithCard(database, 'ab-2', 'A002');
    final first = await _taggedBook(database, 'Premier', 'B001');
    final second = await _taggedBook(database, 'Second', 'B002');

    final desk = _FakeDeskReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      deskReader: desk,
    );
    final kiosk = controller.kiosk
      ..transport = 'simulation'
      ..maxLoans = 1;
    try {
      await kiosk.enter();
      expect(desk.reading, isTrue);
      expect(controller.kioskActive, isTrue);

      // Carte sans abonnement : l'emprunt est refusé.
      desk.emit(_cardTag(unsubscribed));
      await _until(() => kiosk.borrower != null);
      expect(kiosk.stage, KioskStage.borrow);
      expect(kiosk.borrower!.eligible, isFalse);
      expect(kiosk.borrowBlocker, contains('Aucun abonnement'));
      kiosk.cancelSession();
      expect(kiosk.stage, KioskStage.home);

      // Carte valide et deux livres pour un quota d'un livre.
      desk.emit(_cardTag(member));
      await _until(() => kiosk.borrower != null);
      expect(kiosk.subscriber!.id, member.id);
      desk.emit(_bookTag(first));
      desk.emit(_bookTag(second));
      desk.emit(
        const ReaderTag(
          epc: 'E20000000000000000001234',
          tid: 'E2000000000000000000ABCD',
          rssi: 50,
        ),
      );
      await _until(() => kiosk.items.length == 2 && kiosk.unknownTags == 1);
      expect(kiosk.stateOf(kiosk.items.last), KioskItemState.overQuota);
      expect(kiosk.canConfirmBorrow, isFalse);
      expect(kiosk.borrowBlocker, contains('retirez-en 1'));

      kiosk.removeItem(second.epc);
      expect(kiosk.canConfirmBorrow, isTrue);
      await kiosk.confirmBorrow();
      expect(kiosk.stage, KioskStage.receipt);
      expect(kiosk.receipt!.borrow, isTrue);
      expect(kiosk.receipt!.loans.single.bookId, first.id);
      expect(
        DateTime.parse(kiosk.receipt!.loans.single.dueAt).toLocal().day,
        kiosk.dueDate.day,
      );

      // La carte restée posée ne relance pas de session.
      kiosk.finish();
      desk.emit(_cardTag(member));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(kiosk.stage, KioskStage.home);

      // Un livre emprunté posé seul ouvre le retour ; la carte est inutile.
      await kiosk.leave();
      await kiosk.enter();
      desk.emit(_bookTag(first));
      await _until(() => kiosk.returnableItems.length == 1);
      expect(kiosk.stage, KioskStage.giveBack);
      desk.emit(_cardTag(member));
      await _until(() => kiosk.notice != null);
      expect(kiosk.notice, contains('Aucune carte'));
      await kiosk.confirmReturn();
      expect(kiosk.stage, KioskStage.receipt);
      expect(kiosk.receipt!.borrow, isFalse);
      expect(kiosk.receipt!.loans.single.returned, isTrue);
      expect(await database.activeLoanForBook(first.id), isNull);

      await kiosk.leave();
      expect(desk.reading, isFalse);
      expect(controller.kioskActive, isFalse);
    } finally {
      controller.dispose();
    }
  });

  test('encode une carte d’abonné avec le lecteur du poste', () async {
    final database = LibraryDatabase.instance;
    final member = await database.saveSubscriber(
      memberNumber: 'ab-9',
      name: 'Nouvel abonné',
    );
    final other = await _subscriberWithCard(database, 'ab-8', 'A008');
    final book = await _taggedBook(database, 'Livre', 'B009');
    const blank = ReaderTag(
      epc: '300833B2DDD9014000000000',
      tid: 'E2801170200000000000C0DE',
      rssi: 55,
    );
    final desk = _FakeDeskReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      deskReader: desk,
    );
    final kiosk = controller.kiosk..transport = 'simulation';
    try {
      expect(member.hasCard, isFalse);

      desk.placed = [];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains('Aucun tag'))),
      );

      desk.placed = [blank, _bookTag(book)];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains('Plusieurs tags'))),
      );

      // Un livre ou la carte d'un autre abonné n'est jamais réécrit.
      desk.placed = [_bookTag(book)];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains('livre'))),
      );
      desk.placed = [_cardTag(other)];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains(other.name))),
      );
      // Livre ou carte encodés sur un autre appareil, inconnus ici.
      desk.placed = [
        ReaderTag(epc: generateEpc(2026, 999), tid: blank.tid, rssi: 50),
      ];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains('autre appareil'))),
      );
      desk.placed = [
        ReaderTag(epc: generateCardEpc(), tid: blank.tid, rssi: 50),
      ];
      await expectLater(
        kiosk.encodeCard(member),
        throwsA(predicate((e) => '$e'.contains('autre abonné'))),
      );
      expect(desk.written, isEmpty);

      desk.placed = [blank];
      final encoded = await kiosk.encodeCard(member);
      expect(encoded.hasCard, isTrue);
      expect(encoded.cardTid, blank.tid);
      expect(desk.written.single, (member.cardEpc, blank.tid));
      expect(
        (await database.cardForTag(member.cardEpc!, blank.tid))?.id,
        member.id,
      );
      // Hors poste actif, la lecture n'est pas laissée en marche.
      expect(desk.reading, isFalse);
    } finally {
      controller.dispose();
    }
  });

  test('bips du poste et anti-rebond de présence', () async {
    final database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 365)),
    );
    final first = await _taggedBook(database, 'Premier', 'B001');
    final second = await _taggedBook(database, 'Second', 'B002');
    final tablet = _SilentReader();
    final desk = _FakeDeskReader();
    final controller = LibraryController(
      database: database,
      reader: tablet,
      deskReader: desk,
    );
    final kiosk = controller.kiosk
      ..transport = 'simulation'
      ..beepRearmSeconds = 1;
    try {
      await kiosk.enter();

      // Carte puis deux livres posés ensemble : un bip pour la carte, un
      // seul pour les deux livres.
      desk.emit(_cardTag(member));
      await _until(() => kiosk.subscriber != null);
      await _until(() => desk.beeps == 1);
      desk.emit(_bookTag(first));
      desk.emit(_bookTag(second));
      await _until(() => kiosk.items.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(desk.beeps, 2);

      // Un tag qui clignote (relu sans retrait confirmé) ne rebipe pas.
      for (var index = 0; index < 5; index++) {
        desk.emit(_bookTag(first));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(desk.beeps, 2);
      expect(tablet.beeps, 0);

      // Fin de session : les livres encore posés ne relancent rien tant
      // que leur retrait n'est pas confirmé.
      kiosk.cancelSession();
      desk.emit(_bookTag(first));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(kiosk.stage, KioskStage.home);
      expect(desk.beeps, 2);

      // Retiré plus de 2,2 s + 1 s de réarmement : il ouvre une session et
      // bipe de nouveau.
      await Future<void>.delayed(const Duration(milliseconds: 3400));
      desk.emit(_bookTag(first));
      await _until(() => kiosk.items.length == 1);
      await _until(() => desk.beeps == 3);

      // Buzzer du lecteur muet : la tablette prend le relais.
      desk.buzzer = false;
      await kiosk.testBeep();
      expect(tablet.beeps, 1);
      await kiosk.configureFeedback(nextSource: 'off', nextRearmSeconds: 1);
      await kiosk.testBeep();
      expect(desk.beeps, 3);
      expect(tablet.beeps, 1);
    } finally {
      controller.dispose();
    }
  });

  test('consultation du catalogue au poste', () async {
    final database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 365)),
    );
    final shelved = await database.createBook({
      'title': 'Atlas du monde',
      'author': 'Collectif',
      'shelf': 'A-12',
    });
    final lent = await _taggedBook(database, 'Botanique', 'B010');
    final withdrawn = await database.createBook({
      'title': 'Chimie',
      'shelf': 'C-03',
    });
    await (await database.database).update(
      'books',
      {'status': 'indisponible'},
      where: 'id = ?',
      whereArgs: [withdrawn.id],
    );
    await database.borrowBook(
      lent.id,
      memberNumber: member.memberNumber,
      name: member.name,
      dueAt: DateTime.now().add(const Duration(days: 14)),
    );

    final all = await database.browseCatalog();
    expect(all.map((entry) => entry.book.title), [
      'Atlas du monde',
      'Botanique',
      'Chimie',
    ]);
    expect(all[0].available, isTrue);
    expect(all[1].onLoan, isTrue);
    expect(all[1].dueAt, isNotNull);
    expect(all[2].available, isFalse);
    expect(
      (await database.browseCatalog(availableOnly: true)).single.book.id,
      shelved.id,
    );
    expect(
      (await database.browseCatalog(search: 'a-12')).single.book.shelf,
      'A-12',
    );
    expect(await database.browseCatalog(search: 'introuvable'), isEmpty);

    // En consultation, poser sa carte ouvre l'emprunt.
    final desk = _FakeDeskReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      deskReader: desk,
    );
    final kiosk = controller.kiosk..transport = 'simulation';
    try {
      await kiosk.enter();
      kiosk.startBrowse();
      expect(kiosk.stage, KioskStage.browse);
      desk.emit(_cardTag(member));
      await _until(() => kiosk.subscriber != null);
      expect(kiosk.stage, KioskStage.borrow);
    } finally {
      controller.dispose();
    }
  });

  test('délais d’anti-rebond réglables et enregistrés', () async {
    final database = LibraryDatabase.instance;
    final member = await _subscriberWithCard(database, 'ab-1', 'A001');
    await database.renewSubscription(
      member.id,
      DateTime.now().add(const Duration(days: 365)),
    );
    final book = await _taggedBook(database, 'Premier', 'B001');
    final desk = _FakeDeskReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      deskReader: desk,
    );
    final kiosk = controller.kiosk..transport = 'simulation';
    try {
      expect(kiosk.presenceMs, KioskController.defaultPresenceMs);
      expect(kiosk.releaseMs, KioskController.defaultReleaseMs);
      await expectLater(
        kiosk.configureFeedback(
          nextSource: 'reader',
          nextRearmSeconds: 1,
          nextPresenceMs: 50,
        ),
        throwsRangeError,
      );
      await kiosk.configureFeedback(
        nextSource: 'reader',
        nextRearmSeconds: 1,
        nextPresenceMs: 200,
        nextReleaseMs: 0,
      );
      final settings = await SharedPreferences.getInstance();
      expect(settings.getInt('kiosk_presence_ms'), 200);
      expect(settings.getInt('kiosk_release_ms'), 0);

      // Avec 200 ms d'absence, un livre retiré puis reposé après 400 ms
      // ouvre une nouvelle session (au lieu d'attendre 2,2 s).
      await kiosk.enter();
      desk.emit(_bookTag(book));
      await _until(() => kiosk.items.length == 1);
      kiosk.cancelSession();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      desk.emit(_bookTag(book));
      await _until(() => kiosk.items.length == 1);
      expect(kiosk.stage, KioskStage.borrow);
    } finally {
      controller.dispose();
    }
  });

  test('le type d’appareil est mémorisé', () async {
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: _SilentReader(),
      deskReader: _FakeDeskReader(),
    );
    try {
      expect(controller.deviceRole, isNull);
      await controller.setDeviceRole('kiosk');
      final settings = await SharedPreferences.getInstance();
      expect(settings.getString('device_role'), 'kiosk');
      await controller.setDeviceRole(null);
      expect(settings.getString('device_role'), isNull);
      await expectLater(controller.setDeviceRole('autre'), throwsArgumentError);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('affiche le choix d’appareil, le poste et le terminal admin', (
    tester,
  ) async {
    await initializeDateFormatting('fr_FR');
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final desk = _FakeDeskReader();
    late LibraryController controller;
    late Subscriber member;
    late Book book;
    await tester.runAsync(() async {
      // Les lectures de tags s'abonnent hors de la zone d'horloge simulée.
      controller = LibraryController(
        database: LibraryDatabase.instance,
        reader: _SilentReader(),
        deskReader: desk,
      );
      controller.kiosk.transport = 'simulation';
      final database = LibraryDatabase.instance;
      member = await _subscriberWithCard(database, 'ab-1', 'A001');
      await database.renewSubscription(
        member.id,
        DateTime.now().add(const Duration(days: 30)),
      );
      book = await _taggedBook(database, 'Livre du poste', 'B001');
    });

    await tester.pumpWidget(
      MaterialApp(home: DeviceRoleScreen(controller: controller)),
    );
    expect(find.text('Poste d’emprunt'), findsOneWidget);
    expect(find.text('Lecteur mobile'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(home: KioskScreen(controller: controller, asHome: true)),
    );
    await tester.pump();
    expect(find.text('Bienvenue'), findsOneWidget);

    await tester.runAsync(() async {
      desk.emit(_cardTag(member));
      await _until(() => controller.kiosk.borrower != null);
      desk.emit(_bookTag(book));
      await _until(() => controller.kiosk.items.isNotEmpty);
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ab-1'), findsOneWidget);
    expect(find.text('Livre du poste'), findsOneWidget);
    expect(find.text('Emprunter 1 livre'), findsOneWidget);

    await tester.runAsync(controller.kiosk.confirmBorrow);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Emprunt enregistré'), findsOneWidget);
    controller.kiosk.finish();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminScreen(controller: controller)),
      ),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.text('Livre du poste').evaluate().isNotEmpty) break;
    }
    expect(find.text('Livre du poste'), findsOneWidget);
    await tester.tap(find.text('Poste'));
    await tester.pumpAndSettle();
    expect(find.text('Lecteur RFID de bureau'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => controller.dispose());
  });

  test('code du poste et règles de prêt', () async {
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: _SilentReader(),
      deskReader: _FakeDeskReader(),
    );
    final kiosk = controller.kiosk;
    try {
      await kiosk.initialize();
      expect(kiosk.usesDefaultPin, isTrue);
      expect(kiosk.verifyPin(KioskController.defaultPin), isTrue);
      await expectLater(
        kiosk.changePin(current: '0000', next: '5678'),
        throwsStateError,
      );
      await expectLater(
        kiosk.changePin(current: KioskController.defaultPin, next: '12'),
        throwsArgumentError,
      );
      await kiosk.changePin(current: KioskController.defaultPin, next: '5678');
      expect(kiosk.verifyPin('5678'), isTrue);
      expect(kiosk.usesDefaultPin, isFalse);

      await kiosk.configurePolicy(nextMaxLoans: 5, nextLoanDays: 21);
      await kiosk.initialize();
      expect(kiosk.maxLoans, 5);
      expect(kiosk.loanDays, 21);
      expect(kiosk.verifyPin('5678'), isTrue);
    } finally {
      controller.dispose();
    }
  });
}

Future<Subscriber> _subscriberWithCard(
  LibraryDatabase database,
  String number,
  String suffix,
) async {
  final subscriber = await database.saveSubscriber(
    memberNumber: number,
    name: number,
  );
  return database.markCardTagged(subscriber.id, 'E2801170200000000000$suffix');
}

Future<Book> _taggedBook(
  LibraryDatabase database,
  String title,
  String suffix,
) async {
  final book = await database.createBook({'title': title});
  return database.markTagged(book.id, 'E2806894000050CA4D00$suffix');
}

ReaderTag _cardTag(Subscriber subscriber) =>
    ReaderTag(epc: subscriber.cardEpc!, tid: subscriber.cardTid!, rssi: 60);

ReaderTag _bookTag(Book book) =>
    ReaderTag(epc: book.epc, tid: book.tid!, rssi: 60);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition non atteinte.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _SilentReader extends ReaderService {
  int beeps = 0;

  @override
  Future<void> playScanBeep() async => beeps++;
}

class _FakeDeskReader extends DeskReaderService {
  final StreamController<ReaderTag> _events = StreamController.broadcast();
  bool _connected = false;
  bool _reading = false;

  @override
  bool get connected => _connected;

  @override
  bool get reading => _reading;

  @override
  Stream<ReaderTag> get tags => _events.stream;

  /// Tags posés sur le lecteur, remontés au démarrage de la lecture.
  List<ReaderTag> placed = [];
  int beeps = 0;
  bool buzzer = true;

  @override
  Future<bool> beep() async {
    if (buzzer) beeps++;
    return buzzer;
  }
  final List<(String, String)> written = [];

  void emit(ReaderTag tag) => _events.add(tag);

  @override
  Future<Map<Object?, Object?>> connect({
    required String transport,
    required String endpoint,
  }) async {
    _connected = true;
    return {'connected': true};
  }

  @override
  Future<void> startInventory({int? power}) async {
    _reading = true;
    final tags = List.of(placed);
    Timer(const Duration(milliseconds: 20), () => tags.forEach(emit));
  }

  @override
  Future<Map<Object?, Object?>> writeEpc(String epc, String tid) async {
    _reading = false;
    written.add((epc, tid));
    return {'verified': true, 'epc': epc, 'tid': tid};
  }

  @override
  Future<void> stopInventory() async => _reading = false;

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}

  @override
  Future<void> dispose() => _events.close();
}
