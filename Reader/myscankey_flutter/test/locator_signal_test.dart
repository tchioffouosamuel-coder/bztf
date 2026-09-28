import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/services/locator_signal.dart';

void main() {
  group('LocatorSignalTracker', () {
    test('normalizes the two RSSI scales used by supported readers', () {
      expect(LocatorSignalTracker.normalizeRssi(-85), 0);
      expect(LocatorSignalTracker.normalizeRssi(-10), 1);
      expect(LocatorSignalTracker.normalizeRssi(15), 0);
      expect(LocatorSignalTracker.normalizeRssi(100), 1);
    });

    test('keeps an isolated RSSI spike from moving the target abruptly', () {
      final tracker = LocatorSignalTracker();
      for (final rssi in [-60, -59, -61, -60, -10]) {
        tracker.add(rssi);
      }

      expect(tracker.rssi, inInclusiveRange(-62, -57));
      expect(tracker.sampleCount, 5);
      expect(tracker.confidence, greaterThan(0));
    });

    test('reset clears the current estimate', () {
      final tracker = LocatorSignalTracker()..add(-35);

      tracker.reset();

      expect(tracker.rssi, isNull);
      expect(tracker.strength, 0);
      expect(tracker.confidence, 0);
      expect(tracker.sampleCount, 0);
    });
  });
}
