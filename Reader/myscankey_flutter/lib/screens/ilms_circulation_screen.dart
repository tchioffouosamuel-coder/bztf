import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/ilms_circulation_journal.dart';
import '../services/ilms_circulation_client.dart';
import '../services/ilms_circulation_sync.dart';
import 'ilms_messages.dart';

class IlmsCirculationScreen extends StatefulWidget {
  const IlmsCirculationScreen({super.key, required this.sync});
  final IlmsCirculationSync sync;
  @override
  State<IlmsCirculationScreen> createState() => _IlmsCirculationScreenState();
}

class _IlmsCirculationScreenState extends State<IlmsCirculationScreen> {
  final _cardEpc = TextEditingController();
  final _cardTid = TextEditingController();
  final _copyEpc = TextEditingController();
  final _copyTid = TextEditingController();
  Map<String, Object?>? _member;
  Map<String, Object?>? _copy;
  List<Map<String, Object?>> _entries = [];
  DateTime? _date;
  String _kind = 'checkout';
  bool _busy = false;
  bool _confirming = false;
  String? _notice;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in [_cardEpc, _cardTid, _copyEpc, _copyTid]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.sync.list();
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) _message(ilmsErrorMessage(error), error: true);
    }
  }

  void _message(String message, {bool error = false}) {
    setState(() {
      _notice = message;
      _error = error;
    });
  }

  Map<String, String> _tag(bool card) => normalizeIlmsTag({
    'epc': (card ? _cardEpc : _copyEpc).text,
    'tid': (card ? _cardTid : _copyTid).text,
  });

  Future<void> _resolve(bool card) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final result = card
          ? await widget.sync.resolveMember(_tag(true))
          : await widget.sync.resolveCopy(_tag(false));
      if (mounted) {
        setState(() {
          if (card) {
            _member = result;
          } else {
            _copy = result;
          }
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (card) {
            _member = null;
          } else {
            _copy = null;
          }
        });
        _message(ilmsErrorMessage(error), error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _ready =>
      _copy != null &&
      (_kind == 'checkout'
          ? _member != null &&
                _member!['eligible'] == true &&
                _copy!['available_for_checkout'] == true &&
                _date != null
          : _copy!['active_loan'] != null);

  Future<bool> _confirm(String title, String body, String action) async {
    setState(() => _confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: Text(title),
              content: Text(body),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _send() async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      final copy = _copy!['copy'] as Map;
      final operation = {
        'kind': _kind,
        'payload': _kind == 'checkout'
            ? {
                'operation_id': newIlmsCirculationId(),
                'card': _tag(true),
                'copy': _tag(false),
                'preferred_return_date': _date!.toUtc().toIso8601String(),
                'expected_card_id': _member!['card_id'],
                'expected_member_id': _member!['member_id'],
                'expected_copy_id': copy['id'],
              }
            : {
                'copy': _tag(false),
                'loan_id': (_copy!['active_loan'] as Map)['id'],
              },
      };
      final details =
          '${_copy!['title']}\n${copy['number']}'
          '${_kind == 'checkout' ? '\n${_member!['name']}\n${DateFormat('dd/MM/yyyy').format(_date!)}' : '\nPret ${(_copy!['active_loan'] as Map)['number']}'}';
      if (!await _confirm(
        _kind == 'checkout' ? 'Confirmer le pret' : 'Confirmer le retour',
        details,
        'Confirmer',
      )) {
        return;
      }
      if (!mounted) return;
      final entry = await widget.sync.enqueue(operation);
      if (!mounted) return;
      // Once durable, the only retry path is the original journal entry.
      setState(() {
        _member = null;
        _copy = null;
      });
      _cardEpc.clear();
      _cardTid.clear();
      _copyEpc.clear();
      _copyTid.clear();
      try {
        final loan = await widget.sync.retry(entry['id'] as String);
        if (mounted) _message('Confirme par ILMS : ${loan['number']}.');
      } catch (error) {
        if (mounted) {
          _message(
            'Demande conservee dans le journal. ${ilmsErrorMessage(error)}',
            error: true,
          );
        }
      }
    } catch (error) {
      if (mounted) _message(ilmsErrorMessage(error), error: true);
    } finally {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _retry(Map<String, Object?> entry) async {
    if (_busy) return;
    if (!await _confirm(
      'Renvoyer la demande',
      '${entry['kind'] == 'checkout' ? 'Pret' : 'Retour'} ${entry['id']}\nEtat : ${entry['state']}.',
      'Renvoyer',
    )) {
      return;
    }
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final loan = await widget.sync.retry(entry['id'] as String);
      if (mounted) _message('Confirme par ILMS : ${loan['number']}.');
    } catch (error) {
      if (mounted) _message(ilmsErrorMessage(error), error: true);
    } finally {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _discard(Map<String, Object?> entry) async {
    if (_busy) return;
    if (!await _confirm(
      'Supprimer localement',
      'Cette suppression retire uniquement la demande locale. Elle ne peut pas annuler un pret ou un retour deja accepte par ILMS.',
      'Supprimer localement',
    )) {
      return;
    }
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.sync.discard(entry['id'] as String, confirmed: true);
      if (mounted) _message('Demande supprimee localement.');
    } catch (error) {
      if (mounted) _message(ilmsErrorMessage(error), error: true);
    } finally {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Widget _tagFields(bool card) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        card ? 'Carte adherent' : 'Exemplaire',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: ValueKey(card ? 'card-epc' : 'copy-epc'),
              controller: card ? _cardEpc : _copyEpc,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'EPC'),
              onChanged: (_) => setState(() {
                if (card) {
                  _member = null;
                } else {
                  _copy = null;
                }
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: ValueKey(card ? 'card-tid' : 'copy-tid'),
              controller: card ? _cardTid : _copyTid,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'TID'),
              onChanged: (_) => setState(() {
                if (card) {
                  _member = null;
                } else {
                  _copy = null;
                }
              }),
            ),
          ),
          IconButton(
            tooltip: card ? 'Rechercher la carte' : 'Rechercher l\'exemplaire',
            onPressed: _busy ? null : () => _resolve(card),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      if (card && _member != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${_member!['name']} - ${_member!['number']}\n'
            '${_member!['eligible'] == true ? 'Adherent eligible' : 'Pret refuse : ${_member!['blocked_reason'] ?? 'adherent non eligible'}'}',
          ),
        ),
      if (!card && _copy != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${_copy!['title']} - ${(_copy!['copy'] as Map)['number']}\n'
            '${_copy!['available_for_checkout'] == true ? 'Disponible' : 'Indisponible'}'
            '${_copy!['active_loan'] == null ? '' : '\nPret ${(_copy!['active_loan'] as Map)['number']}'}',
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Circulation RFID',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'checkout',
                  label: Text('Pret'),
                  icon: Icon(Icons.north_east),
                ),
                ButtonSegment(
                  value: 'return',
                  label: Text('Retour'),
                  icon: Icon(Icons.south_west),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _kind = value.single;
                      _member = null;
                      _copy = null;
                      _notice = null;
                    }),
            ),
            const SizedBox(height: 20),
            if (_kind == 'checkout') ...[
              _tagFields(true),
              const SizedBox(height: 20),
            ],
            _tagFields(false),
            if (_kind == 'checkout') ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final now = DateTime.now();
                        final date = await showDatePicker(
                          context: context,
                          initialDate:
                              _date ?? now.add(const Duration(days: 14)),
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: now.add(const Duration(days: 3650)),
                        );
                        if (mounted && date != null) {
                          setState(() => _date = date);
                        }
                      },
                icon: const Icon(Icons.event),
                label: Text(
                  _date == null
                      ? 'Date de retour souhaitee'
                      : DateFormat('dd/MM/yyyy').format(_date!),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: !_busy && _ready ? _send : null,
              icon: const Icon(Icons.check),
              label: Text(
                _kind == 'checkout'
                    ? 'Confirmer le pret'
                    : 'Confirmer le retour',
              ),
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _notice!,
                  style: TextStyle(
                    color: _error
                        ? Theme.of(context).colorScheme.error
                        : const Color(0xFF176447),
                  ),
                ),
              ),
            if (_busy && !_confirming)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 24),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Journal local (${_entries.length})',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualiser le journal',
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Aucune demande en attente.'),
              ),
            for (final entry in _entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry['kind'] == 'checkout' ? 'Pret' : 'Retour'} - ${entry['state'] == 'blocked' ? 'Refuse' : 'En attente'}',
                          ),
                          Text(
                            '${entry['id']}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            'Tentatives : ${entry['attempts']}${entry['last_status'] == null || entry['last_status'] == 0 ? '' : ' - HTTP ${entry['last_status']}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Renvoyer la demande',
                      onPressed: _busy ? null : () => _retry(entry),
                      icon: const Icon(Icons.sync),
                    ),
                    IconButton(
                      tooltip: 'Supprimer localement',
                      onPressed: _busy ? null : () => _discard(entry),
                      icon: const Icon(Icons.delete_outline),
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
