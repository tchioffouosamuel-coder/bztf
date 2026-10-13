import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myscankey_flutter/services/ilms_circulation_client.dart';

void main() {
  final fixture =
      (jsonDecode(
                File(
                  '../../BiblioRFID/tests/fixtures/ilms-circulation-contract.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  final nativeScope = (fixture['scope'] as Map).cast<String, String>();
  final entries = fixture['operations'] as List;
  final loan = (fixture['loan'] as Map).cast<String, Object?>();
  final original = (entries[0] as Map)['normalized'] as Map;
  IlmsSession session({
    String? gateway,
    String? account,
    String? library,
    String token = 'fake.jwt.token',
  }) => IlmsSession(
    gatewayUrl: gateway ?? nativeScope['gatewayUrl']!,
    accountId: account ?? nativeScope['accountId']!,
    libraryId: library ?? nativeScope['libraryId']!,
    accessToken: token,
  );
  http.Response reply(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
  Matcher error(String code, [int? status]) => isA<IlmsClientException>()
      .having((value) => value.code, 'code', code)
      .having(
        (value) => status == null || value.status == status,
        'status',
        true,
      );
  late IlmsSession? current;
  late IlmsCirculationClient client;
  setUp(() => current = session());
  tearDown(() => client.close());
  void use(MockClient httpClient, {Duration? timeout}) {
    client = IlmsCirculationClient(
      getSession: () => current,
      client: httpClient,
      timeout: timeout ?? const Duration(seconds: 30),
    );
  }

  test(
    'mobile normalization matches the desktop contract and removes credentials and extra fields',
    () {
      use(MockClient((_) async => reply(loan)));
      for (final row in entries.cast<Map>()) {
        expect(normalizeIlmsOperation(row['input']), row['normalized']);
      }
      final input = <String, Object?>{
        'kind': 'checkout',
        'payload': {
          ...original['payload'] as Map,
          'preferred_return_date': '2030-12-01T12:00:00.123456Z',
        },
      };
      expect(
        (normalizeIlmsOperation(input)['payload']
            as Map)['preferred_return_date'],
        '2030-12-01T12:00:00.123Z',
      );
    },
  );
  test(
    'requires an exact HTTPS or local HTTP gateway without URL credentials, query, fragment or service path',
    () {
      use(MockClient((_) async => reply(loan)));
      for (final gateway in [
        'http://ilms.test',
        'https://user:password@ilms.test',
        'https://ilms.test/api',
        'https://ilms.test/?token=secret',
        'https://ilms.test/#x',
        'file:///x',
      ]) {
        current = session(gateway: gateway);
        expect(() => client.scope, throwsA(error('scope')));
      }
      current = session(gateway: 'https://ILMS.test/');
      expect(client.scope['gateway_url'], 'https://ilms.test');
      current = session(gateway: 'http://[::1]:8081');
      expect(client.scope['gateway_url'], 'http://[::1]:8081');
    },
  );
  test(
    'uses normalized native routes and only the ILMS bearer, with redirects disabled',
    () async {
      final requests = <http.Request>[];
      use(
        MockClient((request) async {
          requests.add(request);
          return reply(
            request.url.path.endsWith('members/resolve')
                ? fixture['member']
                : fixture['copy'],
          );
        }),
      );
      final member = await client.resolveMember({'epc': 'aa12'});
      final copy = await client.resolveCopy({'tid': 'bb34'});
      expect(member['member_id'], (fixture['member'] as Map)['member_id']);
      expect(
        (copy['copy'] as Map)['id'],
        (fixture['copy'] as Map)['copy']['id'],
      );
      for (final request in requests) {
        expect(
          request.url.path,
          startsWith(
            '/library-service/api/v1/libraries/${nativeScope['libraryId']}/circulation/rfid/',
          ),
        );
        expect(request.headers['Authorization'], 'Bearer fake.jwt.token');
        expect(request.headers.containsKey('X-Device-Key'), false);
        expect(request.headers.containsKey('Cookie'), false);
        expect(request.followRedirects, false);
      }
      expect(jsonDecode(requests[0].body), {'epc': 'AA12'});
      expect(jsonDecode(requests[1].body), {'tid': 'BB34'});
    },
  );
  test(
    'sends exactly the persisted-style native checkout payload and validates the acknowledgement',
    () async {
      Object? body;
      use(
        MockClient((request) async {
          body = jsonDecode(request.body);
          return reply({...loan, 'member_name': 'Not retained'}, 201);
        }),
      );
      final result = await client.send((entries[0] as Map)['input']);
      expect(body, original['payload']);
      expect(result['id'], loan['id']);
      expect(result.containsKey('member_name'), false);
    },
  );
  test(
    'replays a return with the original loan ID and no member card',
    () async {
      Object? body;
      use(
        MockClient((request) async {
          body = jsonDecode(request.body);
          return reply({...loan, 'status': 2});
        }),
      );
      final originalReturn = (entries[1] as Map)['normalized'];
      await client.send(originalReturn);
      expect(body, (originalReturn as Map)['payload']);
      expect((body as Map).containsKey('card'), false);
    },
  );
  for (final status in [400, 401, 403, 404, 409, 429, 503]) {
    test(
      'HTTP $status is an explicit failure with no secret error-body leak',
      () async {
        use(
          MockClient(
            (_) async => reply({'message': 'private-secret-body'}, status),
          ),
        );
        try {
          await client.send(original);
          fail('Expected a refusal');
        } on IlmsClientException catch (exception) {
          expect(exception.code, 'denied');
          expect(exception.status, status);
          expect(exception.toString(), isNot(contains('private-secret-body')));
        }
      },
    );
  }
  for (final update in [
    {'library_id': nativeScope['accountId']},
    {'member_id': nativeScope['accountId']},
    {'copy_id': nativeScope['accountId']},
    {'id': 'bad'},
    {'status': 99},
  ]) {
    test(
      'rejects a malformed or mismatched loan ${update.keys.first}',
      () async {
        use(MockClient((_) async => reply({...loan, ...update}, 201)));
        await expectLater(client.send(original), throwsA(error('response')));
      },
    );
  }
  test(
    'cannot acknowledge a different return loan or a loan not yet returned',
    () async {
      var body = {...loan, 'status': 1};
      use(MockClient((_) async => reply(body)));
      await expectLater(
        client.send((entries[1] as Map)['normalized']),
        throwsA(error('response')),
      );
      body = {...loan, 'status': 2, 'id': nativeScope['accountId']};
      await expectLater(
        client.send((entries[1] as Map)['normalized']),
        throwsA(error('response')),
      );
    },
  );
  test(
    'missing session or token and malformed tags or native IDs cause no HTTP request',
    () async {
      var calls = 0;
      use(
        MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      current = null;
      await expectLater(client.send(original), throwsA(error('scope')));
      current = session(token: '');
      await expectLater(client.send(original), throwsA(error('auth')));
      current = session();
      await expectLater(
        client.resolveMember({'epc': 'ABC'}),
        throwsA(error('input')),
      );
      final payload = {...original['payload'] as Map}
        ..remove('expected_card_id');
      await expectLater(
        client.send({'kind': 'checkout', 'payload': payload}),
        throwsA(error('input')),
      );
      expect(calls, 0);
    },
  );
  for (final change in ['account', 'library', 'gateway', 'logout']) {
    test(
      'rejects a late response after $change instead of exposing it to another session',
      () async {
        use(
          MockClient((_) async {
            current = switch (change) {
              'account' => session(account: nativeScope['libraryId']),
              'library' => session(library: nativeScope['accountId']),
              'gateway' => session(gateway: 'https://another.test'),
              _ => null,
            };
            return reply(loan, 201);
          }),
        );
        await expectLater(client.send(original), throwsA(error('scope')));
      },
    );
  }
  test(
    'rejects malformed JSON, wrong media type and oversized JSON without returning a loan',
    () async {
      var index = 0;
      final replies = [
        http.Response('{', 200, headers: {'content-type': 'application/json'}),
        http.Response('{}', 200, headers: {'content-type': 'text/html'}),
        reply({'padding': 'x' * 70000}),
      ];
      use(MockClient((_) async => replies[index++]));
      for (var i = 0; i < replies.length; i++) {
        await expectLater(client.send(original), throwsA(error('response')));
      }
    },
  );
  test('timeout is bounded and does not invent a successful reply', () async {
    use(
      MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(client.send(original), throwsA(error('network')));
  });
  test(
    'transport does not synchronize or register a device when merely created',
    () async {
      var calls = 0;
      use(
        MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 0);
      client.close();
      await expectLater(client.send(original), throwsA(error('auth')));
      expect(calls, 0);
    },
  );
  test(
    'validates the native copy active-loan identity before allowing the caller to prepare a return',
    () async {
      use(
        MockClient(
          (_) async => reply({
            ...fixture['copy'] as Map,
            'active_loan': {...loan, 'copy_id': nativeScope['accountId']},
          }),
        ),
      );
      await expectLater(
        client.resolveCopy({'tid': 'BB34'}),
        throwsA(error('response')),
      );
    },
  );
  test('optional null tags are omitted without accepting an empty tag', () {
    expect(normalizeIlmsTag({'epc': 'aa12', 'tid': null}), {'epc': 'AA12'});
    expect(
      () => normalizeIlmsTag({'epc': null, 'tid': null}),
      throwsA(error('input')),
    );
  });
  test('malformed lookup IDs and nested loans are response failures', () async {
    final member = fixture['member'] as Map;
    final copy = fixture['copy'] as Map;
    final replies = [
      {
        ...member,
        'member_id': [member['member_id']],
      },
      {
        ...member,
        'card_id': [member['card_id']],
      },
      {
        ...copy,
        'copy': {
          ...copy['copy'] as Map,
          'id': [(copy['copy'] as Map)['id']],
        },
      },
      {...copy, 'active_loan': false},
    ];
    var index = 0;
    use(MockClient((_) async => reply(replies[index++])));
    for (var i = 0; i < 2; i++) {
      await expectLater(
        client.resolveMember({'epc': 'AA12'}),
        throwsA(error('response')),
      );
    }
    for (var i = 0; i < 2; i++) {
      await expectLater(
        client.resolveCopy({'tid': 'BB34'}),
        throwsA(error('response')),
      );
    }
  });
  test(
    'all four routes use the direct gateway without the Angular proxy prefix',
    () async {
      final prefix =
          '/library-service/api/v1/libraries/${nativeScope['libraryId']}/circulation/rfid/';
      final replies = <String, Object?>{
        '${prefix}members/resolve': fixture['member'],
        '${prefix}copies/resolve': fixture['copy'],
        '${prefix}checkouts': loan,
        '${prefix}returns': {...loan, 'status': 2},
      };
      final paths = <String>[];
      final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = gateway.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        expect(request.method, 'POST');
        request.response.statusCode = replies.containsKey(request.uri.path)
            ? 200
            : 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(replies[request.uri.path] ?? {}));
        await request.response.close();
      });
      current = session(gateway: 'http://127.0.0.1:${gateway.port}');
      client = IlmsCirculationClient(getSession: () => current);
      try {
        await client.resolveMember({'epc': 'AA12'});
        await client.resolveCopy({'tid': 'BB34'});
        await client.send(original);
        await client.send((entries[1] as Map)['normalized']);
        expect(paths, replies.keys.toList());
      } finally {
        client.close();
        await gateway.close(force: true);
        await listener.cancel();
      }
    },
  );

  test(
    'real loopback HTTP exposes only native routes and never follows a redirect to another origin',
    () async {
      final requests = <Map<String, Object?>>[];
      var redirects = false;
      var foreignCalls = 0;
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final foreign = destination.listen((request) async {
        foreignCalls++;
        await request.response.close();
      });
      final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = gateway.listen((request) async {
        requests.add({
          'path': request.uri.path,
          'authorization': request.headers.value('authorization'),
          'legacyKey': request.headers.value('X-Device-Key'),
          'body': jsonDecode(await utf8.decoder.bind(request).join()),
        });
        if (redirects) {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${destination.port}/stolen',
          );
        } else {
          request.response.statusCode = 201;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(loan));
        }
        await request.response.close();
      });
      current = session(gateway: 'http://127.0.0.1:${gateway.port}');
      client = IlmsCirculationClient(getSession: () => current);
      try {
        expect((await client.send(original))['id'], loan['id']);
        expect(requests.single['body'], original['payload']);
        expect(requests.single['authorization'], 'Bearer fake.jwt.token');
        expect(requests.single['legacyKey'], null);
        redirects = true;
        await expectLater(client.send(original), throwsA(error('denied', 302)));
        expect(foreignCalls, 0);
      } finally {
        client.close();
        await gateway.close(force: true);
        await destination.close(force: true);
        await listener.cancel();
        await foreign.cancel();
      }
    },
  );
}
