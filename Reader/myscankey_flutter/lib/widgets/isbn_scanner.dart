import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/isbn.dart';
import '../services/barcode_scanner_service.dart';
import '../services/library_controller.dart';

class IsbnScanner extends StatefulWidget {
  const IsbnScanner({super.key, this.controller});

  final LibraryController? controller;

  @override
  State<IsbnScanner> createState() => _IsbnScannerState();
}

class _IsbnScannerState extends State<IsbnScanner> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _scanner = BarcodeScannerService();
  StreamSubscription<Map<Object?, Object?>>? _scanSubscription;
  String? _error;
  String _status = 'Ouverture du scanner';
  bool _ready = false;
  bool _accepted = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.setBarcodeScannerActive(true);
    _scanSubscription = _scanner.events.listen(_onScan, onError: _onError);
    unawaited(_openScanner());
  }

  Future<void> _openScanner() async {
    try {
      if (widget.controller?.reader.reading == true) {
        await widget.controller!.stopInventory();
      }
      if (!mounted) return;
      await _scanner.open();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Prêt';
      });
    } catch (error) {
      _onError(error);
    }
  }

  @override
  void dispose() {
    unawaited(_scanSubscription?.cancel());
    unawaited(_scanner.close().catchError((Object _) {}));
    widget.controller?.setBarcodeScannerActive(false);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScan(Map<Object?, Object?> event) {
    if (!mounted || _accepted) return;
    final barcode = event['barcode']?.toString();
    if (barcode != null) {
      _field.text = barcode;
      _tryAccept(barcode, fromScanner: true);
    } else {
      setState(() {
        _status = event['state'] == 'scanning' ? 'Lecture en cours' : 'Prêt';
        if (event['state'] == 'scanning') _error = null;
      });
    }
  }

  void _onError(Object error) {
    if (!mounted) return;
    setState(() {
      _ready = false;
      _status = 'Scanner indisponible';
      _error = error is PlatformException
          ? error.message ?? 'Erreur du scanner optique.'
          : 'Impossible d’activer le scanner optique.';
    });
  }

  Future<void> _startScan() async {
    try {
      await _scanner.startScan();
    } catch (error) {
      _onError(error);
    }
  }

  void _onChanged(String value) {
    final normalized = _digits(value);
    if (value != normalized) {
      _field.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    if (normalized.length >= 10) _tryAccept(normalized, quiet: true);
  }

  void _submit() => _tryAccept(_field.text);

  void _tryAccept(
    String value, {
    bool quiet = false,
    bool fromScanner = false,
  }) {
    if (_accepted) return;
    final digits = _digits(value);
    if (Isbn.isValid(digits) &&
        (digits.length == 10 ||
            digits.startsWith('978') ||
            digits.startsWith('979'))) {
      _accepted = true;
      if (fromScanner) unawaited(_scanner.playScanBeep());
      Navigator.pop(context, Isbn.toIsbn13(digits));
      return;
    }
    if (!quiet && mounted) {
      setState(() {
        _error = 'ISBN invalide.';
        _status = 'Lecture refusée';
      });
    }
  }

  String _digits(String value) => value.replaceAll(RegExp(r'[^0-9Xx]'), '');

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scanner l’ISBN')),
    body: SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.qr_code_scanner,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Lecteur de codes',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('isbn_scanner_input'),
                    controller: _field,
                    focusNode: _focus,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'ISBN lu',
                      errorText: _error,
                      suffixIcon: IconButton(
                        tooltip: 'Valider',
                        onPressed: _submit,
                        icon: const Icon(Icons.check),
                      ),
                    ),
                    onChanged: _onChanged,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  IconButton.filled(
                    tooltip: 'Scanner',
                    onPressed: _ready ? _startScan : null,
                    icon: const Icon(Icons.qr_code_scanner),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Saisir au clavier'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
