import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_controller.dart';

class InventoryScreen extends StatelessWidget {
  const InventoryScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final records = controller.referencedInventoryRecords;
    final connected = controller.readerConnected;

    // Liste paresseuse : avec des centaines de tags lus, seules les lignes
    // visibles sont construites à chaque rafraîchissement.
    final header = <Widget>[
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Inventaire RFID',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                const Text('Maintenez la gâchette RFID pour inventorier.'),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton.outlined(
            tooltip: 'Vider la session',
            onPressed: records.isEmpty
                ? null
                : controller.clearInventorySession,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _InventorySummary(controller: controller),
      const SizedBox(height: 14),
      if (!connected)
        const Card(
          child: ListTile(
            leading: Icon(Icons.sensors_off),
            title: Text('Lecteur non connecté'),
            subtitle: Text('Connectez le lecteur depuis la barre supérieure.'),
          ),
        )
      else if (records.isEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 34),
            child: Column(
              children: [
                Icon(
                  controller.reading ? Icons.radar : Icons.fact_check_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text(
                  controller.reading
                      ? 'Recherche des livres en cours'
                      : 'Aucun livre référencé détecté',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Appuyez sur la gâchette RFID pour commencer.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
    ];
    final rows = connected ? records : const <InventoryRecord>[];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      itemCount: header.length + rows.length,
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        final row = index - header.length;
        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(row == 0 ? 12 : 0),
              bottom: Radius.circular(row == rows.length - 1 ? 12 : 0),
            ),
          ),
          child: Column(
            children: [
              if (row > 0) const Divider(height: 1),
              _InventoryRow(
                key: ValueKey(rows[row].tag.epc + rows[row].tag.tid),
                record: rows[row],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InventorySummary extends StatelessWidget {
  const _InventorySummary({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final records = controller.referencedInventoryRecords;
    final readCount = records.fold<int>(
      0,
      (total, record) => total + record.readCount,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            _Count(
              label: 'Livres référencés',
              value: records.length,
              color: Theme.of(context).colorScheme.primary,
            ),
            const VerticalDivider(width: 20),
            _Count(
              label: 'Lectures RFID',
              value: readCount,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          '$value',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow({required this.record, super.key});

  final InventoryRecord record;

  @override
  Widget build(BuildContext context) {
    final book = record.book;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      leading: Icon(
        book == null ? Icons.help_outline : Icons.menu_book_outlined,
        color: book == null
            ? Theme.of(context).colorScheme.tertiary
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        book?.title ?? 'Tag inconnu',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        book == null
            ? record.tag.epc
            : '${book.accession} · ${book.author.isEmpty ? 'Auteur non renseigné' : book.author}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${record.tag.rssi} dBm',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              '${record.readCount} lecture${record.readCount > 1 ? 's' : ''}',
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
