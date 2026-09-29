import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/book.dart';
import '../services/library_controller.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${controller.activities.length} opérations récentes',
              ),
            ),
            IconButton(
              tooltip: 'Actualiser',
              onPressed: controller.loadActivity,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      Expanded(
        child: controller.activities.isEmpty
            ? const Center(child: Text('Aucune opération enregistrée.'))
            : RefreshIndicator(
                onRefresh: controller.loadActivity,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: controller.activities.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _ActivityCard(item: controller.activities[index]),
                ),
              ),
      ),
    ],
  );
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.item});

  final ActivityEntry item;

  @override
  Widget build(BuildContext context) {
    final isFailure = item.result == 'echec';
    final color = isFailure
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    final date = DateTime.tryParse(item.createdAt)?.toLocal();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: color.withValues(alpha: .12),
                  child: Icon(_icon(item.type), size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.message,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (date != null)
                  Text(
                    DateFormat('dd MMM\nHH:mm', 'fr_FR').format(date),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            if (item.title != null || item.accession != null) ...[
              const SizedBox(height: 9),
              Text(
                item.title ?? item.accession!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  isFailure ? Icons.error_outline : Icons.check_circle_outline,
                  size: 15,
                  color: color,
                ),
                const SizedBox(width: 5),
                Text(
                  isFailure ? 'Échec' : 'Succès',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  item.type.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(String type) => switch (type) {
    'ecriture' => Icons.edit_note,
    'desencodage' => Icons.remove_circle_outline,
    'connexion' => Icons.cable,
    'emprunt' => Icons.outbox_outlined,
    'retour' => Icons.move_to_inbox_outlined,
    'carte' => Icons.badge_outlined,
    'abonnement' => Icons.card_membership_outlined,
    _ => Icons.library_books_outlined,
  };
}
