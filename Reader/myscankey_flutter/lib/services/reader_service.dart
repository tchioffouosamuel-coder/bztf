import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';

class ReaderService {
  static const minPower = 5;
  static const maxPower = 33;
  static const _methods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/reader',
  );
  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/reader-events',
  );
  static const _keyEvents = EventChannel(
    'com.bibliorfid.myscankey_flutter/rfid-key-events',
  );
  static const emptyEpc = '000000000000000000000000';

  final StreamController<ReaderTag> _simulationEvents =
      StreamController.broadcast();
  final StreamController<ReaderTag> _tagEvents = StreamController.broadcast();
  final StreamController<String> _nativeRfidKeyEvents =
      StreamController.broadcast();
  StreamSubscription<Object?>? _nativeSubscription;
  StreamSubscription<Object?>? _nativeKeySubscription;
  String _transport = 'serial';
  bool _connected = false;
  bool _reading = false;
  ReaderTag _simulationTag = const ReaderTag(
    epc: '300833B2DDD9014000000001',
    tid: 'E28068940000500A12AB0001',
    rssi: 62,
  );
  Timer? _simulationTimer;

  bool get connected => _connected;
  bool get reading => _reading;
  String get transport => _transport;

  Stream<ReaderTag> get tags => _tagEvents.stream;
  Stream<String> get nativeRfidKeyEvents => _nativeRfidKeyEvents.stream;

  void listenForNativeRfidKeys() {
    if (defaultTargetPlatform != TargetPlatform.android ||
        _nativeKeySubscription != null) {
      return;
    }
    _nativeKeySubscription = _keyEvents.receiveBroadcastStream().listen((
      event,
    ) {
      if (event is Map) {
        final action = event['action']?.toString();
        if (action == 'down' || action == 'up') {
          _nativeRfidKeyEvents.add(action!);
        }
      }
    }, onError: (Object error) => _nativeRfidKeyEvents.addError(error));
  }

  Future<Map<Object?, Object?>> connect({
    required String transport,
    required String endpoint,
  }) async {
    _transport = transport;
    if (transport == 'simulation') {
      _connected = true;
      return {
        'connected': true,
        'readerId': 'SIMULATION',
        'version': 'Virtuel',
      };
    }
    _nativeSubscription ??= _events.receiveBroadcastStream().listen(
      (event) => _tagEvents.add(
        ReaderTag.fromMap(Map<Object?, Object?>.from(event as Map)),
      ),
      onError: _tagEvents.addError,
    );
    final result = await _methods.invokeMapMethod<Object?, Object?>('connect', {
      'transport': transport,
      'endpoint': endpoint,
    });
    _connected = result?['connected'] == true;
    return result ?? const {};
  }

  Future<void> startInventory({int? power, String? targetEpc}) async {
    if (!_connected) {
      throw StateError('Connectez le lecteur RFID avant la lecture.');
    }
    if (_transport == 'simulation') {
      _reading = true;
      _simulationTimer?.cancel();
      _tagEvents.add(_simulationTag);
      _simulationTimer = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => _tagEvents.add(_simulationTag),
      );
      return;
    }
    await _methods.invokeMethod<void>('startInventory', {
      'power': power,
      'targetEpc': targetEpc,
    });
    _reading = true;
  }

  Future<void> configurePower({
    required int readPower,
    required int writePower,
  }) async {
    _validatePower(readPower);
    _validatePower(writePower);
    if (_transport == 'simulation' || !_connected) return;
    await _methods.invokeMethod<void>('configurePower', {
      'readPower': readPower,
      'writePower': writePower,
    });
  }

  Future<void> stopInventory() async {
    _simulationTimer?.cancel();
    _reading = false;
    if (_transport != 'simulation' && _connected) {
      await _methods.invokeMethod<void>('stopInventory');
    }
  }

  Future<void> playScanBeep() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _methods.invokeMethod<void>('playScanBeep');
  }

  Future<String> resolveTid(String epc) async {
    final normalizedEpc = epc.trim().toUpperCase();
    if (_transport == 'simulation') {
      return _simulationTag.epc == normalizedEpc ? _simulationTag.tid : '';
    }
    if (!_connected || normalizedEpc.isEmpty) return '';
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'resolveTid',
      {'epc': normalizedEpc},
    );
    return result?['tid']?.toString().toUpperCase() ?? '';
  }

  Future<void> disconnect() async {
    await stopInventory();
    if (_transport != 'simulation' && _connected) {
      await _methods.invokeMethod<void>('disconnect');
    }
    _connected = false;
  }

  Future<Map<Object?, Object?>> writeEpc(
    String epc,
    String tid, {
    required String currentEpc,
    int? writePower,
    int? restorePower,
  }) async {
    if (!_connected) {
      throw StateError('Connectez le lecteur RFID avant l’écriture.');
    }
    final normalizedEpc = epc.trim().toUpperCase();
    final normalizedTid = tid.trim().toUpperCase();
    final normalizedCurrentEpc = currentEpc.trim().toUpperCase();
    if (writePower != null) _validatePower(writePower);
    if (restorePower != null) _validatePower(restorePower);
    if (!RegExp(r'^[0-9A-F]{24}$').hasMatch(normalizedEpc) ||
        !RegExp(r'^[0-9A-F]{24}$').hasMatch(normalizedCurrentEpc) ||
        normalizedTid.isEmpty) {
      throw ArgumentError('EPC ou TID invalide.');
    }
    if (_transport == 'simulation') {
      if (_simulationTag.tid != normalizedTid) {
        throw StateError(
          'Le tag présent ne correspond pas au livre sélectionné.',
        );
      }
      if (_simulationTag.epc != normalizedCurrentEpc) {
        throw StateError('L’EPC du tag présent a changé.');
      }
      _simulationTag = ReaderTag(
        epc: normalizedEpc,
        tid: normalizedTid,
        rssi: _simulationTag.rssi,
        antenna: _simulationTag.antenna,
      );
      _tagEvents.add(_simulationTag);
      return {'verified': true, 'epc': normalizedEpc, 'tid': normalizedTid};
    }
    return await _methods.invokeMapMethod<Object?, Object?>('writeEpc', {
          'epc': normalizedEpc,
          'tid': normalizedTid,
          'currentEpc': normalizedCurrentEpc,
          'writePower': writePower,
          'restorePower': restorePower,
        }) ??
        const {};
  }

  static void _validatePower(int power) {
    if (power < minPower || power > maxPower) {
      throw RangeError.range(power, minPower, maxPower, 'power');
    }
  }

  Future<void> dispose() async {
    _simulationTimer?.cancel();
    await _nativeSubscription?.cancel();
    await _nativeKeySubscription?.cancel();
    if (_connected) await disconnect();
    await _simulationEvents.close();
    await _tagEvents.close();
    await _nativeRfidKeyEvents.close();
  }
}
