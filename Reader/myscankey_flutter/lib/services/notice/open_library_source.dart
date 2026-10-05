import 'dart:convert';

import 'package:http/http.dart' as http;

import 'notice_source.dart';

class OpenLibrarySource implements NoticeSource {
  OpenLibrarySource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  String get name => 'Open Library';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async {
    final response = await _client.get(
      Uri.https('openlibrary.org', '/isbn/$isbn13.json'),
    );
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw NoticeSourceUnavailableException('Open Library indisponible.');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final title = json['title']?.toString().trim() ?? '';
    if (title.isEmpty) return const [];
    final authors = (json['authors'] as List? ?? const [])
        .whereType<Map>()
        .map((author) => author['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .map((name) => NoticeAuthor(nom: name))
        .toList();
    return [
      NoticeResult(
        title: title,
        auteurs: authors,
        editeur: (json['publishers'] as List?)?.firstOrNull?.toString(),
        datePublication: json['publish_date']?.toString(),
        nbPages: json['number_of_pages']?.toString(),
        sourceNotice: name,
        identifiantSource: json['key']?.toString(),
        dateRecuperation: DateTime.now().toUtc(),
      ),
    ];
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
