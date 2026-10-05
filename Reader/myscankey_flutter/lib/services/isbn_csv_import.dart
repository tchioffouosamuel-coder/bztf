import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';

import '../core/catalogue_text.dart';
import '../core/isbn.dart';
import '../data/catalog_exporter.dart';
import '../data/library_database.dart';
import 'notice/bnf_sru_source.dart';
import 'notice/google_books_source.dart';
import 'notice/notice_lookup_service.dart';
import 'notice/open_library_source.dart';
import 'notice/rate_limited_client.dart';
import 'notice/sudoc_source.dart';

class IsbnImportRow {
  IsbnImportRow.fromMap(Map<String, Object?> map)
    : number = map['row_number'] as int,
      rawIsbn = map['raw_isbn'] as String,
      isbn13 = map['isbn13'] as String,
      state = map['state'] as String,
      detail = map['detail'] as String,
      bookId = map['book_id'] as int?;
  final int number;
  final String rawIsbn, isbn13, state, detail;
  final int? bookId;
  String get label => switch (state) {
    'found' => 'Trouvé — brouillon',
    'not_found' => 'Non trouvé',
    'duplicate' => 'Doublon ignoré',
    'error' => 'Erreur',
    'empty' => 'Ligne vide',
    _ => 'En attente',
  };
}

/// Journal SQL durable. Création du livre et état « trouvé » sont validés
/// dans la même transaction ; une interruption ne crée pas de double exemplaire.
class IsbnCsvImport extends ChangeNotifier {
  IsbnCsvImport(this.database, {this.lookupService, this.batchSize = 20});
  final LibraryDatabase database;
  final NoticeLookupService? lookupService;
  final int batchSize;
  String? jobId;
  String filename = '';
  List<IsbnImportRow> rows = [];
  bool running = false;
  bool _cancelled = false;
  bool _disposed = false;
  int _generation = 0;
  NoticeRateLimitedClient? _activeClient;
  int get completed => rows.where((row) => row.state != 'pending').length;
  int count(String state) => rows.where((row) => row.state == state).length;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadLatest() async {
    final jobs = await (await database.database).query(
      'isbn_import_jobs',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (jobs.isEmpty) return;
    jobId = jobs.single['id'] as String;
    filename = jobs.single['filename'] as String;
    await refresh();
  }

  Future<void> refresh() async {
    if (jobId == null) return;
    rows = (await (await database.database).query(
      'isbn_import_rows',
      where: 'job_id = ?',
      whereArgs: [jobId],
      orderBy: 'row_number',
    )).map(IsbnImportRow.fromMap).toList();
    _notify();
  }

  Future<void> createJob(List<int> bytes, String name) async {
    if (running) throw StateError('Un traitement est déjà en cours.');
    final decoded = Csv(
      skipEmptyLines: false,
    ).decode(utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), ''));
    if (decoded.isEmpty) {
      throw const FormatException('Le fichier ne contient aucune ligne.');
    }
    final id = sha256.convert(bytes).toString();
    final db = await database.database;
    await db.transaction((txn) async {
      if ((await txn.query(
        'isbn_import_jobs',
        where: 'id = ?',
        whereArgs: [id],
      )).isNotEmpty) {
        return;
      }
      await txn.insert('isbn_import_jobs', {
        'id': id,
        'filename': name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      var firstNonEmpty = true;
      for (var i = 0; i < decoded.length; i++) {
        final raw = decoded[i].isEmpty
            ? ''
            : decoded[i].first.toString().trim();
        if (raw.isNotEmpty && firstNonEmpty) {
          firstNonEmpty = false;
          if (const [
            'isbn',
            'isbn 13',
            'isbn13',
            'isbn 10',
            'isbn10',
            'ean',
          ].contains(normalizeBibliography(raw))) {
            continue;
          }
        }
        final valid = Isbn.isValid(raw);
        await txn.insert('isbn_import_rows', {
          'job_id': id,
          'row_number': i + 1,
          'raw_isbn': raw,
          'isbn13': valid ? Isbn.toIsbn13(raw) : '',
          'state': raw.isEmpty
              ? 'empty'
              : valid
              ? 'pending'
              : 'error',
          'detail': raw.isEmpty
              ? 'Ligne vide ignorée.'
              : valid
              ? ''
              : 'ISBN invalide.',
        });
      }
    });
    jobId = id;
    filename = name;
    await refresh();
  }

  void cancel() {
    _cancelled = true;
    _generation++;
    _activeClient?.close();
    _notify();
  }

  Future<void> retryErrors() async {
    if (running || jobId == null) return;
    await (await database.database).rawUpdate(
      "UPDATE isbn_import_rows SET state='pending', detail='' WHERE job_id=? AND state='error' AND isbn13<>''",
      [jobId],
    );
    await refresh();
  }

  Future<void> _finish(
    IsbnImportRow row,
    String state,
    String detail, {
    int? bookId,
  }) async {
    await (await database.database).update(
      'isbn_import_rows',
      {'state': state, 'detail': detail, 'book_id': bookId},
      where: "job_id = ? AND row_number = ? AND state = 'pending'",
      whereArgs: [jobId, row.number],
    );
  }

  Future<void> run() async {
    if (running || jobId == null) return;
    running = true;
    _cancelled = false;
    final generation = ++_generation;
    bool cancelled() => _disposed || _cancelled || generation != _generation;
    final client = lookupService == null
        ? NoticeRateLimitedClient(isCancelled: cancelled)
        : null;
    _activeClient = client;
    final lookup =
        lookupService ??
        NoticeLookupService(
          database: database,
          sources: [
            BnfSruSource(client: client),
            SudocSource(client: client),
            OpenLibrarySource(client: client),
            GoogleBooksSource(client: client),
          ],
        );
    _notify();
    try {
      while (!cancelled()) {
        final pending = (await (await database.database).query(
          'isbn_import_rows',
          where: "job_id = ? AND state = 'pending'",
          whereArgs: [jobId],
          orderBy: 'row_number',
          limit: batchSize,
        )).map(IsbnImportRow.fromMap).toList();
        if (pending.isEmpty) break;
        for (final row in pending) {
          if (cancelled()) break;
          try {
            final books = await database.findBooksByIsbn(row.isbn13);
            if (cancelled()) break;
            if (books.isNotEmpty) {
              await _finish(
                row,
                'duplicate',
                'ISBN déjà au catalogue : ${books.first.accession}',
                bookId: books.first.id,
              );
            } else {
              final results = await lookup.lookup(
                row.isbn13,
                isCancelled: cancelled,
              );
              if (cancelled()) break;
              if (results.isEmpty) {
                await _finish(row, 'not_found', 'Aucune notice disponible.');
              } else if (results.first.dejaAuCatalogue) {
                await _finish(row, 'duplicate', 'ISBN déjà au catalogue.');
              } else {
                await database.createBook(
                  {
                    ...results.first.toBookFields(isbn: row.isbn13),
                    'catalog_draft': 1,
                    'document_type': '',
                    'notes':
                        'Rétroconversion CSV : notice à vérifier.${results.length > 1 ? ' ${results.length} éditions trouvées ; première proposition retenue.' : ''}',
                  },
                  importJobId: jobId,
                  importRowNumber: row.number,
                );
              }
            }
          } on NoticeLookupCancelledException {
            break;
          } on NoticeNotFoundException {
            if (!cancelled()) {
              await _finish(row, 'not_found', 'Aucune notice disponible.');
            }
          } catch (error) {
            if (!cancelled()) await _finish(row, 'error', error.toString());
          }
          await refresh();
        }
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      client?.close();
      _activeClient = null;
      running = false;
      await refresh();
    }
  }

  Uint8List reportCsvBytes() => encodeCsvRows([
    [
      'Ligne',
      'ISBN saisi',
      'ISBN-13',
      'Résultat',
      'Détail',
      'Identifiant local',
    ],
    for (final row in rows)
      [
        row.number,
        row.rawIsbn,
        row.isbn13,
        row.label,
        row.detail,
        row.bookId ?? '',
      ],
  ]);

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
