import 'package:flutter/material.dart';

import '../app.dart';
import '../services/gate_controller.dart';
import '../services/gate_reader_service.dart';
import 'n01_settings_form.dart';

/// Réglages du portail antivol dans le terminal admin : connexion au
/// portail N01, barrières infrarouges (sens de passage) et alarme.
class GateSettingsSection extends StatefulWidget {
  const GateSettingsSection({required this.gate, super.key});

  final GateController gate;

  @override
  State<GateSettingsSection> createState() => _GateSettingsSectionState();
}

class _GateSettingsSectionState extends State<GateSettingsSection> {
  late String _transport;
  late final TextEditingController _endpoint;
  late final TextEditingController _name;
  late int _power;
  late int _outside;
  late int _inside;
  late double _volume;
  late int _lightGpo;
  late int _rearm;
  late bool _buzzer;
  late int _buzzerGpo;
  late int _buzzerSeconds;
  bool _testing = false;
  bool _loadingN01 = false;
  bool _applyingN01 = false;
  Map<String, Object?>? _n01Settings;

  GateController get gate => widget.gate;

  @override
  void initState() {
    super.initState();
    _transport = gate.transport;
    _endpoint = TextEditingController(text: gate.endpoint);
    _name = TextEditingController(text: gate.gateName);
    _power = gate.power;
    _outside = gate.outsideSensor;
    _inside = gate.insideSensor;
    _volume = gate.alarmVolume;
    _lightGpo = gate.lightGpo;
    _rearm = gate.bookRearmSeconds;
    _buzzer = gate.buzzerEnabled;
    _buzzerGpo = gate.buzzerGpo;
    _buzzerSeconds = gate.buzzerSeconds;
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) showMessage(context, done);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _saveReader() async {
    setState(() {
      _testing = true;
      _n01Settings = null;
    });
    try {
      await gate.configureReader(
        nextTransport: _transport,
        nextEndpoint: _endpoint.text,
        nextPower: _power,
      );
      _endpoint.text = gate.endpoint;
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _loadN01Settings() async {
    if (!gate.readerConnected || gate.simulation) return;
    setState(() => _loadingN01 = true);
    try {
      final settings = await gate.readN01Settings();
      if (mounted) {
        setState(() => _n01Settings = settings);
        showMessage(context, 'Paramètres N01 relus.');
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loadingN01 = false);
    }
  }

  Future<void> _applyN01Settings(Map<String, Object?> settings) async {
    if (!gate.readerConnected || gate.simulation) return;
    setState(() => _applyingN01 = true);
    try {
      final result = await gate.applyN01Settings(settings);
      final applied = result['applied'];
      if (mounted) {
        setState(() => _n01Settings = result);
        final requested = [
          for (final entry in settings.entries)
            if (entry.value is Map)
              ...(entry.value as Map).keys.map((key) => key.toString())
            else
              entry.key == 'antennas' ? 'antennaPowers' : entry.key,
        ];
        final refused = requested
            .where((key) => applied is! List || !applied.contains(key))
            .toList();
        showMessage(
          context,
          refused.isNotEmpty
              ? 'Le portail a refusé ${refused.length} réglage(s).'
              : 'Modifications N01 appliquées.',
          error: refused.isNotEmpty,
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _applyingN01 = false);
    }
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

  DropdownButtonFormField<int> _outputField(
    String label,
    int value,
    ValueChanged<int> onChanged, {
    bool allowNone = false,
  }) => DropdownButtonFormField<int>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      if (allowNone) const DropdownMenuItem(value: 0, child: Text('Aucun')),
      for (var gpo = 1; gpo <= 4; gpo++)
        DropdownMenuItem(value: gpo, child: Text('Sortie GPO $gpo')),
    ],
    onChanged: (next) => onChanged(next ?? 0),
  );

  DropdownButtonFormField<int> _sensorField(
    String label,
    int value,
    ValueChanged<int> onChanged,
  ) => DropdownButtonFormField<int>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      const DropdownMenuItem(value: 0, child: Text('Aucune')),
      for (var gpi = 1; gpi <= 4; gpi++)
        DropdownMenuItem(value: gpi, child: Text('GPI $gpi')),
    ],
    onChanged: (next) => onChanged(next ?? 0),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: gate,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final small = Theme.of(context).textTheme.bodySmall;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('Portail antivol N01'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        gate.readerConnected
                            ? Icons.sensors
                            : Icons.sensors_off,
                        color: gate.readerConnected
                            ? colors.primary
                            : colors.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          gate.readerError ??
                              (gate.readerConnected
                                  ? gate.readerInfo ?? 'Portail connecté'
                                  : 'Portail non connecté'),
                        ),
                      ),
                    ],
                  ),
                  if (gate.readerConnected && gate.buzzerSilenced == false) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Le portail n’a pas accepté la coupure de son buzzer : '
                      'désactivez-le dans l’outil du fabricant.',
                      style: small?.copyWith(color: colors.error),
                    ),
                  ],
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
                            ? 'Adresse IP (port ${GateReaderService.tcpPort} imposé par le SDK)'
                            : 'Port série (115 200 bauds)',
                        hintText: _transport == 'tcp'
                            ? '192.168.0.101'
                            : 'dev/ttyS5',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Puissance'),
                      Expanded(
                        child: Slider(
                          min: GateReaderService.minPower.toDouble(),
                          max: GateReaderService.maxPower.toDouble(),
                          divisions:
                              GateReaderService.maxPower -
                              GateReaderService.minPower,
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
                    'Réglez la puissance pour couvrir le passage sans lire les '
                    'livres rangés près du portail.',
                    style: small,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _testing || _loadingN01 || _applyingN01
                        ? null
                        : _saveReader,
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
          _heading('Paramètres matériels N01'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune, color: colors.primary),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'SDK N01',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Relire',
                        onPressed:
                            gate.readerConnected &&
                                !gate.simulation &&
                                !_loadingN01 &&
                                !_applyingN01
                            ? _loadN01Settings
                            : null,
                        icon: _loadingN01
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_n01Settings case final settings?)
                    N01SettingsForm(
                      settings: settings,
                      busy: _applyingN01 || _loadingN01,
                      onApply: gate.readerConnected && !gate.simulation
                          ? _applyN01Settings
                          : null,
                    )
                  else
                    OutlinedButton.icon(
                      onPressed:
                          gate.readerConnected &&
                              !gate.simulation &&
                              !_loadingN01
                          ? _loadN01Settings
                          : null,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Charger les paramètres N01'),
                    ),
                ],
              ),
            ),
          ),
          _heading('Barrières infrarouges (entrées / sorties)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _sensorField(
                          'Barrière côté extérieur',
                          _outside,
                          (value) => setState(() => _outside = value),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Inverser le sens',
                        onPressed: () => setState(() {
                          final swap = _outside;
                          _outside = _inside;
                          _inside = swap;
                        }),
                        icon: const Icon(Icons.swap_horiz),
                      ),
                      Expanded(
                        child: _sensorField(
                          'Barrière côté intérieur',
                          _inside,
                          (value) => setState(() => _inside = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var gpi = 1; gpi <= 4; gpi++)
                        Chip(
                          avatar: Icon(
                            gate.tracker.isActive(gpi)
                                ? Icons.do_not_step
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: gate.tracker.isActive(gpi)
                                ? colors.error
                                : colors.onSurfaceVariant,
                          ),
                          label: Text(
                            'GPI $gpi : '
                            '${switch (gate.tracker.levels[gpi]) {
                              null => '—',
                              final level => gate.tracker.isActive(gpi) ? 'coupée ($level)' : 'libre ($level)',
                            }}',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Une personne qui coupe la barrière extérieure puis '
                    'l’intérieure entre ; l’inverse, elle sort. Passez devant '
                    'le portail, portail ouvert, pour vérifier l’état des '
                    'barrières ci-dessus, puis utilisez « Inverser » si les '
                    'entrées sont comptées comme des sorties. « Aucune » '
                    'désactive le comptage : les passages du personnel sont '
                    'alors alternés (premier passage du jour = entrée).'
                    '${gate.sensorReport == false ? ' Attention : le portail a refusé la remontée des barrières.' : ''}',
                    style: small,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _run(
                      () => gate.configureSensors(
                        nextOutside: _outside,
                        nextInside: _inside,
                      ),
                      'Barrières enregistrées.',
                    ),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer les barrières'),
                  ),
                ],
              ),
            ),
          ),
          _heading('Alarme antivol'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _name,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: 'Nom du portail',
                      hintText: 'Entrée principale',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.volume_up_outlined),
                      Expanded(
                        child: Slider(
                          min: 0.1,
                          max: 1,
                          divisions: 9,
                          value: _volume,
                          label: '${(_volume * 100).round()} %',
                          onChanged: (value) => setState(() => _volume = value),
                        ),
                      ),
                      Text('${(_volume * 100).round()} %'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _outputField(
                    'Voyant du portail pendant l’alarme',
                    _lightGpo,
                    (value) => setState(() => _lightGpo = value),
                    allowNone: true,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Réarmement d’un même livre (secondes)'),
                      ),
                      IconButton(
                        onPressed: _rearm > 5
                            ? () => setState(() => _rearm -= 5)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '$_rearm',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _rearm < 600
                            ? () => setState(() => _rearm += 5)
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  Text(
                    'Un livre non emprunté déclenche le message vocal « Attention ! '
                    'Ne sortez pas avec un livre non emprunté… » sur fond de '
                    'sirène, joué par la tablette (volume « alarme »), et allume '
                    'le voyant choisi (GPO1 = voyant rouge d’après le manuel). '
                    'Un livre resté près du portail ne redéclenche l’alarme '
                    'qu’après ce délai d’absence.',
                    style: small,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _run(gate.testAlarm, 'Alarme jouée.'),
                          icon: const Icon(Icons.campaign_outlined),
                          label: const Text('Tester l’alarme'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _run(
                            () => gate.configureAlarm(
                              nextVolume: _volume,
                              nextLightGpo: _lightGpo,
                              nextRearmSeconds: _rearm,
                              nextGateName: _name.text,
                            ),
                            'Réglages de l’alarme enregistrés.',
                          ),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Enregistrer'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _heading('Buzzer du portail'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _buzzer,
                    onChanged: (value) => setState(() => _buzzer = value),
                    title: const Text(
                      'Faire sonner le buzzer pendant l’alarme',
                    ),
                    subtitle: Text(
                      _buzzer
                          ? 'Le buzzer bipe en plus du message vocal.'
                          : 'Désactivé : seuls le message vocal de la tablette '
                                'et le voyant signalent l’alarme.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  _outputField(
                    'Sortie du buzzer',
                    _buzzerGpo,
                    (value) => setState(() => _buzzerGpo = value),
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('Durée du bip (secondes)')),
                      IconButton(
                        onPressed: _buzzerSeconds > 1
                            ? () => setState(() => _buzzerSeconds--)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '$_buzzerSeconds',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _buzzerSeconds < 10
                            ? () => setState(() => _buzzerSeconds++)
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  if (!_buzzer && _buzzerGpo == _lightGpo)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Le voyant est sur la même sortie que le buzzer : il '
                        'ne sera pas allumé, pour que le buzzer reste muet.',
                        style: small?.copyWith(color: colors.error),
                      ),
                    ),
                  Text(
                    'Si le buzzer sonne quand l’alarme allume le voyant, il est '
                    'câblé sur la sortie du voyant : utilisez « Tester le '
                    'buzzer » pour trouver sa sortie et indiquez-la ici. '
                    'Désactivé, sa sortie n’est jamais actionnée par '
                    'l’application et le portail ne la déclenche plus de '
                    'lui-même à la lecture d’un tag.',
                    style: small,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: gate.readerConnected && !gate.simulation
                              ? () => _run(() async {
                                  if (!await gate.testBuzzer(gpo: _buzzerGpo)) {
                                    throw StateError(
                                      'Le portail a refusé la sortie GPO '
                                      '$_buzzerGpo.',
                                    );
                                  }
                                }, 'Sortie GPO $_buzzerGpo activée.')
                              : null,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Tester le buzzer'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _run(
                            () => gate.configureBuzzer(
                              nextEnabled: _buzzer,
                              nextGpo: _buzzerGpo,
                              nextSeconds: _buzzerSeconds,
                            ),
                            'Réglages du buzzer enregistrés.',
                          ),
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Enregistrer'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
