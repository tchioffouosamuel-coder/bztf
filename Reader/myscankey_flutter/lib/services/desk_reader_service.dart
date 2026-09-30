import 'dart:async';

import 'package:flutter/services.dart';

import '../models/book.dart';

/// Lecteur RFID de bureau du poste d'emprunt, piloté par le SDK « RFID
/// Desktop Reader » (`reader.jar`) : connexion TCP (port 8160 par défaut) ou
/// série RS232. Le mode Simulation permet d'essayer le poste sans matériel.
class DeskReaderService {
  static const minPower = 5;
  static const maxPower = 33;
  static const defaultTcpPort = 8160;
  static const defaultBaudRate = 115200;
  static const _methods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/desk-reader',
  );
  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/desk-reader-events',
  );

  final StreamController<ReaderTag> _tags = StreamController.broadcast();
  final Map<String, ReaderTag> _simulatedTags = {};
  StreamSubscription<Object?>? _nativeSubscription;
  Timer? _simulationTimer;
  String _transport = 'tcp';
  bool _connected = false;
  bool _reading = false;

  bool get connected => _connected;
  bool get reading => _reading;
  String get transport => _transport;
  Stream<ReaderTag> get tags => _tags.stream;
  List<ReaderTag> get simulatedTags => _simulatedTags.values.toList();

  /// Chaîne de connexion attendue par le SDK : `ip:port` en TCP,
  /// `/dev/ttyXX:débit` en série.
  static String normalizeEndpoint(String transport, String endpoint) {
    final value = endpoint.trim();
    switch (transport) {
      case 'tcp':
        if (value.isEmpty) {
          throw ArgumentError('Indiquez l’adresse IP du lecteur de bureau.');
        }
        return value.contains(':') ? value : '$value:$defaultTcpPort';
      case 'serial':
        if (value.isEmpty) {
          throw ArgumentError('Indiquez le port série du lecteur de bureau.');
        }
        final device = value.startsWith('/') ? value : '/dev/$value';
        return RegExp(r':\d+$').hasMatch(device)
            ? device
            : '$device:$defaultBaudRate';
      default:
        return '';
    }
  }

  Future<Map<Object?, Object?>> connect({
    required String transport,
    required String endpoint,
  }) async {
    await disconnect();
    _transport = transport;
    if (transport == 'simulation') {
      _connected = true;
      return {'connected': true, 'readerId': 'SIMULATION', 'version': ''};
    }
    final target = normalizeEndpoint(transport, endpoint);
    _nativeSubscription ??= _events.receiveBroadcastStream().listen(
      (event) => _tags.add(
        ReaderTag.fromMap(Map<Object?, Object?>.from(event as Map)),
      ),
      onError: (Object error) {
        if (error is PlatformException && error.code == 'DESK_DISCONNECTED') {
          _connected = false;
          _reading = false;
        }
        _tags.addError(error);
      },
    );
    final result = await _methods.invokeMapMethod<Object?, Object?>('connect', {
      'transport': transport,
      'endpoint': target,
    });
    _connected = result?['connected'] == true;
    return result ?? const {};
  }

  Future<void> startInventory({int? power}) async {
    if (!_connected) {
      throw StateError('Connectez le lecteur de bureau avant la lecture.');
    }
    if (power != null && (power < minPower || power > maxPower)) {
      throw RangeError.range(power, minPower, maxPower, 'power');
    }
    if (_transport == 'simulation') {
      _reading = true;
      _simulationTimer?.cancel();
      _emitSimulated();
      _simulationTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _emitSimulated(),
      );
      return;
    }
    await _methods.invokeMethod<void>('startInventory', {'power': power});
    _reading = true;
  }

  Future<void> stopInventory() async {
    _simulationTimer?.cancel();
    _reading = false;
    if (_transport != 'simulation' && _connected) {
      await _methods.invokeMethod<void>('stopInventory');
    }
  }

  /// Tags distincts (par EPC) remontés pendant [duration], lecture continue
  /// démarrée si besoin.
  Future<List<ReaderTag>> capture({
    Duration duration = const Duration(milliseconds: 1500),
    int? power,
  }) async {
    final seen = <String, ReaderTag>{};
    final subscription = tags.listen(
      (tag) {
        final known = seen[tag.epc];
        // Garde la remontée qui fournit un TID.
        if (known == null || known.tid.isEmpty) seen[tag.epc] = tag;
      },
      onError: (_) {},
    );
    try {
      if (!reading) await startInventory(power: power);
      await Future<void>.delayed(duration);
    } finally {
      await subscription.cancel();
    }
    return seen.values.toList();
  }

  /// Écrit [epc] sur le tag identifié par [tid], relecture de contrôle
  /// comprise. La lecture continue est arrêtée à l'issue.
  Future<Map<Object?, Object?>> writeEpc(String epc, String tid) async {
    if (!connected) {
      throw StateError('Connectez le lecteur de bureau avant l’écriture.');
    }
    _simulationTimer?.cancel();
    _reading = false;
    if (_transport == 'simulation') {
      final current = _simulatedTags.values.where((tag) => tag.tid == tid);
      if (current.isEmpty) throw StateError('Le tag a été retiré du lecteur.');
      final written = ReaderTag(epc: epc, tid: tid, rssi: current.first.rssi);
      _simulatedTags
        ..remove(current.first.epc)
        ..[epc] = written;
      return {'verified': true, 'epc': epc, 'tid': tid};
    }
    return await _methods.invokeMapMethod<Object?, Object?>('writeEpc', {
          'epc': epc,
          'tid': tid,
        }) ??
        const {};
  }

  Future<void> disconnect() async {
    if (!_connected) return;
    await stopInventory();
    if (_transport != 'simulation') {
      await _methods.invokeMethod<void>('disconnect');
    }
    _connected = false;
  }

  /// Bip unique du buzzer du lecteur. `false` si le lecteur ne l'a pas
  /// accepté (ou en simulation) : l'appelant peut alors jouer un son local.
  Future<bool> beep() async {
    if (!connected || _transport == 'simulation') return false;
    try {
      return await _methods.invokeMethod<bool>('beep') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Garde l'écran allumé tant que le poste est ouvert.
  Future<void> setKeepScreenOn(bool enabled) async {
    await _methods.invokeMethod<void>('keepScreenOn', {'enabled': enabled});
  }

  /// Simulation : pose un tag sur le lecteur virtuel.
  void simulatePlace(ReaderTag tag) {
    _simulatedTags[tag.epc] = tag;
    if (_reading && _transport == 'simulation') _tags.add(tag);
  }

  void simulateRemove(String epc) => _simulatedTags.remove(epc);

  void simulateClear() => _simulatedTags.clear();

  void _emitSimulated() {
    for (final tag in _simulatedTags.values) {
      _tags.add(tag);
    }
  }

  Future<void> dispose() async {
    _simulationTimer?.cancel();
    await _nativeSubscription?.cancel();
    if (_connected) {
      try {
        await disconnect();
      } catch (_) {}
    }
    await _tags.close();
  }
}
