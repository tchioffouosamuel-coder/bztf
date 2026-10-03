import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/services/desk_reader_service.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/reader_service.dart';
import 'package:myscankey_flutter/widgets/pin_dialog.dart';

void main() {
  testWidgets('le code administrateur tient au-dessus du clavier', (
    tester,
  ) async {
    // Tablette 1280 × 800 en paysage, clavier numérique ouvert.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 36, bottom: 72);
    tester.view.viewInsets = const FakeViewPadding(bottom: 455);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: ReaderService(),
      deskReader: DeskReaderService(),
    );
    await tester.pumpWidget(
      MaterialApp(
        // Champs encadrés et remplis, comme dans le thème de l'application.
        theme: ThemeData(
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
            border: OutlineInputBorder(),
          ),
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => requestAdminPin(context, controller.kiosk),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    expect(find.text('Accès administrateur'), findsOneWidget);
    expect(find.text('Valider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
