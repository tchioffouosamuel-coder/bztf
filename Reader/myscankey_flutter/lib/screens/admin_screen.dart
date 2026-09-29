import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../data/catalog_exporter.dart';
import '../models/lending.dart';
import '../services/desk_reader_service.dart';
import '../services/kiosk_controller.dart';
import '../services/library_controller.dart';
import '../widgets/accounts_card.dart';
import 'kiosk_screen.dart';

/// Terminal admin : historique des emprunts, abonnés et réglages du poste.
class AdminScreen extends StatelessWidget {
  const AdminScreen({
    required this.controller,
    this.insideKiosk = false,
    super.key,
  });

  final LibraryController controller;

  /// Ouvert depuis le poste d'emprunt (au-dessus de celui-ci).
  final bool insideKiosk;

  static Route<void> route(
    LibraryController controller, {
    bool insideKiosk = false,
  }) => MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('Terminal admin')),
      body: SafeArea(
        top: false,
        child: AdminScreen(controller: controller, insideKiosk: insideKiosk),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Emprunts'),
            Tab(icon: Icon(Icons.people_outline), text: 'Abonnés'),
            Tab(icon: Icon(Icons.point_of_sale_outlined), text: 'Poste'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _LoansTab(controller: controller),
              _SubscribersTab(controller: controller),
              _KioskSettingsTab(
                controller: controller,
                insideKiosk: insideKiosk,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String _date(String? value, {bool time = false}) {
  if (value == null) return '—';
  final date = DateTime.parse(value).toLocal();
  return DateFormat(time ? 'dd/MM/yyyy HH:mm' : 'dd/MM/yyyy').format(date);
}

(String, Color) _loanStatus(BuildContext context, Loan loan) {
  final colors = Theme.of(context).colorScheme;
  if (loan.returned) {
    return loan.late
        ? ('Rendu en retard', colors.tertiary)
        : ('Rendu', colors.onSurfaceVariant);
  }
  return loan.overdue
      ? ('En retard', colors.error)
      : ('En cours', colors.primary);
}

class _LoansTab extends StatefulWidget {
  const _LoansTab({required this.controller});

  final LibraryController controller;

  @override
  State<_LoansTab> createState() => _LoansTabState();
}

class _LoansTabState extends State<_LoansTab> {
  static const _pageSize = 50;

  final _search = TextEditingController();
  LoanFilter _filter = LoanFilter.all;
  List<Loan> _loans = const [];
  LoanStats _stats = const LoanStats();
  bool _loading = true;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    final database = widget.controller.database;
    final page = await database.listLoans(
      filter: _filter,
      search: _search.text,
      limit: _pageSize,
      offset: more ? _loans.length : 0,
    );
    final stats = await database.loanStats();
    if (!mounted) return;
    setState(() {
      _loans = more ? [..._loans, ...page] : page;
      _hasMore = page.length == _pageSize;
      _stats = stats;
      _loading = false;
    });
  }

  Future<void> _export() async {
    try {
      final loans = await widget.controller.database.listLoans(
        filter: _filter,
        search: _search.text,
        limit: 100000,
      );
      await shareLoansCsv(loans);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _open(Loan loan) async {
    final returned = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _LoanDetails(loan: loan, controller: widget.controller),
    );
    if (returned == true) await _load();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _Stat('En cours', _stats.active, Icons.outbox_outlined, width),
                _Stat(
                  'En retard',
                  _stats.overdue,
                  Icons.warning_amber_rounded,
                  width,
                  alert: _stats.overdue > 0,
                ),
                _Stat(
                  'Empruntés aujourd’hui',
                  _stats.borrowedToday,
                  Icons.today_outlined,
                  width,
                ),
                _Stat(
                  'Rendus aujourd’hui',
                  _stats.returnedToday,
                  Icons.move_to_inbox_outlined,
                  width,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Titre, numéro, abonné…',
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            IconButton(
              tooltip: 'Exporter en CSV',
              onPressed: _loans.isEmpty ? null : _export,
              icon: const Icon(Icons.ios_share),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (filter, label) in const [
                (LoanFilter.all, 'Tous'),
                (LoanFilter.active, 'En cours'),
                (LoanFilter.overdue, 'En retard'),
                (LoanFilter.returned, 'Rendus'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _filter == filter,
                    onSelected: (_) {
                      setState(() => _filter = filter);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_loading && _loans.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loans.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Aucun emprunt ne correspond.')),
          )
        else
          for (final loan in _loans)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _LoanTile(loan: loan, onTap: () => _open(loan)),
            ),
        if (_hasMore)
          Center(
            child: TextButton(
              onPressed: _loading ? null : () => _load(more: true),
              child: const Text('Charger plus'),
            ),
          ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(
    this.label,
    this.value,
    this.icon,
    this.width, {
    this.alert = false,
  });

  final String label;
  final int value;
  final IconData icon;
  final double width;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = alert ? colors.error : colors.primary;
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      '$value',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: alert ? color : null,
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

class _LoanTile extends StatelessWidget {
  const _LoanTile({required this.loan, required this.onTap});

  final Loan loan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, color) = _loanStatus(context, loan);
    return Card(
      child: ListTile(
        onTap: onTap,
        title: Text(
          loan.bookTitle ?? 'Livre supprimé',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${loan.subscriberName ?? '—'} · ${loan.memberNumber ?? ''}\n'
          'Emprunté le ${_date(loan.borrowedAt)} · '
          '${loan.returned ? 'rendu le ${_date(loan.returnedAt)}' : 'retour prévu le ${_date(loan.dueAt)}'}',
        ),
        isThreeLine: true,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoanDetails extends StatefulWidget {
  const _LoanDetails({required this.loan, required this.controller});

  final Loan loan;
  final LibraryController controller;

  @override
  State<_LoanDetails> createState() => _LoanDetailsState();
}

class _LoanDetailsState extends State<_LoanDetails> {
  bool _busy = false;

  Future<void> _return() async {
    final loan = widget.loan;
    final confirmed = await confirmAction(
      context,
      title: 'Enregistrer le retour ?',
      message: '« ${loan.bookTitle} » emprunté par ${loan.subscriberName}.',
      confirmLabel: 'Enregistrer',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final book = await widget.controller.database.getBook(loan.bookId);
      if (book == null) throw StateError('Livre introuvable.');
      await widget.controller.returnBook(book);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, error.toString(), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loan = widget.loan;
    final (label, color) = _loanStatus(context, loan);
    Widget row(String name, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(name, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loan.bookTitle ?? 'Livre supprimé',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            row('Numéro', loan.bookAccession ?? '—'),
            row(
              'Abonné',
              '${loan.subscriberName ?? '—'} (${loan.memberNumber ?? '—'})',
            ),
            if ((loan.subscriberPhone ?? '').isNotEmpty)
              row('Téléphone', loan.subscriberPhone!),
            if ((loan.subscriberEmail ?? '').isNotEmpty)
              row('E-mail', loan.subscriberEmail!),
            row('Emprunté le', _date(loan.borrowedAt, time: true)),
            row('Retour prévu', _date(loan.dueAt)),
            row('Rendu le', _date(loan.returnedAt, time: true)),
            if (loan.notes.isNotEmpty) row('Notes', loan.notes),
            if (!loan.returned) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy ? null : _return,
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: const Text('Enregistrer le retour'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubscribersTab extends StatefulWidget {
  const _SubscribersTab({required this.controller});

  final LibraryController controller;

  @override
  State<_SubscribersTab> createState() => _SubscribersTabState();
}

class _SubscribersTabState extends State<_SubscribersTab> {
  final _search = TextEditingController();
  List<Subscriber> _subscribers = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await widget.controller.database.listSubscribers(
      search: _search.text,
    );
    if (mounted) {
      setState(() {
        _subscribers = rows;
        _loading = false;
      });
    }
  }

  Future<void> _open(Subscriber subscriber) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SubscriberDetails(
        subscriber: subscriber,
        controller: widget.controller,
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final now = DateTime.now().toUtc();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Nom, numéro, téléphone…',
            ),
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 10),
          if (_loading && _subscribers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_subscribers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Aucun abonné ne correspond.')),
            )
          else
            for (final subscriber in _subscribers)
              Builder(
                builder: (context) {
                  final ends = subscriber.subscriptionEndsAt;
                  final valid =
                      ends != null && !DateTime.parse(ends).isBefore(now);
                  final ok =
                      subscriber.active &&
                      valid &&
                      subscriber.overdueLoans == 0;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      onTap: () => _open(subscriber),
                      leading: Icon(
                        ok ? Icons.verified_user_outlined : Icons.block,
                        color: ok ? colors.primary : colors.error,
                      ),
                      title: Text(
                        subscriber.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${subscriber.memberNumber}'
                        '${subscriber.hasCard ? '' : ' · sans carte'}\n'
                        '${!subscriber.active
                            ? 'Compte désactivé'
                            : valid
                            ? 'Abonné jusqu’au ${_date(ends)}'
                            : ends == null
                            ? 'Sans abonnement'
                            : 'Abonnement expiré le ${_date(ends)}'}'
                        ' · ${subscriber.activeLoans} emprunt(s)'
                        '${subscriber.overdueLoans > 0 ? ', ${subscriber.overdueLoans} en retard' : ''}',
                      ),
                      isThreeLine: true,
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }
}

class _SubscriberDetails extends StatefulWidget {
  const _SubscriberDetails({
    required this.subscriber,
    required this.controller,
  });

  final Subscriber subscriber;
  final LibraryController controller;

  @override
  State<_SubscriberDetails> createState() => _SubscriberDetailsState();
}

class _SubscriberDetailsState extends State<_SubscriberDetails> {
  BorrowerStatus? _status;
  List<Loan> _loans = const [];
  bool _busy = false;

  KioskController get _kiosk => widget.controller.kiosk;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final database = widget.controller.database;
    final status = await database.borrowerStatus(
      widget.subscriber.id,
      maxLoans: _kiosk.maxLoans,
    );
    final loans = await database.listLoans(
      filter: LoanFilter.active,
      subscriberId: widget.subscriber.id,
    );
    if (mounted) {
      setState(() {
        _status = status;
        _loans = loans;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (mounted) showMessage(context, done);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renew() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(today.year + 1, today.month, today.day),
      firstDate: today.add(const Duration(days: 1)),
      lastDate: DateTime(today.year + 5, today.month, today.day),
      helpText: 'Fin de l’abonnement',
    );
    if (picked == null || !mounted) return;
    await _run(
      () => widget.controller.database.renewSubscription(
        widget.subscriber.id,
        picked.add(const Duration(hours: 23, minutes: 59)),
      ),
      'Abonnement enregistré.',
    );
  }

  Future<void> _suspend() async {
    final confirmed = await confirmAction(
      context,
      title: 'Suspendre l’abonnement ?',
      message: '${widget.subscriber.name} ne pourra plus emprunter au poste.',
      confirmLabel: 'Suspendre',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      () =>
          widget.controller.database.suspendSubscription(widget.subscriber.id),
      'Abonnement suspendu.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = _status;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.subscriber.name,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            Text(
              '${widget.subscriber.memberNumber} · '
              '${widget.subscriber.hasCard ? 'carte encodée' : 'carte non encodée'}',
            ),
            const SizedBox(height: 14),
            if (status == null)
              const LinearProgressIndicator()
            else ...[
              Text(
                status.eligible
                    ? 'Peut emprunter ${status.remaining} livre(s) au poste'
                    : 'Emprunt refusé au poste',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: status.eligible ? colors.primary : colors.error,
                ),
              ),
              for (final reason in status.reasons) Text('• $reason'),
              const SizedBox(height: 6),
              Text(
                status.subscription == null
                    ? 'Aucun abonnement valide.'
                    : 'Abonnement valable jusqu’au ${_date(status.subscription!.endsAt)}.',
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Emprunts en cours (${_loans.length})',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final loan in _loans)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(loan.bookTitle ?? '—'),
                subtitle: Text('Retour prévu le ${_date(loan.dueAt)}'),
                trailing: loan.overdue
                    ? Text('En retard', style: TextStyle(color: colors.error))
                    : null,
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _renew,
                    icon: const Icon(Icons.event_repeat_outlined),
                    label: const Text('Renouveler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || status?.subscription == null
                        ? null
                        : _suspend,
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('Suspendre'),
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

class _KioskSettingsTab extends StatefulWidget {
  const _KioskSettingsTab({
    required this.controller,
    required this.insideKiosk,
  });

  final LibraryController controller;
  final bool insideKiosk;

  @override
  State<_KioskSettingsTab> createState() => _KioskSettingsTabState();
}

class _KioskSettingsTabState extends State<_KioskSettingsTab> {
  late String _transport;
  late final TextEditingController _endpoint;
  late int _power;
  late int _maxLoans;
  late int _loanDays;
  bool _testing = false;
  String? _readerInfo;

  KioskController get kiosk => widget.controller.kiosk;

  @override
  void initState() {
    super.initState();
    _transport = kiosk.transport;
    _endpoint = TextEditingController(text: kiosk.endpoint);
    _power = kiosk.power;
    _maxLoans = kiosk.maxLoans;
    _loanDays = kiosk.loanDays;
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _saveReader() async {
    setState(() {
      _testing = true;
      _readerInfo = null;
    });
    try {
      final info = await kiosk.configureReader(
        nextTransport: _transport,
        nextEndpoint: _endpoint.text,
        nextPower: _power,
      );
      _endpoint.text = kiosk.endpoint;
      final id = info['readerId']?.toString() ?? '';
      final version = info['version']?.toString() ?? '';
      setState(
        () => _readerInfo = [
          'Lecteur connecté',
          if (id.isNotEmpty) 'n° $id',
          if (version.isNotEmpty) 'version $version',
        ].join(' · '),
      );
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _savePolicy() async {
    try {
      await kiosk.configurePolicy(
        nextMaxLoans: _maxLoans,
        nextLoanDays: _loanDays,
      );
      if (mounted) showMessage(context, 'Règles de prêt enregistrées.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _changePin() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget field(TextEditingController controller, String label) =>
                TextField(
                  controller: controller,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: label,
                    counterText: '',
                  ),
                );
            return AlertDialog(
              title: const Text('Code administrateur'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field(current, 'Code actuel'),
                  field(next, 'Nouveau code (4 à 8 chiffres)'),
                  field(confirm, 'Confirmer le nouveau code'),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (next.text != confirm.text) {
                      setDialogState(
                        () => error = 'Les codes ne correspondent pas.',
                      );
                      return;
                    }
                    try {
                      await kiosk.changePin(
                        current: current.text,
                        next: next.text,
                      );
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (exception) {
                      setDialogState(
                        () => error = exception.toString().replaceFirst(
                          RegExp(r'^(Bad state|Invalid argument\(s\)):?\s*'),
                          '',
                        ),
                      );
                    }
                  },
                  child: const Text('Enregistrer'),
                ),
              ],
            );
          },
        );
      },
    );
    for (final field in [current, next, confirm]) {
      field.dispose();
    }
    if (saved == true && mounted) {
      setState(() {});
      showMessage(context, 'Code administrateur modifié.');
    }
  }

  Future<void> _switchRole() async {
    final toKiosk = widget.controller.deviceRole != 'kiosk';
    final confirmed = await confirmAction(
      context,
      title: toKiosk
          ? 'Passer en poste d’emprunt ?'
          : 'Passer en lecteur mobile ?',
      message: toKiosk
          ? 'L’application s’ouvrira directement sur le poste d’emprunt. '
                'Le code administrateur sera nécessaire pour en sortir.'
          : 'L’application s’ouvrira sur les écrans du personnel '
                '(catalogue, station, inventaire).',
      confirmLabel: 'Changer',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    await widget.controller.setDeviceRole(toKiosk ? 'kiosk' : 'mobile');
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: kiosk,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final isKiosk = widget.controller.deviceRole == 'kiosk';
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          _heading('Compte'),
          AccountsCard(controller: widget.controller),
          _heading('Type d’appareil'),
          Card(
            child: ListTile(
              leading: Icon(
                isKiosk
                    ? Icons.point_of_sale_outlined
                    : Icons.phone_android_outlined,
              ),
              title: Text(isKiosk ? 'Poste d’emprunt' : 'Lecteur mobile'),
              subtitle: Text(
                isKiosk
                    ? 'L’application s’ouvre sur le poste en libre-service.'
                    : 'L’application s’ouvre sur les écrans du personnel.',
              ),
              trailing: TextButton(
                onPressed: _switchRole,
                child: const Text('Changer'),
              ),
            ),
          ),
          if (!widget.insideKiosk && !isKiosk) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => Navigator.of(
                context,
              ).push(KioskScreen.route(widget.controller)),
              icon: const Icon(Icons.point_of_sale_outlined),
              label: const Text('Ouvrir le poste d’emprunt sur cet appareil'),
            ),
          ],
          _heading('Lecteur RFID de bureau'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        kiosk.readerConnected
                            ? Icons.sensors
                            : Icons.sensors_off,
                        color: kiosk.readerConnected
                            ? colors.primary
                            : colors.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _readerInfo ??
                              kiosk.readerError ??
                              (kiosk.readerConnected
                                  ? 'Lecteur connecté'
                                  : 'Lecteur non connecté'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _transport,
                    decoration: const InputDecoration(labelText: 'Connexion'),
                    items: const [
                      DropdownMenuItem(
                        value: 'tcp',
                        child: Text('Réseau · TCP/IP'),
                      ),
                      DropdownMenuItem(
                        value: 'serial',
                        child: Text('Série · RS232'),
                      ),
                      DropdownMenuItem(
                        value: 'simulation',
                        child: Text('Simulation'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _transport = value ?? 'tcp'),
                  ),
                  if (_transport != 'simulation') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _endpoint,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: _transport == 'tcp'
                            ? 'Adresse IP (port ${DeskReaderService.defaultTcpPort} par défaut)'
                            : 'Port série (débit ${DeskReaderService.defaultBaudRate} par défaut)',
                        hintText: _transport == 'tcp'
                            ? '192.168.1.168:8160'
                            : '/dev/ttyS1:115200',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Puissance'),
                      Expanded(
                        child: Slider(
                          min: DeskReaderService.minPower.toDouble(),
                          max: DeskReaderService.maxPower.toDouble(),
                          divisions:
                              DeskReaderService.maxPower -
                              DeskReaderService.minPower,
                          value: _power.toDouble(),
                          label: '$_power dBm',
                          onChanged: (value) =>
                              setState(() => _power = value.round()),
                        ),
                      ),
                      Text('$_power dBm'),
                    ],
                  ),
                  Text(
                    'Une puissance faible évite de lire les livres posés à côté du poste.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _testing ? null : _saveReader,
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cable),
                    label: const Text('Enregistrer et tester'),
                  ),
                ],
              ),
            ),
          ),
          _heading('Règles de prêt'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Stepper(
                    label: 'Livres empruntés à la fois',
                    value: _maxLoans,
                    min: 1,
                    max: 50,
                    onChanged: (value) => setState(() => _maxLoans = value),
                  ),
                  _Stepper(
                    label: 'Durée du prêt (jours)',
                    value: _loanDays,
                    min: 1,
                    max: 365,
                    onChanged: (value) => setState(() => _loanDays = value),
                  ),
                  Text(
                    'Pour emprunter, l’abonné doit avoir un compte actif, un '
                    'abonnement valide et aucun livre en retard.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _savePolicy,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer les règles'),
                  ),
                ],
              ),
            ),
          ),
          _heading('Sécurité'),
          Card(
            child: ListTile(
              leading: Icon(
                kiosk.usesDefaultPin
                    ? Icons.warning_amber_rounded
                    : Icons.lock_outline,
                color: kiosk.usesDefaultPin ? colors.error : null,
              ),
              title: const Text('Code administrateur'),
              subtitle: Text(
                kiosk.usesDefaultPin
                    ? 'Code par défaut (${KioskController.defaultPin}) : changez-le.'
                    : 'Protège la sortie du poste d’emprunt.',
              ),
              trailing: TextButton(
                onPressed: _changePin,
                child: const Text('Modifier'),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label)),
      IconButton(
        onPressed: value > min ? () => onChanged(value - 1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: 40,
        child: Text(
          '$value',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
      IconButton(
        onPressed: value < max ? () => onChanged(value + 1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}
