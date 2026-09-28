import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';

import 'library_database.dart';

class CatalogImporter {
  CatalogImporter(this.database);

  final LibraryDatabase database;

  Future<int> importBytes(List<int> bytes) async {
    final workbook = Excel.decodeBytes(bytes);
    final records = <Map<String, Object?>>[];

    for (final entry in workbook.tables.entries) {
      final rows = entry.value.rows;
      if (rows.length < 2) continue;
      final headers = <String, int>{};
      for (var column = 0; column < rows.first.length; column++) {
        headers[_header(_cell(rows.first[column]))] = column;
      }
      if (!headers.containsKey('TITRE') || !headers.containsKey('AUTEURS')) {
        throw FormatException(
          'La feuille « ${entry.key} » doit contenir TITRE et AUTEURS.',
        );
      }
      String at(List<Data?> row, String name) {
        final column = headers[name];
        return column == null || column >= row.length ? '' : _cell(row[column]);
      }

      for (var index = 1; index < rows.length; index++) {
        final row = rows[index];
        final rawTitle = at(row, 'TITRE');
        final rawAuthor = at(row, 'AUTEURS');
        final legacyBible =
            rawAuthor.isNotEmpty && RegExp(r'^[\d\s./-]+$').hasMatch(rawTitle);
        final title = legacyBible ? rawAuthor : rawTitle;
        final author = legacyBible ? '' : rawAuthor;
        if (title.isEmpty) {
          continue;
        }
        final building = at(row, 'BATIMENT');
        final room = at(row, 'SALLE');
        final shelfName = at(row, 'ETAGERE');
        final block = at(row, 'NUMERO_DE_BLOC');
        final shelf = [
          building,
          room,
          shelfName,
          block,
        ].where((part) => part.isNotEmpty).join(' · ');
        final isbn = at(row, 'ISBN');
        final image = at(row, 'IMAGE');
        final sourceValues = [
          entry.key,
          index + 1,
          rawTitle,
          rawAuthor,
          isbn,
          image,
          shelf,
        ].join('\u001f');
        final legacyNumber = legacyBible ? 'Numéro source : $rawTitle' : '';
        final noteParts = [
          legacyNumber,
          if (at(row, 'SECTION').isNotEmpty) 'Section : ${at(row, 'SECTION')}',
          if (at(row, 'SOUS_SECTION').isNotEmpty)
            'Sous-section : ${at(row, 'SOUS_SECTION')}',
          if (at(row, 'PAGES').isNotEmpty) 'Pages : ${at(row, 'PAGES')}',
          if (at(row, 'TYPE_DE_DOC').isNotEmpty)
            'Type : ${at(row, 'TYPE_DE_DOC')}',
          if (at(row, 'LANGUE').isNotEmpty) 'Langue : ${at(row, 'LANGUE')}',
          if (image.isNotEmpty) 'Image : $image',
          if (at(row, 'RESUME').isNotEmpty) 'Résumé : ${at(row, 'RESUME')}',
        ].where((part) => part.isNotEmpty).join('\n');
        final yearMatch = RegExp(
          r'\b(1\d{3}|20\d{2})\b',
        ).firstMatch(at(row, 'DATE_PUBLICATION'));
        final parsedYear = yearMatch == null ? '' : yearMatch.group(1)!;
        final publicationYear =
            parsedYear.isNotEmpty &&
                int.parse(parsedYear) <= DateTime.now().year + 1
            ? parsedYear
            : '';

        records.add({
          'import_key': sha256
              .convert(utf8.encode('biblio-xlsx-v1\u001f$sourceValues'))
              .toString(),
          'title': title,
          'author': author,
          'isbn': isbn,
          'publisher': at(row, 'EDITEUR'),
          'publication_year': publicationYear,
          'category': at(row, 'SOUS_CATEGORIE').isNotEmpty
              ? at(row, 'SOUS_CATEGORIE')
              : at(row, 'CATEGORIE').isNotEmpty
              ? at(row, 'CATEGORIE')
              : at(row, 'SECTION'),
          'shelf': shelf,
          'notes': noteParts,
        });
      }
    }

    if (records.isEmpty) {
      throw const FormatException(
        'Le classeur ne contient aucun livre exploitable.',
      );
    }
    return database.importBooks(records);
  }

  static String _cell(Data? cell) => cell?.value?.toString().trim() ?? '';

  static String _header(String value) => value
      .toUpperCase()
      .replaceAll(RegExp('[ÀÁÂÃÄÅ]'), 'A')
      .replaceAll(RegExp('[ÈÉÊË]'), 'E')
      .replaceAll(RegExp('[ÌÍÎÏ]'), 'I')
      .replaceAll(RegExp('[ÒÓÔÕÖ]'), 'O')
      .replaceAll(RegExp('[ÙÚÛÜ]'), 'U')
      .replaceAll(RegExp('[Ç]'), 'C')
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
