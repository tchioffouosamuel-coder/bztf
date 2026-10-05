import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart' as csv;
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book.dart';
import '../models/lending.dart';

Uint8List encodeCsvRows(List<List<dynamic>> rows) =>
    Uint8List.fromList(utf8.encode(csv.Csv.excel().encode(rows)));

Uint8List catalogCsvBytes(List<Book> books) {
  final rows = <List<dynamic>>[
    [
      'Numéro',
      'Titre',
      'Auteur',
      'ISBN',
      'Catégorie',
      'Rayon',
      'Statut',
      'EPC',
      'TID',
      'Sous-titre',
      'Éditeur',
      'Date de publication',
      'Collection',
      'Numéro dans la collection',
      'Langue',
      'Langue originale',
      'Résumé',
      'Sujets',
      'Dewey',
      'Édition',
      'Pagination',
      'Source de la notice',
      'Identifiant de la notice',
      'Date de récupération',
      'Type de document',
      'Localisation',
      'Statut de l’exemplaire',
      'Brouillon',
      'Notes',
    ],
    for (final book in books)
      [
        book.accession,
        book.title,
        book.author,
        book.isbn,
        book.category,
        book.shelf,
        book.status,
        book.epc,
        book.tid ?? '',
        book.subtitle,
        book.publisher,
        book.publicationYear,
        book.collection,
        book.collectionNumber,
        book.language,
        book.originalLanguage,
        book.summary,
        book.subjects,
        book.dewey,
        book.edition,
        book.pageCount,
        book.sourceNotice,
        book.sourceIdentifier,
        book.retrievedAt ?? '',
        book.documentType,
        book.location,
        book.itemStatus,
        book.catalogDraft ? 'Oui' : 'Non',
        book.notes,
      ],
  ];
  return encodeCsvRows(rows);
}

Future<void> shareCatalogCsv(List<Book> books) async {
  final directory = await getDatabasesPath();
  final file = File(path.join(directory, 'biblio-rfid.csv'));
  await file.writeAsBytes(catalogCsvBytes(books), flush: true);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)], subject: 'Export BiblioRFID'),
  );
}

/// Historique des emprunts (terminal admin).
Future<void> shareLoansCsv(List<Loan> loans) async {
  String status(Loan loan) => loan.returned
      ? (loan.late ? 'Rendu en retard' : 'Rendu')
      : (loan.overdue ? 'En retard' : 'En cours');
  final rows = <List<dynamic>>[
    [
      'Numéro',
      'Titre',
      'N° abonné',
      'Abonné',
      'Emprunté le',
      'Retour prévu',
      'Rendu le',
      'Statut',
    ],
    for (final loan in loans)
      [
        loan.bookAccession ?? '',
        loan.bookTitle ?? '',
        loan.memberNumber ?? '',
        loan.subscriberName ?? '',
        loan.borrowedAt,
        loan.dueAt,
        loan.returnedAt ?? '',
        status(loan),
      ],
  ];
  final content = csv.Csv.excel().encode(rows);
  final directory = await getDatabasesPath();
  final file = File(path.join(directory, 'biblio-rfid-emprunts.csv'));
  await file.writeAsString(content, flush: true);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)], subject: 'Emprunts BiblioRFID'),
  );
}
