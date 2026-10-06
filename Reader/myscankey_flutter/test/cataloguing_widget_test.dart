import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/services/cataloguing_preferences.dart';
import 'package:myscankey_flutter/services/notice/notice_lookup_service.dart';
import 'package:myscankey_flutter/services/notice/notice_source.dart';
import 'package:myscankey_flutter/widgets/book_editor.dart';

const _notice = NoticeResult(
  title: 'L’Étranger',
  sourceNotice: 'BnF',
  auteurs: [NoticeAuthor(nom: 'Camus, Albert')],
  editeur: 'Gallimard',
  datePublication: '1942',
  nbPages: '184 p.',
  indiceClassification: '843',
  resume: 'Un roman.',
  collection: 'Folio',
);

class _Lookup extends NoticeLookupService {
  _Lookup(this.answer)
    : super(sources: const [], cache: _NoCache(), localLookup: (_) async => []);
  final Future<List<NoticeResult>> Function() answer;
  int calls = 0;
  @override
  Future<List<NoticeResult>> lookup(
    String isbn, {
    bool Function()? isCancelled,
  }) {
    calls++;
    return answer();
  }
}

class _NoCache implements NoticeLookupCache {
  @override
  Future<List<NoticeResult>> read(String isbn13) async => [];
  @override
  Future<void> write(String isbn13, List<NoticeResult> results) async {}
}

Finder _field(String key) => find.byKey(ValueKey('field_$key'));
String _value(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(_field(key)).controller!.text;

Future<void> _open(
  WidgetTester tester,
  _Lookup lookup, {
  ValueChanged<Map<String, Object?>?>? onSave,
}) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await Navigator.of(context)
                  .push<Map<String, Object?>>(
                    MaterialPageRoute(
                      builder: (_) => BookEditor(
                        lookupService: lookup,
                        preferences: const CataloguingPreferences(),
                      ),
                    ),
                  );
              onSave?.call(result);
            },
            child: const Text('Cataloguer'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Cataloguer'));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('isbn_input')),
    '9782070360024',
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_field(key));
  await tester.pumpAndSettle();
  await tester.enterText(_field(key), text);
  await tester.pump();
}

void main() {
  const scannerMethods = MethodChannel(
    'com.bibliorfid.myscankey_flutter/barcode',
  );
  const scannerEvents = MethodChannel(
    'com.bibliorfid.myscankey_flutter/barcode-events',
  );
  final scannerCalls = <String>[];

  setUp(() {
    scannerCalls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(scannerMethods, (call) async {
      scannerCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(scannerEvents, (_) async => null);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(scannerMethods, null);
    messenger.setMockMethodCallHandler(scannerEvents, null);
  });

  void scan(WidgetTester tester, String barcode) {
    tester.binding.channelBuffers.push(
      scannerEvents.name,
      const StandardMethodCodec().encodeSuccessEnvelope({'barcode': barcode}),
      (_) {},
    );
  }

  testWidgets(
    'scan direct à l’étape 1 : recherche unique sans ouvrir un autre écran',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final pending = Completer<List<NoticeResult>>();
      final lookup = _Lookup(() => pending.future);
      await _open(tester, lookup);
      expect(scannerCalls, ['open']);
      scan(tester, '9782070360024');
      scan(tester, '9782070360024');
      await tester.pump();
      await tester.pump();
      expect(lookup.calls, 1);
      expect(find.text('2 · Récupération de la notice…'), findsOneWidget);
      expect(find.text('Scanner l’ISBN'), findsNothing);
      expect(scannerCalls, ['open', 'close']);
      pending.complete([_notice]);
      await tester.pumpAndSettle();
      expect(_value(tester, 'title'), 'L’Étranger');
      expect(_value(tester, 'isbn'), '9782070360024');
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('code invalide refusé et scanner réactivé au retour à l’ISBN', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final lookup = _Lookup(() async => [_notice]);
    await _open(tester, lookup);
    scan(tester, '1234567890123');
    await tester.pumpAndSettle();
    expect(lookup.calls, 0);
    expect(find.text('Le code lu n’est pas un ISBN valide.'), findsOneWidget);
    expect(scannerCalls, ['open']);
    scan(tester, '2070360024');
    await tester.pumpAndSettle();
    expect(lookup.calls, 1);
    expect(_value(tester, 'isbn'), '9782070360024');
    await tester.tap(find.text('Retour à l’ISBN'));
    await tester.pumpAndSettle();
    expect(scannerCalls, ['open', 'close', 'open']);
    scan(tester, '9782070360024');
    await tester.pumpAndSettle();
    expect(lookup.calls, 2);
    expect(scannerCalls, ['open', 'close', 'open', 'close']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('quitter l’étape 1 libère le scanner optique', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _open(tester, _Lookup(() async => []));
    expect(scannerCalls, ['open']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(scannerCalls, ['open', 'close']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('scanner indisponible : recherche au clavier toujours possible', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(scannerMethods, (call) async {
          scannerCalls.add(call.method);
          if (call.method == 'open') {
            throw PlatformException(
              code: 'BARCODE_SCANNER',
              message: 'Scanner indisponible.',
            );
          }
          return null;
        });
    final lookup = _Lookup(() async => [_notice]);
    await _open(tester, lookup);
    expect(find.text('Scanner indisponible.'), findsOneWidget);
    await _search(tester);
    expect(lookup.calls, 1);
    expect(_value(tester, 'title'), 'L’Étranger');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'ISBN trouvé : notice pré-remplie, source fixe et cote modifiable',
    (tester) async {
      final lookup = _Lookup(() async => [_notice]);
      await _open(tester, lookup);
      await _search(tester);
      expect(lookup.calls, 1);
      expect(_value(tester, 'title'), 'L’Étranger');
      expect(_value(tester, 'author'), 'Camus, Albert');
      expect(_value(tester, 'publisher'), 'Gallimard');
      expect(_value(tester, 'publication_year'), '1942');
      expect(find.text('Source : BnF'), findsOneWidget);
      await _enter(tester, 'document_type', 'Fiction');
      await _enter(tester, 'shelf', 'R CAM / réserve');
      await _enter(tester, 'author', 'Dumas');
      expect(_value(tester, 'shelf'), 'R CAM / réserve');
      expect(find.text('Source : BnF'), findsOneWidget);
      await tester.ensureVisible(find.text('Description détaillée'));
      await tester.tap(find.text('Description détaillée'));
      await tester.pumpAndSettle();
      expect(_value(tester, 'summary'), 'Un roman.');
      expect(_value(tester, 'page_count'), '184 p.');
    },
  );

  for (final offline in [false, true]) {
    testWidgets(
      offline
          ? 'hors ligne : formulaire manuel disponible'
          : 'ISBN inconnu : formulaire vide',
      (tester) async {
        await _open(
          tester,
          _Lookup(() async {
            if (offline) throw const NoticeNetworkException('offline');
            throw const NoticeNotFoundException('inconnu');
          }),
        );
        await _search(tester);
        expect(_value(tester, 'title'), isEmpty);
        expect(_value(tester, 'author'), isEmpty);
        expect(_value(tester, 'publisher'), isEmpty);
        expect(find.text('Source : manuelle'), findsOneWidget);
        expect(find.text('Enregistrer et fermer'), findsOneWidget);
      },
    );
  }

  for (final missing in [
    'title',
    'author',
    'publisher',
    'publication_year',
    'document_type',
  ]) {
    testWidgets('champ obligatoire : $missing', (tester) async {
      Map<String, Object?>? saved;
      final lookup = _Lookup(() async => []);
      await _open(tester, lookup, onSave: (value) => saved = value);
      await tester.tap(find.text('Saisie manuelle / sans ISBN'));
      await tester.pumpAndSettle();
      for (final entry in {
        'title': 'Livre',
        'author': 'Auteur',
        'publisher': 'Éditeur',
        'publication_year': '2026',
        'document_type': 'Documentaire',
      }.entries) {
        if (entry.key != missing) await _enter(tester, entry.key, entry.value);
      }
      await tester.tap(find.text('Enregistrer et fermer'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Ce champ est obligatoire.'), findsOneWidget);
      expect(lookup.calls, 0);
    });
  }

  testWidgets('saisie sans ISBN, bouton anonyme et enregistrement', (
    tester,
  ) async {
    Map<String, Object?>? saved;
    final lookup = _Lookup(() async => []);
    await _open(tester, lookup, onSave: (value) => saved = value);
    await tester.tap(find.text('Saisie manuelle / sans ISBN'));
    await tester.pumpAndSettle();
    await _enter(tester, 'title', 'Livre sans ISBN');
    await tester.ensureVisible(find.text('Anonyme'));
    await tester.tap(find.text('Anonyme'));
    await _enter(tester, 'publisher', 'Éditeur local');
    await _enter(tester, 'publication_year', '2026');
    await _enter(tester, 'document_type', 'Fiction');
    await tester.tap(find.text('Enregistrer et fermer'));
    await tester.pumpAndSettle();
    expect(saved?['title'], 'Livre sans ISBN');
    expect(saved?['author'], 'Anonyme');
    expect(saved?['shelf'], 'R ANO');
    expect(saved?['isbn'], isEmpty);
    expect(lookup.calls, 0);
  });

  testWidgets('plusieurs éditions : choix avant pré-remplissage', (
    tester,
  ) async {
    await _open(
      tester,
      _Lookup(
        () async => [
          _notice,
          _notice.copyWith(
            title: 'Autre édition',
            editeur: 'Folio',
            datePublication: '2000',
            nbPages: '200 p.',
          ),
        ],
      ),
    );
    await _search(tester);
    expect(find.text('Choisir l’édition'), findsOneWidget);
    expect(find.textContaining('200 p.'), findsOneWidget);
    await tester.tap(find.text('Autre édition'));
    await tester.pumpAndSettle();
    expect(_value(tester, 'title'), 'Autre édition');
    expect(_value(tester, 'publisher'), 'Folio');
  });

  testWidgets('doublon : ajouter un exemplaire sans recopier son identité', (
    tester,
  ) async {
    final book = Book.fromMap({
      'id': 7,
      'accession': 'BCM-2026-000007',
      'epc': 'EPC',
      'title': 'Livre existant',
      'author': 'Dumas',
      'publisher': 'Local',
      'publication_year': '2020',
      'source_notice': 'SUDOC',
      'document_type': 'Fiction',
      'location': 'Ancien rayon',
      'item_status': 'Retiré',
      'shelf': 'Ancienne cote',
      'status': 'encode',
      'created_at': '',
      'updated_at': '',
    });
    await _open(
      tester,
      _Lookup(
        () async => [
          NoticeResult(
            title: book.title,
            sourceNotice: 'déjà au catalogue',
            dejaAuCatalogue: true,
            livresCatalogue: [book],
          ),
        ],
      ),
    );
    await _search(tester);
    expect(find.text('Déjà au catalogue'), findsOneWidget);
    await tester.tap(find.text('Ajouter un exemplaire'));
    await tester.pumpAndSettle();
    expect(_value(tester, 'title'), 'Livre existant');
    expect(_value(tester, 'location'), isEmpty);
    expect(_value(tester, 'item_status'), 'Disponible');
    expect(find.text('Source : SUDOC'), findsOneWidget);
    expect(
      find.textContaining('L’identifiant et l’EPC seront générés'),
      findsOneWidget,
    );
  });

  testWidgets('annulation : une réponse tardive ne remplit pas le formulaire', (
    tester,
  ) async {
    final response = Completer<List<NoticeResult>>();
    await _open(tester, _Lookup(() => response.future));
    await tester.enterText(
      find.byKey(const ValueKey('isbn_input')),
      '9782070360024',
    );
    await tester.tap(find.text('Récupérer la notice'));
    await tester.pump();
    expect(find.text('Annuler la recherche'), findsOneWidget);
    await tester.tap(find.text('Annuler la recherche'));
    await tester.pumpAndSettle();
    response.complete([_notice]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('isbn_input')), findsOneWidget);
    expect(_field('title'), findsNothing);
  });

  testWidgets(
    'nouvelle recherche : une ancienne notice ne reste pas dans le formulaire vide',
    (tester) async {
      var found = true;
      await _open(tester, _Lookup(() async => found ? [_notice] : []));
      await _search(tester);
      expect(_value(tester, 'title'), 'L’Étranger');
      await tester.tap(find.text('Retour à l’ISBN'));
      await tester.pumpAndSettle();
      found = false;
      await _search(tester);
      expect(_value(tester, 'title'), isEmpty);
      expect(_value(tester, 'author'), isEmpty);
      expect(find.text('Source : manuelle'), findsOneWidget);
    },
  );

  testWidgets('saisie manuelle utilisable sur un écran de téléphone', (
    tester,
  ) async {
    await _open(tester, _Lookup(() async => []));
    tester.view.physicalSize = const Size(360, 720);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saisie manuelle / sans ISBN'));
    await tester.pumpAndSettle();
    await _enter(tester, 'title', 'Livre');
    await _enter(tester, 'author', 'Auteur');
    expect(find.text('Source : manuelle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'exemplaire d’un ancien livre sans source : provenance manuelle affichée',
    (tester) async {
      final book = Book.fromMap({
        'id': 1,
        'accession': 'BCM-2026-000001',
        'epc': 'EPC',
        'title': 'Ancien livre',
        'status': 'a_encoder',
        'created_at': '',
        'updated_at': '',
      });
      await _open(
        tester,
        _Lookup(
          () async => [
            NoticeResult(
              title: book.title,
              sourceNotice: 'déjà au catalogue',
              dejaAuCatalogue: true,
              livresCatalogue: [book],
            ),
          ],
        ),
      );
      await _search(tester);
      await tester.tap(find.text('Ajouter un exemplaire'));
      await tester.pumpAndSettle();
      expect(find.text('Source : manuelle'), findsOneWidget);
    },
  );

  testWidgets('scanner matériel visible uniquement sur Android', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _open(tester, _Lookup(() async => []));
    expect(find.text('Scanner avec le lecteur'), findsNothing);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const SizedBox());
    await _open(tester, _Lookup(() async => []));
    expect(find.text('Scanner avec le lecteur'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
