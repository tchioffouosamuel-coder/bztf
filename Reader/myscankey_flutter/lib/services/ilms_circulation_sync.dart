import 'package:http/http.dart' as http;

import '../data/ilms_circulation_journal.dart';
import 'ilms_circulation_client.dart';

/// Explicit write-ahead circulation, independent of the legacy Render sync.
class IlmsCirculationSync {
  IlmsCirculationSync({
    required this.journal,
    required this.getSession,
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) : _transport = IlmsCirculationClient(
         getSession: getSession,
         client: client,
         timeout: timeout,
       );

  final IlmsCirculationJournal journal;
  final IlmsSession? Function() getSession;
  final IlmsCirculationClient _transport;
  bool _closed = false;

  Map<String, String> get _scope {
    if (_closed) throw const IlmsClientException('auth', 401);
    return normalizeIlmsScope(getSession());
  }

  void _checkLocalScope(Map<String, String> expected) {
    final current = _scope;
    if (expected.keys.any((key) => expected[key] != current[key])) {
      throw const IlmsClientException('scope');
    }
  }

  Future<List<Map<String, Object?>>> list() async {
    final scope = _scope;
    final entries = await journal.list(scope);
    _checkLocalScope(scope);
    return entries;
  }

  Future<Map<String, Object?>> enqueue(Object? input) async {
    final scope = _scope;
    final entry = await journal.enqueue(scope, input);
    _checkLocalScope(scope);
    return entry;
  }

  Future<void> discard(String id, {required bool confirmed}) async {
    if (!confirmed) throw const IlmsClientException('input');
    final scope = _scope;
    await journal.remove(scope, id);
    _checkLocalScope(scope);
  }

  Future<Map<String, Object?>> checkout(Map<String, Object?> payload) async {
    final entry = await enqueue({'kind': 'checkout', 'payload': payload});
    return retry(entry['id'] as String);
  }

  Future<Map<String, Object?>> returnCopy(Map<String, Object?> payload) async {
    final entry = await enqueue({'kind': 'return', 'payload': payload});
    return retry(entry['id'] as String);
  }

  Future<Map<String, Object?>> retry(String id) async {
    final scope = _scope;
    _transport.checkSession(scope);
    final lease = newIlmsCirculationId();
    final entry = await journal.claim(scope, id, lease);
    var acknowledged = false;
    try {
      _transport.checkSession(scope);
      final loan = await _transport.send({
        'kind': entry['kind'],
        'payload': entry['payload'],
      });
      _transport.checkSession(scope);
      await journal.remove(scope, entry['id'] as String, lease: lease);
      acknowledged = true;
      _checkLocalScope(scope);
      return loan;
    } catch (error) {
      final safe = error is IlmsClientException
          ? error
          : const IlmsClientException('network');
      if (!acknowledged) {
        await journal.failed(
          scope,
          entry['id'] as String,
          lease,
          safe.code == 'denied' ? safe.status : 0,
        );
      }
      throw safe;
    }
  }

  Future<Map<String, Object?>> resolveMember(Object? tag) {
    _transport.checkSession(_scope);
    return _transport.resolveMember(tag);
  }

  Future<Map<String, Object?>> resolveCopy(Object? tag) {
    _transport.checkSession(_scope);
    return _transport.resolveCopy(tag);
  }

  /// The journal belongs to the caller and survives closing this session.
  void close() {
    _closed = true;
    _transport.close();
  }
}
