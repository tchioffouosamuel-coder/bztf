// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:myscankey_flutter/core/epc.dart';

void main() {
  test('génère un EPC BCM de 96 bits valide et stable', () {
    final epc = generateEpc(2026, 42);
    expect(epc, '42434D0107EA0000002A172A');
    expect(epc.length, 24);
    expect(isValidEpc(epc), isTrue);
    expect(isValidEpc('${epc.substring(0, 22)}00'), isFalse);
    expect(formatAccession(2026, 42), 'BCM-2026-000042');
  });
}
