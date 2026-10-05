import 'package:flutter/material.dart';

import '../app.dart';
import '../core/cote.dart';
import '../services/cataloguing_preferences.dart';

class CataloguingSettingsCard extends StatefulWidget {
  const CataloguingSettingsCard({super.key});

  @override
  State<CataloguingSettingsCard> createState() =>
      _CataloguingSettingsCardState();
}

class _CataloguingSettingsCardState extends State<CataloguingSettingsCard> {
  final _form = GlobalKey<FormState>();
  final _prefixes = <String, TextEditingController>{};
  final _width = TextEditingController();
  final _height = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await CataloguingPreferences.load();
    if (!mounted) return;
    for (final entry in {
      ...defaultGenrePrefixes,
      ...settings.prefixes,
    }.entries) {
      _prefixes[entry.key] = TextEditingController(text: entry.value);
    }
    _width.text = settings.labelWidthMm.toString();
    _height.text = settings.labelHeightMm.toString();
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final field in [..._prefixes.values, _width, _height]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await CataloguingPreferences(
        prefixes: {
          for (final entry in _prefixes.entries)
            entry.key: entry.value.text.trim().toUpperCase(),
        },
        labelWidthMm: double.parse(_width.text.replaceAll(',', '.')),
        labelHeightMm: double.parse(_height.text.replaceAll(',', '.')),
      ).save();
      if (mounted) showMessage(context, 'Réglages de catalogage enregistrés.');
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _dimension(String? value) {
    final number = double.tryParse((value ?? '').replaceAll(',', '.'));
    return number == null || !number.isFinite || number < 20 || number > 200
        ? 'Entre 20 et 200 mm.'
        : null;
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: _loading
          ? const LinearProgressIndicator()
          : Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Catalogage et étiquettes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text('Préfixes de cote par genre'),
                  for (final entry in _prefixes.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: TextFormField(
                        controller: entry.value,
                        decoration: InputDecoration(labelText: entry.key),
                        maxLength: 12,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Renseignez un préfixe.'
                            : null,
                      ),
                    ),
                  const Text('Étiquette : largeur × hauteur en millimètres'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _width,
                          decoration: const InputDecoration(
                            labelText: 'Largeur (mm)',
                          ),
                          keyboardType: TextInputType.number,
                          validator: _dimension,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _height,
                          decoration: const InputDecoration(
                            labelText: 'Hauteur (mm)',
                          ),
                          keyboardType: TextInputType.number,
                          validator: _dimension,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer les réglages'),
                  ),
                ],
              ),
            ),
    ),
  );
}
