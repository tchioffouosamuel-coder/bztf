import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../models/book.dart';
import '../models/lending.dart';
import '../services/kiosk_controller.dart';
import '../services/library_controller.dart';
import '../widgets/pin_dialog.dart';
import 'admin_screen.dart';

/// Poste d'emprunt en libre-service. Plein écran : seul le code
/// administrateur permet d'en sortir.
class KioskScreen extends StatefulWidget {
  const KioskScreen({required this.controller, this.asHome = false, super.key});

  final LibraryController controller;

  /// Vrai quand l'appareil est configuré en poste d'emprunt (écran
  /// d'accueil de l'application) ; faux quand il est ouvert depuis le
  /// lecteur mobile.
  final bool asHome;

  static Route<void> route(LibraryController controller) => MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => KioskScreen(controller: controller),
  );

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  KioskController get kiosk => widget.controller.kiosk;

  @override
  void initState() {
    super.initState();
    unawaited(kiosk.enter());
  }

  @override
  void dispose() {
    unawaited(kiosk.leave());
    super.dispose();
  }

  Future<void> _openMenu() async {
    if (!await requestAdminPin(context, kiosk) || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Terminal admin'),
              subtitle: const Text(
                'Historique des emprunts, abonnés, réglages',
              ),
              onTap: () => Navigator.pop(context, 'admin'),
            ),
            if (widget.asHome) ...[
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Changer le type d’appareil'),
                onTap: () => Navigator.pop(context, 'role'),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(
                  'Se déconnecter'
                  '${widget.controller.currentUser == null ? '' : ' (${widget.controller.currentUser!.name})'}',
                ),
                onTap: () => Navigator.pop(context, 'logout'),
              ),
            ] else
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Quitter le poste d’emprunt'),
                onTap: () => Navigator.pop(context, 'exit'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'admin':
        // Le poste ne lit plus pendant la consultation du terminal.
        await kiosk.leave();
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(AdminScreen.route(widget.controller, insideKiosk: true));
        if (mounted) await kiosk.enter();
      case 'role':
        await widget.controller.setDeviceRole(null);
      case 'logout':
        await widget.controller.signOut();
      case 'exit':
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && kiosk.stage != KioskStage.home) kiosk.cancelSession();
    },
    child: AnimatedBuilder(
      animation: kiosk,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _Header(kiosk: kiosk, onMenu: _openMenu),
              if (kiosk.readerError case final error?)
                _ReaderBanner(message: error, onRetry: kiosk.reconnect),
              Expanded(
                child: Listener(
                  onPointerDown: (_) => kiosk.touch(),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: switch (kiosk.stage) {
                      KioskStage.home => _HomeView(
                        key: const ValueKey('home'),
                        kiosk: kiosk,
                      ),
                      KioskStage.browse => _BrowseView(
                        key: const ValueKey('browse'),
                        kiosk: kiosk,
                      ),
                      KioskStage.borrow => _BorrowView(
                        key: const ValueKey('borrow'),
                        kiosk: kiosk,
                      ),
                      KioskStage.giveBack => _ReturnView(
                        key: const ValueKey('return'),
                        kiosk: kiosk,
                      ),
                      KioskStage.receipt => _ReceiptView(
                        key: const ValueKey('receipt'),
                        kiosk: kiosk,
                      ),
                    },
                  ),
                ),
              ),
              if (kiosk.simulation)
                _SimulationBar(controller: widget.controller),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.kiosk, required this.onMenu});

  final KioskController kiosk;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, color, icon) = kiosk.connecting
        ? ('Connexion…', colors.onSurfaceVariant, Icons.sync)
        : kiosk.readerConnected
        ? ('Lecteur prêt', colors.primary, Icons.sensors)
        : ('Lecteur hors ligne', colors.error, Icons.sensors_off);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Image.asset('assets/images/bibliorfid-logo.jpg', height: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bibliothèque ZTF',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                Text(
                  'Poste de prêt en libre-service',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Chip(
            avatar: Icon(icon, size: 18, color: color),
            label: Text(label, style: TextStyle(color: color)),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: 'Administration',
            onPressed: onMenu,
            icon: const Icon(Icons.lock_outline),
          ),
        ],
      ),
    );
  }
}

class _ReaderBanner extends StatelessWidget {
  const _ReaderBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView({required this.kiosk, super.key});

  final KioskController kiosk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            children: [
              Icon(
                Icons.contactless_outlined,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Bienvenue',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Posez votre carte d’abonné et vos livres sur le lecteur.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  _BigAction(
                    icon: Icons.manage_search_outlined,
                    title: 'Consulter',
                    subtitle: 'Titres disponibles et emplacement',
                    onTap: kiosk.startBrowse,
                  ),
                  _BigAction(
                    icon: Icons.outbox_outlined,
                    title: 'Emprunter',
                    subtitle: 'Carte d’abonné puis livres',
                    onTap: kiosk.startBorrow,
                  ),
                  _BigAction(
                    icon: Icons.move_to_inbox_outlined,
                    title: 'Rendre',
                    subtitle: 'Livres seuls, sans carte',
                    onTap: kiosk.startReturn,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Jusqu’à ${kiosk.maxLoans} livre(s) à la fois, '
                'pour ${kiosk.loanDays} jours.',
                style: theme.textTheme.bodyMedium,
              ),
              if (kiosk.notice case final notice?) ...[
                const SizedBox(height: 12),
                _Notice(text: notice),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Card(
        color: colors.primaryContainer,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            child: Column(
              children: [
                Icon(icon, size: 48, color: colors.onPrimaryContainer),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(color: colors.onPrimaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Consultation du catalogue par les abonnés : recherche, disponibilité et
/// emplacement de chaque exemplaire. Poser une carte ou un livre ouvre
/// l'emprunt ou le retour.
class _BrowseView extends StatefulWidget {
  const _BrowseView({required this.kiosk, super.key});

  final KioskController kiosk;

  @override
  State<_BrowseView> createState() => _BrowseViewState();
}

class _BrowseViewState extends State<_BrowseView> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<CatalogEntry> _entries = const [];
  bool _availableOnly = true;
  bool _loading = true;
  int _query = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final query = ++_query;
    setState(() => _loading = true);
    final entries = await widget.kiosk.library.database.browseCatalog(
      search: _search.text,
      availableOnly: _availableOnly,
    );
    if (!mounted || query != _query) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _onSearch(String _) {
    widget.kiosk.touch();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: _SessionLayout(
          title: 'Consulter le catalogue',
          footer: const SizedBox.shrink(),
          children: [
            TextField(
              controller: _search,
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 18),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Titre, auteur, ISBN, catégorie ou rayon…',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilterChip(
                  label: const Text('Disponibles seulement'),
                  selected: _availableOnly,
                  onSelected: (value) {
                    widget.kiosk.touch();
                    setState(() => _availableOnly = value);
                    _load();
                  },
                ),
                const Spacer(),
                Text(
                  _loading
                      ? 'Recherche…'
                      : '${_entries.length} exemplaire${_entries.length > 1 ? 's' : ''}',
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (!_loading && _entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'Aucun titre ne correspond à votre recherche.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              for (final entry in _entries) _CatalogTile(entry: entry),
          ],
        ),
      ),
      Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.contactless_outlined),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Pour emprunter, posez votre carte puis vos livres sur le lecteur.',
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: widget.kiosk.cancelSession,
                icon: const Icon(Icons.home_outlined),
                label: const Text('Accueil'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.entry});

  final CatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final book = entry.book;
    final (label, color) = entry.available
        ? ('Disponible', colors.primary)
        : entry.onLoan
        ? (
            'Emprunté · retour prévu le '
                '${DateFormat('dd/MM/yyyy').format(DateTime.parse(entry.dueAt!).toLocal())}',
            colors.tertiary,
          )
        : ('Indisponible', colors.error);
    final details = [
      if (book.author.isNotEmpty) book.author,
      if (book.category.isNotEmpty) book.category,
      book.accession,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 32, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(details),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // L'emplacement, pour trouver le livre en rayon.
            Container(
              constraints: const BoxConstraints(minWidth: 96),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Text(
                    'Rayon',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                  Text(
                    book.shelf.isEmpty ? '—' : book.shelf,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BorrowView extends StatelessWidget {
  const _BorrowView({required this.kiosk, super.key});

  final KioskController kiosk;

  @override
  Widget build(BuildContext context) {
    final count = kiosk.borrowableItems.length;
    return _SessionLayout(
      title: 'Emprunt',
      footer: _ActionBar(
        message:
            kiosk.borrowBlocker ??
            'Retour prévu le '
                '${DateFormat('EEEE d MMMM', 'fr_FR').format(kiosk.dueDate)}.',
        blocked: kiosk.borrowBlocker != null,
        confirmLabel: 'Emprunter $count livre${count > 1 ? 's' : ''}',
        busy: kiosk.processing,
        onCancel: kiosk.cancelSession,
        onConfirm: kiosk.canConfirmBorrow ? kiosk.confirmBorrow : null,
      ),
      children: [
        _SubscriberPanel(kiosk: kiosk),
        const SizedBox(height: 16),
        _ItemsSection(
          kiosk: kiosk,
          emptyText: 'Posez les livres à emprunter sur le lecteur.',
        ),
      ],
    );
  }
}

class _ReturnView extends StatelessWidget {
  const _ReturnView({required this.kiosk, super.key});

  final KioskController kiosk;

  @override
  Widget build(BuildContext context) {
    final count = kiosk.returnableItems.length;
    return _SessionLayout(
      title: 'Retour',
      footer: _ActionBar(
        message: count == 0
            ? 'Posez les livres à rendre sur le lecteur.'
            : 'Déposez ensuite les livres dans le bac de retour.',
        blocked: count == 0,
        confirmLabel: 'Rendre $count livre${count > 1 ? 's' : ''}',
        busy: kiosk.processing,
        onCancel: kiosk.cancelSession,
        onConfirm: kiosk.canConfirmReturn ? kiosk.confirmReturn : null,
      ),
      children: [
        _ItemsSection(
          kiosk: kiosk,
          emptyText: 'Posez les livres à rendre sur le lecteur.',
        ),
      ],
    );
  }
}

class _SessionLayout extends StatelessWidget {
  const _SessionLayout({
    required this.title,
    required this.footer,
    required this.children,
  });

  final String title;
  final List<Widget> children;
  final Widget footer;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                ...children,
              ],
            ),
          ),
        ),
      ),
      footer,
    ],
  );
}

class _SubscriberPanel extends StatelessWidget {
  const _SubscriberPanel({required this.kiosk});

  final KioskController kiosk;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subscriber = kiosk.subscriber;
    final status = kiosk.borrower;
    if (subscriber == null || status == null) {
      return Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: Icon(Icons.badge_outlined, size: 40, color: colors.primary),
          title: const Text(
            'Posez votre carte d’abonné',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          subtitle: const Text(
            'La carte peut rester sur le lecteur avec les livres.',
          ),
        ),
      );
    }
    final accent = status.eligible ? colors.primary : colors.error;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: accent.withValues(alpha: .12),
              child: Icon(
                status.eligible ? Icons.verified_user_outlined : Icons.block,
                color: accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subscriber.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                  Text('N° ${subscriber.memberNumber}'),
                  const SizedBox(height: 8),
                  if (status.eligible)
                    Text(
                      'Vous pouvez emprunter ${status.remaining} livre(s) · '
                      '${status.activeLoans} emprunt(s) en cours',
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else ...[
                    Text(
                      'Emprunt impossible',
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    for (final reason in status.reasons) Text('• $reason'),
                    const SizedBox(height: 4),
                    const Text('Vous pouvez toujours rendre vos livres.'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemsSection extends StatelessWidget {
  const _ItemsSection({required this.kiosk, required this.emptyText});

  final KioskController kiosk;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final items = kiosk.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Livres (${items.length})',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
              child: Column(
                children: [
                  const Icon(Icons.menu_book_outlined, size: 36),
                  const SizedBox(height: 8),
                  Text(emptyText, textAlign: TextAlign.center),
                ],
              ),
            ),
          )
        else
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ItemTile(
                item: item,
                state: kiosk.stateOf(item),
                onRemove: () => kiosk.removeItem(item.epc),
              ),
            ),
        if (kiosk.unknownTags > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${kiosk.unknownTags} étiquette(s) non reconnue(s) ignorée(s). '
              'Adressez-vous à l’accueil pour ces documents.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (kiosk.notice case final notice?) ...[
          const SizedBox(height: 8),
          _Notice(text: notice),
        ],
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.state,
    required this.onRemove,
  });

  final KioskItem item;
  final KioskItemState state;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final loan = item.loan;
    final dueLabel = loan == null ? '' : _shortDate(loan.dueAt);
    final (label, color, icon) = switch (state) {
      KioskItemState.available => (
        'Sera emprunté',
        colors.primary,
        Icons.check_circle_outline,
      ),
      KioskItemState.overQuota => ('Quota dépassé', colors.error, Icons.block),
      KioskItemState.alreadyYours => (
        'Déjà emprunté par vous · retour le $dueLabel',
        colors.tertiary,
        Icons.info_outline,
      ),
      KioskItemState.unavailable => ('Indisponible', colors.error, Icons.block),
      KioskItemState.returnable => (
        loan!.overdue ? 'Sera rendu · en retard' : 'Sera rendu',
        loan.overdue ? colors.tertiary : colors.primary,
        Icons.check_circle_outline,
      ),
      KioskItemState.notBorrowed => (
        'Pas en prêt : rien à rendre',
        colors.onSurfaceVariant,
        Icons.info_outline,
      ),
    };
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        leading: Icon(icon, color: color, size: 30),
        title: Text(
          item.book.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${item.book.author.isEmpty ? item.book.accession : '${item.book.author} · ${item.book.accession}'}\n$label',
          style: TextStyle(height: 1.4, color: colors.onSurfaceVariant),
        ),
        isThreeLine: true,
        trailing: IconButton(
          tooltip: 'Retirer de la liste',
          onPressed: onRemove,
          icon: const Icon(Icons.close),
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.message,
    required this.blocked,
    required this.confirmLabel,
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
  });

  final String message;
  final bool blocked;
  final String confirmLabel;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              style: TextStyle(
                color: blocked ? colors.error : colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton(
                  onPressed: busy ? null : onCancel,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(120, 56),
                  ),
                  child: const Text('Annuler'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onConfirm,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                      textStyle: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptView extends StatelessWidget {
  const _ReceiptView({required this.kiosk, super.key});

  final KioskController kiosk;

  @override
  Widget build(BuildContext context) {
    final receipt = kiosk.receipt!;
    final colors = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Icon(Icons.check_circle, size: 80, color: colors.primary),
              const SizedBox(height: 10),
              Text(
                receipt.borrow ? 'Emprunt enregistré' : 'Retour enregistré',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (receipt.subscriber case final subscriber?)
                Text(subscriber.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 18),
              Card(
                child: Column(
                  children: [
                    for (final loan in receipt.loans)
                      ListTile(
                        leading: const Icon(Icons.menu_book_outlined),
                        title: Text(
                          loan.bookTitle ?? loan.bookAccession ?? 'Livre',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          receipt.borrow
                              ? 'À rendre le ${_longDate(loan.dueAt)}'
                              : loan.late
                              ? 'Rendu en retard (échéance ${_shortDate(loan.dueAt)})'
                              : 'Rendu dans les délais',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                receipt.borrow
                    ? 'Vous pouvez reprendre votre carte et vos livres.'
                    : 'Déposez les livres dans le bac de retour.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: kiosk.finish,
                style: FilledButton.styleFrom(minimumSize: const Size(220, 56)),
                child: Text('Terminer (${kiosk.receiptSecondsLeft} s)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mode Simulation : pose des cartes et des livres sur un lecteur virtuel.
class _SimulationBar extends StatefulWidget {
  const _SimulationBar({required this.controller});

  final LibraryController controller;

  @override
  State<_SimulationBar> createState() => _SimulationBarState();
}

class _SimulationBarState extends State<_SimulationBar> {
  LibraryController get controller => widget.controller;

  Future<void> _placeCard(BuildContext context) async {
    final subscribers = (await controller.database.listSubscribers())
        .where((subscriber) => subscriber.hasCard)
        .toList();
    if (!context.mounted) return;
    if (subscribers.isEmpty) {
      showMessage(context, 'Aucune carte d’abonné encodée.', error: true);
      return;
    }
    final subscriber = await _pick<Subscriber>(
      context,
      subscribers,
      (subscriber) => (subscriber.name, subscriber.memberNumber),
    );
    if (subscriber == null || !mounted) return;
    setState(
      () => controller.kiosk.reader.simulatePlace(
        ReaderTag(epc: subscriber.cardEpc!, tid: subscriber.cardTid!, rssi: 60),
      ),
    );
  }

  Future<void> _placeBook(BuildContext context) async {
    final books = (await controller.database.listBooks(
      limit: 200,
    )).where((book) => book.tid != null).toList();
    if (!context.mounted) return;
    if (books.isEmpty) {
      showMessage(context, 'Aucun livre encodé.', error: true);
      return;
    }
    final book = await _pick<Book>(
      context,
      books,
      (book) => (book.title, '${book.accession} · ${book.status}'),
    );
    if (book == null || !mounted) return;
    setState(
      () => controller.kiosk.reader.simulatePlace(
        ReaderTag(epc: book.epc, tid: book.tid!, rssi: 60),
      ),
    );
  }

  Future<T?> _pick<T>(
    BuildContext context,
    List<T> values,
    (String, String) Function(T) describe,
  ) => showModalBottomSheet<T>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final value in values)
            ListTile(
              title: Text(describe(value).$1),
              subtitle: Text(describe(value).$2),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final reader = controller.kiosk.reader;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.science_outlined, size: 18),
            const SizedBox(width: 6),
            Text('Simulation · ${reader.simulatedTags.length} tag(s) posé(s)'),
            TextButton(
              onPressed: () => _placeCard(context),
              child: const Text('Poser une carte'),
            ),
            TextButton(
              onPressed: () => _placeBook(context),
              child: const Text('Poser un livre'),
            ),
            TextButton(
              onPressed: () => setState(reader.simulateClear),
              child: const Text('Tout retirer'),
            ),
          ],
        ),
      ),
    );
  }
}

String _shortDate(String value) =>
    DateFormat('dd/MM/yyyy').format(DateTime.parse(value).toLocal());

String _longDate(String value) => DateFormat(
  'EEEE d MMMM yyyy',
  'fr_FR',
).format(DateTime.parse(value).toLocal());
