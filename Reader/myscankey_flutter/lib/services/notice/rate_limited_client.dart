import 'dart:async';

import 'package:http/http.dart' as http;

import 'notice_lookup_service.dart';

/// Sérialise les requêtes par hôte, y compris les appels ISBN→PPN→XML SUDOC.
/// Les files sont partagées entre reprises d'import pour conserver l'espacement.
class NoticeRateLimitedClient extends http.BaseClient {
  NoticeRateLimitedClient({
    http.Client? inner,
    this.isCancelled,
    this.minimumInterval = const Duration(milliseconds: 300),
  }) : _inner = inner ?? http.Client() {
    if (minimumInterval < const Duration(milliseconds: 300)) {
      throw ArgumentError('Intervalle minimal : 300 ms.');
    }
  }
  final http.Client _inner;
  final bool Function()? isCancelled;
  final Duration minimumInterval;
  static final _tails = <String, Future<void>>{};
  static final _lastRequest = <String, DateTime>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final previous = _tails[host] ?? Future<void>.value();
    final release = Completer<void>();
    _tails[host] = release.future;
    try {
      await previous;
      void check() {
        if (_closed || isCancelled?.call() == true) {
          throw const NoticeLookupCancelledException();
        }
      }

      check();
      final last = _lastRequest[host];
      if (last != null) {
        final remaining = minimumInterval - DateTime.now().difference(last);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      check();
      try {
        return await _inner.send(request);
      } finally {
        _lastRequest[host] = DateTime.now();
      }
    } finally {
      release.complete();
    }
  }

  @override
  void close() {
    _closed = true;
    _inner.close();
  }
}
