class Book {
  const Book({
    required this.id,
    required this.accession,
    required this.epc,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.tid,
    this.author = '',
    this.subtitle = '',
    this.isbn = '',
    this.publisher = '',
    this.publicationYear = '',
    this.collection = '',
    this.collectionNumber = '',
    this.language = '',
    this.originalLanguage = '',
    this.summary = '',
    this.subjects = '',
    this.dewey = '',
    this.edition = '',
    this.pageCount = '',
    this.sourceNotice = '',
    this.sourceIdentifier = '',
    this.retrievedAt,
    this.category = '',
    this.documentType = '',
    this.location = '',
    this.itemStatus = 'Disponible',
    this.catalogDraft = false,
    this.shelf = '',
    this.notes = '',
    this.taggedAt,
    this.serverId,
    this.serverRevision = 0,
    this.syncState = 'pending',
  });

  final int id;
  final String accession;
  final String epc;
  final String? tid;
  final String title;
  final String author;
  final String subtitle;
  final String isbn;
  final String publisher;
  final String publicationYear;
  final String collection;
  final String collectionNumber;
  final String language;
  final String originalLanguage;
  final String summary;
  final String subjects;
  final String dewey;
  final String edition;
  final String pageCount;
  final String sourceNotice;
  final String sourceIdentifier;
  final String? retrievedAt;
  final String category;
  final String documentType;
  final String location;
  final String itemStatus;
  final bool catalogDraft;
  final String shelf;
  final String notes;
  final String status;
  final String createdAt;
  final String updatedAt;
  final String? taggedAt;
  final String? serverId;
  final int serverRevision;
  final String syncState;

  factory Book.fromMap(Map<String, Object?> map) => Book(
    id: map['id'] as int,
    accession: map['accession'] as String,
    epc: map['epc'] as String,
    tid: map['tid'] as String?,
    title: map['title'] as String,
    author: map['author'] as String? ?? '',
    subtitle: map['subtitle'] as String? ?? '',
    isbn: map['isbn'] as String? ?? '',
    publisher: map['publisher'] as String? ?? '',
    publicationYear: map['publication_year'] as String? ?? '',
    collection: map['collection'] as String? ?? '',
    collectionNumber: map['collection_number'] as String? ?? '',
    language: map['language'] as String? ?? '',
    originalLanguage: map['original_language'] as String? ?? '',
    summary: map['summary'] as String? ?? '',
    subjects: map['subjects'] as String? ?? '',
    dewey: map['dewey'] as String? ?? '',
    edition: map['edition'] as String? ?? '',
    pageCount: map['page_count'] as String? ?? '',
    sourceNotice: map['source_notice'] as String? ?? '',
    sourceIdentifier: map['source_identifier'] as String? ?? '',
    retrievedAt: map['retrieved_at'] as String?,
    category: map['category'] as String? ?? '',
    documentType: map['document_type'] as String? ?? '',
    location: map['location'] as String? ?? '',
    itemStatus: map['item_status'] as String? ?? 'Disponible',
    catalogDraft: map['catalog_draft'] == 1,
    shelf: map['shelf'] as String? ?? '',
    notes: map['notes'] as String? ?? '',
    status: map['status'] as String,
    createdAt: map['created_at'] as String,
    updatedAt: map['updated_at'] as String,
    taggedAt: map['tagged_at'] as String?,
    serverId: map['server_id'] as String?,
    serverRevision: (map['server_revision'] as num?)?.toInt() ?? 0,
    syncState: map['sync_state'] as String? ?? 'pending',
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'accession': accession,
    'epc': epc,
    'tid': tid,
    'title': title,
    'author': author,
    'subtitle': subtitle,
    'isbn': isbn,
    'publisher': publisher,
    'publication_year': publicationYear,
    'collection': collection,
    'collection_number': collectionNumber,
    'language': language,
    'original_language': originalLanguage,
    'summary': summary,
    'subjects': subjects,
    'dewey': dewey,
    'edition': edition,
    'page_count': pageCount,
    'source_notice': sourceNotice,
    'source_identifier': sourceIdentifier,
    'retrieved_at': retrievedAt,
    'category': category,
    'document_type': documentType,
    'location': location,
    'item_status': itemStatus,
    'catalog_draft': catalogDraft ? 1 : 0,
    'shelf': shelf,
    'notes': notes,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'tagged_at': taggedAt,
    'server_id': serverId,
    'server_revision': serverRevision,
    'sync_state': syncState,
  };

  Map<String, Object?> toSyncJson() => {
    'serverId': serverId,
    'accession': accession,
    'epc': epc,
    'tid': tid,
    'title': title,
    'author': author,
    'subtitle': subtitle,
    'isbn': isbn,
    'publisher': publisher,
    'publicationYear': publicationYear,
    'collection': collection,
    'collectionNumber': collectionNumber,
    'language': language,
    'originalLanguage': originalLanguage,
    'summary': summary,
    'subjects': subjects,
    'dewey': dewey,
    'edition': edition,
    'pageCount': pageCount,
    'sourceNotice': sourceNotice,
    'sourceIdentifier': sourceIdentifier,
    'retrievedAt': retrievedAt,
    'category': category,
    'documentType': documentType,
    'location': location,
    'itemStatus': itemStatus,
    'shelf': shelf,
    'notes': notes,
    'status': status,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'taggedAt': taggedAt,
    'revision': serverRevision,
  };
}

class ReaderTag {
  const ReaderTag({
    required this.epc,
    required this.tid,
    required this.rssi,
    this.antenna = 0,
    this.count = 1,
  });

  final String epc;
  final String tid;
  final int rssi;
  final int antenna;
  final int count;

  factory ReaderTag.fromMap(Map<Object?, Object?> map) => ReaderTag(
    epc: (map['epc'] ?? '').toString().toUpperCase(),
    tid: (map['tid'] ?? '').toString().toUpperCase(),
    rssi: (map['rssi'] as num?)?.toInt() ?? 0,
    antenna: (map['antenna'] as num?)?.toInt() ?? 0,
    count: (map['count'] as num?)?.toInt() ?? 1,
  );
}

class InventoryRecord {
  const InventoryRecord({
    required this.tag,
    required this.firstSeen,
    required this.lastSeen,
    required this.readCount,
    this.book,
  });

  final ReaderTag tag;
  final Book? book;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int readCount;

  InventoryRecord copyWith({
    ReaderTag? tag,
    Book? book,
    bool preserveBook = true,
    DateTime? lastSeen,
    int? readCount,
  }) => InventoryRecord(
    tag: tag ?? this.tag,
    book: preserveBook ? (book ?? this.book) : book,
    firstSeen: firstSeen,
    lastSeen: lastSeen ?? this.lastSeen,
    readCount: readCount ?? this.readCount,
  );
}

class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.type,
    required this.result,
    required this.message,
    required this.createdAt,
    this.title,
    this.accession,
    this.epc,
    this.tid,
  });

  final int id;
  final String type;
  final String result;
  final String message;
  final String createdAt;
  final String? title;
  final String? accession;
  final String? epc;
  final String? tid;

  factory ActivityEntry.fromMap(Map<String, Object?> map) => ActivityEntry(
    id: map['id'] as int,
    type: map['type'] as String,
    result: map['result'] as String,
    message: map['message'] as String,
    createdAt: map['created_at'] as String,
    title: map['title'] as String?,
    accession: map['accession'] as String?,
    epc: map['epc'] as String?,
    tid: map['tid'] as String?,
  );
}

/// Exemplaire consultable au poste d'emprunt, avec sa disponibilité.
class CatalogEntry {
  const CatalogEntry({required this.book, this.dueAt});

  factory CatalogEntry.fromMap(Map<String, Object?> map) => CatalogEntry(
    book: Book.fromMap(map),
    dueAt: map['loan_due_at'] as String?,
  );

  final Book book;

  /// Retour prévu si l'exemplaire est emprunté.
  final String? dueAt;

  bool get onLoan => dueAt != null;
  bool get available => !onLoan && book.status != 'indisponible';
}
