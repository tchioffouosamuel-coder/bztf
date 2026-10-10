import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/n01_settings.dart';

class N01SettingsForm extends StatefulWidget {
  const N01SettingsForm({
    required this.settings,
    required this.onApply,
    this.busy = false,
    super.key,
  });

  final Map<String, Object?> settings;
  final Future<void> Function(Map<String, Object?>)? onApply;
  final bool busy;

  @override
  State<N01SettingsForm> createState() => _N01SettingsFormState();
}

class _N01SettingsFormState extends State<N01SettingsForm> {
  final _form = GlobalKey<FormState>();
  final _controllers = {
    for (final section in _sections.keys) section: ExpansibleController(),
  };
  late N01SettingsDraft _draft;
  int _revision = 0;
  bool _showPassword = false;

  bool get _enabled => widget.onApply != null && !widget.busy;

  @override
  void initState() {
    super.initState();
    _draft = N01SettingsDraft(widget.settings);
  }

  @override
  void didUpdateWidget(N01SettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      _draft = N01SettingsDraft(widget.settings);
      _revision++;
    }
  }

  void _update(List<Object> path, Object? value) =>
      setState(() => _draft.set(path, value));

  void _apply() {
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isEmpty) {
      widget.onApply?.call(_draft.patch);
    } else {
      for (final controller in _controllers.values) {
        controller.expand();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && invalid.first.mounted) {
          Scrollable.ensureVisible(invalid.first.context);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in _sections.entries)
          if (_draft.values.containsKey(section.key))
            ExpansionTile(
              key: PageStorageKey('n01-${section.key}'),
              controller: _controllers[section.key],
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              initiallyExpanded: section.key == 'rfid',
              maintainState: true,
              title: Text(section.value),
              children: [
                _fields(_draft.values[section.key], [section.key]),
              ],
            ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _enabled && _draft.patch.isNotEmpty ? _apply : null,
                icon: widget.busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Appliquer les modifications N01'),
              ),
            ),
            IconButton(
              tooltip: 'Annuler les modifications',
              onPressed: _enabled && _draft.patch.isNotEmpty
                  ? () => setState(() {
                      _draft = N01SettingsDraft(widget.settings);
                      _revision++;
                    })
                  : null,
              icon: const Icon(Icons.undo),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _fields(Object? value, List<Object> path) {
    final name = path.map((part) => part is int ? '*' : part).join('.');
    if (name == 'rfid.invAntennas' && value is List) {
      return _inventoryAntennas(path, value);
    }
    if (value is Map) {
      final fields = _grid([
        for (final entry in value.entries)
          _fields(entry.value, [...path, entry.key.toString()]),
      ]);
      return path.length > 1 && path.first != 'antennas'
          ? _group(_label(name), fields)
          : fields;
    }
    if (value is List) {
      final specs = _arraySpecs[name];
      final offset =
          (name == 'network.ethConfig' || name == 'network.wifiDhcp') &&
              value.length == 3
          ? 1
          : 0;
      final children = <Widget>[
        for (var i = 0; i < value.length; i++)
          if (specs != null)
            _field(
              [...path, i],
              value[i],
              i + offset < specs.length
                  ? specs[i + offset]
                  : _Spec('Valeur ${i + 1}', readOnly: true),
            )
          else if (name == 'antennas')
            _group(
              'Antenne ${(value[i] as Map)['ant']}',
              _fields(value[i], [...path, i]),
            )
          else
            _field(
              [...path, i],
              value[i],
              _Spec('Fréquence ${i + 1} (kHz)', min: 1),
            ),
      ];
      if (name == 'rfid.hopTable') {
        return _group(
          _label(name),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: children[i],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Supprimer la fréquence',
                      onPressed: _enabled && value.length > 1
                          ? () => setState(() {
                              value.removeAt(i);
                              _revision++;
                            })
                          : null,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _enabled
                      ? () => _update(path, [
                          ...value,
                          value.isEmpty ? 915750 : value.last,
                        ])
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Ajouter une fréquence'),
                ),
              ),
            ],
          ),
        );
      }
      return _group(_label(name), _grid(children));
    }
    return _field(
      path,
      value,
      _specs[name] ?? _Spec(_label(name), readOnly: true),
    );
  }

  Widget _group(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      child,
    ],
  );

  Widget _grid(List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final child in children)
          SizedBox(
            width: constraints.maxWidth >= 700
                ? (constraints.maxWidth - 16) / 2
                : constraints.maxWidth,
            child: child,
          ),
      ],
    ),
  );

  Widget _inventoryAntennas(List<Object> path, List value) {
    final antennas = _draft.values['antennas'];
    final available = <int>{
      if (antennas is List)
        for (final antenna in antennas)
          if (antenna is Map && antenna['ant'] is int) antenna['ant'] as int,
      for (final ant in value)
        if (ant is int) ant,
    }.toList()..sort();
    return _group(
      _label('rfid.invAntennas'),
      FormField<List>(
        key: ValueKey('n01-$_revision-inventory-antennas'),
        initialValue: value,
        validator: (_) => _draft.changed('rfid', 'invAntennas') && value.isEmpty
            ? 'Sélectionnez au moins une antenne.'
            : null,
        builder: (state) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              children: [
                for (final ant in available)
                  SizedBox(
                    width: 130,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('ANT $ant'),
                      value: value.contains(ant),
                      onChanged: _enabled
                          ? (checked) {
                              final next = List<Object?>.from(value);
                              if (checked == true) {
                                next.add(ant);
                              } else {
                                next.remove(ant);
                              }
                              next.sort(
                                (a, b) => (a as int).compareTo(b as int),
                              );
                              _update(path, next);
                            }
                          : null,
                    ),
                  ),
              ],
            ),
            if (state.hasError)
              Text(
                state.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(List<Object> path, Object? value, _Spec spec) {
    final key = ValueKey('n01-$_revision-${path.join('.')}');
    final editable =
        _enabled &&
        !spec.readOnly &&
        (value != null || path.last == 'syncinterv');
    final decoration = InputDecoration(
      labelText: spec.label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      suffixIcon: spec.readOnly
          ? const Tooltip(
              message: 'Lecture seule',
              child: Icon(Icons.lock_outline, size: 18),
            )
          : null,
    );
    if (spec.toggle && value != null) {
      return SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        title: Text(spec.label),
        value: value == true || value == 1,
        onChanged: editable
            ? (next) => _update(path, value is bool ? next : (next ? 1 : 0))
            : null,
      );
    }
    if (spec.options != null && value != null) {
      final options = {...spec.options!};
      if (!options.containsKey(value)) {
        options[value] = 'Valeur actuelle : $value';
      }
      return DropdownButtonFormField<Object>(
        key: key,
        initialValue: value,
        isExpanded: true,
        decoration: decoration,
        items: [
          for (final option in options.entries)
            DropdownMenuItem(value: option.key, child: Text(option.value)),
        ],
        onChanged: editable ? (next) => _update(path, next) : null,
      );
    }
    final isNumber = spec.min != null || value is num;
    return TextFormField(
      key: key,
      initialValue: value?.toString() ?? '',
      enabled: editable || spec.readOnly,
      readOnly: spec.readOnly || !editable,
      autocorrect: false,
      enableSuggestions: false,
      obscureText: spec.secret && !_showPassword,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(signed: true)
          : spec.url
          ? TextInputType.url
          : TextInputType.text,
      inputFormatters: isNumber
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))]
          : null,
      decoration: decoration.copyWith(
        hintText: value == null ? 'Non disponible' : null,
        suffixIcon: spec.secret
            ? IconButton(
                tooltip: _showPassword
                    ? 'Masquer le mot de passe'
                    : 'Afficher le mot de passe',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
              )
            : decoration.suffixIcon,
      ),
      onChanged: editable
          ? (text) =>
                _update(path, isNumber ? int.tryParse(text) ?? text : text)
          : null,
      validator: (text) {
        if (!editable) return null;
        final changed = path.first == 'antennas'
            ? _draft.patch.containsKey('antennas')
            : _draft.changed(path.first as String, path[1] as String);
        if (!changed) return null;
        if (isNumber) {
          final number = int.tryParse(text ?? '');
          if (number == null) return 'Entrez un nombre entier.';
          if (spec.min != null && number < spec.min!) {
            return 'Minimum : ${spec.min}';
          }
          if (spec.max != null && number > spec.max!) {
            return 'Maximum : ${spec.max}';
          }
        }
        if (spec.ip && !_validIp(text ?? '')) return 'Adresse IPv4 invalide.';
        if (spec.hex &&
            !RegExp(r'^(?:[0-9A-Fa-f]{2})*$').hasMatch(text ?? '')) {
          return 'Entrez des paires hexadécimales.';
        }
        if (path.join('.') == 'identity.readerId' &&
            (text ?? '').trim().isEmpty) {
          return 'Indiquez l’identifiant du lecteur.';
        }
        if (spec.url && (text ?? '').isNotEmpty) {
          final uri = Uri.tryParse(text!);
          if (uri == null ||
              !['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty) {
            return 'Adresse HTTP ou HTTPS invalide.';
          }
        }
        if (path.length == 3 && path[0] == 'network' && path[1] == 'time') {
          final parts = _draft.at(['network', 'time']) as List;
          if (parts.every((part) => part is int) && parts.length == 6) {
            if (parts[0] < 2000 ||
                parts[0] > 9999 ||
                parts[1] < 1 ||
                parts[1] > 12) {
              return 'Date invalide.';
            }
            final date = DateTime(parts[0], parts[1], parts[2]);
            if (date.year != parts[0] ||
                date.month != parts[1] ||
                date.day != parts[2]) {
              return 'Date invalide.';
            }
          }
        }
        return null;
      },
    );
  }

  bool _validIp(String text) {
    final parts = text.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          final number = int.tryParse(part);
          return RegExp(r'^\d{1,3}$').hasMatch(part) &&
              number != null &&
              number <= 255;
        });
  }
}

const _sections = {
  'identity': 'Identification',
  'rfid': 'RFID / Gen2',
  'antennas': 'Antennes',
  'io': 'Entrées / sorties GPI et GPO',
  'network': 'Réseau et horloge',
  'reporting': 'Rapports et inventaire automatique',
};

class _Spec {
  const _Spec(
    this.label, {
    this.min,
    this.max,
    this.options,
    this.toggle = false,
    this.readOnly = false,
    this.secret = false,
    this.ip = false,
    this.hex = false,
    this.url = false,
  });

  final String label;
  final int? min;
  final int? max;
  final Map<Object, String>? options;
  final bool toggle;
  final bool readOnly;
  final bool secret;
  final bool ip;
  final bool hex;
  final bool url;
}

const _banks = {0: 'Reserved', 1: 'EPC', 2: 'TID', 3: 'User'};
const _gpi = {0: 'Aucune', 1: 'GPI 1', 2: 'GPI 2', 3: 'GPI 3', 4: 'GPI 4'};
const _gpo = {
  0: 'Aucune',
  1: 'GPO 1',
  2: 'GPO 2',
  3: 'GPO 1 + 2',
  4: 'GPO 3',
  5: 'GPO 1 + 3',
  6: 'GPO 2 + 3',
  7: 'GPO 1 + 2 + 3',
};
const _triggers = {
  'NONE': 'NONE',
  'GPI1': 'GPI1',
  'GPI2': 'GPI2',
  'GPI3': 'GPI3',
  'GPI12HIGH': 'GPI12HIGH',
  'GPI12LOW': 'GPI12LOW',
  'OTHER': 'OTHER',
};

const _specs = <String, _Spec>{
  'identity.readerId': _Spec('Identifiant du lecteur (Reader ID)'),
  'rfid.region': _Spec(
    'Région / bande de fréquence',
    options: {
      'NA': 'NA - Amérique du Nord',
      'CN': 'CN - Chine',
      'EUR': 'EUR - Europe',
      'KOR': 'KOR - Corée',
      'ALL': 'ALL - Toutes les bandes',
    },
  ),
  'rfid.session': _Spec(
    'Session Gen2',
    options: {0: 'S0', 1: 'S1', 2: 'S2', 3: 'S3'},
  ),
  'rfid.qValue': _Spec('Valeur Q (Gen2 Q)', min: 0, max: 16),
  'rfid.target': _Spec(
    'Cible Gen2 (Target)',
    options: {'A': 'A', 'B': 'B', 'A-B': 'A-B', 'B-A': 'B-A'},
  ),
  'rfid.gen2RfMode': _Spec(
    'Mode RF Gen2',
    options: {
      0: 'FM0',
      1: 'M2',
      2: 'M4',
      3: 'M8',
      101: 'RF_MODE_1',
      103: 'RF_MODE_3',
      105: 'RF_MODE_5',
      107: 'RF_MODE_7',
      111: 'RF_MODE_11',
      112: 'RF_MODE_12',
      113: 'RF_MODE_13',
      115: 'RF_MODE_15',
      203: 'RF_MODE_103',
      220: 'RF_MODE_120',
      45: 'RF_MODE_345',
    },
  ),
  'rfid.rfidLevel': _Spec(
    'Type de module RFID',
    options: {0: 'Multiport', 1: 'Monoport'},
  ),
  'rfid.uniByAnt': _Spec('Unicité par antenne (UniByAnt)', toggle: true),
  'rfid.uniByBank': _Spec('Unicité par banque (UniByBank)', toggle: true),
  'rfid.maxRssi': _Spec('RSSI maximal (Max RSSI)', toggle: true),
  'antennas.*.ant': _Spec('Numéro d’antenne', readOnly: true),
  'antennas.*.read': _Spec('Puissance de lecture (dBm)', min: 5, max: 33),
  'antennas.*.write': _Spec('Puissance d’écriture (dBm)', min: 5, max: 33),
  'io.gpiLevels.1': _Spec('Niveau GPI 1', readOnly: true),
  'io.gpiLevels.2': _Spec('Niveau GPI 2', readOnly: true),
  'io.gpiLevels.3': _Spec('Niveau GPI 3', readOnly: true),
  'io.gpiLevels.4': _Spec('Niveau GPI 4', readOnly: true),
  'network.localTcpPort': _Spec('Port TCP local', min: 1, max: 65535),
  'network.ethMac': _Spec('Adresse MAC Ethernet', readOnly: true),
  'network.wifiMac': _Spec('Adresse MAC Wi-Fi', readOnly: true),
  'network.httpUrl': _Spec('URL HTTP', url: true),
  'network.otaUrl': _Spec('URL de mise à jour OTA', readOnly: true),
  'network.timezone': _Spec('Fuseau horaire (Timezone)'),
  'network.time': _Spec('Heure du lecteur', readOnly: true),
  'reporting.autoInvCfg.stopdelay': _Spec('Délai d’arrêt (stopdelay)', min: 0),
  'reporting.autoInvCfg.syncinterv': _Spec(
    'Intervalle d’inventaire (ms)',
    min: 1,
  ),
  'reporting.autoInvCfg.synctimeout': _Spec('Durée d’inventaire (ms)', min: 0),
  'reporting.autoInvCfg.trigpo': _Spec('GPO au déclenchement', options: _gpo),
  'reporting.autoInvCfg.epc0gpo': _Spec(
    'GPO sans tag (epc0gpo)',
    options: _gpo,
  ),
  'reporting.autoInvCfg.epc1gpo': _Spec(
    'GPO avec tag (epc1gpo)',
    options: _gpo,
  ),
  'reporting.autoInvCfg.legalgpo': _Spec(
    'GPO tag autorisé (legalgpo)',
    options: _gpo,
  ),
  'reporting.autoInvCfg.illegalgpo': _Spec(
    'GPO tag interdit (illegalgpo)',
    options: _gpo,
  ),
  'reporting.autoInvCfg.errgpo': _Spec('GPO erreur (errgpo)', options: _gpo),
  'reporting.autoInvCfg.gpodur': _Spec('Durée GPO (s)', min: 0),
  'reporting.autoInvCfg.ingpi': _Spec('GPI d’entrée (ingpi)', options: _gpi),
  'reporting.autoInvCfg.outgpi': _Spec('GPI de sortie (outgpi)', options: _gpi),
  'reporting.autoInvCfg.tagFilter.bank': _Spec(
    'Banque du filtre (Bank)',
    options: {1: 'EPC', 2: 'TID', 3: 'User'},
  ),
  'reporting.autoInvCfg.tagFilter.startBit': _Spec(
    'Bit de départ (start_bit)',
    min: 0,
  ),
  'reporting.autoInvCfg.tagFilter.mask': _Spec(
    'Masque du filtre (Mask)',
    hex: true,
  ),
  'reporting.autoInvCfg.tagFilter.match': _Spec(
    'Correspondance du filtre (Match)',
    toggle: true,
  ),
  'reporting.autoInvCfg.bankData.bank': _Spec(
    'Banque à lire (Bank)',
    options: _banks,
  ),
  'reporting.autoInvCfg.bankData.startWord': _Spec(
    'Mot de départ (start_word)',
    min: 0,
  ),
  'reporting.autoInvCfg.bankData.wordCount': _Spec(
    'Nombre de mots (word_count)',
    min: 1,
  ),
  'reporting.autoInvCfg.bankData.password': _Spec(
    'Mot de passe d’accès',
    hex: true,
    secret: true,
  ),
};

const _arraySpecs = <String, List<_Spec>>{
  'identity.hardwareVersion': [
    _Spec('Version matérielle (HW)', readOnly: true),
    _Spec('Version logicielle (SW)', readOnly: true),
    _Spec('Version RFID', readOnly: true),
  ],
  'identity.license': [
    _Spec('Licence', readOnly: true),
    _Spec('Clé du lecteur', readOnly: true, secret: true),
  ],
  'io.exGet': [
    _Spec('Identifiant dans les rapports', toggle: true),
    _Spec(
      'Rapport GPI (gpistatus)',
      options: {
        0: 'Désactivé',
        1: 'Auto-inventaire',
        2: 'TCP actuel',
        3: 'RS232',
      },
    ),
    _Spec('Heartbeat (s)', min: 0),
    _Spec('Horodatage (posttime)', toggle: true),
    _Spec('Rapport GPO (gpostatus)', toggle: true),
  ],
  'io.tagInfoEx': [
    _Spec('EPC en ASCII (vascii)', toggle: true),
    _Spec('Inclure le TID', toggle: true),
    _Spec('Unicité antenne (uniantid)', toggle: true),
  ],
  'io.tagGpo': [
    _Spec('Sorties GPO à la lecture', options: _gpo),
    _Spec('Niveau GPO', options: {0: 'Bas (0)', 1: 'Haut (1)'}),
    _Spec('Durée GPO (s)', min: 0),
    _Spec('Octet de départ du filtre', min: 0),
    _Spec('Masque EPC', hex: true),
    _Spec('Correspondance du filtre', toggle: true),
  ],
  'io.indicatorGpo': [
    _Spec('GPO initialisation', options: _gpo),
    _Spec('GPO connexion Ethernet', options: _gpo),
    _Spec('GPO connexion Wi-Fi', options: _gpo),
    _Spec('GPO initialisation RFID', options: _gpo),
    _Spec('Durée des voyants (s)', min: 0),
    _Spec('GPO au redémarrage', options: {-1: 'Conserver l’état', ..._gpo}),
  ],
  'network.ethConfig': [
    _Spec(
      'DHCP Ethernet',
      readOnly: true,
      options: {'0': 'IP statique', '1': 'DHCP'},
    ),
    _Spec('Adresse IP Ethernet', ip: true),
    _Spec('Masque réseau Ethernet', ip: true),
    _Spec('Passerelle Ethernet', ip: true),
  ],
  'network.wifiDhcp': [
    _Spec(
      'DHCP Wi-Fi',
      readOnly: true,
      options: {'0': 'IP statique', '1': 'DHCP'},
    ),
    _Spec('Adresse IP Wi-Fi', ip: true),
    _Spec('Masque réseau Wi-Fi', ip: true),
    _Spec('Passerelle Wi-Fi', ip: true),
  ],
  'network.wifiSsidPassw': [
    _Spec('Nom du réseau Wi-Fi (SSID)'),
    _Spec('Mot de passe Wi-Fi', secret: true),
  ],
  'network.time': [
    _Spec('Année', min: 2000, max: 9999),
    _Spec('Mois', min: 1, max: 12),
    _Spec('Jour', min: 1, max: 31),
    _Spec('Heure', min: 0, max: 23),
    _Spec('Minute', min: 0, max: 59),
    _Spec('Seconde', min: 0, max: 59),
  ],
  'reporting.reportCfg': [
    _Spec('Route réseau (router)', options: {0: 'WIFI_ETH', 1: '4G'}),
    _Spec('Période de rapport (s)', min: 0),
    _Spec('Heure de lecture (rptime)', toggle: true),
    _Spec('EPC par rapport (rpmaxnum)', min: 1, max: 100),
    _Spec('Cache des doublons (s)', min: 0),
    _Spec(
      'Format des rapports',
      options: {0: 'Par défaut', 1: 'Personnalisé 1', 2: 'Personnalisé 2'},
    ),
  ],
  'reporting.autoInv': [
    _Spec(
      'Mode d’auto-inventaire',
      readOnly: true,
      options: {
        'NONE': 'NONE',
        'TCP_FAST': 'TCP_FAST',
        'RS232_FAST': 'RS232_FAST',
        'MQTT_DB': 'MQTT_DB',
        'MQTT_SG': 'MQTT_SG',
        'HTTP': 'HTTP',
        'HTTP_DB': 'HTTP_DB',
        'HTTP_SG': 'HTTP_SG',
      },
    ),
    _Spec('Durée d’inventaire (s)', readOnly: true),
    _Spec('Déclenchement 1', readOnly: true, options: _triggers),
    _Spec('Arrêt 1', readOnly: true, options: _triggers),
    _Spec('Déclenchement 2', readOnly: true, options: _triggers),
    _Spec('Arrêt 2', readOnly: true, options: _triggers),
  ],
};

String _label(String name) =>
    const {
      'identity.hardwareVersion': 'Versions du lecteur',
      'identity.license': 'Licence',
      'rfid.hopTable': 'Table de saut de fréquence (Hop Table)',
      'rfid.invAntennas': 'Antennes d’inventaire (Inventory Antenna)',
      'io.exGet': 'Extension des rapports (Report Extension)',
      'io.tagInfoEx': 'Informations des tags (Tag Info Ex)',
      'io.tagGpo': 'GPO à la lecture d’un tag (Tag GPO)',
      'io.indicatorGpo': 'Voyants GPO (Indicator GPO)',
      'network.ethConfig': 'Configuration Ethernet',
      'network.wifiDhcp': 'Configuration IP Wi-Fi',
      'network.wifiSsidPassw': 'Connexion Wi-Fi',
      'network.time': 'Horloge du lecteur',
      'reporting.reportCfg': 'Configuration des rapports (Report Config)',
      'reporting.autoInv': 'Inventaire automatique (Auto Inventory)',
      'reporting.autoInvCfg': 'Réglages d’inventaire automatique',
      'io.gpiLevels': 'Niveaux des entrées GPI',
      'reporting.autoInvCfg.tagFilter': 'Filtre des tags (Tag Filter)',
      'reporting.autoInvCfg.bankData': 'Lecture mémoire (Bank Data)',
    }[name] ??
    name.split('.').last;
