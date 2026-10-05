import 'package:flutter/material.dart';

import '../app.dart';
import '../models/book.dart';
import '../services/catalogue_duplicates.dart';
import '../services/library_controller.dart';
import 'book_details.dart';

class DuplicateReview extends StatefulWidget {
  const DuplicateReview({super.key, required this.controller});
  final LibraryController controller;
  @override
  State<DuplicateReview> createState() => _DuplicateReviewState();
}

class _DuplicateReviewState extends State<DuplicateReview> {
  late final _service = CatalogueDuplicates(widget.controller.database);
  late Future<List<DuplicatePair>> _pairs;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _pairs = _service.detect();
  }

  Future<void> _ignore(DuplicatePair pair) async {
    setState(() => _busy = true);
    try {
      await _service.ignore(pair);
      if (mounted) setState(() => _pairs = _service.detect());
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _book(Book book) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(book.title, style: Theme.of(context).textTheme.titleMedium),
        Text(book.author),
        Text('${book.publisher} · ${book.publicationYear}'),
        Text('${book.edition} · ${book.pageCount}'),
        Text('ISBN : ${book.isbn}'),
        Text('Cote : ${book.shelf}'),
        Text(book.accession),
        Text('EPC : ${book.epc}', style: Theme.of(context).textTheme.bodySmall),
        TextButton(
          onPressed: () => BookDetails.show(
            context,
            controller: widget.controller,
            book: book,
          ),
          child: const Text('Ouvrir la fiche'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Un ISBN commun peut correspondre à deux exemplaires physiques. Vérifiez les fiches avant de les ignorer. '
          'La fusion reste à traiter pour conserver les identités RFID, les prêts et les activités synchronisés.',
        ),
      ),
      TextButton.icon(
        onPressed: _busy
            ? null
            : () => setState(() => _pairs = _service.detect()),
        icon: const Icon(Icons.refresh),
        label: const Text('Actualiser la revue'),
      ),
      Expanded(
        child: FutureBuilder<List<DuplicatePair>>(
          future: _pairs,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Revue indisponible : ${snapshot.error}'),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.data!.isEmpty) {
              return const Center(
                child: Text('Aucun doublon suspect à revoir.'),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: snapshot.data!.length,
              itemBuilder: (context, index) {
                final pair = snapshot.data![index];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          pair.kind == DuplicateKind.certain
                              ? 'Même ISBN-13'
                              : 'Titre et auteur proches',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _book(pair.first),
                            const SizedBox(width: 16),
                            _book(pair.second),
                          ],
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonal(
                          onPressed: _busy ? null : () => _ignore(pair),
                          child: const Text(
                            'Deux exemplaires distincts, ignorer',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}
