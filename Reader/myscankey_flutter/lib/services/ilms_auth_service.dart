import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ilms_circulation_client.dart';

class IlmsLibrary {
  const IlmsLibrary(this.id, this.name);
  final String id;
  final String name;
}

enum IlmsAuthStage { oauth, user, libraries }

enum IlmsAuthRedirect { missing, login, sameGateway, otherOrigin, unsafe }

class IlmsAuthHttpException extends IlmsClientException {
  const IlmsAuthHttpException(this.stage, int status, {this.redirect})
    : super('denied', status);
  final IlmsAuthStage stage;
  final IlmsAuthRedirect? redirect;
}

IlmsAuthRedirect _redirectKind(Uri request, String? location) {
  if (location == null || location.isEmpty) return IlmsAuthRedirect.missing;
  if (location.length > 4096 || RegExp(r'[\x00-\x20\x7f]').hasMatch(location)) {
    return IlmsAuthRedirect.unsafe;
  }
  try {
    final target = request.resolve(location);
    if (!target.hasAuthority ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        !['http', 'https'].contains(target.scheme) ||
        (request.scheme == 'https' && target.scheme != 'https')) {
      return IlmsAuthRedirect.unsafe;
    }
    if (target.origin != request.origin) return IlmsAuthRedirect.otherOrigin;
    if (const {
      '/login',
      '/auth/login',
      '/auth-service/login',
      '/auth-service/api/v1/auth/login',
      '/auth-service/oauth/authorize',
      '/oauth/authorize',
    }.contains(target.path)) {
      return IlmsAuthRedirect.login;
    }
    return IlmsAuthRedirect.sameGateway;
  } catch (_) {
    return IlmsAuthRedirect.unsafe;
  }
}

/// Native login contract from the ILMS portal. Credentials are never persisted.
/// The OAuth client is a deployment setting, supplied by the caller from a
/// build default or the login form; the portal ships the same pair publicly.
/// Direct gateway routes omit the portal proxy's local /api prefix.
class IlmsAuthService extends ChangeNotifier {
  IlmsAuthService({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      throw const IlmsClientException('input');
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final DateTime Function() _now;
  final Set<Completer<void>> _active = {};
  int _generation = 0;
  bool _closed = false;
  String? _gateway;
  String? _accountId;
  String? _token;
  DateTime? _expiresAt;
  String? _libraryId;
  List<IlmsLibrary> _libraries = const [];

  List<IlmsLibrary> get libraries => _libraries;
  bool get signedIn => !_closed && _accountId != null;
  IlmsSession? get session {
    if (!signedIn || _libraryId == null) return null;
    return IlmsSession(
      gatewayUrl: _gateway!,
      accountId: _accountId!,
      libraryId: _libraryId!,
      accessToken: _expiresAt!.isAfter(_now()) ? _token! : '',
    );
  }

  void _check(int generation) {
    if (_closed || generation != _generation) {
      throw const IlmsClientException('scope');
    }
  }

  void _cancel() {
    _generation++;
    for (final abort in _active) {
      if (!abort.isCompleted) abort.complete();
    }
    _gateway = _accountId = _token = _libraryId = null;
    _expiresAt = null;
    _libraries = const [];
  }

  void logout() {
    if (_closed) return;
    _cancel();
    notifyListeners();
  }

  void selectLibrary(String id) {
    if (!signedIn || !_libraries.any((library) => library.id == id)) {
      throw const IlmsClientException('scope');
    }
    if (_libraryId == id) return;
    _libraryId = id;
    notifyListeners();
  }

  Future<void> signIn({
    required String gatewayUrl,
    required String username,
    required String password,
    required String clientId,
    required String clientSecret,
  }) async {
    if (_closed) throw const IlmsClientException('auth', 401);
    _cancel();
    notifyListeners();
    final generation = _generation;
    const placeholder = '00000000-0000-0000-0000-000000000000';
    final gateway = normalizeIlmsScope(
      IlmsSession(
        gatewayUrl: gatewayUrl,
        accountId: placeholder,
        libraryId: placeholder,
        accessToken: '',
      ),
    )['gateway_url']!;
    if (username.trim().isEmpty ||
        username.length > 255 ||
        password.isEmpty ||
        password.length > 4096 ||
        clientId.isEmpty ||
        clientId.length > 255 ||
        clientSecret.isEmpty ||
        clientSecret.length > 4096 ||
        clientId.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(clientId)) {
      throw const IlmsClientException('input');
    }
    final oauth = _object(
      await _request(
        generation,
        gateway,
        'POST',
        '/auth-service/oauth/token',
        stage: IlmsAuthStage.oauth,
        authorization:
            'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
        contentType: 'application/x-www-form-urlencoded',
        body: 'grant_type=client_credentials&scope=read+write',
      ),
    );
    if (oauth['token_type'] is! String ||
        (oauth['token_type'] as String).toLowerCase() != 'bearer' ||
        oauth['expires_in'] is! int ||
        (oauth['expires_in'] as int) <= 0) {
      throw const IlmsClientException('response');
    }
    final bootstrap = _bearer(oauth['access_token']);
    final response = _object(
      await _request(
        generation,
        gateway,
        'POST',
        '/auth-service/api/v1/auth/login',
        stage: IlmsAuthStage.user,
        authorization: 'Bearer $bootstrap',
        body: jsonEncode({'username': username.trim(), 'password': password}),
      ),
    );
    final access = _object(response['access_token']);
    if (access['type'] == 'Password-Token') {
      throw const IlmsClientException('password_change');
    }
    if (access['type'] != 'Bearer') {
      throw const IlmsClientException('response');
    }
    final user = _object(response['user']);
    if (user['password_change_required'] == true) {
      throw const IlmsClientException('password_change');
    }
    final accountId = normalizeIlmsUuid(user['id'], 'response');
    final token = _bearer(access['token']);
    final expiresAt = _expiry(token);
    final rawLibraries = await _request(
      generation,
      gateway,
      'GET',
      '/library-service/api/v1/libraries',
      stage: IlmsAuthStage.libraries,
      authorization: 'Bearer $token',
    );
    if (rawLibraries is! List || rawLibraries.length > 1000) {
      throw const IlmsClientException('response');
    }
    final libraries = <IlmsLibrary>[];
    final ids = <String>{};
    for (final raw in rawLibraries) {
      final library = _object(raw);
      final id = normalizeIlmsUuid(library['id'], 'response');
      final name = library['name'];
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 255 ||
          !ids.add(id)) {
        throw const IlmsClientException('response');
      }
      libraries.add(IlmsLibrary(id, name));
    }
    _check(generation);
    if (!expiresAt.isAfter(_now())) {
      throw const IlmsClientException('auth', 401);
    }
    if (libraries.isEmpty) throw const IlmsClientException('no_library');
    _gateway = gateway;
    _accountId = accountId;
    _token = token;
    _expiresAt = expiresAt;
    _libraries = List.unmodifiable(libraries);
    // The server list is not an RFID grant: every business call remains scoped
    // and server-authorized. No synthetic "all libraries" scope is permitted.
    _libraryId = libraries.length == 1 ? libraries.single.id : null;
    notifyListeners();
  }

  String _bearer(Object? value) {
    if (value is! String ||
        value.length > 8192 ||
        !RegExp(r'^[A-Za-z0-9._~+/\-]+=*$').hasMatch(value)) {
      throw const IlmsClientException('response');
    }
    return value;
  }

  DateTime _expiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
        throw const FormatException();
      }
      final claims = _object(
        jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        ),
      );
      final exp = claims['exp'];
      if (exp is! int || exp <= 0 || exp > 8640000000000) {
        throw const FormatException();
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        exp * 1000,
        isUtc: true,
      );
      if (!expiry.isAfter(_now())) throw const IlmsClientException('auth', 401);
      return expiry;
    } on IlmsClientException {
      rethrow;
    } catch (_) {
      throw const IlmsClientException('response');
    }
  }

  Map<String, Object?> _object(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const IlmsClientException('response');
    }
    return value.cast<String, Object?>();
  }

  Future<Object?> _request(
    int generation,
    String gateway,
    String method,
    String route, {
    required IlmsAuthStage stage,
    required String authorization,
    String contentType = 'application/json',
    String? body,
  }) async {
    _check(generation);
    final abort = Completer<void>();
    _active.add(abort);
    Future<Object?> perform() async {
      final request = http.AbortableRequest(
        method,
        Uri.parse('$gateway$route'),
        abortTrigger: abort.future,
      )..followRedirects = false;
      request.headers.addAll({
        'Authorization': authorization,
        'Accept': 'application/json',
        if (body != null) 'Content-Type': contentType,
      });
      if (body != null) request.body = body;
      final response = await _client.send(request);
      _check(generation);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Keep only an enum, never the Location URL, response body or credentials.
        throw IlmsAuthHttpException(
          stage,
          response.statusCode,
          redirect: response.statusCode >= 300 && response.statusCode < 400
              ? _redirectKind(request.url, response.headers['location'])
              : null,
        );
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
        if (bytes.length + chunk.length > 1048576) {
          throw const IlmsClientException('response');
        }
        bytes.addAll(chunk);
      }
      _check(generation);
      try {
        return jsonDecode(utf8.decode(bytes));
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

  @override
  void dispose() {
    _cancel();
    _closed = true;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
