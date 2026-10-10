import 'dart:async';

import 'package:flutter/services.dart';

import '../models/book.dart';

/// Changement de niveau d'une barrière infrarouge (entrée GPI) du portail.
class GateSensorEvent {
  const GateSensorEvent(this.sensor, this.level);

  final int sensor;
  final int level;
}

/// Portail antivol N01 piloté par son SDK Android (`GateBridge.kt`) :
/// TCP (port 8080 imposé par le SDK) ou série RS232 (115 200 bauds). Le mode
/// Simulation permet d'essayer le portail sans matériel.
class GateReaderService {
  static const minPower = 5;
  static const maxPower = 33;
  static const tcpPort = 8080;
  static const _methods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/gate',
  );
  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/gate-events',
  );

  final StreamController<ReaderTag> _tags = StreamController.broadcast();
  final StreamController<GateSensorEvent> _sensors =
      StreamController.broadcast();
  StreamSubscription<Object?>? _nativeSubscription;
  String _transport = 'tcp';
  bool _connected = false;
  bool _reading = false;

  bool get connected => _connected;
  bool get reading => _reading;
  bool get simulation => _transport == 'simulation';
  Stream<ReaderTag> get tags => _tags.stream;
  Stream<GateSensorEvent> get sensors => _sensors.stream;

  /// Adresse attendue par le SDK : IP seule en TCP (le port 8080 est fixe),
  /// `dev/ttyXX` en série (sans barre initiale, comme la démo du SDK).
  static String normalizeEndpoint(String transport, String endpoint) {
    final value = endpoint.trim();
    switch (transport) {
      case 'tcp':
        if (value.isEmpty) {
          throw ArgumentError('Indiquez l’adresse IP du portail.');
        }
        final host = value.split(':').first.trim();
        if (!RegExp(r'^[0-9A-Za-z.\-]+$').hasMatch(host)) {
          throw ArgumentError('Adresse IP du portail invalide.');
        }
        return host;
      case 'serial':
        if (value.isEmpty) {
          throw ArgumentError('Indiquez le port série du portail.');
        }
        final device = value.split(':').first.replaceFirst(RegExp(r'^/+'), '');
        return device.startsWith('dev/') ? device : 'dev/$device';
      default:
        return '';
    }
  }

  /// Connecte le portail et relève le niveau au repos des [sensors]. Avec
  /// [silenceBuzzer], la sortie [buzzerGpo] est retirée de ce que le portail
  /// déclenche de lui-même.
  Future<Map<Object?, Object?>> connect({
    required String transport,
    required String endpoint,
    List<int> sensors = const [],
    int buzzerGpo = 3,
    bool silenceBuzzer = true,
  }) async {
    await disconnect();
    _transport = transport;
    if (transport == 'simulation') {
      _connected = true;
      return {
        'connected': true,
        'readerId': 'SIMULATION',
        'version': '',
        'gpiLevels': {for (final sensor in sensors) '$sensor': 0},
        'gpiReport': true,
        'buzzerSilenced': true,
      };
    }
    final target = normalizeEndpoint(transport, endpoint);
    _nativeSubscription ??= _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: _tags.addError,
    );
    final result = await _methods.invokeMapMethod<Object?, Object?>('connect', {
      'transport': transport,
      'endpoint': target,
      'sensors': sensors,
      'buzzerGpo': buzzerGpo,
      'silenceBuzzer': silenceBuzzer,
    });
    _connected = result?['connected'] == true;
    return result ?? const {};
  }

  void _onNativeEvent(Object? raw) {
    if (raw is! Map) return;
    final event = Map<Object?, Object?>.from(raw);
    if (event['type'] == 'gpi') {
      _sensors.add(
        GateSensorEvent(
          (event['gpi'] as num?)?.toInt() ?? 0,
          (event['level'] as num?)?.toInt() ?? 0,
        ),
      );
    } else {
      _tags.add(ReaderTag.fromMap(event));
    }
  }

  Future<void> startInventory({int? power}) async {
    if (!_connected) {
      throw StateError('Connectez le portail avant la lecture.');
    }
    if (power != null && (power < minPower || power > maxPower)) {
      throw RangeError.range(power, minPower, maxPower, 'power');
    }
    if (!simulation) {
      await _methods.invokeMethod<void>('startInventory', {'power': power});
    }
    _reading = true;
  }

  Future<void> stopInventory() async {
    _reading = false;
    if (!simulation && _connected) {
      await _methods.invokeMethod<void>('stopInventory');
    }
  }

  /// TID du tag [epc], relu par une commande ciblée : le portail ne le
  /// transmet pas pendant la lecture continue. Vide si le tag n'a pas
  /// répondu.
  Future<String> readTid(String epc) async {
    if (!_connected || simulation) return '';
    try {
      return await _methods.invokeMethod<String>('readTid', {'epc': epc}) ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// `false` si le portail ne répond plus (le SDK ne signale pas les coupures).
  Future<bool> ping() async {
    if (!_connected) return false;
    if (simulation) return true;
    try {
      return await _methods.invokeMethod<bool>('ping') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Snapshot complet des paramètres exposés par le SDK N01 et la démo native.
  Future<Map<String, Object?>> readN01Settings() async {
    if (!_connected || simulation) return const {};
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'getN01Settings',
    );
    return _stringMap(result);
  }

  /// Applique les clés présentes dans [settings] puis renvoie le nouveau
  /// snapshot. Les clés absentes ne sont pas modifiées côté matériel.
  Future<Map<String, Object?>> applyN01Settings(
    Map<String, Object?> settings,
  ) async {
    if (!_connected || simulation) return const {};
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'applyN01Settings',
      {'settings': settings},
    );
    return _stringMap(result);
  }

  Future<void> disconnect() async {
    if (!_connected) return;
    await stopInventory();
    if (!simulation) await _methods.invokeMethod<void>('disconnect');
    _connected = false;
  }

  /// Active la sortie [gpo] du portail (voyant ou buzzer) pendant [duration].
  Future<bool> pulseGpo(int gpo, Duration duration) async {
    if (!_connected || simulation) return false;
    try {
      return await _methods.invokeMethod<bool>('pulseGpo', {
            'gpo': gpo,
            'durationMs': duration.inMilliseconds,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Retire la sortie [gpo] du buzzer de ce que le portail déclenche seul.
  Future<bool> silenceBuzzer(int gpo) async {
    if (!_connected || simulation) return true;
    try {
      return await _methods.invokeMethod<bool>('silenceBuzzer', {'gpo': gpo}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Message vocal d'alarme joué par la tablette. Renvoie sa durée restante
  /// (un message déjà en cours n'est pas relancé).
  Future<Duration> playAlarm(double volume) async {
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'playAlarm',
      {'volume': volume},
    );
    return Duration(
      milliseconds: (result?['remainingMs'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> stopAlarm() => _methods.invokeMethod<void>('stopAlarm');

  Future<void> setKeepScreenOn(bool enabled) =>
      _methods.invokeMethod<void>('keepScreenOn', {'enabled': enabled});

  /// Simulation : un tag passe sous les antennes.
  void simulateTag(ReaderTag tag) {
    if (simulation && _reading) _tags.add(tag);
  }

  /// Simulation : une barrière change de niveau.
  void simulateSensor(int sensor, int level) {
    if (simulation && _connected) _sensors.add(GateSensorEvent(sensor, level));
  }

  Future<void> dispose() async {
    await _nativeSubscription?.cancel();
    if (_connected) {
      try {
        await disconnect();
      } catch (_) {}
    }
    await _tags.close();
    await _sensors.close();
  }

  static Map<String, Object?> _stringMap(Map<Object?, Object?>? value) {
    if (value == null) return const {};
    return value.map((key, data) => MapEntry(key.toString(), data));
  }
}
