import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/library_controller.dart';
import '../widgets/status_pill.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final counts = controller.counts;
    return RefreshIndicator(
      onRefresh: controller.refreshDashboard,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        children: [
          Text(
            'Gestion du fonds',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Activité de la bibliothèque',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _StatCard(
                    title: 'Livres',
                    value: counts['total'] ?? 0,
                    icon: Icons.menu_book_outlined,
                    width: (width - 10) / 2,
                  ),
                  _StatCard(
                    title: 'Tags encodés',
                    value: counts['tagged'] ?? 0,
                    icon: Icons.verified_outlined,
                    width: (width - 10) / 2,
                  ),
                  _StatCard(
                    title: 'À encoder',
                    value: counts['pending'] ?? 0,
                    icon: Icons.schedule_outlined,
                    width: (width - 10) / 2,
                  ),
                  _StatCard(
                    title: 'Ajoutés aujourd’hui',
                    value: counts['today'] ?? 0,
                    icon: Icons.event_available_outlined,
                    width: (width - 10) / 2,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          _SectionHeading(
            title: 'Derniers livres',
            action: 'Tout voir',
            onTap: () => controller.setView('catalogue'),
          ),
          const SizedBox(height: 8),
          if (controller.recentBooks.isEmpty)
            const _EmptyBlock(
              icon: Icons.library_books_outlined,
              text: 'Le catalogue est vide.',
            )
          else
            ...controller.recentBooks
                .take(6)
                .map(
                  (book) => Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.menu_book_outlined),
                          title: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${book.author.isEmpty ? 'Auteur non renseigné' : book.author} · ${book.accession}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: StatusPill(book.status),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
                    ),
                  ),
                ),
          const SizedBox(height: 22),
          _SectionHeading(
            title: 'Journal récent',
            action: 'Tout voir',
            onTap: () => controller.setView('history'),
          ),
          const SizedBox(height: 8),
          if (controller.activities.isEmpty)
            const _EmptyBlock(
              icon: Icons.history,
              text: 'Aucune opération enregistrée.',
            )
          else
            ...controller.activities
                .take(8)
                .map(
                  (item) => Card(
                    child: ListTile(
                      leading: Icon(_activityIcon(item.type)),
                      title: Text(
                        item.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(item.title ?? item.accession ?? item.type),
                      trailing: Text(
                        DateFormat(
                          'dd MMM HH:mm',
                          'fr_FR',
                        ).format(DateTime.parse(item.createdAt).toLocal()),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  static IconData _activityIcon(String type) => switch (type) {
    'ecriture' => Icons.verified_outlined,
    'desencodage' => Icons.remove_circle_outline,
    'connexion' => Icons.cable,
    _ => Icons.menu_book_outlined,
  };
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.width,
  });

  final String title;
  final int value;
  final IconData icon;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(icon, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$value',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.action,
    required this.onTap,
  });

  final String title;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
      TextButton.icon(
        onPressed: onTap,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.arrow_forward, size: 16),
        label: Text(action),
      ),
    ],
  );
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Center(
        child: Column(
          children: [
            Icon(
              icon,
              size: 28,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(text),
          ],
        ),
      ),
    ),
  );
}
