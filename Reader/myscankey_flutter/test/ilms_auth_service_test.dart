import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myscankey_flutter/services/ilms_auth_service.dart';
import 'package:myscankey_flutter/services/ilms_circulation_client.dart';
import 'package:myscankey_flutter/screens/ilms_messages.dart';

const account = '11111111-1111-4111-8111-111111111111';
const library = '22222222-2222-4222-8222-222222222222';
const otherLibrary = '33333333-3333-4333-8333-333333333333';
final clock = DateTime.utc(2030, 1, 1);

String jwt({DateTime? expiry}) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({
      'exp': (expiry ?? clock.add(const Duration(hours: 1))).millisecondsSinceEpoch ~/ 1000,
      // Deliberately not the account UUID: account metadata comes from user.id.
      'sub': 'not-the-user-uuid',
    }))).replaceAll('=', '')}.signature';

Map<String, Object?> nativeLogin({
  String? token,
  String type = 'Bearer',
  Object? id = account,
}) => {
  'user': {'id': id, 'name': 'Native operator'},
  'access_token': {'type': type, 'token': token ?? jwt(), 'expires_in': 3600},
};

http.Response jsonReply(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Future<void> login(
  IlmsAuthService auth, {
  String gateway = 'https://gateway.example',
}) => auth.signIn(
  gatewayUrl: gateway,
  username: ' native-user ',
  password: 'test-password',
  clientId: 'test-client',
  clientSecret: 'test-client-secret',
);

MockClient nativeAuthClient({
  Object? loginResponse,
  Object? libraries,
  int? denied,
  List<http.Request>? requests,
  Future<void> Function(http.Request)? before,
}) => MockClient((request) async {
  requests?.add(request);
  await before?.call(request);
  if (denied != null) {
    return jsonReply({'private_error': 'never expose'}, denied);
  }
  if (request.url.path == '/auth-service/oauth/token') {
    return jsonReply({
      'access_token': 'bootstrap-token',
      'token_type': 'bearer',
      'expires_in': 3600,
    });
  }
  if (request.url.path == '/auth-service/api/v1/auth/login') {
    return jsonReply(loginResponse ?? nativeLogin());
  }
  if (request.url.path != '/library-service/api/v1/libraries') {
    return jsonReply({}, 404);
  }
  return jsonReply(
    libraries ??
        [
          {'id': library, 'name': 'Bibliotheque ZTF'},
        ],
  );
});

void main() {
  for (final stage in IlmsAuthStage.values) {
    test(
      'HTTP failures identify the exact authentication stage: ${stage.name}',
      () async {
        final requests = <http.Request>[];
        final expectedPath = switch (stage) {
          IlmsAuthStage.oauth => '/auth-service/oauth/token',
          IlmsAuthStage.user => '/auth-service/api/v1/auth/login',
          IlmsAuthStage.libraries => '/library-service/api/v1/libraries',
        };
        final normal = nativeAuthClient();
        final auth = IlmsAuthService(
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path == expectedPath) {
              return http.Response(
                'private-server-body',
                302,
                headers: {
                  'location':
                      '/auth-service/login?token=private-redirect-token',
                },
              );
            }
            return normal.get(request.url);
          }),
          now: () => clock,
        );
        addTearDown(auth.dispose);
        addTearDown(normal.close);
        await expectLater(
          login(auth),
          throwsA(
            isA<IlmsAuthHttpException>()
                .having((e) => e.stage, 'stage', stage)
                .having((e) => e.status, 'status', 302)
                .having((e) => e.redirect, 'redirect', IlmsAuthRedirect.login)
                .having(
                  (e) => ilmsErrorMessage(e),
                  'safe message',
                  isNot(contains('private-')),
                ),
          ),
        );
        expect(requests.length, stage.index + 1);
        expect(requests.last.url.path, expectedPath);
        expect(requests.every((r) => !r.followRedirects), isTrue);
        expect(auth.signedIn, isFalse);
        expect(auth.session, isNull);
      },
    );
  }

  test(
    'redirect diagnostics retain no URL, query, fragment, userinfo or server body',
    () async {
      final cases = <String?, IlmsAuthRedirect>{
        null: IlmsAuthRedirect.missing,
        '': IlmsAuthRedirect.missing,
        '/login?password=private-query#private-fragment':
            IlmsAuthRedirect.login,
        'https://gateway.example/auth-service/login?code=private-code':
            IlmsAuthRedirect.login,
        '/private-path?token=private-token': IlmsAuthRedirect.sameGateway,
        'https://foreign.example/private-path?code=private-code':
            IlmsAuthRedirect.otherOrigin,
        'https://private-user:private-password@gateway.example/login':
            IlmsAuthRedirect.unsafe,
        'http://gateway.example/login': IlmsAuthRedirect.unsafe,
        'javascript:private-code': IlmsAuthRedirect.unsafe,
      'https://': IlmsAuthRedirect.unsafe,
        '/login\nprivate-control': IlmsAuthRedirect.unsafe,
        '/${'private-' * 600}': IlmsAuthRedirect.unsafe,
      };
      for (final entry in cases.entries) {
        var calls = 0;
        final auth = IlmsAuthService(
          client: MockClient((_) async {
            calls++;
            return http.Response(
              'private-body',
              302,
              headers: {if (entry.key != null) 'location': entry.key!},
            );
          }),
        );
        try {
          await expectLater(
            login(auth),
            throwsA(
              isA<IlmsAuthHttpException>()
                  .having((e) => e.redirect, 'redirect', entry.value)
                  .having(
                    (e) => '${e.toString()} ${ilmsErrorMessage(e)}',
                    'safe output',
                    isNot(contains('private-')),
                  ),
            ),
          );
          expect(calls, 1);
          expect(auth.session, isNull);
        } finally {
          auth.dispose();
        }
      }
    },
  );

  test(
    'actual IO OAuth 302 never forwards credentials to its destination',
    () async {
      var destinationCalls = 0;
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      destination.listen((request) async {
        destinationCalls++;
        await request.drain<void>();
        await request.response.close();
      });
      final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gateway.listen((request) async {
        expect(request.uri.path, '/auth-service/oauth/token');
        expect(request.method, 'POST');
        await request.drain<void>();
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${destination.port}/login?code=private-code',
        );
        await request.response.close();
      });
      final auth = IlmsAuthService();
      try {
        await expectLater(
          login(auth, gateway: 'http://127.0.0.1:${gateway.port}'),
          throwsA(
            isA<IlmsAuthHttpException>()
                .having((e) => e.stage, 'stage', IlmsAuthStage.oauth)
                .having(
                  (e) => e.redirect,
                  'redirect',
                  IlmsAuthRedirect.otherOrigin,
                ),
          ),
        );
        expect(destinationCalls, 0);
        expect(auth.session, isNull);
      } finally {
        auth.dispose();
        await gateway.close(force: true);
        await destination.close(force: true);
      }
    },
  );

  test(
    'authentication messages distinguish access refusal and missing routes from expired sessions',
    () {
      for (final stage in IlmsAuthStage.values) {
        for (final status in [401, 403, 404, 500]) {
          final message = ilmsErrorMessage(
            IlmsAuthHttpException(stage, status),
          );
          expect(message, contains('HTTP $status'));
          expect(message, isNot(contains('Session expiree')));
          expect(message, isNot(contains('Element introuvable')));
        }
      }
    },
  );

  test(
    'native OAuth then user login then libraries; no legacy or cookies',
    () async {
      final requests = <http.Request>[];
      final auth = IlmsAuthService(
        client: nativeAuthClient(requests: requests),
        now: () => clock,
      );
      addTearDown(auth.dispose);
      await login(auth);
      expect(requests.map((r) => '${r.method} ${r.url.path}'), [
        'POST /auth-service/oauth/token',
        'POST /auth-service/api/v1/auth/login',
        'GET /library-service/api/v1/libraries',
      ]);
      expect(
        requests.first.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('test-client:test-client-secret'))}',
      );
      expect(
        requests.first.body,
        'grant_type=client_credentials&scope=read+write',
      );
      expect(jsonDecode(requests[1].body), {
        'username': 'native-user',
        'password': 'test-password',
      });
      expect(requests[1].headers['authorization'], 'Bearer bootstrap-token');
      expect(requests.last.headers['authorization'], 'Bearer ${jwt()}');
      for (final request in requests) {
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('cookie'), isFalse);
        expect(request.url.query, isEmpty);
      }
      expect(auth.session!.accountId, account);
      expect(auth.session!.libraryId, library);
      expect(auth.session!.accessToken, jwt());
    },
  );

  test('multiple libraries require explicit selection; no all scope', () async {
    final auth = IlmsAuthService(
      client: nativeAuthClient(
        libraries: [
          {'id': library, 'name': 'First'},
          {'id': otherLibrary, 'name': 'Second'},
        ],
      ),
      now: () => clock,
    );
    addTearDown(auth.dispose);
    await login(auth);
    expect(auth.signedIn, isTrue);
    expect(auth.session, isNull);
    auth.selectLibrary(otherLibrary);
    expect(auth.session!.libraryId, otherLibrary);
    expect(
      () => auth.selectLibrary('all'),
      throwsA(isA<IlmsClientException>()),
    );
    expect(() => auth.libraries.clear(), throwsUnsupportedError);
  });

  test(
    'expiry preserves scoped queue metadata but removes usable token',
    () async {
      var now = clock;
      final auth = IlmsAuthService(client: nativeAuthClient(), now: () => now);
      addTearDown(auth.dispose);
      await login(auth);
      now = clock.add(const Duration(hours: 1));
      expect(auth.session!.accessToken, isEmpty);
      expect(auth.session!.accountId, account);
      auth.logout();
      expect(auth.session, isNull);
      expect(auth.libraries, isEmpty);
    },
  );

  for (final url in [
    'http://remote.example',
    'https://a:b@gateway.example',
    'https://gateway.example/api',
    'https://gateway.example/?token=x',
    'https://gateway.example/#x',
  ]) {
    test('reject unsafe gateway $url before HTTP', () async {
      final requests = <http.Request>[];
      final auth = IlmsAuthService(
        client: nativeAuthClient(requests: requests),
        now: () => clock,
      );
      addTearDown(auth.dispose);
      await expectLater(
        login(auth, gateway: url),
        throwsA(isA<IlmsClientException>()),
      );
      expect(requests, isEmpty);
    });
  }

  for (final status in [301, 302, 400, 401, 403, 500]) {
    test('HTTP $status does not create session or reveal error body', () async {
      final auth = IlmsAuthService(
        client: nativeAuthClient(denied: status),
        now: () => clock,
      );
      addTearDown(auth.dispose);
      await expectLater(
        login(auth),
        throwsA(
          isA<IlmsClientException>()
              .having((e) => e.status, 'status', status)
              .having(
                (e) => e.toString(),
                'generic error',
                isNot(contains('private_error')),
              ),
        ),
      );
      expect(auth.signedIn, isFalse);
    });
  }

  final invalidResponses = <Object?>[
    nativeLogin(id: 5),
    nativeLogin(id: [account]),
    nativeLogin(type: 'Password-Token'),
    nativeLogin(type: '2FA-Token'),
    nativeLogin(token: 'opaque-token'),
    nativeLogin(token: 'bad token'),
    nativeLogin(token: jwt(expiry: clock)),
    {
      'user': {'id': account, 'password_change_required': true},
      'access_token': {'type': 'Bearer', 'token': jwt()},
    },
  ];
  for (var index = 0; index < invalidResponses.length; index++) {
    test('invalid/incomplete login $index fails before libraries', () async {
      final requests = <http.Request>[];
      final auth = IlmsAuthService(
        client: nativeAuthClient(
          loginResponse: invalidResponses[index],
          requests: requests,
        ),
        now: () => clock,
      );
      addTearDown(auth.dispose);
      await expectLater(login(auth), throwsA(isA<IlmsClientException>()));
      expect(auth.session, isNull);
      expect(requests.length, 2);
    });
  }

  for (final libraries in [
    [],
    [
      {'id': 'all', 'name': 'All'},
    ],
    [
      {'id': library, 'name': ''},
    ],
    [
      {'id': library, 'name': 'One'},
      {'id': library, 'name': 'Duplicate'},
    ],
    {'content': []},
  ]) {
    test(
      'invalid libraries ${libraries.toString()} leave no partial session',
      () async {
        final auth = IlmsAuthService(
          client: nativeAuthClient(libraries: libraries),
          now: () => clock,
        );
        addTearDown(auth.dispose);
        await expectLater(login(auth), throwsA(isA<IlmsClientException>()));
        expect(auth.session, isNull);
        expect(auth.libraries, isEmpty);
      },
    );
  }

  test('logout while login is pending suppresses late session', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final auth = IlmsAuthService(
      client: nativeAuthClient(
        before: (request) async {
          if (request.url.path.endsWith('/auth/login')) {
            entered.complete();
            await release.future;
          }
        },
      ),
      now: () => clock,
    );
    addTearDown(auth.dispose);
    final pending = login(auth);
    final rejected = expectLater(pending, throwsA(isA<IlmsClientException>()));
    await entered.future;
    auth.logout();
    release.complete();
    await rejected;
    expect(auth.session, isNull);
  });

  test('overlapping login cannot restore previous account context', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var attempts = 0;
    final auth = IlmsAuthService(
      client: nativeAuthClient(
        before: (request) async {
          if (request.url.path.endsWith('/auth/login') && ++attempts == 1) {
            entered.complete();
            await release.future;
          }
        },
      ),
      now: () => clock,
    );
    addTearDown(auth.dispose);
    final pending = login(auth);
    final rejected = expectLater(pending, throwsA(isA<IlmsClientException>()));
    await entered.future;
    await login(auth, gateway: 'https://other.example');
    release.complete();
    await rejected;
    expect(auth.session!.gatewayUrl, 'https://other.example');
  });

  test('bounded timeout leaves no session', () async {
    final release = Completer<void>();
    final auth = IlmsAuthService(
      client: nativeAuthClient(before: (_) => release.future),
      now: () => clock,
      timeout: const Duration(milliseconds: 20),
    );
    addTearDown(auth.dispose);
    await expectLater(
      login(auth),
      throwsA(
        isA<IlmsClientException>().having((e) => e.code, 'code', 'network'),
      ),
    );
    expect(auth.session, isNull);
    release.complete();
  });

  for (final badResponse in [
    http.Response(
      '<html>private body</html>',
      200,
      headers: {'content-type': 'text/html'},
    ),
    http.Response(
      'invalid-json',
      200,
      headers: {'content-type': 'application/json'},
    ),
    http.Response(
      jsonEncode({'private': 'x' * 1048576}),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ]) {
    test(
      'invalid HTTP body is bounded and never becomes a session (${badResponse.bodyBytes.length})',
      () async {
        final auth = IlmsAuthService(
          client: MockClient((_) async => badResponse),
        );
        addTearDown(auth.dispose);
        await expectLater(
          login(auth),
          throwsA(
            isA<IlmsClientException>().having(
              (e) => e.code,
              'code',
              'response',
            ),
          ),
        );
        expect(auth.session, isNull);
      },
    );
  }

  for (final redirect in [false, true]) {
    test(
      'actual IO native login, redirects=$redirect, never forwards credentials',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final paths = <String>[];
        server.listen((request) async {
          paths.add(request.uri.path);
          expect(request.cookies, isEmpty);
          expect(request.uri.query, isEmpty);
          final body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path == '/auth-service/oauth/token') {
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              startsWith('Basic '),
            );
            expect(body, 'grant_type=client_credentials&scope=read+write');
            request.response.write(
              jsonEncode({
                'access_token': 'bootstrap-token',
                'token_type': 'bearer',
                'expires_in': 60,
              }),
            );
          } else if (request.uri.path == '/auth-service/api/v1/auth/login') {
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer bootstrap-token',
            );
            expect(jsonDecode(body), {
              'username': 'native-user',
              'password': 'test-password',
            });
            if (redirect) {
              request.response.statusCode = 307;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/must-not-receive-credentials',
              );
            } else {
              request.response.write(jsonEncode(nativeLogin()));
            }
          } else if (request.uri.path == '/library-service/api/v1/libraries') {
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer ${jwt()}',
            );
            request.response.write(
              jsonEncode([
                {'id': library, 'name': 'Native library'},
              ]),
            );
          } else {
            request.response.statusCode = 404;
          }
          await request.response.close();
        });
        final auth = IlmsAuthService(now: () => clock);
        addTearDown(auth.dispose);
        final pending = login(auth, gateway: 'http://127.0.0.1:${server.port}');
        if (redirect) {
          await expectLater(
            pending,
            throwsA(
              isA<IlmsClientException>().having((e) => e.status, 'status', 307),
            ),
          );
          expect(auth.session, isNull);
          expect(paths, [
            '/auth-service/oauth/token',
            '/auth-service/api/v1/auth/login',
          ]);
        } else {
          await pending;
          expect(auth.session!.accountId, account);
          expect(paths, [
            '/auth-service/oauth/token',
            '/auth-service/api/v1/auth/login',
            '/library-service/api/v1/libraries',
          ]);
        }
        expect(paths, isNot(contains('/must-not-receive-credentials')));
      },
    );
  }
}
