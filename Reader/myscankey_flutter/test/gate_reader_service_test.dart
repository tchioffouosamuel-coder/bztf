import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/services/gate_reader_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('com.bibliorfid.myscankey_flutter/gate');
  const events = MethodChannel('com.bibliorfid.myscankey_flutter/gate-events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late GateReaderService reader;
  var failStart = false;

  setUp(() async {
    failStart = false;
    reader = GateReaderService();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connect') return {'connected': true};
      if (call.method == 'startInventory' && failStart) {
        throw PlatformException(
          code: 'INVENTORY_START',
          message: 'ERR_BACK_DATA_FAIL',
        );
      }
      return null;
    });
    await reader.connect(transport: 'tcp', endpoint: '192.168.0.101');
  });

  tearDown(() async {
    await reader.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test('a refused start clears the previous reading state', () async {
    await reader.startInventory();
    expect(reader.reading, isTrue);
    failStart = true;
    await expectLater(
      reader.startInventory(),
      throwsA(isA<PlatformException>()),
    );
    expect(reader.connected, isTrue);
    expect(reader.reading, isFalse);
  });

  test(
    'a native restart error stops reading and reaches the controller',
    () async {
      final errorReceived = Completer<Object>();
      final subscription = reader.tags.listen(
        (_) {},
        onError: (Object error) => errorReceived.complete(error),
      );
      try {
        await reader.startInventory();
        ServicesBinding.instance.channelBuffers.push(
          events.name,
          const StandardMethodCodec().encodeErrorEnvelope(
            code: 'INVENTORY_START',
            message: 'AutoInvSet:ERR=203',
          ),
          (_) {},
        );
        final error = await errorReceived.future;
        expect(error, isA<PlatformException>());
        expect(reader.reading, isFalse);
        expect(reader.connected, isTrue);
      } finally {
        await subscription.cancel();
      }
    },
  );
}
