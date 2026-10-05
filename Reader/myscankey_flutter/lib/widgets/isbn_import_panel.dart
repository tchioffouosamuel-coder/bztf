import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../app.dart';
import '../services/isbn_csv_import.dart';
import '../services/library_controller.dart';

class IsbnImportPanel extends StatefulWidget {
  const IsbnImportPanel({super.key, required this.controller});
  final LibraryController controller;
  @override
  State<IsbnImportPanel> createState() => _IsbnImportPanelState();
}

class _IsbnImportPanelState extends State<IsbnImportPanel> {
  late final _import = IsbnCsvImport(widget.controller.database);
  bool _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _import.loadLatest();
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _import.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (file == null || !mounted) return;
      await _import.createJob(await file.readAsBytes(), file.name);
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _run({bool retry = false}) async {
    try {
      if (retry) await _import.retryErrors();
      await _import.run();
      await widget.controller.catalogImported();
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _export() async {
    try {
      final file = File(
        path.join(await getDatabasesPath(), 'rapport-retroconversion.csv'),
      );
      await file.writeAsBytes(_import.reportCsvBytes(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Rapport de rétroconversion',
        ),
      );
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _import,
    builder: (context, _) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Rétroconversion : un ISBN dans la première colonne. En-tête facultatif ; les autres colonnes sont ignorées.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Les notices seront des brouillons à vérifier, au statut « À encoder ». Le traitement peut être repris après interruption.',
                ),
                if (_error != null) Text(_error!),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _import.running ? null : _choose,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Choisir le CSV'),
                    ),
                    if (_import.jobId != null) ...[
                      if (_import.running)
                        FilledButton.tonal(
                          onPressed: _import.cancel,
                          child: const Text('Annuler le traitement'),
                        )
                      else if (_import.count('pending') > 0)
                        FilledButton(
                          onPressed: () => unawaited(_run()),
                          child: const Text('Traiter / reprendre'),
                        ),
                      if (!_import.running && _import.count('error') > 0)
                        TextButton(
                          onPressed: () => unawaited(_run(retry: true)),
                          child: const Text('Réessayer les erreurs réseau'),
                        ),
                      TextButton.icon(
                        onPressed: _export,
                        icon: const Icon(Icons.download),
                        label: const Text('Exporter le rapport CSV'),
                      ),
                    ],
                  ],
                ),
                if (_import.jobId != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${_import.filename} · ${_import.completed}/${_import.rows.length} lignes traitées',
                  ),
                  LinearProgressIndicator(
                    value: _import.rows.isEmpty
                        ? 0
                        : _import.completed / _import.rows.length,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Trouvés : ${_import.count('found')} · Non trouvés : ${_import.count('not_found')} · Doublons ignorés : ${_import.count('duplicate')} · Erreurs : ${_import.count('error')}',
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _import.rows.length,
              itemBuilder: (context, index) {
                final row = _import.rows[index];
                return ListTile(
                  title: Text('Ligne ${row.number} · ${row.rawIsbn}'),
                  subtitle: Text('${row.label}\n${row.detail}'),
                  isThreeLine: true,
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
