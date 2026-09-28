import 'package:flutter/material.dart';

import '../services/library_controller.dart';
import '../widgets/reader_connection_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _serverUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _deviceName;
  bool _saving = false;
  bool _savingPowers = false;
  late int _readPower;
  late int _writePower;
  late int _inventoryPower;

  LibraryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(text: controller.sync.serverUrl);
    _apiKey = TextEditingController(text: controller.sync.apiKey);
    _deviceName = TextEditingController(text: controller.sync.deviceName);
    _readPower = controller.readPower;
    _writePower = controller.writePower;
    _inventoryPower = controller.inventoryPower;
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _apiKey.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _connect(BuildContext context) async {
    final config = await ReaderConnectionDialog.show(
      context,
      transport: controller.transport,
      endpoint: controller.endpoint,
    );
    if (config == null || !context.mounted) return;
    try {
      await controller.connectReader(
        nextTransport: config.$1,
        nextEndpoint: config.$2,
      );
      if (context.mounted) _message(context, 'Lecteur connecté.');
    } catch (error) {
      if (context.mounted) _message(context, error.toString());
    }
  }

  void _message(BuildContext context, String text) =>
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
        context,
        controller.sync.connected
            ? 'Serveur connecté et catalogue synchronisé.'
            : controller.sync.error ?? 'Configuration enregistrée.',
      );
    } catch (error) {
      if (mounted) _message(context, error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _savePowers() async {
    setState(() => _savingPowers = true);
    try {
      await controller.configureReaderPowers(
        nextReadPower: _readPower,
        nextWritePower: _writePower,
        nextInventoryPower: _inventoryPower,
      );
      if (mounted) {
        _message(context, 'Puissances RFID enregistrées et appliquées.');
      }
    } catch (error) {
      if (mounted) _message(context, error.toString());
    } finally {
      if (mounted) setState(() => _savingPowers = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
    children: [
      Text(
        'Lecteur RFID',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                controller.readerConnected ? Icons.sensors : Icons.sensors_off,
                color: controller.readerConnected
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(
                controller.readerConnected
                    ? 'Lecteur connecté'
                    : 'Lecteur hors ligne',
              ),
              subtitle: Text(switch (controller.transport) {
                'simulation' => 'Mode Simulation',
                'serial' => 'Service UHF Seuic intégré',
                _ => controller.endpoint,
              }),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _connect(context),
                      icon: const Icon(Icons.cable),
                      label: Text(
                        controller.readerConnected
                            ? 'Reconfigurer'
                            : 'Connecter',
                      ),
                    ),
                  ),
                  if (controller.readerConnected) ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Déconnecter',
                      onPressed: controller.disconnectReader,
                      icon: const Icon(Icons.link_off),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.signal_cellular_alt),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Puissance UHF',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Plage du lecteur : 5 à 33 dBm.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              _PowerSlider(
                label: 'Lecture',
                icon: Icons.nfc,
                value: _readPower,
                onChanged: (value) => setState(() => _readPower = value),
              ),
              _PowerSlider(
                label: 'Écriture',
                icon: Icons.edit_note,
                value: _writePower,
                onChanged: (value) => setState(() => _writePower = value),
              ),
              _PowerSlider(
                label: 'Inventaire',
                icon: Icons.fact_check_outlined,
                value: _inventoryPower,
                onChanged: (value) => setState(() => _inventoryPower = value),
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _savingPowers ? null : _savePowers,
                icon: _savingPowers
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Appliquer les puissances'),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 22),
      Text(
        'Synchronisation réseau',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      Card(
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
      const SizedBox(height: 22),
      Text(
        'Application',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      Card(
        child: SwitchListTile(
          secondary: Icon(
            controller.darkTheme
                ? Icons.dark_mode_outlined
                : Icons.light_mode_outlined,
          ),
          title: const Text('Thème sombre'),
          value: controller.darkTheme,
          onChanged: (_) => controller.toggleTheme(),
        ),
      ),
      const SizedBox(height: 22),
      Text(
        'Stockage local',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      const Card(
        child: ListTile(
          leading: Icon(Icons.storage_outlined),
          title: Text('Base SQLite sur cet appareil'),
          subtitle: Text(
            'Le catalogue et son historique restent disponibles hors ligne.',
          ),
        ),
      ),
    ],
  );
}

class _PowerSlider extends StatelessWidget {
  const _PowerSlider({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 21),
      const SizedBox(width: 9),
      SizedBox(
        width: 72,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      Expanded(
        child: Slider(
          min: 5,
          max: 33,
          divisions: 28,
          value: value.toDouble(),
          label: '$value dBm',
          onChanged: (next) => onChanged(next.round()),
        ),
      ),
      SizedBox(
        width: 54,
        child: Text(
          '$value dBm',
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}
