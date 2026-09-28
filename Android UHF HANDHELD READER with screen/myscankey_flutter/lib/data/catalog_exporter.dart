import 'dart:io';

import 'package:csv/csv.dart' as csv;
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../models/book.dart';

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
