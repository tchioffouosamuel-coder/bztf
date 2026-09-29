import 'package:flutter/material.dart';

import '../services/library_controller.dart';
import '../widgets/accounts_card.dart';
import '../widgets/reader_connection_dialog.dart';
import '../widgets/sync_settings_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.controller, super.key});

  final LibraryController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _savingPowers = false;
  late int _readPower;
  late int _writePower;
  late int _inventoryPower;

  LibraryController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _readPower = controller.readPower;
    _writePower = controller.writePower;
    _inventoryPower = controller.inventoryPower;
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
        'Compte',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      AccountsCard(controller: controller),
      const SizedBox(height: 22),
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
      SyncSettingsCard(controller: controller),
      const SizedBox(height: 22),
      Text(
        'Type d’appareil',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 10),
      Card(
        child: ListTile(
          leading: const Icon(Icons.phone_android_outlined),
          title: const Text('Lecteur mobile'),
          subtitle: const Text(
            'Le poste d’emprunt et le changement de type d’appareil se '
            'règlent dans le terminal admin.',
          ),
          trailing: TextButton(
            onPressed: () => controller.setView('admin'),
            child: const Text('Ouvrir'),
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
