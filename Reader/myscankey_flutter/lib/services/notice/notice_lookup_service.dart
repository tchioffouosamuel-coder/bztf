import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/isbn.dart';
import '../../data/library_database.dart';
import '../../models/book.dart';
import 'bnf_sru_source.dart';
import 'google_books_source.dart';
import 'notice_source.dart';
import 'open_library_source.dart';
import 'sudoc_source.dart';

typedef LocalBookLookup = Future<List<Book>> Function(String isbn13);

class NoticeLookupService {
  NoticeLookupService({
    List<NoticeSource>? sources,
    LibraryDatabase? database,
    LocalBookLookup? localLookup,
    NoticeLookupCache? cache,
    this.timeoutPerSource = const Duration(seconds: 5),
  }) : _sources =
           sources ??
           [
             BnfSruSource(),
             SudocSource(),
             OpenLibrarySource(),
             GoogleBooksSource(),
           ],
       _localLookup =
           localLookup ??
           ((isbn13) =>
               (database ?? LibraryDatabase.instance).findBooksByIsbn(isbn13)),
       _cache = cache ?? SharedPreferencesNoticeCache();

  final List<NoticeSource> _sources;
  final LocalBookLookup _localLookup;
  final NoticeLookupCache _cache;
  final Duration timeoutPerSource;

  Future<List<NoticeResult>> lookup(
    String isbn, {
    bool Function()? isCancelled,
  }) async {
    void checkCancellation() {
      if (isCancelled?.call() == true) {
        throw const NoticeLookupCancelledException();
      }
    }

    checkCancellation();
    late final String isbn13;
    try {
      isbn13 = Isbn.toIsbn13(isbn);
    } on FormatException {
      throw const NoticeLookupException('ISBN invalide.');
    }

    final localBooks = await _localLookup(isbn13);
    checkCancellation();
    if (localBooks.isNotEmpty) {
      return [
        NoticeResult(
          title: localBooks.first.title,
          sourceNotice: 'déjà au catalogue',
          dateRecuperation: DateTime.now().toUtc(),
          dejaAuCatalogue: true,
          livresCatalogue: localBooks,
        ),
      ];
    }

    final cached = await _cache.read(isbn13);
    checkCancellation();
    if (cached.isNotEmpty) return cached;

    var unavailableSources = 0;
    for (final source in _sources) {
      checkCancellation();
      try {
        final results = await source.lookup(isbn13).timeout(timeoutPerSource);
        checkCancellation();
        final usable = results
            .where((result) => result.title.trim().isNotEmpty)
            .map(
              (result) => result.copyWith(
                sourceNotice: result.sourceNotice.isEmpty
                    ? source.name
                    : result.sourceNotice,
                dateRecuperation:
                    result.dateRecuperation ?? DateTime.now().toUtc(),
              ),
            )
            .toList();
        if (usable.isNotEmpty) {
          await _cache.write(isbn13, usable);
          return usable;
        }
      } on TimeoutException {
        unavailableSources++;
      } on SocketException {
        unavailableSources++;
      } on http.ClientException {
        unavailableSources++;
      } on NoticeSourceUnavailableException {
        unavailableSources++;
      }
    }

    if (_sources.isNotEmpty && unavailableSources == _sources.length) {
      throw const NoticeNetworkException(
        'Aucune source bibliographique n’est joignable.',
      );
    }
    throw const NoticeNotFoundException(
      'Aucune notice bibliographique trouvée pour cet ISBN.',
    );
  }
}

class NoticeLookupCancelledException implements Exception {
  const NoticeLookupCancelledException();
}

class NoticeLookupException implements Exception {
  const NoticeLookupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NoticeNetworkException extends NoticeLookupException {
  const NoticeNetworkException(super.message);
}

class NoticeNotFoundException extends NoticeLookupException {
  const NoticeNotFoundException(super.message);
}

abstract class NoticeLookupCache {
  Future<List<NoticeResult>> read(String isbn13);

  Future<void> write(String isbn13, List<NoticeResult> results);
}

class SharedPreferencesNoticeCache implements NoticeLookupCache {
  SharedPreferencesNoticeCache({
    SharedPreferencesAsync? preferences,
    this.ttl = const Duration(days: 30),
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  final Duration ttl;

  @override
  Future<List<NoticeResult>> read(String isbn13) async {
    final raw = await _preferences.getString(_key(isbn13));
    if (raw == null) return const [];
    final json = jsonDecode(raw) as Map<String, Object?>;
    final expiresAt = DateTime.tryParse(json['expiresAt']?.toString() ?? '');
    if (expiresAt == null || expiresAt.isBefore(DateTime.now().toUtc())) {
      await _preferences.remove(_key(isbn13));
      return const [];
    }
    return (json['results'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => NoticeResult.fromJson(Map<String, Object?>.from(item)))
        .where((result) => result.title.isNotEmpty)
        .toList();
  }

  @override
  Future<void> write(String isbn13, List<NoticeResult> results) async {
    if (results.isEmpty) return;
    // `shared_preferences` suffit ici : cache non relationnel, clé ISBN-13,
    // durée courte, et aucune migration SQL supplémentaire à maintenir.
    await _preferences.setString(
      _key(isbn13),
      jsonEncode({
        'expiresAt': DateTime.now().toUtc().add(ttl).toIso8601String(),
        'results': results.map((result) => result.toJson()).toList(),
      }),
    );
  }

  String _key(String isbn13) => 'notice_lookup_cache_$isbn13';
}
