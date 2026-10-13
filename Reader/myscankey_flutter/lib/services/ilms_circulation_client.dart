import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class IlmsClientException implements Exception {
  const IlmsClientException(this.code, [this.status = 0]);
  final String code;
  final int status;
  @override
  String toString() => 'ILMS : $code ($status)';
}

/// Supplied by the native ILMS session, never by the legacy device-key settings.
class IlmsSession {
  const IlmsSession({
    required this.gatewayUrl,
    required this.accountId,
    required this.libraryId,
    required this.accessToken,
  });
  final String gatewayUrl;
  final String accountId;
  final String libraryId;
  final String accessToken;
}

String _nativeUuid(Object? value, [String code = 'input']) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw IlmsClientException(code);
  }
  return value.toLowerCase();
}

String normalizeIlmsUuid(Object? value, [String code = 'input']) =>
    _nativeUuid(value, code);

Map<String, String> normalizeIlmsScope(IlmsSession? session) {
  if (session == null) throw const IlmsClientException('scope');
  final url = Uri.tryParse(session.gatewayUrl.trim());
  final local = ['localhost', '127.0.0.1', '::1'].contains(url?.host);
  if (url == null ||
      !url.hasAuthority ||
      url.host.isEmpty ||
      (url.scheme != 'https' && !(url.scheme == 'http' && local)) ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment ||
      (url.path.isNotEmpty && url.path != '/') ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(session.gatewayUrl.trim())) {
    throw const IlmsClientException('scope');
  }
  return {
    'gateway_url': url.origin,
    'account_id': _nativeUuid(session.accountId, 'scope'),
    'library_id': _nativeUuid(session.libraryId, 'scope'),
  };
}

Map<String, Object?> _map(Object? value, [String code = 'input']) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw IlmsClientException(code);
  }
  return value.cast<String, Object?>();
}

Map<String, String> normalizeIlmsTag(Object? input) {
  final value = _map(input);
  final result = <String, String>{};
  for (final key in ['epc', 'tid']) {
    final raw = value[key];
    if (raw == null || raw == '') continue;
    if (raw is! String) throw const IlmsClientException('input');
    final normalized = raw.trim().toUpperCase();
    if (normalized.length > 254 ||
        !RegExp(r'^(?:[0-9A-F]{2})+$').hasMatch(normalized)) {
      throw const IlmsClientException('input');
    }
    result[key] = normalized;
  }
  if (result.isEmpty) throw const IlmsClientException('input');
  return result;
}

Map<String, Object?> normalizeIlmsOperation(Object? input) {
  final operation = _map(input);
  final value = _map(operation['payload']);
  if (operation['kind'] == 'return') {
    return {
      'kind': 'return',
      'payload': {
        'copy': normalizeIlmsTag(value['copy']),
        'loan_id': _nativeUuid(value['loan_id']),
      },
    };
  }
  final rawDate = value['preferred_return_date'];
  final date = rawDate is String ? DateTime.tryParse(rawDate) : null;
  if (operation['kind'] != 'checkout' ||
      rawDate is! String ||
      date == null ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(rawDate)) {
    throw const IlmsClientException('input');
  }
  return {
    'kind': 'checkout',
    'payload': {
      'operation_id': _nativeUuid(value['operation_id']),
      'card': normalizeIlmsTag(value['card']),
      'copy': normalizeIlmsTag(value['copy']),
      'preferred_return_date': DateTime.fromMillisecondsSinceEpoch(
        date.millisecondsSinceEpoch,
        isUtc: true,
      ).toIso8601String(),
      'expected_card_id': _nativeUuid(value['expected_card_id']),
      'expected_member_id': _nativeUuid(value['expected_member_id']),
      'expected_copy_id': _nativeUuid(value['expected_copy_id']),
    },
  };
}

Map<String, Object?> _loan(
  Map<String, Object?> value,
  Map<String, String> scope, [
  Map<String, Object?>? operation,
]) {
  final result = <String, Object?>{};
  for (final key in [
    'id',
    'library_id',
    'member_id',
    'copy_id',
    'document_id',
  ]) {
    result[key] = _nativeUuid(value[key], 'response');
  }
  final number = value['number'];
  final status = value['status'];
  if (result['library_id'] != scope['library_id'] ||
      number is! String ||
      number.trim().isEmpty ||
      number.length > 255 ||
      status is! int ||
      status < 0 ||
      status > 8) {
    throw const IlmsClientException('response');
  }
  if (operation != null) {
    final payload = _map(operation['payload']);
    if ((operation['kind'] == 'checkout' &&
            (result['member_id'] != payload['expected_member_id'] ||
                result['copy_id'] != payload['expected_copy_id'])) ||
        (operation['kind'] == 'return' &&
            (result['id'] != payload['loan_id'] || status != 2))) {
      throw const IlmsClientException('response');
    }
  }
  result['number'] = number;
  result['status'] = status;
  for (final key in ['due_date', 'return_date']) {
    final date = value[key];
    if (date != null) {
      if (date is! String || DateTime.tryParse(date) == null) {
        throw const IlmsClientException('response');
      }
      result[key] = date;
    }
  }
  return result;
}

/// Native HTTP transport only. Callers must durably save an intent before send.
/// No timers, legacy catalogue upload, shared preferences or implicit replay.
class IlmsCirculationClient {
  IlmsCirculationClient({
    required this.getSession,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      throw const IlmsClientException('input');
    }
  }
  final IlmsSession? Function() getSession;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Set<Completer<void>> _active = {};
  bool _closed = false;

  Map<String, String> get scope => normalizeIlmsScope(getSession());

  /// Checks the current session without HTTP before/after durable journal work.
  void checkSession(Map<String, String> expected) => _requireScope(expected);

  String _token() {
    final token = getSession()?.accessToken;
    if (_closed ||
        token == null ||
        token.length > 8192 ||
        !RegExp(r'^[A-Za-z0-9._~+/\-]+=*$').hasMatch(token)) {
      throw const IlmsClientException('auth', 401);
    }
    return token;
  }

  void _requireScope(Map<String, String> expected) {
    final current = scope;
    if (expected.keys.any((key) => expected[key] != current[key])) {
      throw const IlmsClientException('scope');
    }
    _token();
  }

  Future<Map<String, Object?>> resolveMember(Object? tag) async {
    final value = await _request(
      scope,
      'members/resolve',
      normalizeIlmsTag(tag),
    );
    final memberId = _nativeUuid(value['member_id'], 'response');
    final cardId = _nativeUuid(value['card_id'], 'response');
    if (value['name'] is! String ||
        value['number'] is! String ||
        value['status'] is! int ||
        value['eligible'] is! bool) {
      throw const IlmsClientException('response');
    }
    return {
      'member_id': memberId,
      'card_id': cardId,
      'name': value['name'],
      'number': value['number'],
      'status': value['status'],
      'eligible': value['eligible'],
      if (value['blocked_reason'] is String)
        'blocked_reason': value['blocked_reason'],
    };
  }

  Future<Map<String, Object?>> resolveCopy(Object? tag) async {
    final expected = scope;
    final value = await _request(
      expected,
      'copies/resolve',
      normalizeIlmsTag(tag),
    );
    final copy = value['copy'];
    if (copy is! Map ||
        copy['number'] is! String ||
        (copy['number'] as String).trim().isEmpty ||
        value['title'] is! String ||
        value['available_for_checkout'] is! bool) {
      throw const IlmsClientException('response');
    }
    final id = _nativeUuid(copy['id'], 'response');
    final documentId = _nativeUuid(copy['document_id'], 'response');
    final active = value['active_loan'] == null
        ? null
        : _loan(_map(value['active_loan'], 'response'), expected);
    if (active != null && active['copy_id'] != id) {
      throw const IlmsClientException('response');
    }
    return {
      'copy': {'id': id, 'document_id': documentId, 'number': copy['number']},
      'title': value['title'],
      'available_for_checkout': value['available_for_checkout'],
      'active_loan': active,
    };
  }

  Future<Map<String, Object?>> send(Object? input) async {
    final expected = scope;
    final operation = normalizeIlmsOperation(input);
    final reply = await _request(
      expected,
      operation['kind'] == 'checkout' ? 'checkouts' : 'returns',
      _map(operation['payload']),
    );
    return _loan(reply, expected, operation);
  }

  Future<Map<String, Object?>> _request(
    Map<String, String> expected,
    String route,
    Map<String, Object?> body,
  ) async {
    _requireScope(expected);
    final abort = Completer<void>();
    _active.add(abort);
    Future<Map<String, Object?>> perform() async {
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse(
                '${expected['gateway_url']}/library-service/api/v1/libraries/${expected['library_id']}/circulation/rfid/$route',
              ),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer ${_token()}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            })
            ..body = jsonEncode(body);
      final response = await _client.send(request);
      _requireScope(expected);
      if (response.statusCode < 100 || response.statusCode > 599) {
        throw const IlmsClientException('response');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!abort.isCompleted) abort.complete();
        throw IlmsClientException('denied', response.statusCode);
      }
      if (response.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/json') {
        throw const IlmsClientException('response');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 65536) {
          throw const IlmsClientException('response');
        }
        bytes.addAll(chunk);
      }
      _requireScope(expected);
      try {
        return _map(jsonDecode(utf8.decode(bytes)));
      } catch (_) {
        throw const IlmsClientException('response');
      }
    }

    try {
      return await perform().timeout(timeout);
    } on IlmsClientException {
      rethrow;
    } catch (_) {
      throw const IlmsClientException('network');
    } finally {
      if (!abort.isCompleted) abort.complete();
      _active.remove(abort);
    }
  }

  void close() {
    _closed = true;
    for (final abort in _active) {
      if (!abort.isCompleted) abort.complete();
    }
    if (_ownsClient) _client.close();
  }
}
