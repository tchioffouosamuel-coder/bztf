import 'package:flutter/material.dart';

import '../data/library_database.dart';
import '../models/book.dart';
import '../widgets/status_pill.dart';

class BookSearchDelegate extends SearchDelegate<Book?> {
  BookSearchDelegate(this.database, {this.encodedOnly = false})
    : super(
        searchFieldLabel: encodedOnly
            ? 'Livre encodé à localiser'
            : 'Titre, auteur, ISBN ou numéro',
      );

  final LibraryDatabase database;
  final bool encodedOnly;

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        tooltip: 'Effacer',
        onPressed: () => query = '',
        icon: const Icon(Icons.close),
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: 'Retour',
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final term = query.trim();
    if (term.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Recherchez un titre, un auteur, un ISBN ou un numéro de livre.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return FutureBuilder<List<Book>>(
      future: database.listBooks(
        search: term,
        status: encodedOnly ? 'encode' : 'tous',
        limit: 60,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Recherche impossible : ${snapshot.error}'),
          );
        }
        final books = snapshot.data ?? const [];
        if (books.isEmpty) {
          return Center(
            child: Text(
              encodedOnly
                  ? 'Aucun livre encodé trouvé.'
                  : 'Aucun livre trouvé.',
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: books.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
          itemBuilder: (context, index) {
            final book = books[index];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 5,
              ),
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${book.author.isEmpty ? 'Auteur non renseigné' : book.author} · ${book.accession}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 15,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          book.shelf.isEmpty
                              ? 'Position non renseignée'
                              : book.shelf,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              trailing: StatusPill(book.status),
              onTap: () => close(context, book),
            );
          },
        );
      },
    );
  }
}
