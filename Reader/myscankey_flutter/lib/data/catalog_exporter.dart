import 'dart:io';

import 'package:csv/csv.dart' as csv;
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book.dart';
import '../models/lending.dart';

Future<void> shareCatalogCsv(List<Book> books) async {
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
      ],
  ];
  final content = csv.Csv.excel().encode(rows);
  final directory = await getDatabasesPath();
  final file = File(path.join(directory, 'biblio-rfid.csv'));
  await file.writeAsString(content, flush: true);
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
