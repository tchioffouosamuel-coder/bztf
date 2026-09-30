import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/library_database.dart';

class SyncService extends ChangeNotifier {
  SyncService(this.database, {http.Client? client})
    : _client = client ?? http.Client();

  final LibraryDatabase database;
  final http.Client _client;
  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _socketSubscription;
  Timer? _retryTimer;
  Timer? _eventDebounce;
  bool _syncing = false;
  bool _disposed = false;

  String serverUrl = '';
  String apiKey = '';
  String deviceId = '';
  String deviceName = '';
  bool connected = false;
  String? error;

  /// Échec du dernier rapport d'appareil (comptes et activité), sans effet
  /// sur la synchronisation du catalogue.
  String? reportError;
  DateTime? lastSyncAt;
  int pendingCount = 0;

  bool get configured => serverUrl.isNotEmpty && apiKey.isNotEmpty;
  bool get syncing => _syncing;

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    serverUrl = preferences.getString('sync_server_url') ?? '';
    apiKey = preferences.getString('sync_api_key') ?? '';
    deviceId = preferences.getString('sync_device_id') ?? '';
    deviceName = preferences.getString('sync_device_name') ?? 'Lecteur RFID';
    if (deviceId.isEmpty) {
      deviceId = _newId();
      await preferences.setString('sync_device_id', deviceId);
    }
    final lastSync = preferences.getString('sync_last_at');
    lastSyncAt = lastSync == null ? null : DateTime.tryParse(lastSync);
    await database.prepareInitialSync();
    pendingCount = await database.pendingMutationCount();
    if (configured) {
      unawaited(syncNow());
      _retryTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(syncNow()),
      );
    }
    notifyListeners();
  }

  Future<void> configure({
    required String nextServerUrl,
    required String nextApiKey,
    required String nextDeviceName,
  }) async {
    serverUrl = nextServerUrl.trim().replaceAll(RegExp(r'/+$'), '');
    apiKey = nextApiKey.trim();
    deviceName = nextDeviceName.trim().isEmpty
        ? 'Lecteur RFID'
        : nextDeviceName.trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('sync_server_url', serverUrl);
    await preferences.setString('sync_api_key', apiKey);
    await preferences.setString('sync_device_name', deviceName);
    await _disconnectSocket();
    _retryTimer?.cancel();
    if (configured) {
      _retryTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(syncNow()),
      );
      await syncNow();
    } else {
      connected = false;
      error = null;
      notifyListeners();
    }
  }

  Future<void> syncNow() async {
    if (!configured || _syncing || _disposed) return;
    _syncing = true;
    error = null;
    notifyListeners();
    try {
      await _registerDevice();
      await _pushPending();
      await _pullAll();
      // Un serveur plus ancien refuse le rapport : le catalogue reste
      // synchronisé.
      try {
        await _sendReport();
        reportError = null;
      } catch (exception) {
        reportError = _friendlyError(exception);
      }
      pendingCount = await database.pendingMutationCount();
      connected = true;
      lastSyncAt = DateTime.now();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'sync_last_at',
        lastSyncAt!.toIso8601String(),
      );
      await _connectSocket();
    } catch (exception) {
      connected = false;
      error = _friendlyError(exception);
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _registerDevice() async {
    final response = await _client
        .post(
          _httpUri('/api/v1/devices/register'),
          headers: _headers,
          body: jsonEncode({'deviceId': deviceId, 'name': deviceName}),
        )
        .timeout(const Duration(seconds: 12));
    _requireSuccess(response);
  }

  Future<void> _pushPending() async {
    for (var batch = 0; batch < 100; batch++) {
      final rows = await database.pendingMutations();
      if (rows.isEmpty) return;
      final mutations = rows.map((row) {
        final raw = row['payload']?.toString();
        final payload = raw == null ? null : jsonDecode(raw);
        final entityType = row['entity_type']?.toString() ?? 'book';
        return {
          'mutationId': row['mutation_id'],
          'operation': row['operation'],
          'entityId': row['entity_id'],
          'entityType': entityType,
          'book': entityType == 'book' ? payload : null,
          'subscriber': entityType == 'subscriber' ? payload : null,
          'subscription': entityType == 'subscription' ? payload : null,
          'loan': entityType == 'loan' ? payload : null,
          'gateDay': entityType == 'gate_day' ? payload : null,
          'staffPassage': entityType == 'staff_passage' ? payload : null,
        };
      }).toList();
      final response = await _client
          .post(
            _httpUri('/api/v1/sync/push'),
            headers: _headers,
            body: jsonEncode({'deviceId': deviceId, 'mutations': mutations}),
          )
          .timeout(const Duration(seconds: 30));
      _requireSuccess(response);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final acknowledged =
          (body['acknowledgedMutationIds'] as List? ?? const [])
              .map((value) => value.toString())
              .toList();
      if (acknowledged.isEmpty) {
        throw StateError('Le serveur n’a confirmé aucune modification.');
      }
      await database.acknowledgeMutations(acknowledged);
    }
    throw StateError(
      'Trop de modifications en attente pour une seule synchronisation.',
    );
  }

  /// Rapport d'appareil pour l'API de données : comptes (sans mot de passe)
  /// et activité nouvelle depuis le dernier envoi accepté.
  Future<void> _sendReport() async {
    const batchSize = 1000;
    final preferences = await SharedPreferences.getInstance();
    var after = preferences.getInt('sync_report_activity_id') ?? 0;
    for (var batch = 0; batch < 20; batch++) {
      final activity = await database.reportActivity(after, limit: batchSize);
      final response = await _client
          .post(
            _httpUri('/api/v1/devices/${Uri.encodeComponent(deviceId)}/report'),
            headers: _headers,
            body: jsonEncode({
              'deviceId': deviceId,
              'name': deviceName,
              'platform': 'android',
              'users': batch == 0 ? await database.reportUsers() : null,
              'activity': activity,
            }),
          )
          .timeout(const Duration(seconds: 30));
      _requireSuccess(response);
      if (activity.isEmpty) return;
      final body = jsonDecode(response.body) as Map;
      after =
          (body['activityAcknowledgedUntil'] as num?)?.toInt() ??
          activity.last['localId'] as int;
      await preferences.setInt('sync_report_activity_id', after);
      if (activity.length < batchSize) return;
    }
  }

  Future<void> _pullAll() async {
    var cursor = await database.syncCursor();
    for (var page = 0; page < 100; page++) {
      final response = await _client
          .get(
            _httpUri('/api/v1/sync', {'since': '$cursor', 'limit': '500'}),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 30));
      _requireSuccess(response);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final changes = body['changes'] as List? ?? const [];
      cursor = (body['cursor'] as num?)?.toInt() ?? cursor;
      await database.applyRemoteChanges(changes, cursor);
      if (body['hasMore'] != true) return;
    }
    throw StateError('La récupération des changements est incomplète.');
  }

  Future<void> _connectSocket() async {
    if (_socket != null || !configured || _disposed) return;
    try {
      final channel = IOWebSocketChannel.connect(
        _webSocketUri('/api/v1/events'),
        headers: {'X-Device-Key': apiKey, 'X-Device-Id': deviceId},
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 12),
      );
      await channel.ready;
      _socket = channel;
      _socketSubscription = channel.stream.listen(
        (_) {
          _eventDebounce?.cancel();
          _eventDebounce = Timer(
            const Duration(milliseconds: 250),
            () => unawaited(syncNow()),
          );
        },
        onError: (_) => _socketClosed(),
        onDone: _socketClosed,
      );
    } catch (_) {
      await _disconnectSocket();
    }
  }

  void _socketClosed() {
    _socketSubscription = null;
    _socket = null;
    if (!_disposed) {
      connected = false;
      notifyListeners();
    }
  }

  Future<void> _disconnectSocket() async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.sink.close();
  }

  Uri _httpUri(String route, [Map<String, String>? query]) {
    final base = Uri.parse(serverUrl);
    return base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}$route',
      queryParameters: query,
    );
  }

  Uri _webSocketUri(String route) {
    final uri = _httpUri(route);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-Device-Key': apiKey,
    'X-Device-Id': deviceId,
  };

  static void _requireSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var message = 'Erreur serveur ${response.statusCode}.';
    try {
      final body = jsonDecode(response.body) as Map;
      message = body['error']?.toString() ?? message;
    } catch (_) {}
    throw StateError(message);
  }

  static String _friendlyError(Object exception) => exception
      .toString()
      .replaceFirst(RegExp(r'^(StateError|Bad state|Exception):\s*'), '');

  static String _newId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _eventDebounce?.cancel();
    unawaited(_disconnectSocket());
    _client.close();
    super.dispose();
  }
}
