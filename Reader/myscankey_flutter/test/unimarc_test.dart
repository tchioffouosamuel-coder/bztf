import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/core/unimarc.dart';

void main() {
  test('parse une réponse SRU BnF réelle en unimarcxchange', () async {
    final xml = await File(
      'test/fixtures/bnf_9782070360024.xml',
    ).readAsString();
    final notices = parseUnimarcNotices(
      xml,
      sourceNotice: 'BnF',
      dateRecuperation: DateTime.utc(2026, 10, 5),
    );

    expect(notices, hasLength(1));
    final notice = notices.single;
    expect(notice.title, "L'Étranger");
    expect(notice.auteurs.single.nom, 'Camus Albert');
    expect(notice.auteurs.single.role, 'auteur');
    expect(notice.editeur, 'Gallimard');
    expect(notice.collection, 'Folio');
    expect(notice.numeroCollection, '2');
    expect(notice.langue, 'fre');
    expect(notice.identifiantSource, 'FRBNF352244360000008');
  });

  test('parse une notice SUDOC XML réelle', () async {
    final xml = await File('test/fixtures/sudoc_001896431.xml').readAsString();
    final notices = parseUnimarcNotices(
      xml,
      sourceNotice: 'SUDOC',
      dateRecuperation: DateTime.utc(2026, 10, 5),
    );

    expect(notices, hasLength(1));
    final notice = notices.single;
    expect(notice.title, "L'étranger");
    expect(notice.auteurs.single.nom, 'Camus Albert');
    expect(notice.editeur, 'Gallimard');
    expect(notice.datePublication, 'DL 1971');
    expect(notice.nbPages, '1 vol. (187 p.)');
    expect(notice.illustrations, 'couv. ill. en coul.');
    expect(notice.dimensions, '18 cm');
    expect(notice.collection, 'Collection Folio');
    expect(notice.numeroCollection, '2');
    expect(notice.indiceClassification, '843');
    expect(notice.identifiantSource, '001896431');
  });
}
