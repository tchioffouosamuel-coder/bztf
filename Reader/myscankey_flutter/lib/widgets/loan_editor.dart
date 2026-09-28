import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/lending.dart';
import '../services/library_controller.dart';

class LoanRequest {
  const LoanRequest({
    required this.memberNumber,
    required this.name,
    required this.dueAt,
    this.email = '',
    this.phone = '',
    this.notes = '',
  });

  final String memberNumber;
  final String name;
  final String email;
  final String phone;
  final DateTime dueAt;
  final String notes;
}

/// Formulaire d'emprunt : identifie l'abonné (par sa carte RFID ou à la
/// main) et la date de retour prévue.
class LoanEditor extends StatefulWidget {
  const LoanEditor({
    required this.controller,
    required this.bookTitle,
    super.key,
  });

  final LibraryController controller;
  final String bookTitle;

  static Future<LoanRequest?> show(
    BuildContext context, {
    required LibraryController controller,
    required String bookTitle,
  }) => showDialog<LoanRequest>(
    context: context,
    builder: (_) => LoanEditor(controller: controller, bookTitle: bookTitle),
  );

  @override
  State<LoanEditor> createState() => _LoanEditorState();
}

class _LoanEditorState extends State<LoanEditor> {
  static const defaultLoanDays = 14;

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  TextEditingController? _memberNumber;
  List<Subscriber> _subscribers = const [];
  bool _cardBusy = false;
  String _cardStatus = 'Lisez la carte de l’abonné pour remplir le formulaire.';
  bool _cardError = false;
  DateTime _dueAt = DateUtils.dateOnly(
    DateTime.now(),
  ).add(const Duration(days: defaultLoanDays));

  @override
  void initState() {
    super.initState();
    widget.controller.database.listSubscribers().then((subscribers) {
      if (mounted) setState(() => _subscribers = subscribers);
    });
  }

  @override
  void dispose() {
    for (final field in [_name, _email, _phone, _notes]) {
      field.dispose();
    }
    super.dispose();
  }

  void _fillFrom(Subscriber subscriber) {
    _memberNumber?.text = subscriber.memberNumber;
    _name.text = subscriber.name;
    _email.text = subscriber.email;
    _phone.text = subscriber.phone;
  }

  Future<void> _runCard(
    String progress,
    Future<String> Function() action,
  ) async {
    setState(() {
      _cardBusy = true;
      _cardError = false;
      _cardStatus = progress;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _cardStatus = message);
    } catch (error) {
      if (mounted) {
        setState(() {
          _cardError = true;
          _cardStatus = error.toString().replaceFirst(
            RegExp(r'^(Bad state|Invalid argument\(s\)):?\s*'),
            '',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _cardBusy = false);
    }
  }

  Future<void> _readCard() => _runCard(
    'Posez la carte sur le lecteur…',
    () async {
      final subscriber = await widget.controller.readSubscriberCard();
      _fillFrom(subscriber);
      return 'Carte reconnue : ${subscriber.name} (${subscriber.memberNumber})';
    },
  );

  Future<void> _encodeCard() async {
    if (!_formKey.currentState!.validate()) return;
    await _runCard('Posez une carte vierge sur le lecteur…', () async {
      final subscriber = await widget.controller.encodeSubscriberCard(
        memberNumber: _memberNumber!.text,
        name: _name.text,
        email: _email.text,
        phone: _phone.text,
      );
      _fillFrom(subscriber);
      return 'Carte encodée pour ${subscriber.name}.';
    });
  }

  Future<void> _pickDueDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt,
      firstDate: today.add(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Date de retour prévue',
    );
    if (picked != null) setState(() => _dueAt = picked);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      LoanRequest(
        memberNumber: _memberNumber!.text.trim(),
        name: _name.text.trim(),
        email: _email.text.trim(),
        phone: _phone.text.trim(),
        // Retour attendu en fin de journée.
        dueAt: _dueAt.add(const Duration(hours: 23, minutes: 59)),
        notes: _notes.text.trim(),
      ),
    );
  }

  String? _required(String? value, String message) =>
      value == null || value.trim().isEmpty ? message : null;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Emprunter'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.bookTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              _CardPanel(
                status: _cardStatus,
                error: _cardError,
                busy: _cardBusy,
                onRead: _readCard,
                onEncode: _encodeCard,
              ),
              const SizedBox(height: 14),
              Autocomplete<Subscriber>(
                displayStringForOption: (subscriber) => subscriber.memberNumber,
                optionsBuilder: (value) {
                  final term = value.text.trim().toLowerCase();
                  if (term.isEmpty) return const Iterable<Subscriber>.empty();
                  return _subscribers.where(
                    (subscriber) =>
                        subscriber.memberNumber.toLowerCase().contains(term) ||
                        subscriber.name.toLowerCase().contains(term),
                  );
                },
                onSelected: _fillFrom,
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 220,
                        maxWidth: 420,
                      ),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        children: [
                          for (final subscriber in options)
                            ListTile(
                              dense: true,
                              title: Text(subscriber.name),
                              subtitle: Text(
                                '${subscriber.memberNumber}'
                                '${subscriber.activeLoans > 0 ? ' · ${subscriber.activeLoans} emprunt(s) en cours' : ''}',
                              ),
                              onTap: () => onSelected(subscriber),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                  _memberNumber = controller;
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLength: 80,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'N° d’abonné *',
                      counterText: '',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (value) =>
                        _required(value, 'Le numéro d’abonné est obligatoire.'),
                  );
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                maxLength: 240,
                decoration: const InputDecoration(
                  labelText: 'Nom de l’abonné *',
                  counterText: '',
                ),
                validator: (value) =>
                    _required(value, 'Le nom de l’abonné est obligatoire.'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                maxLength: 80,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Téléphone',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                maxLength: 240,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'E-mail',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDueDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Retour prévu le',
                    prefixIcon: Icon(Icons.event_outlined),
                  ),
                  child: Text(
                    DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(_dueAt),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLength: 1000,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  counterText: '',
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
        onPressed: _cardBusy ? null : _submit,
        icon: const Icon(Icons.outbox_outlined),
        label: const Text('Enregistrer l’emprunt'),
      ),
    ],
  );
}

class _CardPanel extends StatelessWidget {
  const _CardPanel({
    required this.status,
    required this.error,
    required this.busy,
    required this.onRead,
    required this.onEncode,
  });

  final String status;
  final bool error;
  final bool busy;
  final VoidCallback onRead;
  final VoidCallback onEncode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = error ? colors.error : colors.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        border: Border(left: BorderSide(color: accent, width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.badge_outlined, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: busy ? null : onRead,
                icon: const Icon(Icons.contactless_outlined),
                label: const Text('Lire la carte'),
              ),
              TextButton.icon(
                onPressed: busy ? null : onEncode,
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Encoder la carte'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
