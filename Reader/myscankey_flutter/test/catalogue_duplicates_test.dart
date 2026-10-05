import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:myscankey_flutter/data/library_database.dart';
import 'package:myscankey_flutter/models/book.dart';
import 'package:myscankey_flutter/services/catalogue_duplicates.dart';

Book _book(
  int id, {
  String title = 'Les aventures extraordinaires de Martin',
  String author = 'Victor Hugo',
  String isbn = '',
  String publisher = '',
  String year = '',
  String edition = '',
  String subtitle = '',
}) => Book.fromMap({
  'id': id,
  'accession': 'BCM-2026-$id',
  'epc': 'EPC$id',
  'title': title,
  'author': author,
  'isbn': isbn,
  'publisher': publisher,
  'publication_year': year,
  'edition': edition,
  'subtitle': subtitle,
  'status': 'a_encoder',
  'created_at': '',
  'updated_at': '',
});

void main() {
  test('ISBN certain : ISBN-10 et ISBN-13 normalisés', () {
    expect(
      classifyDuplicate(
        _book(1, isbn: '2-07-036002-4'),
        _book(2, isbn: '9782070360024'),
      ),
      DuplicateKind.certain,
    );
  });
  test('probable : accents, casse, ponctuation et petite erreur de titre', () {
    expect(
      classifyDuplicate(
        _book(1, title: 'L’Étranger, une aventure extraordinaire'),
        _book(2, title: 'l etranger une aventure extraordinairé'),
      ),
      DuplicateKind.probable,
    );
    expect(
      classifyDuplicate(
        _book(1),
        _book(2, title: 'Les aventures extraordinaires de Martim'),
      ),
      DuplicateKind.probable,
    );
  });
  test('ne rapproche pas des auteurs différents ni les titres vides', () {
    expect(
      classifyDuplicate(_book(1), _book(2, author: 'Albert Camus')),
      isNull,
    );
    expect(classifyDuplicate(_book(1, title: ''), _book(2, title: '')), isNull);
  });
  test('tomes numériques et romains distincts exclus', () {
    for (final volumes in [('1', '2'), ('I', 'II')]) {
      expect(
        classifyDuplicate(
          _book(
            1,
            title: 'Les aventures extraordinaires de Martin tome ${volumes.$1}',
          ),
          _book(
            2,
            title: 'Les aventures extraordinaires de Martin tome ${volumes.$2}',
          ),
        ),
        isNull,
      );
    }
    expect(
      classifyDuplicate(
        _book(1, subtitle: 'Le commencement'),
        _book(2, subtitle: 'La fin'),
      ),
      isNull,
    );
  });
  test(
    'rééditions : ISBN, dates ou mentions d’édition différentes exclues',
    () {
      expect(
        classifyDuplicate(
          _book(1, isbn: '9782070360024'),
          _book(2, isbn: '9782070408504'),
        ),
        isNull,
      );
      expect(
        classifyDuplicate(_book(1, year: '1942'), _book(2, year: '2000')),
        isNull,
      );
      expect(
        classifyDuplicate(
          _book(1, edition: '1re édition'),
          _book(2, edition: '2e édition'),
        ),
        isNull,
      );
      expect(
        classifyDuplicate(
          _book(1, publisher: 'Gallimard'),
          _book(2, publisher: 'Folio'),
        ),
        isNull,
      );
    },
  );
  test('détection retrouve les titres courts et ne répète pas une paire', () {
    final pairs = detectDuplicatePairs([
      _book(2, title: 'Ça'),
      _book(1, title: 'Ca'),
    ]);
    expect(pairs, hasLength(1));
    expect(pairs.single.first.id, 1);
    expect(pairs.single.second.id, 2);
  });

  test(
    'ignorer persiste sans modifier livres, prêts et activités ; correction remet la paire en revue',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'duplicates-test-',
      );
      await databaseFactory.setDatabasesPath(directory.path);
      final database = LibraryDatabase.instance;
      try {
        final first = await database.createBook({
          'title': 'L’Étranger',
          'author': 'Camus',
          'isbn': '9782070360024',
        });
        final second = await database.createBook({
          'title': 'L’Étranger',
          'author': 'Camus',
          'isbn': '9782070360024',
        });
        final loan = await database.borrowBook(
          first.id,
          memberNumber: 'TEST',
          name: 'Lecteur',
          dueAt: DateTime.now().add(const Duration(days: 7)),
        );
        final beforeActivities = await (await database.database).query(
          'activity',
        );
        final service = CatalogueDuplicates(database);
        final pairs = await service.detect();
        expect(pairs, hasLength(1));
        await service.ignore(pairs.single);
        expect(await service.detect(), isEmpty);
        expect((await database.activeLoanForBook(first.id))!.id, loan.id);
        expect(await database.getBook(second.id), isNotNull);
        expect(
          await (await database.database).query('activity'),
          beforeActivities,
        );
        await database.updateBook(second.id, {'title': 'Titre corrigé'});
        expect(await service.detect(), hasLength(1));
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
