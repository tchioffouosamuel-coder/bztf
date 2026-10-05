import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/isbn.dart';
import '../../core/unimarc.dart';
import 'notice_source.dart';

class BnfSruSource implements NoticeSource {
  BnfSruSource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  String get name => 'BnF';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async {
    final isbn10 = Isbn.toIsbn10(isbn13);
    if (isbn10 == null) return const [];
    final uri = Uri.https('catalogue.bnf.fr', '/api/SRU', {
      'version': '1.2',
      'operation': 'searchRetrieve',
      // Vérifié par curl le 05/10/2026 : la forme ISBN-13 du brief renvoie
      // numberOfRecords=0, tandis que l'ISBN-10 avec `adj` renvoie la notice.
      'query': 'bib.isbn adj "$isbn10"',
      'recordSchema': 'unimarcxchange',
    });
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw NoticeSourceUnavailableException('BnF indisponible.');
    }
    return parseUnimarcNotices(
      utf8.decode(response.bodyBytes),
      sourceNotice: name,
      dateRecuperation: DateTime.now().toUtc(),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
