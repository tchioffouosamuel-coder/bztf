import 'package:flutter/material.dart';

class ReaderConnectionDialog extends StatefulWidget {
  const ReaderConnectionDialog({
    required this.transport,
    required this.endpoint,
    super.key,
  });

  final String transport;
  final String endpoint;

  static Future<(String, String)?> show(
    BuildContext context, {
    required String transport,
    required String endpoint,
  }) => showDialog<(String, String)>(
    context: context,
    builder: (_) =>
        ReaderConnectionDialog(transport: transport, endpoint: endpoint),
  );

  @override
  State<ReaderConnectionDialog> createState() => _ReaderConnectionDialogState();
}

class _ReaderConnectionDialogState extends State<ReaderConnectionDialog> {
  late String _transport;
  late final TextEditingController _endpoint;

  @override
  void initState() {
    super.initState();
    _transport = widget.transport;
    _endpoint = TextEditingController(text: widget.endpoint);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connexion RFID'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _transport,
          decoration: const InputDecoration(labelText: 'Type de lecteur'),
          items: const [
            DropdownMenuItem(
              value: 'serial',
              child: Text('Lecteur intégré · Seuic UHF'),
            ),
            DropdownMenuItem(value: 'tcp', child: Text('Lecteur réseau · TCP')),
            DropdownMenuItem(value: 'simulation', child: Text('Simulation')),
          ],
          onChanged: (value) => setState(() => _transport = value ?? 'serial'),
        ),
        if (_transport == 'tcp') ...[
          const SizedBox(height: 14),
          TextField(
            controller: _endpoint,
            decoration: const InputDecoration(
              labelText: 'Adresse IP',
              hintText: '192.168.0.101',
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton.icon(
        onPressed: () {
          final endpoint = _transport == 'tcp'
              ? _endpoint.text.trim().isEmpty
                    ? '192.168.0.101'
                    : _endpoint.text.trim()
              : '';
          Navigator.pop(context, (_transport, endpoint));
        },
        icon: const Icon(Icons.cable),
        label: const Text('Connecter'),
      ),
    ],
  );
}
