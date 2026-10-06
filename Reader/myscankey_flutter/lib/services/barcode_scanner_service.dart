import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BarcodeScannerService {
  static const _methods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/barcode',
  );
  static const _events = EventChannel(
    'com.bibliorfid.myscankey_flutter/barcode-events',
  );
  static const _soundMethods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/reader',
  );

  Stream<Map<Object?, Object?>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<Object?, Object?>.from(event as Map));

  Future<void> open() => _methods.invokeMethod<void>('open');
  Future<void> close() => _methods.invokeMethod<void>('close');
  Future<void> startScan() => _methods.invokeMethod<void>('startScan');
  Future<void> stopScan() => _methods.invokeMethod<void>('stopScan');

  Future<void> playScanBeep() async {
    try {
      await _soundMethods.invokeMethod<void>('playScanBeep');
    } catch (error) {
      debugPrint('Bip du scanner indisponible : $error');
    }
  }
}
