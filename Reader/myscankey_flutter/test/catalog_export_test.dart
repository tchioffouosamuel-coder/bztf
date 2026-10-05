import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myscankey_flutter/data/catalog_exporter.dart';
import 'package:myscankey_flutter/models/book.dart';

void main() {
  test(
    'CSV UTF-8 BOM réel, champs enrichis, guillemets, séparateurs et accents',
    () async {
      final book = Book.fromMap({
        'id': 1,
        'accession': 'BCM-2026-000001',
        'epc': 'EPC',
        'title': 'Été, "à la bibliothèque"; suite',
        'author': 'NGOË',
        'publisher': 'Éditeur',
        'subtitle': 'Sous-titre',
        'collection': 'Folio',
        'collection_number': '42',
        'language': 'fra',
        'original_language': 'eng',
        'summary': 'Résumé\nDeuxième ligne',
        'subjects': 'Histoire, Cameroun',
        'dewey': '966.71',
        'edition': '2e édition',
        'page_count': '120',
        'source_notice': 'BnF',
        'source_identifier': 'ark:123',
        'retrieved_at': '2026-10-05T00:00:00Z',
        'status': 'a_encoder',
        'created_at': '',
        'updated_at': '',
      });
      final directory = await Directory.systemTemp.createTemp(
        'export-csv-test-',
      );
      try {
        final file = File('${directory.path}/catalogue.csv');
        await file.writeAsBytes(catalogCsvBytes([book]));
        final actual = await file.readAsBytes();
        expect(actual.take(3), [0xEF, 0xBB, 0xBF]);
        final content = utf8.decode(actual);
        expect(content, contains('""à la bibliothèque""'));
        final rows = Csv.excel().decode(content);
        final headers = rows.first;
        final record = rows[1];
        expect(record[headers.indexOf('Titre')], book.title);
        expect(record[headers.indexOf('Auteur')], 'NGOË');
        for (final entry in {
          'Sous-titre': 'Sous-titre',
          'Éditeur': 'Éditeur',
          'Collection': 'Folio',
          'Numéro dans la collection': '42',
          'Langue': 'fra',
          'Langue originale': 'eng',
          'Résumé': 'Résumé\nDeuxième ligne',
          'Sujets': 'Histoire, Cameroun',
          'Dewey': '966.71',
          'Édition': '2e édition',
          'Pagination': '120',
          'Source de la notice': 'BnF',
          'Identifiant de la notice': 'ark:123',
          'Date de récupération': '2026-10-05T00:00:00Z',
        }.entries) {
          expect(record[headers.indexOf(entry.key)], entry.value);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
