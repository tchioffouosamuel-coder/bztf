import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'sync_service.dart';

/// Envoie les logs de l'application au serveur de synchronisation, pour le
/// débogage à distance (page `/logs` du serveur). Rien n'est envoyé tant que
/// la synchronisation n'est pas configurée.
class LogShipper {
  LogShipper(
    this.sync, {
    Stream<String>? lines,
    http.Client? client,
    this.interval = const Duration(seconds: 3),
  }) : _lines = lines,
       _client = client ?? http.Client();

  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/app-logs',
  );

  /// Lignes gardées si le serveur est injoignable ; les plus anciennes
  /// partent en premier.
  static const maxBuffered = 2000;
  static const _batchSize = 500;

  final SyncService sync;
  final Duration interval;
  final http.Client _client;
  final Stream<String>? _lines;
  final List<Map<String, String>> _buffer = [];
  StreamSubscription<String>? _subscription;
  Timer? _timer;
  bool _sending = false;

  int get pending => _buffer.length;

  void start() {
    if (_subscription != null) return;
    final lines =
        _lines ??
        (defaultTargetPlatform == TargetPlatform.android
            ? _events.receiveBroadcastStream().map((line) => '$line')
            : null);
    if (lines == null) return;
    _subscription = lines.listen(_add, onError: (_) {});
    _timer = Timer.periodic(interval, (_) => unawaited(flush()));
  }

  void _add(String line) {
    _buffer.add({'at': DateTime.now().toUtc().toIso8601String(), 'line': line});
    if (_buffer.length > maxBuffered) {
      _buffer.removeRange(0, _buffer.length - maxBuffered);
    }
  }

  /// Envoie les lignes en attente ; gardées pour plus tard en cas d'échec.
  Future<void> flush() async {
    if (_sending || _buffer.isEmpty || !sync.configured) return;
    _sending = true;
    try {
      while (_buffer.isNotEmpty) {
        final batch = _buffer.take(_batchSize).toList();
        final base = Uri.parse(sync.serverUrl);
        final response = await _client
            .post(
              base.replace(
                path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/api/v1/logs',
              ),
              headers: {
                'Content-Type': 'application/json',
                'X-Device-Key': sync.apiKey,
                'X-Device-Id': sync.deviceId,
              },
              body: jsonEncode({
                'deviceId': sync.deviceId,
                'name': sync.deviceName,
                'lines': batch,
              }),
            )
            .timeout(const Duration(seconds: 15));
        // Pas de log ici : il serait lui-même renvoyé au serveur.
        if (response.statusCode < 200 || response.statusCode >= 300) return;
        _buffer.removeRange(0, batch.length.clamp(0, _buffer.length));
      }
    } catch (_) {
      // Serveur injoignable : nouvel essai au prochain intervalle.
    } finally {
      _sending = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _client.close();
  }
}
