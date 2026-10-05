import 'dart:convert';

import 'package:http/http.dart' as http;

import 'notice_source.dart';

class GoogleBooksSource implements NoticeSource {
  GoogleBooksSource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  String get name => 'Google Books';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async {
    final response = await _client.get(
      Uri.https('www.googleapis.com', '/books/v1/volumes', {
        'q': 'isbn:$isbn13',
      }),
    );
    if (response.statusCode != 200) {
      throw NoticeSourceUnavailableException('Google Books indisponible.');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return (json['items'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
          final volume = Map<String, Object?>.from(
            item['volumeInfo'] as Map? ?? const {},
          );
          final title = volume['title']?.toString().trim() ?? '';
          if (title.isEmpty) return null;
          return NoticeResult(
            title: title,
            sousTitre: volume['subtitle']?.toString(),
            auteurs: (volume['authors'] as List? ?? const [])
                .map((author) => author.toString())
                .where((author) => author.isNotEmpty)
                .map((author) => NoticeAuthor(nom: author))
                .toList(),
            editeur: volume['publisher']?.toString(),
            datePublication: volume['publishedDate']?.toString(),
            resume: volume['description']?.toString(),
            nbPages: volume['pageCount']?.toString(),
            sujets: (volume['categories'] as List? ?? const [])
                .map((category) => category.toString())
                .where((category) => category.isNotEmpty)
                .toList(),
            sourceNotice: name,
            identifiantSource: item['id']?.toString(),
            dateRecuperation: DateTime.now().toUtc(),
          );
        })
        .whereType<NoticeResult>()
        .toList();
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
