import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../core/unimarc.dart';
import 'notice_source.dart';

class SudocSource implements NoticeSource {
  SudocSource({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  String get name => 'SUDOC';

  @override
  Future<List<NoticeResult>> lookup(String isbn13) async {
    final ppnUri = Uri.https('www.sudoc.fr', '/services/isbn2ppn/$isbn13');
    final ppnResponse = await _client.get(ppnUri);
    if (ppnResponse.statusCode != 200) {
      throw NoticeSourceUnavailableException('SUDOC indisponible.');
    }
    final ppns = _ppns(utf8.decode(ppnResponse.bodyBytes));
    final results = <NoticeResult>[];
    for (final ppn in ppns) {
      final uri = Uri.https('www.sudoc.fr', '/$ppn.xml');
      final response = await _client.get(uri);
      if (response.statusCode != 200) continue;
      results.addAll(
        parseUnimarcNotices(
          utf8.decode(response.bodyBytes),
          sourceNotice: name,
          dateRecuperation: DateTime.now().toUtc(),
        ).map(
          (notice) => notice.identifiantSource == null
              ? notice.copyWith(identifiantSource: ppn)
              : notice,
        ),
      );
    }
    return results;
  }

  List<String> _ppns(String xmlText) {
    final document = XmlDocument.parse(xmlText);
    if (document.descendants.whereType<XmlElement>().any(
      (element) => element.name.local == 'error',
    )) {
      return const [];
    }
    return document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'ppn')
        .map((element) => element.innerText.trim())
        .where((ppn) => ppn.isNotEmpty)
        .toList();
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
