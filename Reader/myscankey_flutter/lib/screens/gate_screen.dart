import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../models/book.dart';
import '../models/staff.dart';
import '../services/gate_controller.dart';
import '../services/library_controller.dart';
import '../widgets/pin_dialog.dart';
import 'admin_screen.dart';

/// Écran du portail antivol : compteurs du jour, alarme, passages du
/// personnel. Plein écran : seul le code administrateur permet d'en sortir.
class GateScreen extends StatefulWidget {
  const GateScreen({required this.controller, this.asHome = false, super.key});

  final LibraryController controller;

  /// Vrai quand l'appareil est configuré en portail antivol.
  final bool asHome;

  static Route<void> route(LibraryController controller) => MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => GateScreen(controller: controller),
  );

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  GateController get gate => widget.controller.gate;

  @override
  void initState() {
    super.initState();
    unawaited(gate.enter());
  }

  @override
  void dispose() {
    unawaited(gate.leave());
    super.dispose();
  }

  Future<void> _dismissAlarm() async {
    if (!await requestAdminPin(
          context,
          widget.controller.kiosk,
          title: 'Arrêter l’alarme',
        ) ||
        !mounted) {
      return;
    }
    gate.dismissAlarm();
  }

  Future<void> _openMenu() async {
    if (!await requestAdminPin(context, widget.controller.kiosk) || !mounted) {
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Terminal admin'),
              subtitle: const Text('Portail, capteurs, alarme, emprunts'),
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
                title: const Text('Quitter le portail'),
                onTap: () => Navigator.pop(context, 'exit'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'admin':
        // Le portail ne surveille plus pendant la consultation du terminal.
        await gate.leave();
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(AdminScreen.route(widget.controller, insideKiosk: true));
        if (mounted) await gate.enter();
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
    child: AnimatedBuilder(
      animation: gate,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _Header(gate: gate, onMenu: _openMenu),
              if (gate.readerError case final error?)
                _ReaderBanner(message: error, onRetry: gate.reconnect),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: switch (gate.alarm) {
                    final alarm? => _AlarmView(
                      key: ValueKey(alarm.at),
                      alarm: alarm,
                      onDismiss: _dismissAlarm,
                    ),
                    null => _Dashboard(
                      key: const ValueKey('dashboard'),
                      gate: gate,
                    ),
                  },
                ),
              ),
              if (gate.simulation)
                _SimulationBar(controller: widget.controller),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.gate, required this.onMenu});

  final GateController gate;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, color, icon) = gate.connecting
        ? ('Connexion…', colors.onSurfaceVariant, Icons.sync)
        : gate.readerConnected
        ? ('Surveillance active', colors.primary, Icons.shield_outlined)
        : ('Portail hors ligne', colors.error, Icons.sensors_off);
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
                  gate.gateName,
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
            side: BorderSide(color: color.withValues(alpha: 0.4)),
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

/// Alarme : message affiché en grand pendant que la tablette le prononce.
class _AlarmView extends StatelessWidget {
  const _AlarmView({required this.alarm, required this.onDismiss, super.key});

  final GateAlarm alarm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFFB3261E);
    const ink = Colors.white;
    final book = alarm.book;
    return Container(
      color: background,
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.campaign_outlined, color: ink, size: 88),
                const SizedBox(height: 12),
                const Text(
                  'Attention ! Ne sortez pas avec un livre non emprunté.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ink,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Redirigez-vous vers le poste d’emprunt. Si vous avez des '
                  'difficultés, allez au poste d’emprunt assisté.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ink, fontSize: 20, height: 1.35),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.menu_book_outlined,
                        color: ink,
                        size: 34,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book?.title ?? 'Livre de la bibliothèque',
                              style: const TextStyle(
                                color: ink,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              book == null
                                  ? 'Non référencé sur ce portail'
                                  : '${book.accession}'
                                        '${book.author.isEmpty ? '' : ' · ${book.author}'}',
                              style: TextStyle(
                                color: ink.withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        DateFormat.Hms('fr_FR').format(alarm.at),
                        style: TextStyle(color: ink.withValues(alpha: 0.85)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: onDismiss,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ink,
                    side: const BorderSide(color: ink),
                  ),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Arrêter l’alarme (personnel)'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.gate, super.key});

  final GateController gate;

  @override
  Widget build(BuildContext context) {
    final counts = gate.today;
    final people = gate.countsPeople;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final staff = _StaffPanel(gate: gate);
        final events = _EventsPanel(gate: gate);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Counter(
                  icon: Icons.login,
                  label: 'Entrées aujourd’hui',
                  value: people ? '${counts.entries}' : '—',
                  width: wide ? null : constraints.maxWidth,
                ),
                _Counter(
                  icon: Icons.logout,
                  label: 'Sorties aujourd’hui',
                  value: people ? '${counts.exits}' : '—',
                  width: wide ? null : constraints.maxWidth,
                ),
                _Counter(
                  icon: Icons.groups_outlined,
                  label: 'Personnes à l’intérieur',
                  value: people ? '${counts.inside}' : '—',
                  width: wide ? null : constraints.maxWidth,
                ),
                _Counter(
                  icon: Icons.notification_important_outlined,
                  label: 'Alarmes aujourd’hui',
                  value: '${counts.alarms}',
                  alert: counts.alarms > 0,
                  width: wide ? null : constraints.maxWidth,
                ),
              ],
            ),
            if (!people) ...[
              const SizedBox(height: 10),
              Text(
                'Comptage des entrées et sorties désactivé : indiquez les '
                'barrières infrarouges du portail dans le terminal admin.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: staff),
                  const SizedBox(width: 16),
                  Expanded(child: events),
                ],
              )
            else ...[
              staff,
              const SizedBox(height: 16),
              events,
            ],
          ],
        );
      },
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.icon,
    required this.label,
    required this.value,
    this.alert = false,
    this.width,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool alert;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = alert ? colors.error : colors.primary;
    return SizedBox(
      width: width ?? 230,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: accent.withValues(alpha: 0.12),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: alert ? colors.error : null,
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
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(subtitle),
          ),
          const Divider(height: 1),
          ...children,
        ],
      ),
    );
  }
}

class _StaffPanel extends StatelessWidget {
  const _StaffPanel({required this.gate});

  final GateController gate;

  @override
  Widget build(BuildContext context) {
    final passages = gate.staffToday.take(20).toList();
    final inside = gate.staffInside.length;
    return _Panel(
      title: 'Personnel',
      subtitle:
          '$inside présent${inside > 1 ? 's' : ''} · '
          '${gate.staffToday.length} passage${gate.staffToday.length > 1 ? 's' : ''} aujourd’hui',
      children: [
        if (passages.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Aucun badge du personnel détecté aujourd’hui.'),
          ),
        for (final passage in passages)
          ListTile(
            dense: true,
            leading: _DirectionIcon(direction: passage.direction),
            title: Text(passage.staffName),
            subtitle: Text(
              '${passage.direction == PassageDirection.entry ? 'Entrée' : 'Sortie'}'
              '${passage.gateName.isEmpty || passage.gateName == gate.gateName ? '' : ' · ${passage.gateName}'}',
            ),
            trailing: Text(DateFormat.Hm('fr_FR').format(passage.passedAt)),
          ),
      ],
    );
  }
}

class _EventsPanel extends StatelessWidget {
  const _EventsPanel({required this.gate});

  final GateController gate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final events = gate.events.take(20).toList();
    return _Panel(
      title: 'Activité récente',
      subtitle: 'Alarmes, livres empruntés et badges',
      children: [
        if (events.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Aucun passage de livre ou de badge pour l’instant.'),
          ),
        for (final event in events)
          ListTile(
            dense: true,
            leading: switch (event.kind) {
              GateEventKind.alarm => Icon(
                Icons.notification_important_outlined,
                color: colors.error,
              ),
              GateEventKind.borrowedBook => Icon(
                Icons.verified_outlined,
                color: colors.primary,
              ),
              GateEventKind.staff => _DirectionIcon(
                direction: event.direction ?? PassageDirection.entry,
              ),
              GateEventKind.unknownBadge => Icon(
                Icons.badge_outlined,
                color: colors.onSurfaceVariant,
              ),
            },
            title: Text(event.title),
            subtitle: Text(event.detail),
            trailing: Text(DateFormat.Hms('fr_FR').format(event.at)),
          ),
      ],
    );
  }
}

class _DirectionIcon extends StatelessWidget {
  const _DirectionIcon({required this.direction});

  final PassageDirection direction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return direction == PassageDirection.entry
        ? Icon(Icons.login, color: colors.primary)
        : Icon(Icons.logout, color: colors.onSurfaceVariant);
  }
}

/// Mode Simulation : passages, livres et badges virtuels.
class _SimulationBar extends StatelessWidget {
  const _SimulationBar({required this.controller});

  final LibraryController controller;

  GateController get gate => controller.gate;

  Future<void> _passBook(BuildContext context) async {
    final books = (await controller.database.listBooks(limit: 200))
        .where((book) => book.tid != null || book.status == 'indisponible')
        .toList();
    if (!context.mounted) return;
    if (books.isEmpty) {
      showMessage(context, 'Aucun livre encodé.', error: true);
      return;
    }
    final book = await _pick<Book>(
      context,
      books,
      (book) => (
        book.title,
        '${book.accession} · '
            '${book.status == 'indisponible' ? 'emprunté' : 'non emprunté'}',
      ),
    );
    if (book == null) return;
    gate.reader.simulateTag(
      ReaderTag(epc: book.epc, tid: book.tid ?? '', rssi: 60),
    );
  }

  Future<void> _passBadge(BuildContext context) async {
    final staff = (await controller.database.listStaff(
      activeOnly: true,
    )).where((member) => member.badgeTid != null).toList();
    if (!context.mounted) return;
    if (staff.isEmpty) {
      showMessage(
        context,
        'Aucun badge du personnel : encodez-en un sur le poste Windows.',
        error: true,
      );
      return;
    }
    final member = await _pick<StaffMember>(
      context,
      staff,
      (member) => (member.name, member.staffNumber),
    );
    if (member == null) return;
    gate.reader.simulateTag(
      ReaderTag(epc: member.badgeEpc!, tid: member.badgeTid!, rssi: 60),
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
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Simulation',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          OutlinedButton.icon(
            onPressed: gate.countsPeople
                ? () => gate.simulatePassage(PassageDirection.entry)
                : null,
            icon: const Icon(Icons.login),
            label: const Text('Entrée'),
          ),
          OutlinedButton.icon(
            onPressed: gate.countsPeople
                ? () => gate.simulatePassage(PassageDirection.exit)
                : null,
            icon: const Icon(Icons.logout),
            label: const Text('Sortie'),
          ),
          OutlinedButton.icon(
            onPressed: () => _passBook(context),
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Livre'),
          ),
          OutlinedButton.icon(
            onPressed: () => _passBadge(context),
            icon: const Icon(Icons.badge_outlined),
            label: const Text('Badge du personnel'),
          ),
        ],
      ),
    ),
  );
}
