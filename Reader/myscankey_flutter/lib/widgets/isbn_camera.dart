import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/isbn.dart';
import '../services/library_controller.dart';
import 'status_pill.dart';

class IsbnCamera extends StatefulWidget {
  const IsbnCamera({super.key, this.controller});

  final LibraryController? controller;

  @override
  State<IsbnCamera> createState() => _IsbnCameraState();
}

class _IsbnCameraState extends State<IsbnCamera> {
  final _scanner = MobileScannerController(formats: [BarcodeFormat.ean13]);
  bool _detected = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scanner l’ISBN'),
      actions: [
        AnimatedBuilder(
          animation: widget.controller ?? _scanner,
          builder: (_, _) => Padding(
            padding: const EdgeInsets.only(right: 12),
            child: StatusPill(
              widget.controller?.readerConnected == true
                  ? 'reader_connected'
                  : 'reader_disconnected',
            ),
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Placez le code-barres ISBN du livre devant la caméra.'),
        ),
        Expanded(
          child: MobileScanner(
            controller: _scanner,
            errorBuilder: (context, error) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('La caméra n’est pas disponible.'),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Saisir au clavier'),
                  ),
                ],
              ),
            ),
            onDetect: (capture) {
              if (_detected) return;
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue ?? '';
                if ((value.startsWith('978') || value.startsWith('979')) &&
                    Isbn.isValid(value)) {
                  _detected = true;
                  Navigator.pop(context, value);
                  return;
                }
              }
            },
          ),
        ),
      ],
    ),
  );
}
