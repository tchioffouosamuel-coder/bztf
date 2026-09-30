import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/screens/locator_screen.dart';
import 'package:myscankey_flutter/services/heading_service.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/locator_direction.dart';
import 'package:myscankey_flutter/services/reader_service.dart';

void main() {
  test('le livre est dans la direction où le signal est le plus fort', () {
    var now = DateTime(2026, 9, 30, 10);
    final direction = LocatorDirection(clock: () => now);
    expect(direction.estimate, isNull);

    // Balayage d'un tour complet : signal fort vers l'est (≈ 90°).
    for (var bearing = 0; bearing < 360; bearing += 10) {
      now = now.add(const Duration(milliseconds: 100));
      final distance = ((bearing - 90).abs() % 360).clamp(0, 180);
      final strength = distance > 60 ? 0.0 : 1 - distance / 70;
      direction.updateHeading(bearing.toDouble(), signalLive: strength > 0);
      if (strength > 0) direction.addSample(strength);
    }
    final estimate = direction.estimate!;
    expect((estimate.bearing - 90).abs(), lessThan(12));
    expect(estimate.confidence, greaterThan(0.5));

    // Le terminal vise le nord : il faut tourner d'environ 90° à droite.
    direction.updateHeading(0, signalLive: false);
    expect(direction.turn!, closeTo(90, 12));
    direction.updateHeading(180, signalLive: false);
    expect(direction.turn!, closeTo(-90, 12));
    // Passage 359° -> 0° : pas de tour complet.
    direction.updateHeading(350, signalLive: false);
    expect(direction.turn!, closeTo(100, 12));
  });

  test(
    'les anciennes mesures s’estompent et une direction muette s’affaiblit',
    () {
      var now = DateTime(2026, 9, 30, 10);
      final direction = LocatorDirection(clock: () => now);
      direction.updateHeading(200, signalLive: true);
      direction.addSample(0.8);
      expect(direction.estimate!.bearing, closeTo(202.5, 8));

      // On vise la même direction sans plus lire le tag.
      for (var index = 0; index < 10; index++) {
        direction.updateHeading(200, signalLive: false);
      }
      expect(direction.sectors[13], lessThan(0.1));

      direction.addSample(0.8);
      now = now.add(const Duration(minutes: 1));
      expect(direction.estimate, isNull);

      direction.reset();
      expect(direction.sectors.every((value) => value == 0), isTrue);
    },
  );

  testWidgets('radar : direction du livre et consigne à suivre', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(540, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reader = _FakeReader();
    final heading = _FakeHeading();
    late LibraryController controller;
    late Book book;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.setDatabasesPath(
        (await Directory.systemTemp.createTemp('bibliorfid_locator_')).path,
      );
      SharedPreferences.setMockInitialValues({});
      await LibraryDatabase.instance.close();
      await databaseFactory.deleteDatabase(
        path.join(await getDatabasesPath(), 'biblio_rfid.db'),
      );
      final database = LibraryDatabase.instance;
      final created = await database.createBook({'title': 'Livre cherché'});
      book = await database.markTagged(created.id, 'E2806894000050CA4D00AB01');
      controller = LibraryController(
        database: database,
        reader: reader,
        heading: heading,
      );
      controller.transport = 'tcp';
      await controller.locateBook(book);
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            // Comme dans l'application : l'écran suit le contrôleur.
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  LocatorScreen(controller: controller, onChooseBook: () {}),
            ),
          ),
        ),
      ),
    );

    // Balayage : signal fort vers 60°, rien ailleurs.
    await tester.runAsync(() async {
      for (var bearing = 0; bearing < 360; bearing += 15) {
        heading.controller.add(bearing.toDouble());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final offset = (bearing - 60).abs();
        if (offset <= 30) {
          reader.emit(
            ReaderTag(epc: book.epc, tid: book.tid!, rssi: -35 - offset),
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      heading.controller.add(0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 200));
    final estimate = controller.locatorDirection.estimate!;
    expect((estimate.bearing - 60).abs(), lessThan(15));
    expect(find.textContaining('à droite'), findsOneWidget);
    expect(find.textContaining('%'), findsWidgets);
    expect(controller.locatorSignal.strength, greaterThan(0));

    final shots = Platform.environment['LOCATOR_SHOTS'];
    if (shots != null) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          path.join(shots, 'locator.png'),
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await LibraryDatabase.instance.close();
    });
  });
}

class _FakeReader extends ReaderService {
  final StreamController<ReaderTag> _events = StreamController.broadcast();
  bool _reading = false;

  @override
  bool get connected => true;

  @override
  bool get reading => _reading;

  @override
  Stream<ReaderTag> get tags => _events.stream;

  @override
  Stream<String> get nativeRfidKeyEvents => const Stream.empty();

  @override
  Future<void> startInventory({int? power, String? targetEpc}) async =>
      _reading = true;

  @override
  Future<void> stopInventory() async => _reading = false;

  @override
  Future<void> playScanBeep() async {}

  void emit(ReaderTag tag) => _events.add(tag);
}

class _FakeHeading extends HeadingService {
  final StreamController<double> controller = StreamController.broadcast();

  @override
  Stream<double> get headings => controller.stream;
}
