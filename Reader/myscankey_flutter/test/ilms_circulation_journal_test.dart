import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myscankey_flutter/data/ilms_circulation_journal.dart';
import 'package:myscankey_flutter/services/ilms_circulation_client.dart';
import 'package:myscankey_flutter/services/ilms_circulation_sync.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final fixture =
      (jsonDecode(
                File(
                  '../../BiblioRFID/tests/fixtures/ilms-circulation-contract.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();
  final configuration = (fixture['scope'] as Map).cast<String, String>();
  final loan = (fixture['loan'] as Map).cast<String, Object?>();
  Map<String, Object?> operation([int index = 0]) =>
      (jsonDecode(
                jsonEncode(
                  ((fixture['operations'] as List)[index] as Map)['normalized'],
                ),
              )
              as Map)
          .cast<String, Object?>();
  Map<String, Object?> payload([int index = 0]) =>
      (operation(index)['payload'] as Map).cast<String, Object?>();
  IlmsSession session({
    String? gateway,
    String? account,
    String? library,
    String token = 'fake.jwt.token',
  }) => IlmsSession(
    gatewayUrl: gateway ?? configuration['gatewayUrl']!,
    accountId: account ?? configuration['accountId']!,
    libraryId: library ?? configuration['libraryId']!,
    accessToken: token,
  );
  http.Response reply(Object? body, [int status = 201]) => http.Response(
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

  late Directory directory;
  late String file;
  late DateTime now;
  late IlmsSession? current;
  late IlmsCirculationJournal journal;
  late List<IlmsCirculationJournal> journals;
  late List<IlmsCirculationSync> services;
  Map<String, String> getScope() => normalizeIlmsScope(current);
  Future<IlmsCirculationJournal> open([String? target]) async {
    final journal = await IlmsCirculationJournal.open(
      filePath: target ?? file,
      factory: databaseFactoryFfi,
      now: () => now,
    );
    journals.add(journal);
    return journal;
  }

  Future<void> close(IlmsCirculationJournal target) async {
    await target.close();
    journals.remove(target);
  }

  IlmsCirculationSync use({
    http.Client? client,
    IlmsCirculationJournal? store,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final service = IlmsCirculationSync(
      journal: store ?? journal,
      getSession: () => current,
      client: client ?? MockClient((_) async => reply(loan)),
      timeout: timeout,
    );
    services.add(service);
    return service;
  }

  Future<Database> raw([String? target]) => databaseFactoryFfi.openDatabase(
    target ?? file,
    options: OpenDatabaseOptions(singleInstance: false),
  );

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ilms-mobile-journal-');
    file = path.join(directory.path, 'native.db');
    now = DateTime.utc(2026, 10, 12);
    current = session();
    journals = [];
    services = [];
    journal = await open();
  });
  tearDown(() async {
    for (final service in services) {
      service.close();
    }
    for (final journal in journals) {
      await journal.close();
    }
    expect(
      path.dirname(path.absolute(directory.path)),
      path.absolute(Directory.systemTemp.path),
    );
    expect(
      path.basename(directory.path).startsWith('ilms-mobile-journal-'),
      true,
    );
    await directory.delete(recursive: true);
  });

  test('generates native v4 operation and lease UUIDs without legacy IDs', () {
    final ids = List.generate(100, (_) => newIlmsCirculationId());
    expect(ids.toSet().length, 100);
    for (final id in ids) {
      expect(normalizeIlmsUuid(id), id);
      expect(id[14], '4');
      expect('89ab'.contains(id[19]), true);
    }
  });
  test(
    'default file is dedicated and never creates or adopts the legacy catalogue',
    () async {
      final factory = databaseFactoryFfi;
      final original = await factory.getDatabasesPath();
      try {
        await factory.setDatabasesPath(directory.path);
        final store = await IlmsCirculationJournal.open(factory: factory);
        journals.add(store);
        expect(
          await File(path.join(directory.path, 'ilms_circulation.db')).exists(),
          true,
        );
        expect(
          await File(path.join(directory.path, 'biblio_rfid.db')).exists(),
          false,
        );
      } finally {
        await factory.setDatabasesPath(original);
      }
    },
  );
  test(
    'uses marked schema, WAL and full durability without auto-migrating a database',
    () async {
      final db = await raw();
      try {
        expect(
          (await db.rawQuery('PRAGMA application_id')).single['application_id'],
          0x494c4d53,
        );
        expect(
          (await db.rawQuery('PRAGMA user_version')).single['user_version'],
          1,
        );
        expect(
          (await db.rawQuery('PRAGMA journal_mode')).single['journal_mode'],
          'wal',
        );
      } finally {
        await db.close();
      }
    },
  );
  test(
    'rejects a legacy database without changing its rows, version, owner or journal mode',
    () async {
      final legacyFile = path.join(directory.path, 'legacy.db');
      var db = await raw(legacyFile);
      await db.execute(
        'CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT)',
      );
      await db.rawInsert('INSERT INTO books VALUES (1, ?)', ['Keep this book']);
      await db.execute('PRAGMA user_version = 11');
      final mode = (await db.rawQuery(
        'PRAGMA journal_mode',
      )).single['journal_mode'];
      await db.close();
      await expectLater(open(legacyFile), throwsA(error('storage')));
      db = await raw(legacyFile);
      try {
        expect((await db.query('books')).single['title'], 'Keep this book');
        expect(
          (await db.rawQuery('PRAGMA application_id')).single['application_id'],
          0,
        );
        expect(
          (await db.rawQuery('PRAGMA user_version')).single['user_version'],
          11,
        );
        expect(
          (await db.rawQuery('PRAGMA journal_mode')).single['journal_mode'],
          mode,
        );
        expect(
          (await db.rawQuery(
            "SELECT count(*) AS count FROM sqlite_master WHERE type='table'",
          )).single['count'],
          1,
        );
      } finally {
        await db.close();
      }
    },
  );
  test(
    'rejects unknown versions, owners, unowned views and non-durable paths',
    () async {
      for (final setup in [
        'PRAGMA user_version = 2',
        'PRAGMA application_id = 42',
      ]) {
        final target = path.join(
          directory.path,
          '${newIlmsCirculationId()}.db',
        );
        final store = await open(target);
        await close(store);
        final db = await raw(target);
        await db.execute(setup);
        await db.close();
        await expectLater(open(target), throwsA(error('storage')));
      }
      final target = path.join(directory.path, 'unowned-view.db');
      final db = await raw(target);
      await db.execute('CREATE VIEW preserved AS SELECT 1');
      await db.close();
      await expectLater(open(target), throwsA(error('storage')));
      await expectLater(open(inMemoryDatabasePath), throwsA(error('storage')));
      await expectLater(open(''), throwsA(error('storage')));
    },
  );
  test(
    'Android metadata names alone never exempt an unowned Windows database',
    () async {
      for (final schema in [
        'CREATE TABLE android_metadata(locale TEXT)',
        'CREATE TABLE android_metadata(private TEXT)',
        'CREATE VIEW android_metadata AS SELECT 1 AS locale',
      ]) {
        final target = path.join(
          directory.path,
          '${newIlmsCirculationId()}.db',
        );
        final db = await raw(target);
        await db.execute(schema);
        await db.close();
        await expectLater(open(target), throwsA(error('storage')));
        final preserved = await raw(target);
        try {
          expect(
            (await preserved.rawQuery(
              'PRAGMA application_id',
            )).single['application_id'],
            0,
          );
          expect(
            (await preserved.rawQuery(
              'PRAGMA user_version',
            )).single['user_version'],
            0,
          );
          expect(
            (await preserved.rawQuery(
              "SELECT count(*) AS count FROM sqlite_master WHERE name = 'operations'",
            )).single['count'],
            0,
          );
        } finally {
          await preserved.close();
        }
      }
    },
  );
  test(
    'stores only the canonical shared intent, with no HTTP, names, tokens or error bodies',
    () async {
      var calls = 0;
      final service = use(
        client: MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      current = session(token: '');
      final source = ((fixture['operations'] as List)[0] as Map)['input'];
      final entry = await service.enqueue(source);
      expect(calls, 0);
      expect(entry['attempts'], 0);
      expect(entry['payload'], payload());
      final db = await raw();
      try {
        final saved = (await db.query('operations')).single;
        final serialized = jsonEncode(saved);
        for (final forbidden in [
          'not-persisted',
          'fake.jwt.token',
          'Lecteur Test',
          'MEM-42',
        ]) {
          expect(serialized.contains(forbidden), false);
        }
        final signaturePayload = {...payload()}..remove('operation_id');
        expect(
          saved['signature'],
          sha256
              .convert(
                utf8.encode(
                  jsonEncode({'kind': 'checkout', 'payload': signaturePayload}),
                ),
              )
              .toString(),
        );
        expect(entry.containsKey('signature'), false);
      } finally {
        await db.close();
      }
    },
  );
  test(
    'identical pending intent keeps the original UUID, but changed identities are distinct',
    () async {
      final first = await journal.enqueue(getScope(), operation());
      final changed = payload()..['operation_id'] = newIlmsCirculationId();
      expect(
        (await journal.enqueue(getScope(), {
          'kind': 'checkout',
          'payload': changed,
        }))['id'],
        first['id'],
      );
      changed['expected_card_id'] = newIlmsCirculationId();
      expect(
        (await journal.enqueue(getScope(), {
          'kind': 'checkout',
          'payload': changed,
        }))['id'],
        isNot(first['id']),
      );
      expect((await journal.list(getScope())).length, 2);
    },
  );
  test('cannot overwrite a UUID with a different intent', () async {
    final first = await journal.enqueue(getScope(), operation());
    final changed = payload()..['copy'] = {'epc': 'AA00'};
    await expectLater(
      journal.enqueue(getScope(), {'kind': 'checkout', 'payload': changed}),
      throwsA(error('storage')),
    );
    expect(await journal.list(getScope()), [first]);
  });
  test(
    'gateway, account and library scopes remain isolated across reopen',
    () async {
      final service = use();
      final original = current;
      final first = await service.enqueue(operation());
      await close(journal);
      journal = await open();
      final reopened = use();
      for (final next in [
        session(gateway: 'https://another.test'),
        session(account: newIlmsCirculationId()),
        session(library: newIlmsCirculationId()),
      ]) {
        current = next;
        expect(await reopened.list(), isEmpty);
        await expectLater(
          reopened.discard(first['id'] as String, confirmed: true),
          throwsA(error('scope')),
        );
      }
      current = original;
      expect(await reopened.list(), [first]);
    },
  );
  test(
    'capacity survives reopen, never evicts, and concurrent enqueues cannot overfill',
    () async {
      for (var index = 0; index < 99; index++) {
        final input = payload()
          ..['operation_id'] = newIlmsCirculationId()
          ..['copy'] = {'epc': index.toRadixString(16).padLeft(4, '0')};
        await journal.enqueue(getScope(), {
          'kind': 'checkout',
          'payload': input,
        });
      }
      await close(journal);
      journal = await open();
      Future<String> extra(String tag) async {
        try {
          await journal.enqueue(getScope(), {
            'kind': 'checkout',
            'payload': payload()
              ..['operation_id'] = newIlmsCirculationId()
              ..['copy'] = {'epc': tag},
          });
          return 'saved';
        } on IlmsClientException catch (error) {
          return error.code;
        }
      }

      expect(
        await Future.wait([extra('FFAA'), extra('FFBB')]),
        containsAll(['saved', 'capacity']),
      );
      expect((await journal.list(getScope())).length, 100);
      expect((await journal.list(getScope())).first['payload'], isNotNull);
    },
  );
  test(
    'corrupt payloads, metadata and signatures fail closed without erasing the request',
    () async {
      await journal.enqueue(getScope(), {
        'kind': 'checkout',
        'payload': payload()
          ..['operation_id'] = 'abcdefab-cdef-4abc-8abc-abcdefabcdef',
      });
      final db = await raw();
      try {
        final saved = (await db.query('operations')).single;
        for (final change in <Map<String, Object?>>[
          {'payload': '{}'},
          {'signature': 'bad'},
          {'id': (saved['id'] as String).toUpperCase()},
          {'attempts': -1},
          {'last_status': 600},
          {'lease_id': 'bad', 'lease_until': 1},
          {'lease_until': 1},
          {'created_at': 'invalid'},
          {'updated_at': 'invalid'},
        ]) {
          await db.update('operations', change);
          await expectLater(
            journal.list(getScope()),
            throwsA(error('storage')),
          );
          expect((await db.query('operations')).length, 1);
          await db.update('operations', saved);
        }
      } finally {
        await db.close();
      }
    },
  );
  test(
    'two real SQLite connections respect leases, expiry and acknowledgement ownership',
    () async {
      final other = await open();
      final entry = await journal.enqueue(getScope(), operation());
      final id = entry['id'] as String;
      final first = newIlmsCirculationId();
      final second = newIlmsCirculationId();
      await journal.claim(getScope(), id, first);
      await expectLater(
        other.claim(getScope(), id, second),
        throwsA(error('busy')),
      );
      await expectLater(other.remove(getScope(), id), throwsA(error('busy')));
      now = now.add(const Duration(milliseconds: 120001));
      await other.claim(getScope(), id, second);
      await expectLater(
        journal.remove(getScope(), id, lease: first),
        throwsA(error('busy')),
      );
      await expectLater(
        journal.failed(getScope(), id, first, 503),
        throwsA(error('busy')),
      );
      await other.remove(getScope(), id, lease: second);
      expect(await journal.list(getScope()), isEmpty);
    },
  );
  test(
    'invalid IDs, scopes, statuses and lease IDs cannot mutate saved requests',
    () async {
      final entry = await journal.enqueue(getScope(), operation());
      await expectLater(
        journal.claim(getScope(), entry['id'] as String, 'not-a-uuid'),
        throwsA(error('input')),
      );
      await expectLater(
        journal.remove(getScope(), 'bad'),
        throwsA(error('input')),
      );
      await expectLater(journal.list({}), throwsA(error('scope')));
      await expectLater(
        journal.failed(
          getScope(),
          entry['id'] as String,
          newIlmsCirculationId(),
          600,
        ),
        throwsA(error('input')),
      );
      expect(await journal.list(getScope()), [entry]);
    },
  );
  test(
    'durably commits and claims before HTTP, validates the native acknowledgement, then removes',
    () async {
      final service = use(
        client: MockClient((request) async {
          final persisted = await journal.list(getScope());
          expect(persisted.single['attempts'], 1);
          expect(persisted.single['lease_id'], isNotNull);
          final second = await open();
          expect(await second.list(getScope()), persisted);
          expect(jsonDecode(request.body), payload());
          expect(request.headers['X-Device-Key'], null);
          return reply({...loan, 'member_name': 'Not persisted'});
        }),
      );
      final result = await service.checkout(payload());
      expect(result['id'], loan['id']);
      expect(result.containsKey('member_name'), false);
      expect(await service.list(), isEmpty);
    },
  );
  for (final status in [400, 401, 403, 404, 409, 408, 425, 429, 503]) {
    test(
      'HTTP $status retains the exact request and numeric status only',
      () async {
        final service = use(
          client: MockClient(
            (_) async => reply({'message': 'private-secret-body'}, status),
          ),
        );
        await expectLater(
          service.checkout(payload()),
          throwsA(error('denied', status)),
        );
        final entry = (await service.list()).single;
        expect(entry['payload'], payload());
        expect(entry['last_status'], status);
        expect(entry['lease_id'], null);
        expect(
          entry['state'],
          status < 500 && ![408, 425, 429].contains(status)
              ? 'blocked'
              : 'pending',
        );
        expect(jsonEncode(entry).contains('private-secret-body'), false);
      },
    );
  }
  test(
    'malformed or mismatched acknowledgements never clear the journal',
    () async {
      final bad = <Map<String, Object?>>[
        {...loan, 'id': 'bad'},
        {...loan, 'member_id': newIlmsCirculationId()},
        {...loan, 'copy_id': newIlmsCirculationId()},
        {...loan, 'library_id': newIlmsCirculationId()},
        {...loan, 'status': 99},
      ];
      var index = 0;
      final service = use(client: MockClient((_) async => reply(bad[index++])));
      for (final _ in bad) {
        await expectLater(
          service.checkout(payload()),
          throwsA(error('response')),
        );
        expect((await service.list()).single['id'], payload()['operation_id']);
      }
    },
  );
  test(
    'return replay keeps the original loan ID and needs no card or newly discovered loan',
    () async {
      final sent = <Object?>[];
      var wrong = true;
      final service = use(
        client: MockClient((request) async {
          sent.add(jsonDecode(request.body));
          return reply({
            ...loan,
            'id': wrong ? newIlmsCirculationId() : loan['id'],
            'status': 2,
          }, 200);
        }),
      );
      await expectLater(
        service.returnCopy(payload(1)),
        throwsA(error('response')),
      );
      final entry = (await service.list()).single;
      expect((entry['payload'] as Map).containsKey('card'), false);
      await close(journal);
      journal = await open();
      wrong = false;
      final reopened = use(
        client: MockClient((request) async {
          sent.add(jsonDecode(request.body));
          return reply({...loan, 'status': 2}, 200);
        }),
      );
      await reopened.retry(entry['id'] as String);
      expect(sent, [payload(1), payload(1)]);
      expect(await reopened.list(), isEmpty);
    },
  );
  test(
    'missing token saves offline without claim, HTTP or automatic replay after token returns',
    () async {
      var calls = 0;
      final service = use(
        client: MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      current = session(token: '');
      await expectLater(
        service.checkout(payload()),
        throwsA(error('auth', 401)),
      );
      final entry = (await service.list()).single;
      expect(entry['attempts'], 0);
      expect(calls, 0);
      current = session();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 0);
      await service.retry(entry['id'] as String);
      expect(calls, 1);
      expect(await service.list(), isEmpty);
    },
  );
  for (final change in ['account', 'library', 'gateway', 'logout']) {
    test(
      'late response after $change cannot acknowledge or expose another context',
      () async {
        final original = current;
        final service = use(
          client: MockClient((_) async {
            current = switch (change) {
              'account' => session(account: newIlmsCirculationId()),
              'library' => session(library: newIlmsCirculationId()),
              'gateway' => session(gateway: 'https://another.test'),
              _ => null,
            };
            return reply(loan);
          }),
        );
        await expectLater(service.checkout(payload()), throwsA(error('scope')));
        current = original;
        final entry = (await service.list()).single;
        expect(entry['lease_id'], null);
        expect(entry['payload'], payload());
      },
    );
  }
  test(
    'scope changes during local persistence retain the old intent without exposing it',
    () async {
      final service = use();
      final original = current;
      final saving = service.enqueue(operation());
      current = session(account: newIlmsCirculationId());
      await expectLater(saving, throwsA(error('scope')));
      expect(await service.list(), isEmpty);
      current = original;
      expect((await service.list()).single['payload'], payload());
    },
  );
  test(
    'scope changes during a local listing cannot expose the old account data',
    () async {
      final service = use();
      await service.enqueue(operation());
      final listing = service.list();
      current = null;
      await expectLater(listing, throwsA(error('scope')));
    },
  );
  test(
    'scope changes during claim release the lease without making an HTTP call',
    () async {
      var calls = 0;
      final service = use(
        client: MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      final entry = await service.enqueue(operation());
      final original = current;
      final sending = service.retry(entry['id'] as String);
      current = null;
      await expectLater(sending, throwsA(error('scope')));
      current = original;
      final saved = (await service.list()).single;
      expect(saved['lease_id'], null);
      expect(saved['attempts'], 1);
      expect(calls, 0);
    },
  );
  test(
    'a second service cannot replay or locally discard an in-flight intent',
    () async {
      final ready = Completer<void>();
      final response = Completer<http.Response>();
      final first = use(
        client: MockClient((_) {
          ready.complete();
          return response.future;
        }),
      );
      final second = use(store: await open());
      final entry = await first.enqueue(operation());
      final sending = first.retry(entry['id'] as String);
      await ready.future;
      try {
        await expectLater(
          second.retry(entry['id'] as String),
          throwsA(error('busy')),
        );
        await expectLater(
          second.discard(entry['id'] as String, confirmed: true),
          throwsA(error('busy')),
        );
      } finally {
        response.complete(reply(loan));
      }
      await sending;
      expect(await first.list(), isEmpty);
    },
  );
  test(
    'timeout releases the lease while retaining the original content for explicit recovery',
    () async {
      final service = use(
        timeout: const Duration(milliseconds: 20),
        client: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(service.checkout(payload()), throwsA(error('network')));
      final entry = (await service.list()).single;
      expect(entry['id'], payload()['operation_id']);
      expect(entry['lease_id'], null);
      expect(entry['last_status'], 0);
    },
  );
  test('local token loss does not record a fictional HTTP refusal', () async {
    var calls = 0;
    final service = use(
      client: MockClient((_) async {
        if (calls++ == 0) current = session(token: '');
        return reply(loan);
      }),
    );
    await expectLater(service.checkout(payload()), throwsA(error('auth', 401)));
    final entry = (await service.list()).single;
    expect(entry['state'], 'pending');
    expect(entry['last_status'], 0);
    expect(entry['lease_id'], null);
    current = session();
    await service.retry(entry['id'] as String);
    expect(await service.list(), isEmpty);
  });
  test(
    'local acknowledgement failure survives reopen and lease expiry, without pretending success',
    () async {
      final service = use(
        client: MockClient((_) async {
          await close(journal);
          return reply(loan);
        }),
      );
      await expectLater(service.checkout(payload()), throwsA(error('storage')));
      now = now.add(const Duration(milliseconds: 120001));
      journal = await open();
      final reopened = use();
      final entry = (await reopened.list()).single;
      expect(entry['payload'], payload());
      await reopened.retry(entry['id'] as String);
      expect(await reopened.list(), isEmpty);
    },
  );
  test(
    'discard requires confirmation, affects only local storage and does no HTTP',
    () async {
      var calls = 0;
      final service = use(
        client: MockClient((_) async {
          calls++;
          return reply(loan);
        }),
      );
      final entry = await service.enqueue(operation(1));
      await expectLater(
        service.discard(entry['id'] as String, confirmed: false),
        throwsA(error('input')),
      );
      expect((await service.list()).length, 1);
      await service.discard(entry['id'] as String, confirmed: true);
      expect(await service.list(), isEmpty);
      expect(calls, 0);
    },
  );
  test(
    'closing the session aborts its request, preserves the journal and prevents new commands',
    () async {
      late IlmsCirculationSync service;
      service = use(
        client: MockClient((_) async {
          service.close();
          return reply(loan);
        }),
      );
      await expectLater(
        service.checkout(payload()),
        throwsA(error('auth', 401)),
      );
      expect((await journal.list(getScope())).length, 1);
      await expectLater(service.enqueue(operation()), throwsA(error('auth')));
      await expectLater(service.list(), throwsA(error('auth')));
    },
  );
  test(
    'online lookups use the native transport but never create pending business operations',
    () async {
      final service = use(
        client: MockClient(
          (request) async => reply(
            request.url.path.endsWith('members/resolve')
                ? fixture['member']
                : fixture['copy'],
            200,
          ),
        ),
      );
      expect(
        (await service.resolveMember({'epc': 'AA12'}))['member_id'],
        (fixture['member'] as Map)['member_id'],
      );
      expect(
        ((await service.resolveCopy({'tid': 'BB34'}))['copy'] as Map)['id'],
        ((fixture['copy'] as Map)['copy'] as Map)['id'],
      );
      expect(await service.list(), isEmpty);
    },
  );
  test(
    'real HTTP retry after app-style reopen sends the original native intent and never follows redirects',
    () async {
      var fail = true;
      var redirect = false;
      var foreignCalls = 0;
      final requests = <Map<String, Object?>>[];
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
        request.response.headers.contentType = ContentType.json;
        if (redirect) {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${destination.port}/stolen',
          );
        } else {
          request.response.statusCode = fail ? 503 : 201;
          request.response.write(
            jsonEncode(fail ? {'message': 'Uncertain'} : loan),
          );
        }
        await request.response.close();
      });
      current = session(gateway: 'http://127.0.0.1:${gateway.port}');
      var service = IlmsCirculationSync(
        journal: journal,
        getSession: () => current,
      );
      services.add(service);
      try {
        await expectLater(
          service.checkout(payload()),
          throwsA(error('denied', 503)),
        );
        final entry = (await service.list()).single;
        service.close();
        await close(journal);
        journal = await open();
        service = IlmsCirculationSync(
          journal: journal,
          getSession: () => current,
        );
        services.add(service);
        expect((await service.list()).single['id'], entry['id']);
        expect(requests.length, 1);
        fail = false;
        await service.retry(entry['id'] as String);
        expect(requests[0], requests[1]);
        expect(requests[0]['legacyKey'], null);
        expect(await service.list(), isEmpty);
        redirect = true;
        await expectLater(
          service.checkout(payload()),
          throwsA(error('denied', 302)),
        );
        expect(foreignCalls, 0);
        expect((await service.list()).length, 1);
        expect(
          requests.every(
            (request) => (request['path'] as String).endsWith(
              '/circulation/rfid/checkouts',
            ),
          ),
          true,
        );
      } finally {
        service.close();
        await gateway.close(force: true);
        await destination.close(force: true);
        await listener.cancel();
        await foreign.cancel();
      }
    },
  );
}
