import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/catalog_exporter.dart';
import '../data/catalog_importer.dart';
import '../models/book.dart';
import '../services/library_controller.dart';
import '../widgets/book_editor.dart';
import '../widgets/status_pill.dart';
import '../app.dart';

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  final _search = TextEditingController();
  Timer? _searchDebounce;
  bool _working = false;

  @override
  void dispose() {
    _search.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _edit([Book? book]) async {
    final values = await BookEditor.show(context, book: book);
    if (values == null || !mounted) return;
    try {
      if (book == null) {
        await widget.controller.createBook(values);
      } else {
        await widget.controller.updateBook(book.id, values);
      }
      if (mounted) {
        showMessage(
          context,
          book == null ? 'Livre ajouté au catalogue.' : 'Livre mis à jour.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _import() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() => _working = true);
      final imported = await CatalogImporter(
        widget.controller.database,
      ).importBytes(bytes);
      await widget.controller.catalogImported();
      if (mounted) showMessage(context, '$imported livre(s) importé(s).');
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _export() async {
    try {
      final books = await widget.controller.database.listBooks(limit: 100000);
      await shareCatalogCsv(books);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _delete(Book book) async {
    final confirmed = await confirmAction(
      context,
      title: 'Supprimer ce livre ?',
      message: '« ${book.title} » sera retiré du catalogue.',
      confirmLabel: 'Supprimer',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.controller.deleteBook(book);
      if (mounted) showMessage(context, 'Livre supprimé.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  void _unencode(Book book) {
    widget.controller.selectForErasure(book);
    widget.controller.setView('station');
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${controller.totalBooks} livres${controller.books.length < controller.totalBooks ? ' · ${controller.books.length} affichés' : ''}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Importer XLSX',
                    onPressed: _working ? null : _import,
                    icon: const Icon(Icons.upload_file_outlined),
                  ),
                  IconButton(
                    tooltip: 'Exporter CSV',
                    onPressed: _export,
                    icon: const Icon(Icons.download_outlined),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Nouveau livre',
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              TextField(
                controller: _search,
                onChanged: (value) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 250),
                    () => controller.setSearch(value),
                  );
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Titre, auteur, ISBN, numéro…',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            controller.setSearch('');
                            setState(() {});
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'tous', label: Text('Tous')),
                    ButtonSegment(value: 'a_encoder', label: Text('À encoder')),
                    ButtonSegment(value: 'encode', label: Text('Encodés')),
                  ],
                  selected: {controller.statusFilter},
                  onSelectionChanged: (selection) =>
                      controller.setStatusFilter(selection.first),
                ),
              ),
            ],
          ),
        ),
        if (_working) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: controller.books.isEmpty
              ? const Center(child: Text('Aucun livre trouvé.'))
              : RefreshIndicator(
                  onRefresh: controller.loadBooks,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                    itemCount:
                        controller.books.length +
                        (controller.books.length < controller.totalBooks
                            ? 1
                            : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      if (index == controller.books.length) {
                        return Center(
                          child: TextButton.icon(
                            onPressed: () => controller.loadBooks(reset: false),
                            icon: const Icon(Icons.expand_more),
                            label: const Text('Charger plus'),
                          ),
                        );
                      }
                      final book = controller.books[index];
                      return _BookCard(
                        book: book,
                        onEncode: () {
                          controller.selectForEncoding(book);
                          controller.setView('station');
                        },
                        onUnencode: () => _unencode(book),
                        onEdit: () => _edit(book),
                        onDelete: () => _delete(book),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onEncode,
    required this.onUnencode,
    required this.onEdit,
    required this.onDelete,
  });

  final Book book;
  final VoidCallback onEncode;
  final VoidCallback onUnencode;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5F0ED),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.menu_book_outlined,
                  size: 20,
                  color: Color(0xFF187C6D),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      book.author.isEmpty
                          ? 'Auteur non renseigné'
                          : book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(book.status),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            book.accession,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          Text(
            book.shelf.isEmpty ? 'Localisation non renseignée' : book.shelf,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 0,
              children: [
                IconButton(
                  tooltip: 'Ouvrir dans la station',
                  onPressed: onEncode,
                  icon: const Icon(Icons.radar_outlined),
                ),
                if (book.status == 'encode')
                  IconButton(
                    tooltip: 'Désencoder le tag',
                    onPressed: onUnencode,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                IconButton(
                  tooltip: 'Modifier',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Supprimer',
                  onPressed: onDelete,
                  color: Theme.of(context).colorScheme.error,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
