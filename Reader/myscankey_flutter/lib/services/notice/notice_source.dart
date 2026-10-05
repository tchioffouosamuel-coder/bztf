import '../../models/book.dart';

class NoticeAuthor {
  const NoticeAuthor({required this.nom, this.role = 'auteur'});

  final String nom;
  final String role;

  Map<String, Object?> toJson() => {'nom': nom, 'role': role};

  factory NoticeAuthor.fromJson(Map<String, Object?> json) => NoticeAuthor(
    nom: json['nom']?.toString() ?? '',
    role: json['role']?.toString() ?? 'auteur',
  );
}

class NoticeResult {
  const NoticeResult({
    required this.title,
    required this.sourceNotice,
    this.sousTitre,
    this.auteurs = const [],
    this.editeur,
    this.lieuPublication,
    this.datePublication,
    this.edition,
    this.nbPages,
    this.illustrations,
    this.dimensions,
    this.collection,
    this.numeroCollection,
    this.langue,
    this.langueOriginale,
    this.resume,
    this.sujets = const [],
    this.indiceClassification,
    this.identifiantSource,
    this.dateRecuperation,
    this.dejaAuCatalogue = false,
    this.livresCatalogue = const [],
  });

  final String title;
  final String sourceNotice;
  final String? sousTitre;
  final List<NoticeAuthor> auteurs;
  final String? editeur;
  final String? lieuPublication;
  final String? datePublication;
  final String? edition;
  final String? nbPages;
  final String? illustrations;
  final String? dimensions;
  final String? collection;
  final String? numeroCollection;
  final String? langue;
  final String? langueOriginale;
  final String? resume;
  final List<String> sujets;
  final String? indiceClassification;
  final String? identifiantSource;
  final DateTime? dateRecuperation;
  final bool dejaAuCatalogue;
  final List<Book> livresCatalogue;

  Map<String, Object?> toBookFields({String? isbn}) => {
    'isbn': ?isbn,
    'title': title,
    'subtitle': sousTitre,
    'author': auteurs
        .where((author) => author.role == 'auteur')
        .map((author) => author.nom)
        .join('; '),
    'publisher': editeur,
    'publication_year': datePublication,
    'collection': collection,
    'collection_number': numeroCollection,
    'language': langue,
    'original_language': langueOriginale,
    'summary': resume,
    'subjects': sujets.join('; '),
    'dewey': indiceClassification,
    'edition': edition,
    'page_count': nbPages,
    'source_notice': sourceNotice,
    'source_identifier': identifiantSource,
    'retrieved_at': dateRecuperation?.toIso8601String(),
  };

  NoticeResult copyWith({
    String? title,
    String? sourceNotice,
    String? sousTitre,
    List<NoticeAuthor>? auteurs,
    String? editeur,
    String? lieuPublication,
    String? datePublication,
    String? edition,
    String? nbPages,
    String? illustrations,
    String? dimensions,
    String? collection,
    String? numeroCollection,
    String? langue,
    String? langueOriginale,
    String? resume,
    List<String>? sujets,
    String? indiceClassification,
    String? identifiantSource,
    DateTime? dateRecuperation,
    bool? dejaAuCatalogue,
    List<Book>? livresCatalogue,
  }) => NoticeResult(
    title: title ?? this.title,
    sourceNotice: sourceNotice ?? this.sourceNotice,
    sousTitre: sousTitre ?? this.sousTitre,
    auteurs: auteurs ?? this.auteurs,
    editeur: editeur ?? this.editeur,
    lieuPublication: lieuPublication ?? this.lieuPublication,
    datePublication: datePublication ?? this.datePublication,
    edition: edition ?? this.edition,
    nbPages: nbPages ?? this.nbPages,
    illustrations: illustrations ?? this.illustrations,
    dimensions: dimensions ?? this.dimensions,
    collection: collection ?? this.collection,
    numeroCollection: numeroCollection ?? this.numeroCollection,
    langue: langue ?? this.langue,
    langueOriginale: langueOriginale ?? this.langueOriginale,
    resume: resume ?? this.resume,
    sujets: sujets ?? this.sujets,
    indiceClassification: indiceClassification ?? this.indiceClassification,
    identifiantSource: identifiantSource ?? this.identifiantSource,
    dateRecuperation: dateRecuperation ?? this.dateRecuperation,
    dejaAuCatalogue: dejaAuCatalogue ?? this.dejaAuCatalogue,
    livresCatalogue: livresCatalogue ?? this.livresCatalogue,
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'sourceNotice': sourceNotice,
    'sousTitre': sousTitre,
    'auteurs': auteurs.map((author) => author.toJson()).toList(),
    'editeur': editeur,
    'lieuPublication': lieuPublication,
    'datePublication': datePublication,
    'edition': edition,
    'nbPages': nbPages,
    'illustrations': illustrations,
    'dimensions': dimensions,
    'collection': collection,
    'numeroCollection': numeroCollection,
    'langue': langue,
    'langueOriginale': langueOriginale,
    'resume': resume,
    'sujets': sujets,
    'indiceClassification': indiceClassification,
    'identifiantSource': identifiantSource,
    'dateRecuperation': dateRecuperation?.toIso8601String(),
  };

  factory NoticeResult.fromJson(Map<String, Object?> json) => NoticeResult(
    title: json['title']?.toString() ?? '',
    sourceNotice: json['sourceNotice']?.toString() ?? '',
    sousTitre: json['sousTitre']?.toString(),
    auteurs: (json['auteurs'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (author) => NoticeAuthor.fromJson(Map<String, Object?>.from(author)),
        )
        .where((author) => author.nom.isNotEmpty)
        .toList(),
    editeur: json['editeur']?.toString(),
    lieuPublication: json['lieuPublication']?.toString(),
    datePublication: json['datePublication']?.toString(),
    edition: json['edition']?.toString(),
    nbPages: json['nbPages']?.toString(),
    illustrations: json['illustrations']?.toString(),
    dimensions: json['dimensions']?.toString(),
    collection: json['collection']?.toString(),
    numeroCollection: json['numeroCollection']?.toString(),
    langue: json['langue']?.toString(),
    langueOriginale: json['langueOriginale']?.toString(),
    resume: json['resume']?.toString(),
    sujets: (json['sujets'] as List? ?? const [])
        .map((subject) => subject.toString())
        .where((subject) => subject.isNotEmpty)
        .toList(),
    indiceClassification: json['indiceClassification']?.toString(),
    identifiantSource: json['identifiantSource']?.toString(),
    dateRecuperation: DateTime.tryParse(
      json['dateRecuperation']?.toString() ?? '',
    ),
  );
}

abstract class NoticeSource {
  String get name;

  Future<List<NoticeResult>> lookup(String isbn13);
}

class NoticeSourceUnavailableException implements Exception {
  const NoticeSourceUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
