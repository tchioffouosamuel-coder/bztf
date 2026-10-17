import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myscankey_flutter/data/ilms_circulation_journal.dart';
import 'package:myscankey_flutter/screens/ilms_app.dart';
import 'package:myscankey_flutter/screens/ilms_circulation_screen.dart';
import 'package:myscankey_flutter/services/ilms_auth_service.dart';
import 'package:myscankey_flutter/services/ilms_circulation_client.dart';
import 'package:myscankey_flutter/services/ilms_circulation_sync.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> settleIo(WidgetTester tester) async {
  for (var index = 0; index < 10; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

http.Response reply(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../BiblioRFID/tests/fixtures/ilms-circulation-contract.json',
            ).readAsStringSync(),
          )
          as Map;
  final scope = (fixture['scope'] as Map).cast<String, String>();
  final loan = (fixture['loan'] as Map).cast<String, Object?>();
  final operation =
      (((fixture['operations'] as List).first as Map)['normalized'] as Map)
          .cast<String, Object?>();
  final checkout = operation['payload'] as Map;
  final token =
      'header.${base64Url.encode(utf8.encode(jsonEncode({'exp': 4102444800}))).replaceAll('=', '')}.signature';
  final session = IlmsSession(
    gatewayUrl: scope['gatewayUrl']!,
    accountId: scope['accountId']!,
    libraryId: scope['libraryId']!,
    accessToken: token,
  );
  final member = {
    'member_id': checkout['expected_member_id'],
    'card_id': checkout['expected_card_id'],
    'name': 'Adherent de recette',
    'number': 'M-42',
    'status': 1,
    'eligible': true,
  };
  final copy = {
    'copy': {
      'id': checkout['expected_copy_id'],
      'document_id': loan['document_id'],
      'number': 'EX-42',
    },
    'title': 'Catalogue de la bibliotheque ZTF',
    'available_for_checkout': true,
    'active_loan': null,
  };

  late Directory directory;
  late String file;
  late IlmsCirculationJournal journal;
  late List<IlmsCirculationSync> services;
  setUpAll(() async {
    sqfliteFfiInit();
    final textFont = FontLoader('Montserrat')
      ..addFont(rootBundle.load('assets/fonts/Montserrat-Variable.ttf'));
    await textFont.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ilms-mobile-ui-');
    file = path.join(directory.path, 'native.db');
    journal = await IlmsCirculationJournal.open(
      filePath: file,
      factory: databaseFactoryFfi,
    );
    services = [];
  });
  tearDown(() async {
    for (final service in services) {
      service.close();
    }
    await journal.close();
    expect(
      path.dirname(path.absolute(directory.path)),
      path.absolute(Directory.systemTemp.path),
    );
    expect(path.basename(directory.path).startsWith('ilms-mobile-ui-'), isTrue);
    await directory.delete(recursive: true);
  });

  IlmsCirculationSync sync(http.Client client) {
    final service = IlmsCirculationSync(
      journal: journal,
      getSession: () => session,
      client: client,
    );
    services.add(service);
    return service;
  }

  Future<void> showStation(
    WidgetTester tester,
    IlmsCirculationSync service,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ilmsTheme(),
        home: Scaffold(body: IlmsCirculationScreen(sync: service)),
      ),
    );
    await settleIo(tester);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settleIo(tester);
  }

  Future<void> resolve(WidgetTester tester, {required bool card}) async {
    for (final entry in (checkout[card ? 'card' : 'copy'] as Map).entries) {
      await tester.enterText(
        find.byKey(ValueKey('${card ? 'card' : 'copy'}-${entry.key}')),
        entry.value as String,
      );
    }
    await tap(
      tester,
      find.byTooltip(card ? 'Rechercher la carte' : "Rechercher l'exemplaire"),
    );
  }

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets(
      'login layout and native entry have no background HTTP at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var calls = 0;
        var opens = 0;
        final auth = IlmsAuthService(
          client: MockClient((_) async {
            calls++;
            return reply({});
          }),
        );
        addTearDown(auth.dispose);
        await tester.pumpWidget(
          IlmsApp(
            auth: auth,
            openJournal: () async {
              opens++;
              return journal;
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('BIBLIORFID'), findsOneWidget);
        expect(find.text('Connexion ILMS'), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(calls, 0);
        expect(opens, 0);
        if (width == 390) {
          final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
            find.byType(RepaintBoundary),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '../../../ilms-migration/.tools/rfid-mobile-ilms-login.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('login redirect diagnostic wraps safely at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      var opens = 0;
      final auth = IlmsAuthService(
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response(
            'private-error-body',
            302,
            headers: {'location': '/auth-service/login?token=private-token'},
          );
        }),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        IlmsApp(
          auth: auth,
          openJournal: () async {
            opens++;
            return journal;
          },
        ),
      );
      for (final entry in {
        'Identifiant ILMS': 'test-user',
        'Mot de passe': 'test-password',
      }.entries) {
        await tester.enterText(
          find.widgetWithText(TextFormField, entry.key),
          entry.value,
        );
      }
      await tap(tester, find.text('Se connecter'));
      const diagnostic =
          'OAuth application : redirection HTTP 302 bloquee (page de connexion du gateway).';
      expect(find.text(diagnostic), findsOneWidget);
      expect(find.textContaining('private-'), findsNothing);
      expect(calls, 1);
      expect(opens, 0);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Mot de passe'),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.ensureVisible(find.text(diagnostic));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the deployment gateway and OAuth client are not configurable', (
    tester,
  ) async {
    final clients = <String>[];
    final origins = <String>{};
    final auth = IlmsAuthService(
      client: MockClient((request) async {
        origins.add(request.url.origin);
        if (request.url.path.endsWith('/oauth/token')) {
          final header = request.headers['authorization']!;
          clients.add(
            utf8.decode(base64Decode(header.split(' ').last)).split(':').first,
          );
          return reply({
            'access_token': 'bootstrap',
            'token_type': 'bearer',
            'expires_in': 60,
          });
        }
        if (request.url.path.endsWith('/auth/login')) {
          return reply({
            'user': {'id': session.accountId},
            'access_token': {'type': 'Bearer', 'token': token},
          });
        }
        return reply([
          {'id': session.libraryId, 'name': 'Bibliotheque ZTF'},
        ]);
      }),
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      IlmsApp(
        auth: auth,
        openJournal: () async => IlmsCirculationJournal.open(
          filePath: file,
          factory: databaseFactoryFfi,
        ),
        circulationClient: MockClient((_) async => reply({})),
      ),
    );
    Future<void> signIn() async {
      for (final entry in {
        'Identifiant ILMS': 'operator',
        'Mot de passe': 'password',
      }.entries) {
        await tester.enterText(
          find.widgetWithText(TextFormField, entry.key),
          entry.value,
        );
      }
      await tap(tester, find.text('Se connecter'));
    }

    // ILMS is one product: the operator signs in, it never picks a backend.
    // No field, and no hidden panel, can retarget the gateway or its client.
    for (final label in [
      'Gateway ILMS',
      'Client OAuth',
      'Secret du client OAuth',
    ]) {
      expect(find.widgetWithText(TextFormField, label), findsNothing);
    }
    expect(find.text('Parametres avances'), findsNothing);

    await signIn();
    expect(auth.signedIn, isTrue);
    // Every call went to the gateway baked into the build, with its client.
    expect(clients, [ilmsDefaultClientId]);
    expect(origins, {Uri.parse(ilmsDefaultGatewayUrl).origin});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native login opens journal without registering or uploading Render data',
    (tester) async {
      final requests = <http.Request>[];
      final auth = IlmsAuthService(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/oauth/token')) {
            return reply({
              'access_token': 'bootstrap',
              'token_type': 'bearer',
              'expires_in': 60,
            });
          }
          if (request.url.path.endsWith('/auth/login')) {
            return reply({
              'user': {'id': session.accountId},
              'access_token': {'type': 'Bearer', 'token': token},
            });
          }
          return reply([
            {'id': session.libraryId, 'name': 'Bibliotheque ZTF'},
          ]);
        }),
      );
      addTearDown(auth.dispose);
      var opens = 0;
      var businessCalls = 0;
      await tester.pumpWidget(
        IlmsApp(
          auth: auth,
          openJournal: () async {
            opens++;
            return IlmsCirculationJournal.open(
              filePath: file,
              factory: databaseFactoryFfi,
            );
          },
          circulationClient: MockClient((_) async {
            businessCalls++;
            return reply({});
          }),
        ),
      );
      for (final entry in {
        'Identifiant ILMS': 'operator',
        'Mot de passe': 'password',
      }.entries) {
        await tester.enterText(
          find.widgetWithText(TextFormField, entry.key),
          entry.value,
        );
      }
      await tap(tester, find.text('Se connecter'));
      expect(opens, 1);
      expect(businessCalls, 0);
      expect(requests.length, 3);
      expect(
        requests.every((r) => r.url.host == 'gateway.bibliotheque-ztf.org'),
        isTrue,
      );
      expect(find.text('Circulation RFID'), findsOneWidget);
      await tap(tester, find.byTooltip('Deconnexion'));
      expect(auth.session, isNull);
      expect(find.text('Connexion ILMS'), findsOneWidget);
      expect(
        find
                .widgetWithText(TextFormField, 'Mot de passe')
                .evaluate()
                .single
                .widget
            is TextFormField,
        isTrue,
      );
      expect(
        (tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Mot de passe'),
        )).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await settleIo(tester);
    },
  );

  testWidgets(
    'lookup previews invalidate when tags change; no business write on lookup',
    (tester) async {
      final requests = <http.Request>[];
      final service = sync(
        MockClient((request) async {
          requests.add(request);
          return reply(
            request.url.path.endsWith('/members/resolve') ? member : copy,
          );
        }),
      );
      await showStation(tester, service);
      await resolve(tester, card: true);
      await resolve(tester, card: false);
      expect(find.textContaining('Adherent de recette'), findsOneWidget);
      expect(
        find.textContaining('Catalogue de la bibliotheque'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const ValueKey('copy-epc')), 'ABCD');
      await tester.pump();
      expect(find.textContaining('Catalogue de la bibliotheque'), findsNothing);
      expect(requests.length, 2);
      expect(
        await tester.runAsync(() => journal.list(normalizeIlmsScope(session))),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'checkout confirmation commits before HTTP and clears consumed previews',
    (tester) async {
      http.Request? sent;
      final service = sync(
        MockClient((request) async {
          if (request.url.path.endsWith('/members/resolve')) {
            return reply(member);
          }
          if (request.url.path.endsWith('/copies/resolve')) return reply(copy);
          sent = request;
          final pending = await journal.list(normalizeIlmsScope(session));
          expect(pending.length, 1);
          expect(pending.single['attempts'], 1);
          expect(
            (pending.single['payload'] as Map)['operation_id'],
            (jsonDecode(request.body) as Map)['operation_id'],
          );
          return reply(loan, 201);
        }),
      );
      await showStation(tester, service);
      await resolve(tester, card: true);
      await resolve(tester, card: false);
      await tap(tester, find.text('Date de retour souhaitee'));
      await tap(tester, find.text('OK'));
      await tap(tester, find.text('Confirmer le pret'));
      expect(sent, isNull);
      expect(
        await tester.runAsync(() => journal.list(normalizeIlmsScope(session))),
        isEmpty,
      );
      await tap(tester, find.text('Confirmer'));
      expect(sent!.url.path.endsWith('/checkouts'), isTrue);
      expect(
        (jsonDecode(sent!.body) as Map)['expected_copy_id'],
        checkout['expected_copy_id'],
      );
      expect(find.textContaining('Confirme par ILMS'), findsOneWidget);
      expect(find.textContaining('Adherent de recette'), findsNothing);
      expect(
        await tester.runAsync(() => journal.list(normalizeIlmsScope(session))),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'return requires original native loan and explicit confirmation',
    (tester) async {
      final requests = <http.Request>[];
      final service = sync(
        MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/copies/resolve')) {
            return reply({
              ...copy,
              'available_for_checkout': false,
              'active_loan': loan,
            });
          }
          return reply({...loan, 'status': 2});
        }),
      );
      await showStation(tester, service);
      await tap(tester, find.text('Retour'));
      expect(find.byKey(const ValueKey('card-epc')), findsNothing);
      await resolve(tester, card: false);
      await tap(tester, find.text('Confirmer le retour'));
      await tap(tester, find.text('Annuler'));
      expect(requests.length, 1);
      await tap(tester, find.text('Confirmer le retour'));
      await tap(tester, find.text('Confirmer'));
      expect(requests.length, 2);
      expect(jsonDecode(requests.last.body), {
        'copy': checkout['copy'],
        'loan_id': loan['id'],
      });
      expect(find.textContaining('Confirme par ILMS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending queue never replays automatically; retry preserves UUID across failure',
    (tester) async {
      await tester.runAsync(
        () => journal.enqueue(normalizeIlmsScope(session), operation),
      );
      final requests = <http.Request>[];
      var status = 503;
      final service = sync(
        MockClient((request) async {
          requests.add(request);
          return reply(status == 201 ? loan : {}, status);
        }),
      );
      await showStation(tester, service);
      expect(requests, isEmpty);
      await tap(tester, find.byTooltip('Renvoyer la demande'));
      await tap(tester, find.text('Annuler'));
      expect(requests, isEmpty);
      await tap(tester, find.byTooltip('Renvoyer la demande'));
      await tap(tester, find.text('Renvoyer'));
      expect(requests.length, 1);
      expect(find.textContaining('HTTP 503'), findsWidgets);
      status = 201;
      await tap(tester, find.byTooltip('Renvoyer la demande'));
      await tap(tester, find.text('Renvoyer'));
      expect(requests.length, 2);
      expect(requests.last.body, requests.first.body);
      expect(find.text('Aucune demande en attente.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('local discard requires confirmation and makes no HTTP call', (
    tester,
  ) async {
    await tester.runAsync(
      () => journal.enqueue(normalizeIlmsScope(session), operation),
    );
    var calls = 0;
    await showStation(
      tester,
      sync(
        MockClient((_) async {
          calls++;
          return reply({});
        }),
      ),
    );
    await tap(tester, find.byTooltip('Supprimer localement'));
    expect(find.textContaining('ne peut pas annuler'), findsOneWidget);
    await tap(tester, find.text('Annuler'));
    expect(
      (await tester.runAsync(
        () => journal.list(normalizeIlmsScope(session)),
      ))!.length,
      1,
    );
    await tap(tester, find.byTooltip('Supprimer localement'));
    await tap(
      tester,
      find.widgetWithText(FilledButton, 'Supprimer localement'),
    );
    expect(
      await tester.runAsync(() => journal.list(normalizeIlmsScope(session))),
      isEmpty,
    );
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  IlmsAuthService nativeSession({bool multiple = false}) => IlmsAuthService(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/oauth/token')) {
        return reply({
          'access_token': 'bootstrap',
          'token_type': 'bearer',
          'expires_in': 60,
        });
      }
      if (request.url.path.endsWith('/auth/login')) {
        return reply({
          'user': {'id': session.accountId},
          'access_token': {'type': 'Bearer', 'token': token},
        });
      }
      return reply([
        {'id': session.libraryId, 'name': 'Bibliotheque ZTF'},
        if (multiple)
          {
            'id': '33333333-3333-4333-8333-333333333333',
            'name': 'Autre bibliotheque',
          },
      ]);
    }),
  );

  Future<void> authenticate(WidgetTester tester, IlmsAuthService auth) async {
    await tester.runAsync(
      () => auth.signIn(
        gatewayUrl: session.gatewayUrl,
        username: 'test-operator',
        password: 'test-password',
        clientId: 'test-client',
        clientSecret: 'test-secret',
      ),
    );
  }

  testWidgets(
    'changing library clears previews and scopes retained journal without replay',
    (tester) async {
      await tester.runAsync(
        () => journal.enqueue(normalizeIlmsScope(session), operation),
      );
      final auth = nativeSession(multiple: true);
      addTearDown(auth.dispose);
      await authenticate(tester, auth);
      var calls = 0;
      var opens = 0;
      await tester.pumpWidget(
        IlmsApp(
          auth: auth,
          openJournal: () async {
            opens++;
            return IlmsCirculationJournal.open(
              filePath: file,
              factory: databaseFactoryFfi,
            );
          },
          circulationClient: MockClient((_) async {
            calls++;
            return reply(member);
          }),
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 0);
      auth.selectLibrary(session.libraryId);
      await settleIo(tester);
      expect(find.text('Journal local (1)'), findsOneWidget);
      expect(calls, 0);
      await resolve(tester, card: true);
      expect(find.textContaining('Adherent de recette'), findsOneWidget);
      auth.selectLibrary('33333333-3333-4333-8333-333333333333');
      await settleIo(tester);
      expect(find.textContaining('Adherent de recette'), findsNothing);
      expect(find.text('Journal local (0)'), findsOneWidget);
      auth.selectLibrary(session.libraryId);
      await settleIo(tester);
      expect(find.text('Journal local (1)'), findsOneWidget);
      expect(calls, 1);
      expect(opens, 3);
      await tester.pumpWidget(const SizedBox());
      await settleIo(tester);
    },
  );

  testWidgets(
    'logout during HTTP removes sensitive UI and preserves original durable intent',
    (tester) async {
      await tester.runAsync(
        () => journal.enqueue(normalizeIlmsScope(session), operation),
      );
      final auth = nativeSession();
      addTearDown(auth.dispose);
      await authenticate(tester, auth);
      final entered = Completer<void>();
      final release = Completer<void>();
      await tester.pumpWidget(
        IlmsApp(
          auth: auth,
          openJournal: () => IlmsCirculationJournal.open(
            filePath: file,
            factory: databaseFactoryFfi,
          ),
          circulationClient: MockClient((_) async {
            entered.complete();
            await release.future;
            return reply(loan, 201);
          }),
        ),
      );
      await settleIo(tester);
      await tap(tester, find.byTooltip('Renvoyer la demande'));
      await tester.tap(find.text('Renvoyer'));
      for (var index = 0; index < 50 && !entered.isCompleted; index++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(entered.isCompleted, isTrue);
      auth.logout();
      await settleIo(tester);
      expect(find.text('Connexion ILMS'), findsOneWidget);
      expect(find.textContaining('Confirme par ILMS'), findsNothing);
      release.complete();
      await settleIo(tester);
      final rows = (await tester.runAsync(
        () => journal.list(normalizeIlmsScope(session)),
      ))!;
      expect(rows.length, 1);
      expect(rows.single['id'], checkout['operation_id']);
      expect(rows.single['attempts'], 1);
      expect(find.textContaining('Confirme par ILMS'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('station and queued identifiers fit at $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => journal.enqueue(normalizeIlmsScope(session), operation),
      );
      await showStation(tester, sync(MockClient((_) async => reply({}))));
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('Retour'));
      expect(tester.takeException(), isNull);
      if (width == 390) {
        final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../../../ilms-migration/.tools/rfid-mobile-ilms-station.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
