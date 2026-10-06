import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/widgets/isbn_scanner.dart';

const _methods = MethodChannel('com.bibliorfid.myscankey_flutter/barcode');
const _events = MethodChannel(
  'com.bibliorfid.myscankey_flutter/barcode-events',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_events, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_events, null);
  });

  Future<void> emit(WidgetTester tester, Map<String, String> event) async {
    tester.binding.channelBuffers.push(
      _events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ouvre le module optique et retourne son ISBN décodé', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => const IsbnScanner()),
              );
            },
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    expect(calls, contains('open'));
    expect(find.text('Prêt'), findsOneWidget);
    await tester.tap(find.byTooltip('Scanner'));
    await tester.pumpAndSettle();
    expect(calls, contains('startScan'));
    await emit(tester, {'state': 'scanning'});
    expect(find.text('Lecture en cours'), findsOneWidget);
    await emit(tester, {'barcode': '9782070360024'});
    expect(result, '9782070360024');
    expect(calls, contains('close'));
  });

  testWidgets('un code invalide permet une nouvelle lecture', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: IsbnScanner()));
    await tester.pumpAndSettle();
    await emit(tester, {'barcode': '1234567890123'});
    expect(find.text('ISBN invalide.'), findsOneWidget);
    expect(find.byType(IsbnScanner), findsOneWidget);
    await emit(tester, {'state': 'ready'});
    await tester.tap(find.byTooltip('Scanner'));
    await tester.pumpAndSettle();
    expect(calls, contains('startScan'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(calls, contains('close'));
  });

  testWidgets('affiche une erreur si le SDK ne peut pas ouvrir le scanner', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call.method);
      if (call.method == 'open') {
        throw PlatformException(
          code: 'BARCODE_SCANNER',
          message: 'Module indisponible.',
        );
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: IsbnScanner()));
    await tester.pumpAndSettle();
    expect(find.text('Module indisponible.'), findsOneWidget);
    expect(find.text('Scanner indisponible'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Scanner',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
