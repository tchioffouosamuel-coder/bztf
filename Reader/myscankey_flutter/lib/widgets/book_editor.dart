import 'package:flutter/material.dart';

import '../models/book.dart';

class BookEditor extends StatefulWidget {
  const BookEditor({super.key, this.book});

  final Book? book;

  static Future<Map<String, Object?>?> show(
    BuildContext context, {
    Book? book,
  }) => showDialog<Map<String, Object?>>(
    context: context,
    builder: (_) => BookEditor(book: book),
  );

  @override
  State<BookEditor> createState() => _BookEditorState();
}

class _BookEditorState extends State<BookEditor> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;

  static const _fieldNames = <String, String>{
    'title': 'Titre *',
    'author': 'Auteur',
    'isbn': 'ISBN',
    'publisher': 'Éditeur',
    'publication_year': 'Année de publication',
    'category': 'Catégorie',
    'shelf': 'Rayon / cote',
    'notes': 'Notes',
  };

  @override
  void initState() {
    super.initState();
    final book = widget.book;
    _fields = {
      for (final entry in _fieldNames.entries)
        entry.key: TextEditingController(
          text:
              switch (entry.key) {
                'title' => book?.title,
                'author' => book?.author,
                'isbn' => book?.isbn,
                'publisher' => book?.publisher,
                'publication_year' => book?.publicationYear,
                'category' => book?.category,
                'shelf' => book?.shelf,
                'notes' => book?.notes,
                _ => '',
              } ??
              '',
        ),
    };
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop({
      for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.book == null ? 'Nouveau livre' : 'Modifier le livre'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in _fieldNames.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    controller: _fields[entry.key],
                    maxLength: entry.key == 'notes' ? 2000 : 240,
                    maxLines: entry.key == 'notes' ? 3 : 1,
                    decoration: InputDecoration(
                      labelText: entry.value,
                      counterText: '',
                    ),
                    validator: entry.key == 'title'
                        ? (value) => value == null || value.trim().isEmpty
                              ? 'Le titre est obligatoire.'
                              : null
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Annuler'),
      ),
      FilledButton.icon(
        onPressed: _save,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Enregistrer'),
      ),
    ],
  );
}
