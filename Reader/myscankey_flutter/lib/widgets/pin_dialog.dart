import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kiosk_controller.dart';

/// Demande le code administrateur du poste d'emprunt.
Future<bool> requestAdminPin(
  BuildContext context,
  KioskController kiosk, {
  String title = 'Accès administrateur',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PinDialog(kiosk: kiosk, title: title),
    ) ??
    false;

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.kiosk, required this.title});

  final KioskController kiosk;
  final String title;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.kiosk.verifyPin(_pin.text)) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _error = 'Code incorrect.';
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Clavier ouvert sur une tablette en paysage : peu de hauteur restante.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return AlertDialog(
      scrollable: true,
      insetPadding: EdgeInsets.symmetric(
        horizontal: 40,
        vertical: keyboardOpen ? 8 : 24,
      ),
      icon: keyboardOpen ? null : const Icon(Icons.lock_outline),
      title: Text(widget.title),
      content: TextField(
        controller: _pin,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: 'Code administrateur',
          counterText: '',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Valider')),
      ],
    );
  }
}
