import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/catalogue_text.dart';
import '../core/isbn.dart';
import '../data/library_database.dart';
import '../models/book.dart';

enum DuplicateKind { certain, probable }

class DuplicatePair {
  const DuplicatePair(this.first, this.second, this.kind);
  final Book first;
  final Book second;
  final DuplicateKind kind;
  String get key => '${first.id}:${second.id}';
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final book in [first, second])
              [
                book.title,
                book.subtitle,
                book.author,
                book.isbn,
                book.publisher,
                book.publicationYear,
                book.edition,
                book.collectionNumber,
                book.pageCount,
              ],
          ]),
        ),
      )
      .toString();
}

int levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = <int>[i];
    for (var j = 1; j <= b.length; j++) {
      final insert = current[j - 1] + 1;
      final delete = previous[j] + 1;
      final replace = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      current.add([insert, delete, replace].reduce((a, b) => a < b ? a : b));
    }
    previous = current;
  }
  return previous.last;
}

bool _close(String a, String b, double threshold) {
  if (a.isEmpty || b.isEmpty) return false;
  final length = a.length > b.length ? a.length : b.length;
  if ((a.length - b.length).abs() > length * (1 - threshold)) return false;
  return 1 - levenshtein(a, b) / length >= threshold;
}

String _isbn(Book book) =>
    Isbn.isValid(book.isbn) ? Isbn.toIsbn13(book.isbn) : '';

/// Seuils : titre >= 92 %, auteur >= 90 %. Les différences numériques
/// (tomes/volumes), sous-titres ou éditions connues excluent les probables.
/// Deux ISBN valides différents sont des éditions distinctes. Un ISBN commun
/// reste un candidat certain à revoir, jamais une fusion automatique.
DuplicateKind? classifyDuplicate(Book a, Book b) {
  final isbnA = _isbn(a), isbnB = _isbn(b);
  if (isbnA.isNotEmpty && isbnA == isbnB) return DuplicateKind.certain;
  if (isbnA.isNotEmpty && isbnB.isNotEmpty) return null;
  for (final values in [
    (a.publisher, b.publisher),
    (a.publicationYear, b.publicationYear),
    (a.edition, b.edition),
    (a.collectionNumber, b.collectionNumber),
    (a.subtitle, b.subtitle),
  ]) {
    final left = normalizeBibliography(values.$1),
        right = normalizeBibliography(values.$2);
    if (left.isNotEmpty && right.isNotEmpty && left != right) return null;
  }
  final titleA = normalizeBibliography(a.title),
      titleB = normalizeBibliography(b.title);
  final numbersA = RegExp(
    r'\b\d+\b',
  ).allMatches(titleA).map((m) => m.group(0)).join(',');
  final numbersB = RegExp(
    r'\b\d+\b',
  ).allMatches(titleB).map((m) => m.group(0)).join(',');
  if (numbersA != numbersB) return null;
  final volumes = RegExp(r'\b(?:tome|volume|vol|t)\s+([ivxlcdm]+|\d+)\b');
  if (volumes.firstMatch(titleA)?.group(1) !=
      volumes.firstMatch(titleB)?.group(1)) {
    return null;
  }
  return _close(titleA, titleB, .92) &&
          _close(
            normalizeBibliography(a.author),
            normalizeBibliography(b.author),
            .90,
          )
      ? DuplicateKind.probable
      : null;
}

class CatalogueDuplicates {
  CatalogueDuplicates(this.database);
  final LibraryDatabase database;

  Future<List<DuplicatePair>> detect() async {
    final books = await database.listBooks(limit: 1000000);
    final ignored = {
      for (final row in await (await database.database).query(
        'catalog_duplicate_ignored',
      ))
        '${row['first_id']}:${row['second_id']}': row['fingerprint'],
    };
    final detected = await compute(detectDuplicatePairs, books);
    return detected
        .where((pair) => ignored[pair.key] != pair.fingerprint)
        .toList();
  }

  Future<void> ignore(DuplicatePair pair) async {
    await (await database.database).rawInsert(
      'INSERT OR REPLACE INTO catalog_duplicate_ignored(first_id, second_id, fingerprint) VALUES (?, ?, ?)',
      [pair.first.id, pair.second.id, pair.fingerprint],
    );
  }
}

List<DuplicatePair> detectDuplicatePairs(List<Book> books) {
  final pairs = <DuplicatePair>[];
  // Partage d'un trigramme obligatoire pour des titres proches : réduit les
  // comparaisons, sans imposer que la première lettre soit identique.
  final isbnBuckets = <String, List<Book>>{}, grams = <String, List<Book>>{};
  for (final book in books.reversed) {
    final isbn = _isbn(book);
    final title = normalizeBibliography(book.title);
    final candidates = <int, Book>{
      if (isbn.isNotEmpty)
        for (final candidate in isbnBuckets[isbn] ?? <Book>[])
          candidate.id: candidate,
      for (final gram in title.length < 3 ? {title} : catalogueTrigrams(title))
        for (final candidate in grams[gram] ?? <Book>[])
          candidate.id: candidate,
    };
    for (final candidate in candidates.values) {
      final kind = classifyDuplicate(candidate, book);
      if (kind == null) continue;
      final pair = DuplicatePair(candidate, book, kind);
      pairs.add(pair);
    }
    if (isbn.isNotEmpty) (isbnBuckets[isbn] ??= []).add(book);
    for (final gram in catalogueTrigrams(title)) {
      (grams[gram] ??= []).add(book);
    }
    if (title.length < 3) (grams[title] ??= []).add(book);
  }
  return pairs;
}
