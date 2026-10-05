import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/services/notice/notice_lookup_service.dart';
import 'package:myscankey_flutter/services/notice/notice_source.dart';

void main() {
  test('annulation : aucune source suivante ni écriture en cache', () async {
    var cancelled = false;
    var nextCalled = false;
    final cache = _MemoryCache();
    final service = NoticeLookupService(
      sources: [
        _CallbackSource(() {
          cancelled = true;
          return [
            const NoticeResult(title: 'Réponse tardive', sourceNotice: 'BnF'),
          ];
        }),
        _CallbackSource(() {
          nextCalled = true;
          return [];
        }),
      ],
      localLookup: (_) async => [],
      cache: cache,
    );
    await expectLater(
      service.lookup('9782070360024', isCancelled: () => cancelled),
      throwsA(isA<NoticeLookupCancelledException>()),
    );
    expect(nextCalled, isFalse);
    expect(await cache.read('9782070360024'), isEmpty);
  });

  test('replie vers la source suivante quand une source est vide', () async {
    final service = _service([
      _FakeSource('BnF', const []),
      _FakeSource('SUDOC', [
        const NoticeResult(title: 'Notice', sourceNotice: 'SUDOC'),
      ]),
    ]);

    final results = await service.lookup('9782070360024');

    expect(results.single.title, 'Notice');
  });

  test('ignore un timeout et continue avec la source suivante', () async {
    final service = _service([
      _SlowSource(),
      _FakeSource('Open Library', [
        const NoticeResult(
          title: 'Après timeout',
          sourceNotice: 'Open Library',
        ),
      ]),
    ], timeout: const Duration(milliseconds: 10));

    final results = await service.lookup('9782070360024');

    expect(results.single.title, 'Après timeout');
  });

  test('distingue une réponse vide de sources toutes injoignables', () async {
    final empty = _service([_FakeSource('BnF', const [])]);
    await expectLater(
      empty.lookup('9782070360024'),
      throwsA(isA<NoticeNotFoundException>()),
    );

    final networkDown = _service([
      _ThrowingSource(http.ClientException('offline')),
      _ThrowingSource(const NoticeSourceUnavailableException('quota')),
    ]);
    await expectLater(
      networkDown.lookup('9782070360024'),
      throwsA(isA<NoticeNetworkException>()),
    );
  });

  test(
    'renvoie tous les résultats exploitables de la première source trouvée',
    () async {
      final service = _service([
        _FakeSource('SUDOC', const [
          NoticeResult(title: 'Premier', sourceNotice: 'SUDOC'),
          NoticeResult(title: 'Second', sourceNotice: 'SUDOC'),
        ]),
        _FakeSource('Open Library', const [
          NoticeResult(title: 'Ignoré', sourceNotice: 'Open Library'),
        ]),
      ]);

      final results = await service.lookup('9782070360024');

      expect(results.map((result) => result.title), ['Premier', 'Second']);
    },
  );

  test('détecte un doublon local sans appeler les sources', () async {
    var called = false;
    final service = NoticeLookupService(
      sources: [
        _CallbackSource(() {
          called = true;
          return const [];
        }),
      ],
      localLookup: (_) async => [_book],
      cache: _MemoryCache(),
    );

    final results = await service.lookup('9782070360024');

    expect(called, isFalse);
    expect(results.single.dejaAuCatalogue, isTrue);
    expect(results.single.sourceNotice, 'déjà au catalogue');
    expect(results.single.livresCatalogue.single.id, _book.id);
  });

  test('refuse un ISBN invalide sans appel réseau', () async {
    var called = false;
    final service = NoticeLookupService(
      sources: [
        _CallbackSource(() {
          called = true;
          return const [];
        }),
      ],
      localLookup: (_) async => const [],
      cache: _MemoryCache(),
    );

    await expectLater(
      service.lookup('9782070360025'),
      throwsA(isA<NoticeLookupException>()),
    );
    expect(called, isFalse);
  });
}

NoticeLookupService _service(
  List<NoticeSource> sources, {
  Duration timeout = const Duration(seconds: 5),
}) => NoticeLookupService(
  sources: sources,
  localLookup: (_) async => const [],
  cache: _MemoryCache(),
  timeoutPerSource: timeout,
);

const _book = Book(
  id: 1,
  accession: 'BCM-2026-000001',
  epc: '110002010010012003000001',
  title: 'Livre local',
  isbn: '978-2-07-036002-4',
  status: 'a_encoder',
  createdAt: '2026-10-05T00:00:00Z',
  updatedAt: '2026-10-05T00:00:00Z',
);

class _FakeSource implements NoticeSource {
  const _FakeSource(this.name, this.results);

  @override
  final String name;
  final List<NoticeResult> results;

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async => results;
}

class _SlowSource implements NoticeSource {
  @override
  String get name => 'Lent';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return const [];
  }
}

class _ThrowingSource implements NoticeSource {
  const _ThrowingSource(this.error);

  final Object error;

  @override
  String get name => 'Erreur';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) => Future.error(error);
}

class _CallbackSource implements NoticeSource {
  const _CallbackSource(this.callback);

  final List<NoticeResult> Function() callback;

  @override
  String get name => 'Callback';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async => callback();
}

class _MemoryCache implements NoticeLookupCache {
  final Map<String, List<NoticeResult>> _values = {};

  @override
  Future<List<NoticeResult>> read(String isbn13) async =>
      _values[isbn13] ?? const [];

  @override
  Future<void> write(String isbn13, List<NoticeResult> results) async {
    _values[isbn13] = results;
  }
}
