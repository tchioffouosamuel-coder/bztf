import 'package:flutter/material.dart';

import '../services/library_controller.dart';

/// Connexion à l'API de synchronisation : état, adresse, clé et nom de
/// l'appareil. Partagé par les Réglages et le terminal admin du poste.
class SyncSettingsCard extends StatefulWidget {
  const SyncSettingsCard({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<SyncSettingsCard> createState() => _SyncSettingsCardState();
}

class _SyncSettingsCardState extends State<SyncSettingsCard> {
  late final TextEditingController _serverUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _deviceName;
  bool _saving = false;

  LibraryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(text: controller.sync.serverUrl);
    _apiKey = TextEditingController(text: controller.sync.apiKey);
    _deviceName = TextEditingController(text: controller.sync.deviceName);
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _apiKey.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _saveSync() async {
    setState(() => _saving = true);
    try {
      await controller.configureSync(
        serverUrl: _serverUrl.text,
        apiKey: _apiKey.text,
        deviceName: _deviceName.text,
      );
      if (!mounted) return;
      _message(
        controller.sync.connected
            ? 'Serveur connecté et catalogue synchronisé.'
            : controller.sync.error ?? 'Configuration enregistrée.',
      );
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  controller.sync.connected
                      ? Icons.cloud_done_outlined
                      : controller.sync.configured
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_outlined,
                  color: controller.sync.connected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        controller.sync.connected
                            ? 'Synchronisation active'
                            : controller.sync.configured
                            ? 'Serveur indisponible'
                            : 'Serveur non configuré',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        controller.sync.syncing
                            ? 'Synchronisation en cours…'
                            : '${controller.sync.pendingCount} modification(s) en attente',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (controller.sync.syncing)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Synchroniser maintenant',
                    onPressed: controller.sync.configured
                        ? controller.sync.syncNow
                        : null,
                    icon: const Icon(Icons.sync),
                  ),
              ],
            ),
            if (controller.sync.error case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _serverUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Adresse du serveur',
                hintText: 'https://rfid.exemple.org',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiKey,
              obscureText: true,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Clé d’appareil',
                prefixIcon: Icon(Icons.key_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(
                labelText: 'Nom de cet appareil',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              'ID : ${controller.sync.deviceId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _saveSync,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Enregistrer et synchroniser'),
            ),
          ],
        ),
      ),
    ),
  );
}
