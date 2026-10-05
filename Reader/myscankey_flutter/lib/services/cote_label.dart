import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/book.dart';
import 'cataloguing_preferences.dart';
import 'library_controller.dart';
import '../widgets/status_pill.dart';

String _short(String value, int max) {
  final chars = value.runes.toList();
  return chars.length <= max
      ? value
      : '${String.fromCharCodes(chars.take(max - 1))}…';
}

Future<Uint8List> buildCoteLabel(
  Book book,
  CataloguingPreferences settings,
) async {
  // Police embarquée : la création du PDF reste disponible hors ligne.
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/Montserrat-Variable.ttf'),
  );
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(
        settings.labelWidthMm * PdfPageFormat.mm,
        settings.labelHeightMm * PdfPageFormat.mm,
        marginAll: 2 * PdfPageFormat.mm,
      ),
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (_) => pw.Center(
        child: pw.FittedBox(
          child: pw.SizedBox(
            width: 170,
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  _short(book.shelf, 80),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 18),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  _short(book.title, 60),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 10),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  _short(book.author, 60),
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 9),
                ),
                pw.SizedBox(height: 5),
                pw.Text(book.accession, style: const pw.TextStyle(fontSize: 8)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return document.save();
}

Future<void> previewCoteLabel(
  BuildContext context,
  Book book, {
  LibraryController? controller,
}) async {
  final settings = await CataloguingPreferences.load();
  final bytes = await buildCoteLabel(book, settings);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('Étiquette de cote'),
          actions: [
            if (controller != null)
              AnimatedBuilder(
                animation: controller,
                builder: (_, _) => Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: StatusPill(
                    controller.readerConnected
                        ? 'reader_connected'
                        : 'reader_disconnected',
                  ),
                ),
              ),
          ],
        ),
        body: PdfPreview(
          build: (_) async => bytes,
          initialPageFormat: PdfPageFormat(
            settings.labelWidthMm * PdfPageFormat.mm,
            settings.labelHeightMm * PdfPageFormat.mm,
          ),
          canChangePageFormat: false,
          canChangeOrientation: false,
          allowSharing: false,
          pdfFileName: '${book.accession}.pdf',
        ),
      ),
    ),
  );
}
