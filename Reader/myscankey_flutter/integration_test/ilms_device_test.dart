import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:myscankey_flutter/data/ilms_circulation_journal.dart';
import 'package:myscankey_flutter/screens/ilms_app.dart';
import 'package:myscankey_flutter/services/ilms_auth_service.dart';
import 'package:myscankey_flutter/services/ilms_circulation_client.dart';
import 'package:myscankey_flutter/services/ilms_circulation_sync.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

http.Response reply(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android locale metadata does not authorize adopting a legacy catalogue',
    (tester) async {
      final file = path.join(
        await getDatabasesPath(),
        'ilms_recipe_${newIlmsCirculationId()}.db',
      );
      var database = await openDatabase(file, singleInstance: false);
      try {
        await database.execute(
          'CREATE TABLE legacy_books(id INTEGER PRIMARY KEY, title TEXT)',
        );
        await database.insert('legacy_books', {
          'id': 1,
          'title': 'Fictitious legacy book',
        });
        final mode = await database.rawQuery('PRAGMA journal_mode');
        await database.close();
        await expectLater(
          IlmsCirculationJournal.open(filePath: file),
          throwsA(isA<IlmsClientException>()),
        );
        database = await openDatabase(file, singleInstance: false);
        expect(await database.query('legacy_books'), [
          {'id': 1, 'title': 'Fictitious legacy book'},
        ]);
        expect(
          (await database.rawQuery(
            'PRAGMA application_id',
          )).single['application_id'],
          0,
        );
        expect(
          (await database.rawQuery(
            'PRAGMA user_version',
          )).single['user_version'],
          0,
        );
        expect(await database.rawQuery('PRAGMA journal_mode'), mode);
      } finally {
        await database.close();
        expect(path.basename(file).startsWith('ilms_recipe_'), isTrue);
        await deleteDatabase(file);
      }
    },
  );

  testWidgets(
    'Android native SQLite retains an intent and only retries explicitly',
    (tester) async {
      final file = path.join(
        await getDatabasesPath(),
        'ilms_recipe_${newIlmsCirculationId()}.db',
      );
      final session = IlmsSession(
        gatewayUrl: 'https://ilms.test',
        accountId: newIlmsCirculationId(),
        libraryId: newIlmsCirculationId(),
        accessToken: 'fake-test-token',
      );
      final member = newIlmsCirculationId();
      final copy = newIlmsCirculationId();
      final loan = {
        'id': newIlmsCirculationId(),
        'library_id': session.libraryId,
        'member_id': member,
        'copy_id': copy,
        'document_id': newIlmsCirculationId(),
        'number': 'RECETTE-ANDROID',
        'status': 1,
      };
      final payload = {
        'operation_id': newIlmsCirculationId(),
        'card': {'epc': 'AA12'},
        'copy': {'tid': 'BB34'},
        'preferred_return_date': DateTime.now()
            .toUtc()
            .add(const Duration(days: 14))
            .toIso8601String(),
        'expected_card_id': newIlmsCirculationId(),
        'expected_member_id': member,
        'expected_copy_id': copy,
      };
      var journal = await IlmsCirculationJournal.open(filePath: file);
      var status = 503;
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        expect(
          request.url.path,
          '/library-service/api/v1/libraries/${session.libraryId}/circulation/rfid/checkouts',
        );
        requests.add(request);
        final rows = await journal.list(normalizeIlmsScope(session));
        expect(rows.single['attempts'], requests.length);
        expect(
          (rows.single['payload'] as Map)['operation_id'],
          payload['operation_id'],
        );
        return reply(status == 201 ? loan : {}, status);
      });
      var sync = IlmsCirculationSync(
        journal: journal,
        getSession: () => session,
        client: client,
      );
      try {
        await expectLater(
          sync.checkout(payload),
          throwsA(isA<IlmsClientException>()),
        );
        expect(requests.length, 1);
        sync.close();
        await journal.close();
        journal = await IlmsCirculationJournal.open(filePath: file);
        sync = IlmsCirculationSync(
          journal: journal,
          getSession: () => session,
          client: client,
        );
        final entries = await sync.list();
        expect(entries.length, 1);
        expect(entries.single['id'], payload['operation_id']);
        expect(entries.single['last_status'], 503);
        expect(requests.length, 1);
        status = 201;
        final accepted = await sync.retry(entries.single['id'] as String);
        expect(accepted['id'], loan['id']);
        expect(requests.last.body, requests.first.body);
        expect(await sync.list(), isEmpty);
      } finally {
        sync.close();
        await journal.close();
        client.close();
        expect(path.basename(file).startsWith('ilms_recipe_'), isTrue);
        await deleteDatabase(file);
      }
    },
  );

  testWidgets(
    'Android native entry renders login then station without automatic business calls',
    (tester) async {
      final file = path.join(
        await getDatabasesPath(),
        'ilms_recipe_${newIlmsCirculationId()}.db',
      );
      final account = newIlmsCirculationId();
      final library = newIlmsCirculationId();
      final token =
          'header.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.signature';
      final authClient = MockClient((request) async {
        if (request.url.path == '/auth-service/oauth/token') {
          return reply({
            'access_token': 'test-bootstrap',
            'token_type': 'bearer',
            'expires_in': 60,
          });
        }
        if (request.url.path == '/auth-service/api/v1/auth/login') {
          return reply({
            'user': {'id': account},
            'access_token': {'type': 'Bearer', 'token': token},
          });
        }
        if (request.url.path != '/library-service/api/v1/libraries') {
          return reply({}, 404);
        }
        return reply([
          {'id': library, 'name': 'Bibliotheque de recette Android'},
        ]);
      });
      final auth = IlmsAuthService(client: authClient);
      var calls = 0;
      final businessClient = MockClient((_) async {
        calls++;
        return reply({});
      });
      try {
        await tester.pumpWidget(
          IlmsApp(
            auth: auth,
            openJournal: () => IlmsCirculationJournal.open(filePath: file),
            circulationClient: businessClient,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Connexion ILMS'), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(calls, 0);
        await auth.signIn(
          gatewayUrl: 'https://ilms.test',
          username: 'operator-test',
          password: 'test-only',
          clientId: 'test-only',
          clientSecret: 'test-only',
        );
        await tester.pumpAndSettle();
        expect(find.text('Circulation RFID'), findsOneWidget);
        expect(find.text('Aucune demande en attente.'), findsOneWidget);
        expect(calls, 0);
        auth.logout();
        await tester.pumpAndSettle();
        expect(find.text('Connexion ILMS'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        auth.dispose();
        authClient.close();
        businessClient.close();
        expect(path.basename(file).startsWith('ilms_recipe_'), isTrue);
        await deleteDatabase(file);
      }
    },
  );
}
