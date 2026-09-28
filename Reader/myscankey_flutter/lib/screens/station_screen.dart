import 'package:flutter/material.dart';

import '../app.dart';
import '../core/epc.dart';
import '../models/book.dart';
import '../services/library_controller.dart';
import '../widgets/book_editor.dart';
import '../widgets/reader_connection_dialog.dart';
import '../widgets/status_pill.dart';

class StationScreen extends StatelessWidget {
  const StationScreen({required this.controller, super.key});

  final LibraryController controller;

  Future<Book?> _chooseBook(BuildContext context) async {
    final search = TextEditingController();
    return showModalBottomSheet<Book>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.viewInsetsOf(context).bottom + 16,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .7,
                child: Column(
                  children: [
                    TextField(
                      controller: search,
                      autofocus: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Rechercher un livre',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: FutureBuilder<List<Book>>(
                        future: controller.database.listBooks(
                          search: search.text,
                          status: 'a_encoder',
                          limit: 80,
                        ),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final books = snapshot.data!;
                          if (books.isEmpty) {
                            return const Center(
                              child: Text(
                                'Aucun livre à encoder ne correspond.',
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: books.length,
                            itemBuilder: (context, index) {
                              final book = books[index];
                              return ListTile(
                                leading: const Icon(Icons.menu_book_outlined),
                                title: Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${book.author.isEmpty ? book.accession : book.author} · ${book.accession}',
                                ),
                                onTap: () => Navigator.pop(context, book),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _write(BuildContext context, Book book, ReaderTag tag) async {
    try {
      await controller.encodeBook(book, tag);
      controller.clearPendingOperation();
      if (context.mounted) showMessage(context, 'Tag écrit et vérifié.');
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _erase(BuildContext context, Book book) async {
    final confirmed = await confirmAction(
      context,
      title: 'Désencoder ce tag ?',
      message:
          'L’EPC associé à « ${book.title} » sera effacé. Le tag restera réutilisable.',
      confirmLabel: 'Désencoder',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await controller.unencodeBook(book);
      controller.clearPendingOperation();
      if (context.mounted) showMessage(context, 'Tag désencodé et vérifié.');
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _registerNew(BuildContext context, ReaderTag tag) async {
    final values = await BookEditor.show(context);
    if (values == null || !context.mounted) return;
    try {
      await controller.createAndEncode(values, tag);
      controller.clearPendingOperation();
      if (context.mounted) {
        showMessage(context, 'Livre ajouté, tag écrit et vérifié.');
      }
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _associate(BuildContext context, ReaderTag tag) async {
    final book = await _chooseBook(context);
    if (book == null || !context.mounted) return;
    await _write(context, book, tag);
  }

  Future<void> _resolveTid(BuildContext context, ReaderTag tag) async {
    try {
      final resolved = await controller.refreshStationTid(tag);
      if (!context.mounted) return;
      showMessage(
        context,
        resolved
            ? 'TID relu. L’écriture est maintenant disponible.'
            : 'TID introuvable. Laissez un seul tag sur le lecteur et réessayez.',
        error: !resolved,
      );
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = controller.observedTags;
    final recognizedTagCount = tags
        .where((tag) => controller.recognizedBook(tag) != null)
        .length;
    final pendingBook = controller.pendingBook;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.transport == 'serial'
                        ? 'Lecture par gâchette'
                        : 'Lecture automatique',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    controller.readerConnected
                        ? 'Lecteur RFID connecté'
                        : 'Lecteur RFID non connecté',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (controller.readerConnected &&
                (controller.transport != 'serial' || controller.reading))
              IconButton.filledTonal(
                tooltip: controller.reading
                    ? 'Arrêter la lecture'
                    : 'Démarrer la lecture',
                onPressed: () => controller.reading
                    ? controller.stopInventory()
                    : controller.startInventory(),
                icon: Icon(controller.reading ? Icons.pause : Icons.play_arrow),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: controller.reading
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.radar,
                    color: controller.reading
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.readerError ??
                            (controller.readerConnected
                                ? controller.reading
                                      ? 'Lecture en cours'
                                      : controller.transport == 'serial'
                                      ? 'Gâchette RFID prête'
                                      : 'Zone de lecture prête'
                                : 'Connexion requise'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        controller.readerConnected
                            ? controller.transport == 'serial'
                                  ? 'Maintenez le bouton RFID enfoncé pour lire les livres.'
                                  : 'Posez un seul livre sur le lecteur pour écrire ou désencoder.'
                            : 'Connectez le lecteur intégré ou activez la simulation.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (pendingBook != null && tags.length != 1) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text(
                'Livre sélectionné',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                pendingBook.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Désélectionner le livre',
                onPressed: controller.clearPendingOperation,
                icon: const Icon(Icons.close),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (!controller.readerConnected)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () => _connectFromStation(context, controller),
                    icon: const Icon(Icons.cable),
                    label: const Text('Connecter le lecteur'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => controller.connectReader(
                      nextTransport: 'simulation',
                      nextEndpoint: '',
                    ),
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('Essayer en simulation'),
                  ),
                ],
              ),
            ),
          )
        else if (tags.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.nfc, size: 34),
                    const SizedBox(height: 8),
                    const Text('En attente d’un tag'),
                    const SizedBox(height: 3),
                    Text(
                      controller.transport == 'serial'
                          ? 'Appuyez sur la gâchette RFID pour lire.'
                          : 'La détection démarre automatiquement.',
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (tags.length > 1)
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${tags.length} tags détectés · $recognizedTagCount reconnu${recognizedTagCount > 1 ? 's' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                for (final tag in tags)
                  Builder(
                    builder: (context) {
                      final book = controller.recognizedBook(tag);
                      final card = book == null && isCardEpc(tag.epc);
                      return ListTile(
                        leading: Icon(
                          card
                              ? Icons.badge_outlined
                              : book == null
                              ? Icons.sell_outlined
                              : Icons.menu_book_outlined,
                        ),
                        title: Text(
                          card
                              ? 'Carte d’abonné'
                              : book?.title ?? 'Livre inconnu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          book == null
                              ? '${tag.epc}\nTID ${tag.tid.isEmpty ? 'non disponible' : tag.tid} · signal ${tag.rssi}'
                              : '${book.accession}\n${tag.epc} · TID ${tag.tid.isEmpty ? 'non disponible' : tag.tid}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: book == null ? null : StatusPill(book.status),
                      );
                    },
                  ),
              ],
            ),
          )
        else
          _SingleTagPanel(
            tag: tags.single,
            book: controller.recognizedBook(tags.single),
            pendingBook: pendingBook,
            pendingAction: controller.pendingAction,
            onAssociate: () => _associate(context, tags.single),
            onCreate: () => _registerNew(context, tags.single),
            onWrite: (book) => _write(context, book, tags.single),
            onErase: (book) => _erase(context, book),
            onResolveTid: () => _resolveTid(context, tags.single),
            onClearSelection: controller.clearPendingOperation,
            reading: controller.reading,
          ),
        const SizedBox(height: 14),
        if (tags.length == 1)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tag détecté',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _Identifier(label: 'EPC', value: tags.single.epc),
                  const SizedBox(height: 7),
                  _Identifier(
                    label: 'TID',
                    value: tags.single.tid.isEmpty
                        ? 'Non disponible'
                        : tags.single.tid,
                  ),
                  const SizedBox(height: 7),
                  _Identifier(
                    label: 'Signal',
                    value: '${tags.single.rssi} dBm',
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _connectFromStation(
    BuildContext context,
    LibraryController controller,
  ) async {
    final config = await ReaderConnectionDialog.show(
      context,
      transport: controller.transport,
      endpoint: controller.endpoint,
    );
    if (config == null || !context.mounted) return;
    try {
      await controller.connectReader(
        nextTransport: config.$1,
        nextEndpoint: config.$2,
      );
    } catch (error) {
      if (context.mounted) showMessage(context, error.toString(), error: true);
    }
  }
}

class _SingleTagPanel extends StatelessWidget {
  const _SingleTagPanel({
    required this.tag,
    required this.book,
    required this.pendingBook,
    required this.pendingAction,
    required this.onAssociate,
    required this.onCreate,
    required this.onWrite,
    required this.onErase,
    required this.onResolveTid,
    required this.onClearSelection,
    required this.reading,
  });

  final ReaderTag tag;
  final Book? book;
  final Book? pendingBook;
  final String? pendingAction;
  final VoidCallback onAssociate;
  final VoidCallback onCreate;
  final ValueChanged<Book> onWrite;
  final ValueChanged<Book> onErase;
  final VoidCallback onResolveTid;
  final VoidCallback onClearSelection;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final selected = pendingBook;
    if (pendingAction == 'erase' && selected != null) {
      final matches = tag.tid == selected.tid && tag.epc == selected.epc;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      matches
                          ? 'Tag associé au livre'
                          : 'Tag différent détecté',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Désélectionner le livre',
                    onPressed: onClearSelection,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                matches
                    ? selected.title
                    : 'Posez le tag de « ${selected.title} » sur le lecteur.',
              ),
              const SizedBox(height: 12),
              if (matches)
                FilledButton.icon(
                  onPressed: () => onErase(selected),
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('Désencoder le tag'),
                ),
            ],
          ),
        ),
      );
    }
    if (selected != null && selected.status == 'a_encoder') {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Livre sélectionné',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Désélectionner le livre',
                    onPressed: onClearSelection,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                selected.title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              if (tag.tid.isEmpty)
                OutlinedButton.icon(
                  onPressed: reading ? null : onResolveTid,
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    reading ? 'Relâchez la gâchette' : 'Relire le TID',
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: () => onWrite(selected),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Écrire le tag'),
                ),
            ],
          ),
        ),
      );
    }
    if (book != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.menu_book,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Livre reconnu',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  StatusPill(book!.status),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                book!.title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                '${book!.author.isEmpty ? 'Auteur non renseigné' : book!.author} · ${book!.accession}',
              ),
            ],
          ),
        ),
      );
    }
    if (isCardEpc(tag.epc)) {
      return Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(
            Icons.badge_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: const Text(
            'Carte d’abonné',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: const Text(
            'Ce tag identifie un abonné : il ne peut pas être encodé comme '
            'livre. Utilisez-le depuis le formulaire d’emprunt.',
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.help_outline,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Tag non enregistré',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Associez-le à un livre en attente ou créez une notice.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onAssociate,
                  icon: const Icon(Icons.search),
                  label: const Text('Choisir un livre'),
                ),
                FilledButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add),
                  label: const Text('Nouveau livre'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Identifier extends StatelessWidget {
  const _Identifier({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 50,
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
      Expanded(
        child: SelectableText(
          value,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    ],
  );
}
