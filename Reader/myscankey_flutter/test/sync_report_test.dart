import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/services/sync_service.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Base distincte des autres fichiers de test, exécutés en parallèle.
    await databaseFactory.setDatabasesPath(
      (await Directory.systemTemp.createTemp('bibliorfid_report_')).path,
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

  /// Serveur simulé : synchronisation vide, rapports enregistrés.
  MockClient server(
    List<Map<String, Object?>> reports, {
    bool reports404 = false,
  }) => MockClient((request) async {
    final route = request.url.path;
    if (route == '/api/v1/sync') {
      return http.Response(
        jsonEncode({'cursor': 0, 'changes': [], 'hasMore': false}),
        200,
      );
    }
    if (route == '/api/v1/sync/push') {
      final body = jsonDecode(request.body) as Map;
      return http.Response(
        jsonEncode({
          'acknowledgedMutationIds': [
            for (final mutation in body['mutations'] as List)
              (mutation as Map)['mutationId'],
          ],
          'cursor': 0,
        }),
        200,
      );
    }
    if (route.endsWith('/report')) {
      if (reports404) {
        return http.Response(jsonEncode({'error': 'Route inconnue'}), 404);
      }
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      reports.add({...body, 'route': route});
      final ids = [
        for (final entry in body['activity'] as List)
          (entry as Map)['localId'] as int,
      ];
      return http.Response(
        jsonEncode({
          'usersStored': (body['users'] as List?)?.length ?? 0,
          'activityAcknowledgedUntil': ids.isEmpty
              ? null
              : ids.reduce((a, b) => a > b ? a : b),
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'registered': true}), 200);
  });

  test(
    'le rapport envoie les comptes sans mot de passe et l’activité nouvelle',
    () async {
      final database = LibraryDatabase.instance;
      await database.createUser(
        name: 'Admin',
        email: 'Admin@BZTF.org',
        password: 'mot-de-passe-solide',
      );
      final book = await database.createBook({'title': 'Livre rapporté'});
      await database.addActivity(
        'lecture',
        'succes',
        'Tag lu',
        bookId: book.id,
        tid: 'E280TID',
      );
      final reports = <Map<String, Object?>>[];
      final sync = SyncService(database, client: server(reports));
      try {
        await sync.initialize();
        await sync.configure(
          nextServerUrl: 'https://api.test',
          nextApiKey: 'secret',
          nextDeviceName: 'Borne',
        );
        expect(sync.connected, isTrue);
        expect(sync.reportError, isNull);

        final first = reports.first;
        expect(first['route'], '/api/v1/devices/${sync.deviceId}/report');
        expect(first['platform'], 'android');
        expect(first['name'], 'Borne');
        final users = (first['users'] as List).cast<Map>();
        expect(users.single['email'], 'admin@bztf.org');
        expect(users.single['role'], 'admin');
        expect(
          jsonEncode(first),
          isNot(matches(RegExp('password|salt|hash', caseSensitive: false))),
        );
        final read = (first['activity'] as List).cast<Map>().firstWhere(
          (entry) => entry['type'] == 'lecture',
        );
        expect(read['bookServerId'], book.serverId);
        expect(read['tid'], 'E280TID');

        // Seule l'activité nouvelle part au rapport suivant.
        await database.addActivity('connexion', 'succes', 'Lecteur connecté');
        await sync.syncNow();
        final last = (reports.last['activity'] as List).cast<Map>();
        expect(last.map((entry) => entry['type']), ['connexion']);
      } finally {
        sync.dispose();
      }
    },
  );

  test(
    'un serveur sans rapport d’appareil ne bloque pas la synchronisation',
    () async {
      final sync = SyncService(
        LibraryDatabase.instance,
        client: server([], reports404: true),
      );
      try {
        await sync.initialize();
        await sync.configure(
          nextServerUrl: 'https://api.test',
          nextApiKey: 'secret',
          nextDeviceName: 'Borne',
        );
        expect(sync.connected, isTrue);
        expect(sync.error, isNull);
        expect(sync.reportError, 'Route inconnue');
      } finally {
        sync.dispose();
      }
    },
  );
}
