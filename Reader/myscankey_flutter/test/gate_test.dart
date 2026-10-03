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
import 'package:myscankey_flutter/models/staff.dart';
import 'package:myscankey_flutter/screens/admin_screen.dart';
import 'package:myscankey_flutter/screens/device_role_screen.dart';
import 'package:myscankey_flutter/screens/gate_screen.dart';
import 'package:myscankey_flutter/services/gate_direction.dart';
import 'package:myscankey_flutter/services/gate_reader_service.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/reader_service.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('bibliorfid_gate_')).path,
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

  test('badges du personnel : format distinct des livres et des cartes', () {
    final badge = generateBadgeEpc();
    expect(isBadgeEpc(badge), isTrue);
    expect(isCardEpc(badge), isFalse);
    expect(isValidEpc(badge), isFalse);
    expect(isBadgeEpc(generateCardEpc()), isFalse);
    expect(badge, startsWith('42434D03'));
  });

  test('normalise les adresses du portail N01', () {
    expect(
      GateReaderService.normalizeEndpoint('tcp', '192.168.0.101:8080'),
      '192.168.0.101',
    );
    expect(
      GateReaderService.normalizeEndpoint('serial', '/dev/ttyS5'),
      'dev/ttyS5',
    );
    expect(GateReaderService.normalizeEndpoint('serial', 'ttyS3'), 'dev/ttyS3');
    expect(
      () => GateReaderService.normalizeEndpoint('tcp', ''),
      throwsArgumentError,
    );
  });

  test('sens de passage déduit de l’ordre des barrières', () {
    final start = DateTime(2026, 9, 30, 8);
    final tracker = GateDirectionTracker(outsideSensor: 1, insideSensor: 2)
      ..setIdleLevels({1: 0, 2: 0});
    // Extérieur puis intérieur : entrée.
    expect(tracker.onLevel(1, 1, start), isNull);
    expect(
      tracker.onLevel(2, 1, start.add(const Duration(milliseconds: 600))),
      PassageDirection.entry,
    );
    tracker
      ..onLevel(1, 0, start.add(const Duration(seconds: 1)))
      ..onLevel(2, 0, start.add(const Duration(seconds: 1)));
    // Intérieur puis extérieur : sortie.
    expect(
      tracker.onLevel(2, 1, start.add(const Duration(seconds: 5))),
      isNull,
    );
    expect(
      tracker.onLevel(1, 1, start.add(const Duration(seconds: 6))),
      PassageDirection.exit,
    );
    tracker
      ..onLevel(1, 0, start.add(const Duration(seconds: 7)))
      ..onLevel(2, 0, start.add(const Duration(seconds: 7)));
    // Deux coupures trop espacées : pas de passage.
    expect(
      tracker.onLevel(1, 1, start.add(const Duration(seconds: 10))),
      isNull,
    );
    expect(
      tracker.onLevel(2, 1, start.add(const Duration(seconds: 20))),
      isNull,
    );

    // Barrières actives au niveau bas : le niveau au repos est relevé.
    final inverted = GateDirectionTracker(outsideSensor: 2, insideSensor: 1)
      ..setIdleLevels({1: 1, 2: 1});
    expect(inverted.onLevel(2, 0, start), isNull);
    expect(inverted.isActive(2), isTrue);
    expect(inverted.onLevel(1, 0, start), PassageDirection.entry);
  });

  test(
    'alarme pour un livre non emprunté, silence pour un livre emprunté',
    () async {
      final database = LibraryDatabase.instance;
      final free = await _taggedBook(database, 'Livre libre', 'B001');
      final borrowed = await _taggedBook(database, 'Livre prêté', 'B002');
      await database.borrowBook(
        borrowed.id,
        memberNumber: 'AB-1',
        name: 'Abonné',
        dueAt: DateTime.now().add(const Duration(days: 14)),
        subscriptionEndsAt: DateTime.now().add(const Duration(days: 300)),
      );
      final reader = _FakeGateReader();
      final controller = LibraryController(
        database: database,
        reader: _SilentReader(),
        gateReader: reader,
      );
      final gate = controller.gate..transport = 'simulation';
      try {
        await gate.enter();
        expect(reader.reading, isTrue);

        reader.simulateTag(_tag(borrowed.epc, borrowed.tid!));
        await _until(() => gate.events.isNotEmpty);
        expect(gate.alarm, isNull);
        expect(reader.alarms, 0);

        reader.simulateTag(_tag(free.epc, free.tid!));
        await _until(() => gate.today.alarms == 1);
        expect(gate.alarm?.book?.id, free.id);
        expect(reader.alarms, 1);
        expect(reader.lights, 1);

        // Le livre reste dans le champ : pas de nouvelle alarme.
        reader.simulateTag(_tag(free.epc, free.tid!));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(reader.alarms, 1);

        // Une carte d'abonné ne déclenche rien.
        reader.simulateTag(_tag(generateCardEpc(), 'E28000000000CARD'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(reader.alarms, 1);

        final activity = await database.activity(limit: 5);
        expect(activity.first.message, contains('Livre libre'));
        final outbox = await database.pendingMutations();
        expect(outbox.map((row) => row['entity_type']), contains('gate_day'));
      } finally {
        await gate.leave();
        controller.dispose();
      }
    },
  );

  test('entrées, sorties et passages du personnel', () async {
    final database = LibraryDatabase.instance;
    final badgeEpc = generateBadgeEpc();
    final now = DateTime.now().toUtc().toIso8601String();
    await database.applyRemoteChanges([
      {
        'entityType': 'staff',
        'operation': 'upsert',
        'entityId': 'staff-1',
        'staff': {
          'serverId': 'staff-1',
          'staffNumber': 'p-01',
          'name': 'Alice',
          'position': 'Bibliothécaire',
          'badgeEpc': badgeEpc,
          'badgeTid': 'E2800000BADGE0001',
          'createdAt': now,
          'updatedAt': now,
        },
      },
    ], 1);
    // Un badge n'est ni un livre ni une carte.
    final book = await database.createBook({'title': 'Livre'});
    expect(
      () => database.markTagged(book.id, 'E2800000BADGE0001'),
      throwsStateError,
    );

    final reader = _FakeGateReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      gateReader: reader,
    );
    final gate = controller.gate..transport = 'simulation';
    try {
      await gate.enter();
      gate.simulatePassage(PassageDirection.entry);
      gate.simulatePassage(PassageDirection.entry);
      gate.simulatePassage(PassageDirection.exit);
      await _until(() => gate.today.entries == 2 && gate.today.exits == 1);
      expect(gate.today.inside, 1);

      // Badge lu juste après une entrée mesurée : passage en entrée.
      gate.simulatePassage(PassageDirection.entry);
      await _until(() => gate.today.entries == 3);
      reader.simulateTag(_tag(badgeEpc, 'E2800000BADGE0001'));
      await _until(() => gate.staffToday.length == 1);
      expect(gate.staffToday.single.direction, PassageDirection.entry);
      expect(gate.staffToday.single.staffName, 'Alice');
      expect(gate.staffInside.single.staffServerId, 'staff-1');
      expect(reader.alarms, 0);

      final outbox = await database.pendingMutations();
      expect(
        outbox.map((row) => row['entity_type']),
        contains('staff_passage'),
      );
      await database.acknowledgeMutations([
        for (final row in outbox) row['mutation_id'] as String,
      ]);
      expect(await database.pendingMutationCount(), 0);
    } finally {
      await gate.leave();
      controller.dispose();
    }
  });

  test('le TID d’un badge absent de la lecture est relu', () async {
    final database = LibraryDatabase.instance;
    final badgeEpc = generateBadgeEpc();
    final now = DateTime.now().toUtc().toIso8601String();
    await database.applyRemoteChanges([
      {
        'entityType': 'staff',
        'operation': 'upsert',
        'entityId': 'staff-3',
        'staff': {
          'serverId': 'staff-3',
          'staffNumber': 'P-03',
          'name': 'Chloé',
          'badgeEpc': badgeEpc,
          'badgeTid': 'E2800000BADGE0003',
          'createdAt': now,
          'updatedAt': now,
        },
      },
    ], 1);
    final reader = _FakeGateReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      gateReader: reader,
    );
    final gate = controller.gate..transport = 'simulation';
    try {
      await gate.configureSensors(nextOutside: 0, nextInside: 0);
      await gate.enter();
      // Lu sans TID : relu à la demande, puis le passage est enregistré.
      reader.tids[badgeEpc] = 'E2800000BADGE0003';
      reader.simulateTag(_tag(badgeEpc, ''));
      await _until(() => gate.staffToday.length == 1);
      expect(gate.staffToday.single.staffName, 'Chloé');
      expect(reader.tidReads, [badgeEpc]);

      // Badge qui ne répond pas : une seule relecture par intervalle.
      final silent = generateBadgeEpc();
      reader.simulateTag(_tag(silent, ''));
      await _until(() => reader.tidReads.length == 2);
      reader.simulateTag(_tag(silent, ''));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reader.tidReads, [badgeEpc, silent]);
    } finally {
      await gate.leave();
      controller.dispose();
    }
  });

  test('sans barrières, les passages du personnel alternent', () async {
    final database = LibraryDatabase.instance;
    final badgeEpc = generateBadgeEpc();
    final now = DateTime.now().toUtc().toIso8601String();
    await database.applyRemoteChanges([
      {
        'entityType': 'staff',
        'operation': 'upsert',
        'entityId': 'staff-2',
        'staff': {
          'serverId': 'staff-2',
          'staffNumber': 'P-02',
          'name': 'Bruno',
          'badgeEpc': badgeEpc,
          'badgeTid': 'E2800000BADGE0002',
          'createdAt': now,
          'updatedAt': now,
        },
      },
    ], 1);
    final staff = (await database.listStaff()).single;
    // Premier passage du jour enregistré par un autre portail : entrée.
    await database.recordStaffPassage(
      staff: staff,
      direction: PassageDirection.entry,
      at: DateTime.now().subtract(const Duration(hours: 2)),
      gateId: 'autre',
      gateName: 'Autre portail',
    );
    final reader = _FakeGateReader();
    final controller = LibraryController(
      database: database,
      reader: _SilentReader(),
      gateReader: reader,
    );
    final gate = controller.gate..transport = 'simulation';
    await gate.configureSensors(nextOutside: 0, nextInside: 0);
    try {
      await gate.enter();
      reader.simulateTag(_tag(badgeEpc, 'E2800000BADGE0002'));
      await _until(() => gate.staffToday.length == 2);
      expect(gate.staffToday.first.direction, PassageDirection.exit);
      expect(gate.staffInside, isEmpty);
    } finally {
      await gate.leave();
      controller.dispose();
    }
  });

  testWidgets('écran du portail : compteurs, alarme et réglages', (
    tester,
  ) async {
    await initializeDateFormatting('fr_FR');
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reader = _FakeGateReader();
    late LibraryController controller;
    late Book book;
    await tester.runAsync(() async {
      controller = LibraryController(
        database: LibraryDatabase.instance,
        reader: _SilentReader(),
        gateReader: reader,
      );
      controller.gate.transport = 'simulation';
      controller.deviceRole = 'gate';
      book = await _taggedBook(LibraryDatabase.instance, 'Livre volé', 'B009');
    });

    await tester.pumpWidget(
      MaterialApp(home: DeviceRoleScreen(controller: controller)),
    );
    expect(find.text('Portail antivol'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(home: GateScreen(controller: controller, asHome: true)),
    );
    // enter() démarre dans initState, sous l'horloge simulée : on alterne
    // images et attentes réelles pour laisser la base répondre.
    for (var i = 0; i < 200 && !reader.reading; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(reader.reading, isTrue);
    expect(find.text('Entrées aujourd’hui'), findsOneWidget);
    expect(find.text('Surveillance active'), findsOneWidget);

    await tester.runAsync(() async {
      controller.gate.simulatePassage(PassageDirection.entry);
      await _until(() => controller.gate.today.entries == 1);
      reader.simulateTag(_tag(book.epc, book.tid!));
      await _until(() => controller.gate.today.alarms == 1);
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('Attention ! Ne sortez pas avec un livre non emprunté.'),
      findsOneWidget,
    );
    expect(find.text('Livre volé'), findsWidgets);
    controller.gate.dismissAlarm();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Surveillance active'), findsOneWidget);
    expect(find.text('Livre volé'), findsOneWidget); // fil d'activité

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminScreen(controller: controller, insideKiosk: true),
        ),
      ),
    );
    await tester.tap(find.text('Poste'));
    await tester.pumpAndSettle();
    expect(find.text('Portail antivol N01'), findsOneWidget);
    for (final label in [
      'Barrières infrarouges (entrées / sorties)',
      'Alarme antivol',
      'Tester l’alarme',
    ]) {
      expect(find.text(label, skipOffstage: false), findsOneWidget);
    }
    // Laisse l'onglet des emprunts finir sa requête avant la fermeture.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await controller.gate.leave();
      controller.dispose();
    });
  });

  test(
    'buzzer : coupé par défaut, réglable, jamais via la sortie du voyant',
    () async {
      final reader = _FakeGateReader();
      final controller = LibraryController(
        database: LibraryDatabase.instance,
        reader: _SilentReader(),
        gateReader: reader,
      );
      final gate = controller.gate..transport = 'simulation';
      try {
        await gate.initialize();
        expect(gate.buzzerEnabled, isFalse);
        await gate.testAlarm();
        expect(reader.outputs, [1]); // voyant seul

        await gate.configureBuzzer(
          nextEnabled: true,
          nextGpo: 3,
          nextSeconds: 2,
        );
        reader.outputs.clear();
        await gate.testAlarm();
        expect(reader.outputs, [1, 3]);

        // Buzzer câblé sur la sortie du voyant et désactivé : rien n'est actionné.
        await gate.configureBuzzer(
          nextEnabled: false,
          nextGpo: 1,
          nextSeconds: 2,
        );
        reader.outputs.clear();
        await gate.testAlarm();
        expect(reader.outputs, isEmpty);

        // Réglages conservés.
        final reloaded = LibraryController(
          database: LibraryDatabase.instance,
          reader: _SilentReader(),
          gateReader: _FakeGateReader(),
        );
        await reloaded.gate.initialize();
        expect(reloaded.gate.buzzerGpo, 1);
        expect(reloaded.gate.buzzerEnabled, isFalse);
        reloaded.dispose();
      } finally {
        controller.dispose();
      }
    },
  );
}

Future<Book> _taggedBook(
  LibraryDatabase database,
  String title,
  String suffix,
) async {
  final book = await database.createBook({'title': title});
  return database.markTagged(book.id, 'E2806894000050CA4D00$suffix');
}

ReaderTag _tag(String epc, String tid) =>
    ReaderTag(epc: epc, tid: tid, rssi: 60);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition non atteinte.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _SilentReader extends ReaderService {
  @override
  Future<void> playScanBeep() async {}
}

/// Portail simulé sans canal natif : compte les alarmes et le voyant.
class _FakeGateReader extends GateReaderService {
  int alarms = 0;
  int lights = 0;

  /// Sorties actionnées (voyant, buzzer), dans l'ordre.
  final List<int> outputs = [];

  @override
  Future<Duration> playAlarm(double volume) async {
    alarms++;
    return const Duration(seconds: 1);
  }

  @override
  Future<void> stopAlarm() async {}

  @override
  Future<bool> pulseGpo(int gpo, Duration duration) async {
    lights++;
    outputs.add(gpo);
    return true;
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}

  /// TID renvoyés par la relecture ciblée, par EPC.
  final Map<String, String> tids = {};
  final List<String> tidReads = [];

  @override
  Future<String> readTid(String epc) async {
    tidReads.add(epc);
    return tids[epc] ?? '';
  }
}
