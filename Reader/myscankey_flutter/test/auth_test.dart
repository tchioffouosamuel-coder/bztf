import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:myscankey_flutter/core/password.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/screens/login_screen.dart';
import 'package:myscankey_flutter/services/library_controller.dart';
import 'package:myscankey_flutter/services/reader_service.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Base distincte des autres fichiers de test, exécutés en parallèle.
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('bibliorfid_auth_')).path,
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

  String hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  test('PBKDF2-HMAC-SHA256 respecte les vecteurs de référence', () {
    expect(
      hex(pbkdf2Sha256('password'.codeUnits, 'salt'.codeUnits, 1, 32)),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
    expect(
      hex(pbkdf2Sha256('password'.codeUnits, 'salt'.codeUnits, 2, 32)),
      'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
    );
    expect(sameDigest('abcd', 'abcd'), isTrue);
    expect(sameDigest('abcd', 'abce'), isFalse);
  });

  test('comptes : règles, identification et désactivation', () async {
    final database = LibraryDatabase.instance;
    await expectLater(
      database.createUser(name: 'A', email: 'a@b.cm', password: 'long-enough'),
      throwsArgumentError,
    );
    await expectLater(
      database.createUser(
        name: 'Admin',
        email: 'pas-un-mail',
        password: 'x' * 8,
      ),
      throwsArgumentError,
    );
    await expectLater(
      database.createUser(name: 'Admin', email: 'a@b.cm', password: 'court'),
      throwsArgumentError,
    );
    // Le premier compte est administrateur même si un autre rôle est demandé.
    final admin = await database.createUser(
      name: 'Admin BCM',
      email: 'ADMIN@BCM.TEST',
      password: 'mot-de-passe-solide',
    );
    expect(admin.isAdmin, isTrue);
    expect(admin.email, 'admin@bcm.test');
    await expectLater(
      database.createUser(
        name: 'Doublon',
        email: 'admin@bcm.test',
        password: 'mot-de-passe-solide',
      ),
      throwsStateError,
    );
    final operator = await database.createUser(
      name: 'Opérateur',
      email: 'op@bcm.test',
      password: 'mot-de-passe-op',
    );
    expect(operator.isAdmin, isFalse);

    expect(
      await database.authenticateUser('admin@bcm.test', 'faux-mot'),
      isNull,
    );
    expect(
      (await database.authenticateUser(
        ' Admin@BCM.test ',
        'mot-de-passe-solide',
      ))?.id,
      admin.id,
    );
    final stored = await (await database.database).query('users');
    expect(
      stored.every((row) => row['password_hash'] != 'mot-de-passe-solide'),
      isTrue,
    );

    await database.changePassword(
      operator.id,
      current: 'mot-de-passe-op',
      next: 'nouveau-secret',
    );
    expect(
      await database.authenticateUser('op@bcm.test', 'mot-de-passe-op'),
      isNull,
    );
    expect(
      await database.authenticateUser('op@bcm.test', 'nouveau-secret'),
      isNotNull,
    );

    await database.setUserActive(operator.id, false);
    expect(
      await database.authenticateUser('op@bcm.test', 'nouveau-secret'),
      isNull,
    );
    await expectLater(
      database.setUserActive(admin.id, false),
      throwsStateError,
    );
  });

  test('ouverture : premier administrateur, connexion, verrouillage', () async {
    final controller = LibraryController(
      database: LibraryDatabase.instance,
      reader: _SilentReader(),
    );
    try {
      expect(controller.currentUser, isNull);
      await controller.createFirstAdmin(
        name: 'Admin BCM',
        email: 'admin@bcm.test',
        password: 'mot-de-passe-solide',
      );
      expect(controller.currentUser?.isAdmin, isTrue);
      expect(controller.hasAccounts, isTrue);
      await expectLater(
        controller.createFirstAdmin(
          name: 'Autre',
          email: 'autre@bcm.test',
          password: 'mot-de-passe-solide',
        ),
        throwsStateError,
      );

      await controller.signOut();
      expect(controller.currentUser, isNull);

      for (var attempt = 0; attempt < 5; attempt++) {
        await expectLater(
          controller.signIn('admin@bcm.test', 'mauvais'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('incorrect'),
            ),
          ),
        );
      }
      // Cinq échecs : même le bon mot de passe attend 30 s.
      await expectLater(
        controller.signIn('admin@bcm.test', 'mot-de-passe-solide'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Trop d’essais'),
          ),
        ),
      );
      expect(controller.currentUser, isNull);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('l’écran d’ouverture demande le compte administrateur', (
    tester,
  ) async {
    late LibraryController controller;
    await tester.runAsync(() async {
      controller = LibraryController(
        database: LibraryDatabase.instance,
        reader: _SilentReader(),
      );
    });
    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(controller: controller)),
    );
    expect(
      find.text('Créez le compte administrateur de cet appareil.'),
      findsOneWidget,
    );
    expect(find.text('Créer le compte'), findsOneWidget);

    controller.hasAccounts = true;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(key: UniqueKey(), controller: controller),
      ),
    );
    expect(
      find.text('Identifiez-vous pour ouvrir l’application.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Se connecter'));
    await tester.pump();
    expect(find.text('L’e-mail est obligatoire.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => controller.dispose());
  });
}

class _SilentReader extends ReaderService {
  @override
  Future<void> playScanBeep() async {}
}
