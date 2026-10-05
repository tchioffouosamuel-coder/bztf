import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../models/book.dart';
import '../models/lending.dart';
import '../services/library_controller.dart';
import '../services/cote_label.dart';
import 'loan_editor.dart';
import 'status_pill.dart';

/// Fiche complète d'un livre. Un double tap sur une information la rend
/// éditable et fait apparaître le bouton d'enregistrement.
class BookDetails extends StatefulWidget {
  const BookDetails({required this.controller, required this.book, super.key});

  final LibraryController controller;
  final Book book;

  /// Bottom sheet sur téléphone, boîte de dialogue sur écran large.
  static Future<void> show(
    BuildContext context, {
    required LibraryController controller,
    required Book book,
  }) {
    final details = BookDetails(controller: controller, book: book);
    if (MediaQuery.sizeOf(context).width >= 720) {
      return showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
            child: details,
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => details,
    );
  }

  @override
  State<BookDetails> createState() => _BookDetailsState();
}

class _BookDetailsState extends State<BookDetails> {
  static const _editableFields = <String, String>{
    'title': 'Titre',
    'author': 'Auteur',
    'isbn': 'ISBN',
    'publisher': 'Éditeur',
    'publication_year': 'Année de publication',
    'category': 'Catégorie',
    'shelf': 'Cote',
    'location': 'Localisation',
    'notes': 'Notes',
  };

  late Book _book = widget.book;
  late final Map<String, TextEditingController> _fields = {
    for (final key in _editableFields.keys)
      key: TextEditingController(text: _valueOf(_book, key)),
  };
  final Set<String> _editing = {};
  Loan? _loan;
  bool _busy = false;

  LibraryController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _reloadLoan();
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  static String _valueOf(Book book, String key) => switch (key) {
    'title' => book.title,
    'author' => book.author,
    'isbn' => book.isbn,
    'publisher' => book.publisher,
    'publication_year' => book.publicationYear,
    'category' => book.category,
    'shelf' => book.shelf,
    'location' => book.location,
    'notes' => book.notes,
    _ => '',
  };

  static String _date(String? value, {bool time = true}) {
    final date = value == null ? null : DateTime.tryParse(value);
    if (date == null) return '—';
    return DateFormat(
      time ? 'd MMM yyyy · HH:mm' : 'd MMM yyyy',
      'fr_FR',
    ).format(date.toLocal());
  }

  Future<void> _reloadLoan() async {
    final loan = await _controller.database.activeLoanForBook(_book.id);
    if (mounted) setState(() => _loan = loan);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startEditing(String key) => setState(() => _editing.add(key));

  void _cancelEditing() => setState(() {
    for (final key in _editing) {
      _fields[key]!.text = _valueOf(_book, key);
    }
    _editing.clear();
  });

  Future<void> _save() => _run(() async {
    if (_fields['title']!.text.trim().isEmpty) {
      throw ArgumentError('Le titre est obligatoire.');
    }
    final updated = await _controller.updateBook(_book.id, {
      for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
    });
    if (!mounted) return;
    setState(() {
      _book = updated;
      _editing.clear();
    });
    showMessage(context, 'Livre mis à jour.');
  });

  Future<void> _delete() async {
    final confirmed = await confirmAction(
      context,
      title: 'Supprimer ce livre ?',
      message: '« ${_book.title} » sera retiré du catalogue.',
      confirmLabel: 'Supprimer',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      await _controller.deleteBook(_book);
      if (!mounted) return;
      showMessage(context, 'Livre supprimé.');
      Navigator.of(context).pop();
    });
  }

  Future<void> _borrow() async {
    final request = await LoanEditor.show(
      context,
      controller: _controller,
      bookTitle: _book.title,
    );
    if (request == null || !mounted) return;
    await _run(() async {
      final loan = await _controller.borrowBook(
        _book,
        memberNumber: request.memberNumber,
        name: request.name,
        email: request.email,
        phone: request.phone,
        dueAt: request.dueAt,
        notes: request.notes,
      );
      final book = await _controller.database.getBook(_book.id);
      if (!mounted) return;
      setState(() {
        _loan = loan;
        if (book != null) _book = book;
      });
      showMessage(context, 'Emprunt enregistré pour ${loan.subscriberName}.');
    });
  }

  Future<void> _return() async {
    final loan = _loan;
    if (loan == null) return;
    final confirmed = await confirmAction(
      context,
      title: 'Enregistrer le retour ?',
      message: '« ${_book.title} » rendu par ${loan.subscriberName}.',
      confirmLabel: 'Retour',
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      final book = await _controller.returnBook(_book);
      if (!mounted) return;
      setState(() {
        _book = book;
        _loan = null;
      });
      showMessage(context, 'Retour enregistré.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final loan = _loan;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Icon(Icons.menu_book_outlined, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _book.title,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _book.accession,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(_book.status),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              children: [
                if (loan != null) ...[
                  _LoanCard(loan: loan, formatDate: _date),
                  const SizedBox(height: 12),
                ],
                Text(
                  'Double-touchez une information pour la modifier.',
                  style: text.bodySmall?.copyWith(color: colors.outline),
                ),
                const SizedBox(height: 6),
                for (final entry in _editableFields.entries)
                  _EditableInfo(
                    label: entry.value,
                    controller: _fields[entry.key]!,
                    editing: _editing.contains(entry.key),
                    multiline: entry.key == 'notes',
                    maxLength: entry.key == 'notes' ? 2000 : 240,
                    onDoubleTap: _busy ? null : () => _startEditing(entry.key),
                  ),
                const Divider(height: 24),
                _ReadOnlyInfo('EPC', _book.epc, monospace: true),
                _ReadOnlyInfo(
                  'Source de la notice',
                  _book.sourceNotice.isEmpty ? 'manuelle' : _book.sourceNotice,
                ),
                _ReadOnlyInfo('Type de document', _book.documentType),
                _ReadOnlyInfo('Statut de l’exemplaire', _book.itemStatus),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => previewCoteLabel(
                            context,
                            _book,
                            controller: _controller,
                          ),
                        ),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Prévisualiser l’étiquette de cote'),
                ),
                _ReadOnlyInfo('TID', _book.tid ?? '—', monospace: true),
                _ReadOnlyInfo('Ajouté le', _date(_book.createdAt)),
                _ReadOnlyInfo('Modifié le', _date(_book.updatedAt)),
                _ReadOnlyInfo('Encodé le', _date(_book.taggedAt)),
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: _editing.isNotEmpty
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _cancelEditing,
                          child: const Text('Annuler'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: _busy ? null : _save,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Enregistrer'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        TextButton.icon(
                          onPressed: _busy ? null : _delete,
                          style: TextButton.styleFrom(
                            foregroundColor: colors.error,
                          ),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Supprimer'),
                        ),
                        const Spacer(),
                        if (loan == null)
                          FilledButton.icon(
                            onPressed: _busy ? null : _borrow,
                            icon: const Icon(Icons.outbox_outlined),
                            label: const Text('Emprunter'),
                          )
                        else
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : _return,
                            icon: const Icon(Icons.assignment_return_outlined),
                            label: const Text('Retour'),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableInfo extends StatelessWidget {
  const _EditableInfo({
    required this.label,
    required this.controller,
    required this.editing,
    required this.multiline,
    required this.maxLength,
    required this.onDoubleTap,
  });

  final String label;
  final TextEditingController controller;
  final bool editing;
  final bool multiline;
  final int maxLength;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLength: maxLength,
          minLines: 1,
          maxLines: multiline ? 4 : 1,
          decoration: InputDecoration(labelText: label, counterText: ''),
        ),
      );
    }
    final value = controller.text.trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onDoubleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: text.labelSmall),
            const SizedBox(height: 2),
            Text(
              value.isEmpty ? 'Non renseigné' : value,
              style: value.isEmpty
                  ? text.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                      fontStyle: FontStyle.italic,
                    )
                  : text.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadOnlyInfo extends StatelessWidget {
  const _ReadOnlyInfo(this.label, this.value, {this.monospace = false});

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: monospace ? 'monospace' : null,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

class _LoanCard extends StatelessWidget {
  const _LoanCard({required this.loan, required this.formatDate});

  final Loan loan;
  final String Function(String?, {bool time}) formatDate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = loan.overdue ? colors.error : colors.tertiary;
    final contact = [
      loan.subscriberPhone,
      loan.subscriberEmail,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: accent, width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.person_outline, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Emprunté par ${loan.subscriberName} (${loan.memberNumber})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  'Depuis le ${formatDate(loan.borrowedAt, time: false)} · '
                  '${loan.overdue ? 'en retard, attendu' : 'retour prévu'} le '
                  '${formatDate(loan.dueAt, time: false)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (contact.isNotEmpty)
                  Text(contact, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
