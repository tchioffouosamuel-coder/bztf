import 'package:xml/xml.dart';

import '../services/notice/notice_source.dart';

List<NoticeResult> parseUnimarcNotices(
  String xmlText, {
  required String sourceNotice,
  DateTime? dateRecuperation,
}) {
  final document = XmlDocument.parse(xmlText);
  final records = document.descendants
      .whereType<XmlElement>()
      .where((element) => _localName(element) == 'record')
      .where((element) => _fields(element).isNotEmpty);

  return records
      .map(
        (record) => _parseRecord(
          record,
          sourceNotice: sourceNotice,
          dateRecuperation: dateRecuperation,
        ),
      )
      .where((notice) => notice.title.trim().isNotEmpty)
      .toList();
}

NoticeResult _parseRecord(
  XmlElement record, {
  required String sourceNotice,
  DateTime? dateRecuperation,
}) {
  final titleField = _field(record, '200');
  final publication = _field(record, '214') ?? _field(record, '210');
  final physical = _field(record, '215');
  final collection = _field(record, '225');
  final language = _field(record, '101');
  final identifier = _control(record, '001') ?? _control(record, '003');
  final authors = [
    for (final field in [
      ..._fields(record, '700'),
      ..._fields(record, '701'),
      ..._fields(record, '702'),
    ])
      _author(field),
  ].where((author) => author.nom.isNotEmpty).toList();

  return NoticeResult(
    title: _sf(titleField, 'a') ?? '',
    sousTitre: _sf(titleField, 'e'),
    auteurs: authors,
    editeur: _sf(publication, 'c'),
    lieuPublication: _sf(publication, 'a'),
    datePublication: _sf(publication, 'd'),
    edition: _sf(_field(record, '205'), 'a'),
    nbPages: _sf(physical, 'a'),
    illustrations: _sf(physical, 'c'),
    dimensions: _sf(physical, 'd'),
    collection: _sf(collection, 'a'),
    numeroCollection: _sf(collection, 'v'),
    langue: _sf(language, 'a'),
    langueOriginale: _sf(language, 'c'),
    resume: _sf(_field(record, '330'), 'a'),
    sujets: [
      for (final field in _fields(record, '606'))
        _joinSubfields(field, const ['a', 'x', 'y', 'z']),
    ].where((subject) => subject.isNotEmpty).toList(),
    indiceClassification: _sf(_field(record, '676'), 'a'),
    sourceNotice: sourceNotice,
    identifiantSource: identifier,
    dateRecuperation: dateRecuperation,
  );
}

NoticeAuthor _author(XmlElement field) {
  final lastName = _sf(field, 'a') ?? '';
  final firstName = _sf(field, 'b') ?? '';
  final name = [lastName, firstName].where((part) => part.isNotEmpty).join(' ');
  return NoticeAuthor(nom: name, role: _role(_sf(field, '4')));
}

String _role(String? code) => switch (code) {
  '070' => 'auteur',
  '730' => 'traducteur',
  '440' => 'illustrateur',
  _ => 'auteur',
};

String? _control(XmlElement record, String tag) => record.children
    .whereType<XmlElement>()
    .where((element) => _localName(element) == 'controlfield')
    .where((element) => element.getAttribute('tag') == tag)
    .map((element) => _clean(element.innerText))
    .firstWhere((value) => value.isNotEmpty, orElse: () => '');

XmlElement? _field(XmlElement record, String tag) =>
    _fields(record, tag).firstOrNull;

List<XmlElement> _fields(XmlElement record, [String? tag]) => record.children
    .whereType<XmlElement>()
    .where((element) => _localName(element) == 'datafield')
    .where((element) => tag == null || element.getAttribute('tag') == tag)
    .toList();

String? _sf(XmlElement? field, String code) {
  if (field == null) return null;
  final value = field.children
      .whereType<XmlElement>()
      .where((element) => _localName(element) == 'subfield')
      .where((element) => element.getAttribute('code') == code)
      .map((element) => _clean(element.innerText))
      .firstWhere((text) => text.isNotEmpty, orElse: () => '');
  return value.isEmpty ? null : value;
}

String _joinSubfields(XmlElement field, List<String> codes) => codes
    .map((code) => _sf(field, code))
    .whereType<String>()
    .where((value) => value.isNotEmpty)
    .join(' -- ');

String _localName(XmlElement element) => element.name.local;

String _clean(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();
