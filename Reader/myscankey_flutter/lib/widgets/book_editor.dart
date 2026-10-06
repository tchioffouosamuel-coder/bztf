import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/cote.dart';
import '../core/isbn.dart';
import '../models/book.dart';
import '../services/barcode_scanner_service.dart';
import '../services/cataloguing_preferences.dart';
import '../services/cote_label.dart';
import '../services/library_controller.dart';
import '../services/notice/notice_lookup_service.dart';
import '../services/notice/notice_source.dart';
import 'book_details.dart';
import 'status_pill.dart';

/// Le catalogue enregistre ici ; la station conserve son chaînage existant
/// et reçoit simplement les valeurs validées via [show].
class BookEditor extends StatefulWidget {
  const BookEditor({
    super.key,
    this.book,
    this.controller,
    this.lookupService,
    this.preferences,
    this.manageSaving = false,
  });

  final Book? book;
  final LibraryController? controller;
  final NoticeLookupService? lookupService;
  final CataloguingPreferences? preferences;
  final bool manageSaving;

  static Future<Map<String, Object?>?> show(
    BuildContext context, {
    Book? book,
    LibraryController? controller,
    bool manageSaving = false,
  }) => Navigator.of(context).push<Map<String, Object?>>(
    MaterialPageRoute(
      builder: (_) => BookEditor(
        book: book,
        controller: controller,
        manageSaving: manageSaving,
      ),
    ),
  );

  @override
  State<BookEditor> createState() => _BookEditorState();
}

enum _Step { isbn, lookup, choice, description }

class _BookEditorState extends State<BookEditor> {
  final _form = GlobalKey<FormState>();
  final _isbnForm = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _isbnFocus = FocusNode();
  final _scanner = BarcodeScannerService();
  StreamSubscription<Map<Object?, Object?>>? _scanSubscription;
  Future<void> _scannerOperations = Future.value();
  int _scanGeneration = 0;
  bool _scannerActive = false;
  bool _scannerReady = false;
  String? _scannerError;
  late final NoticeLookupService _lookup;
  late final Map<String, TextEditingController> _fields;
  CataloguingPreferences _preferences = const CataloguingPreferences();
  _Step _step = _Step.isbn;
  List<NoticeResult> _results = [];
  int _lookupGeneration = 0;
  bool _busy = false;
  bool _manualCote = false;
  bool _printLabel = false;
  String _suggestedCote = '';
  String? _information;
  String? _saveError;
  Book? _savedBook;

  static const _labels = <String, String>{
    'title': 'Titre *',
    'author': 'Auteur *',
    'isbn': 'ISBN',
    'publisher': 'Éditeur *',
    'publication_year': 'Date de publication *',
    'document_type': 'Type de document *',
    'category': 'Genre',
    'subtitle': 'Sous-titre',
    'collection': 'Collection',
    'collection_number': 'Numéro dans la collection',
    'language': 'Langue',
    'original_language': 'Langue originale',
    'summary': 'Résumé',
    'subjects': 'Sujets',
    'dewey': 'Indice Dewey',
    'edition': 'Édition',
    'page_count': 'Pagination',
    'source_identifier': 'Identifiant de la notice',
    'retrieved_at': 'Date de récupération',
    'source_notice': 'Source de la notice',
    'location': 'Localisation',
    'item_status': 'Statut de l’exemplaire',
    'shelf': 'Cote',
    'notes': 'Notes',
  };
  static const _required = {
    'title',
    'author',
    'publisher',
    'publication_year',
    'document_type',
  };
  static const _details = [
    'subtitle',
    'collection',
    'collection_number',
    'language',
    'original_language',
    'summary',
    'subjects',
    'dewey',
    'edition',
    'page_count',
    'source_identifier',
    'retrieved_at',
  ];

  @override
  void initState() {
    super.initState();
    _lookup =
        widget.lookupService ??
        NoticeLookupService(database: widget.controller?.database);
    final values = widget.book?.toMap() ?? <String, Object?>{};
    _fields = {
      for (final key in _labels.keys)
        key: TextEditingController(text: values[key]?.toString() ?? ''),
    };
    if (_fields['source_notice']!.text.isEmpty) {
      _fields['source_notice']!.text = 'manuelle';
    }
    if (_fields['item_status']!.text.isEmpty) {
      _fields['item_status']!.text = 'Disponible';
    }
    if (widget.book != null) {
      _step = _Step.description;
      _manualCote = true;
    }
    for (final key in ['author', 'document_type', 'category', 'dewey']) {
      _fields[key]!.addListener(_proposeCote);
    }
    _fields['source_notice']!.addListener(_refresh);
    widget.controller?.addListener(_refresh);
    if (widget.preferences case final preferences?) {
      _preferences = preferences;
    } else {
      _loadPreferences();
    }
    _syncScanner();
  }

  bool get _usesNativeScanner =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _setStep(_Step step) {
    _step = step;
    _syncScanner();
  }

  void _syncScanner() {
    final active = _usesNativeScanner && _step == _Step.isbn;
    if (active == _scannerActive) return;
    _scannerActive = active;
    _scannerReady = false;
    final generation = ++_scanGeneration;
    widget.controller?.setBarcodeScannerActive(active);
    if (!active) {
      unawaited(_scanSubscription?.cancel());
      _scanSubscription = null;
      _scannerOperations = _scannerOperations
          .then((_) => _scanner.close())
          .catchError((Object error) => debugPrint('Scanner ISBN : $error'));
      return;
    }
    _scannerError = null;
    _scanSubscription = _scanner.events.listen(
      _onBarcode,
      onError: (Object error) => _onScannerError(error, generation),
    );
    // Serialize open/close when returning quickly from a notice search.
    _scannerOperations = _scannerOperations
        .then<void>((_) async {
          if (!mounted || !_scannerActive || generation != _scanGeneration) {
            return;
          }
          if (widget.controller?.reader.reading == true) {
            await widget.controller!.stopInventory();
          }
          if (!mounted || !_scannerActive || generation != _scanGeneration) {
            return;
          }
          await _scanner.open();
          if (mounted && _scannerActive && generation == _scanGeneration) {
            setState(() => _scannerReady = true);
          }
        })
        .catchError((Object error) => _onScannerError(error, generation));
  }

  void _onScannerError(Object error, int generation) {
    if (!mounted || !_scannerActive || generation != _scanGeneration) return;
    setState(() {
      _scannerReady = false;
      _scannerError = error is PlatformException
          ? error.message ?? 'Scanner optique indisponible.'
          : 'Scanner optique indisponible.';
    });
  }

  void _onBarcode(Map<Object?, Object?> event) {
    if (!mounted ||
        !_scannerActive ||
        _step != _Step.isbn ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final barcode = event['barcode']?.toString();
    if (barcode == null) return;
    final isbn = Isbn.normalize(barcode);
    if (!Isbn.isValid(isbn) ||
        (isbn.length == 13 &&
            !isbn.startsWith('978') &&
            !isbn.startsWith('979'))) {
      setState(() => _scannerError = 'Le code lu n’est pas un ISBN valide.');
      return;
    }
    _scannerError = null;
    _fields['isbn']!.text = Isbn.toIsbn13(isbn);
    unawaited(_scanner.playScanBeep());
    unawaited(_search(fromScanner: true));
  }

  Future<void> _loadPreferences() async {
    final preferences = await CataloguingPreferences.load();
    if (mounted) {
      _preferences = preferences;
      _proposeCote();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _lookupGeneration++;
    if (_scannerActive) {
      _setStep(_Step.description);
    }
    widget.controller?.removeListener(_refresh);
    for (final field in _fields.values) {
      field.dispose();
    }
    _scroll.dispose();
    _isbnFocus.dispose();
    super.dispose();
  }

  String _text(String key) => _fields[key]!.text.trim();

  void _proposeCote() {
    if (!mounted) return;
    _suggestedCote = generateCote(
      author: _text('author'),
      documentType: _text('document_type'),
      dewey: _text('dewey'),
      genre: _text('category').isEmpty ? 'Roman' : _text('category'),
      prefixes: _preferences.prefixes,
    );
    if (!_manualCote && _text('author').isNotEmpty) {
      _fields['shelf']!.text = _suggestedCote;
    }
    setState(() {});
  }

  void _description({String? information}) {
    setState(() {
      _setStep(_Step.description);
      _information = information;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _search({bool fromScanner = false}) async {
    if (_step != _Step.isbn) return;
    if (!fromScanner && _isbnForm.currentState?.validate() != true) return;
    _clearBibliography();
    final generation = ++_lookupGeneration;
    _fields['isbn']!.text = Isbn.toIsbn13(_text('isbn'));
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _setStep(_Step.lookup);
      _information = null;
    });
    try {
      final results = await _lookup.lookup(
        _text('isbn'),
        isCancelled: () => !mounted || generation != _lookupGeneration,
      );
      if (!mounted || generation != _lookupGeneration) return;
      if (results.isEmpty) {
        _description(
          information: 'Vous pouvez renseigner la description du livre.',
        );
      } else if (results.length == 1 && !results.single.dejaAuCatalogue) {
        _applyNotice(results.single);
      } else {
        setState(() {
          _results = results;
          _setStep(_Step.choice);
        });
      }
    } on NoticeLookupCancelledException {
      // La requête en cours finit au timeout de la source ; l’annulation
      // empêche les replis suivants et toute modification du formulaire.
    } catch (_) {
      if (mounted && generation == _lookupGeneration) {
        _description(
          information:
              'La saisie manuelle est disponible. Complétez la description du livre.',
        );
      }
    }
  }

  void _cancelSearch() {
    _lookupGeneration++;
    setState(() => _setStep(_Step.isbn));
    _isbnFocus.requestFocus();
  }

  void _clearBibliography() {
    _manualCote = false;
    for (final entry in _fields.entries) {
      if (!const ['isbn', 'document_type', 'location'].contains(entry.key)) {
        entry.value.clear();
      }
    }
    _fields['source_notice']!.text = 'manuelle';
    _fields['item_status']!.text = 'Disponible';
  }

  void _manualDescription() {
    _clearBibliography();
    _description();
  }

  void _applyValues(Map<String, Object?> values) {
    for (final entry in values.entries) {
      if (_fields.containsKey(entry.key)) {
        _fields[entry.key]!.text = entry.value?.toString() ?? '';
      }
    }
    if (_text('source_notice').isEmpty) {
      _fields['source_notice']!.text = 'manuelle';
    }
    _proposeCote();
    _description();
  }

  void _applyNotice(NoticeResult notice) => _applyValues(notice.toBookFields());

  void _additionalCopy(Book book) {
    final values = book.toMap();
    for (final key in ['location', 'item_status', 'shelf']) {
      values.remove(key);
    }
    _applyValues(values);
  }

  Future<void> _scanIsbn() async {
    if (!_scannerReady) return;
    final generation = _scanGeneration;
    try {
      await _scanner.startScan();
    } catch (error) {
      _onScannerError(error, generation);
    }
  }

  Map<String, Object?> _values() => {
    'catalog_draft': 0,
    for (final entry in _fields.entries) entry.key: entry.value.text.trim(),
  };

  Future<void> _save({bool encodeNext = false}) async {
    if (_busy) return;
    if (!_form.currentState!.validate()) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (!widget.manageSaving) {
      Navigator.pop(context, _values());
      return;
    }
    final controller = widget.controller!;
    setState(() {
      _busy = true;
      _saveError = null;
    });
    try {
      if (encodeNext) {
        final tag = await _tagForEncoding(controller);
        if (_savedBook == null) {
          _savedBook = await controller.createAndEncode(
            _values(),
            tag,
            onCreated: (book) => _savedBook = book,
          );
        } else {
          final updated = await controller.updateBook(
            _savedBook!.id,
            _values(),
          );
          await controller.encodeBook(updated, tag);
          _savedBook = await controller.database.getBook(updated.id);
        }
      } else {
        final id = _savedBook?.id ?? widget.book?.id;
        _savedBook = id == null
            ? await controller.createBook(_values())
            : await controller.updateBook(id, _values());
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _saveError = _savedBook == null
              ? error.toString()
              : 'Livre enregistré (${_savedBook!.accession}). L’encodage peut être réessayé. $error',
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (_printLabel) {
      setState(() => _busy = true);
      try {
        await previewCoteLabel(
          context,
          _savedBook!,
          controller: widget.controller,
        );
      } catch (error) {
        if (mounted) {
          showMessage(
            context,
            'Livre enregistré. Étiquette indisponible : $error',
            error: true,
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    if (encodeNext) {
      final accession = _savedBook!.accession;
      _reset();
      showMessage(context, 'Livre $accession enregistré et encodé.');
    } else {
      Navigator.pop(context, _values());
    }
  }

  Future<ReaderTag> _tagForEncoding(LibraryController controller) async {
    final tag = await controller.captureEncodingTag();
    final card = await controller.database.recognizeCard(tag.epc, tag.tid);
    if (card != null) {
      throw StateError(
        'Utilisez un tag de livre. Ce tag est une carte d’abonné.',
      );
    }
    final book = await controller.database.recognizeTag(tag.epc, tag.tid);
    if (book != null && book.id != _savedBook?.id) {
      throw StateError(
        'Ce tag est déjà associé à ${book.accession}. Utilisez un tag libre.',
      );
    }
    return tag;
  }

  void _reset() {
    final repeated = {
      for (final key in ['location', 'document_type']) key: _text(key),
    };
    _manualCote = false;
    for (final entry in _fields.entries) {
      entry.value.text = repeated[entry.key] ?? '';
    }
    _fields['source_notice']!.text = 'manuelle';
    _fields['item_status']!.text = 'Disponible';
    setState(() {
      _savedBook = null;
      _saveError = null;
      _results = [];
      _information = null;
      _setStep(_Step.isbn);
    });
    _isbnFocus.requestFocus();
  }

  Widget _field(String key) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('field_$key'),
      controller: _fields[key],
      minLines: 1,
      maxLines: ['summary', 'subjects', 'notes'].contains(key) ? 4 : 1,
      decoration: InputDecoration(
        labelText: _labels[key],
        suffixIcon: key == 'author'
            ? TextButton(
                onPressed: () => _fields['author']!.text = 'Anonyme',
                child: const Text('Anonyme'),
              )
            : key == 'document_type' ||
                  key == 'category' ||
                  key == 'item_status'
            ? PopupMenuButton<String>(
                tooltip: 'Choisir',
                onSelected: (value) => _fields[key]!.text = value,
                itemBuilder: (_) => [
                  for (final value
                      in key == 'document_type'
                          ? ['Fiction', 'Documentaire', 'Périodique', 'Autre']
                          : key == 'category'
                          ? _preferences.prefixes.keys
                          : [
                              'Disponible',
                              'Consultation sur place',
                              'En réparation',
                              'Retiré',
                            ])
                    PopupMenuItem(value: value, child: Text(value)),
                ],
              )
            : null,
      ),
      onChanged: key == 'shelf' ? (_) => _manualCote = true : null,
      validator: (value) {
        if (_required.contains(key) &&
            (value == null || value.trim().isEmpty)) {
          return 'Ce champ est obligatoire.';
        }
        if (key == 'isbn' &&
            value != null &&
            value.trim().isNotEmpty &&
            !Isbn.isValid(value)) {
          return 'Vérifiez les chiffres de l’ISBN.';
        }
        return null;
      },
    ),
  );

  Widget _descriptionForm() => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '3 · Vérifier la notice',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text('Vérifiez ces informations avec le livre en main.'),
        const SizedBox(height: 16),
        for (final key in [
          'title',
          'author',
          'publisher',
          'publication_year',
          'document_type',
          'category',
          'isbn',
        ])
          _field(key),
        ExpansionTile(
          title: const Text('Description détaillée'),
          children: [for (final key in _details) _field(key)],
        ),
        const SizedBox(height: 20),
        Text(
          '4 · Compléter l’exemplaire',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        _field('location'),
        _field('item_status'),
        _field('shelf'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              _manualCote = false;
              _fields['shelf']!.text = _suggestedCote;
              setState(() {});
            },
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: Text('Proposition : $_suggestedCote'),
          ),
        ),
        _field('notes'),
        if (widget.book != null || _savedBook != null)
          Text(
            'Identifiant : ${(_savedBook ?? widget.book)!.accession}\nEPC : ${(_savedBook ?? widget.book)!.epc}',
          )
        else
          const Text(
            'L’identifiant et l’EPC seront générés à l’enregistrement.',
          ),
        if (widget.manageSaving)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Prévisualiser l’étiquette après enregistrement'),
            value: _printLabel,
            onChanged: (value) => setState(() => _printLabel = value ?? false),
          ),
      ],
    ),
  );

  Widget _choices() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _results.any((result) => result.dejaAuCatalogue)
            ? 'Déjà au catalogue'
            : 'Choisir l’édition',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      for (final result in _results)
        if (result.dejaAuCatalogue)
          for (final book in result.livresCatalogue)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(book.title),
                    Text(
                      '${book.publisher} · ${book.publicationYear} · ${book.pageCount}',
                    ),
                    Text(book.accession),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (widget.controller != null)
                          TextButton(
                            onPressed: () => BookDetails.show(
                              context,
                              controller: widget.controller!,
                              book: book,
                            ),
                            child: const Text('Ouvrir la fiche'),
                          ),
                        FilledButton.tonal(
                          onPressed: () => _additionalCopy(book),
                          child: const Text('Ajouter un exemplaire'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
        else
          Card(
            child: ListTile(
              title: Text(result.title),
              subtitle: Text(
                [
                  result.editeur,
                  result.datePublication,
                  result.edition,
                  result.nbPages,
                  result.sourceNotice,
                ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _applyNotice(result),
            ),
          ),
      TextButton(
        onPressed: _manualDescription,
        child: const Text('Saisie manuelle'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.book == null ? 'Cataloguer un livre' : 'Modifier le livre',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: StatusPill(
              widget.controller?.readerConnected == true
                  ? 'reader_connected'
                  : 'reader_disconnected',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Source : ${_text('source_notice')}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: AbsorbPointer(
              absorbing: _busy,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_information != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(_information!),
                          ),
                        switch (_step) {
                          _Step.isbn => Form(
                            key: _isbnForm,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '1 · Saisir l’ISBN',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Au clavier ou à la douchette, puis Entrée.',
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  key: const ValueKey('isbn_input'),
                                  controller: _fields['isbn'],
                                  focusNode: _isbnFocus,
                                  autofocus: !_usesNativeScanner,
                                  decoration: const InputDecoration(
                                    labelText: 'ISBN',
                                  ),
                                  onFieldSubmitted: (_) => _search(),
                                  validator: (value) =>
                                      Isbn.isValid(value ?? '')
                                      ? null
                                      : 'Vérifiez les chiffres de l’ISBN, ou choisissez la saisie manuelle.',
                                ),
                                if (_scannerError != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      _scannerError!,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: _search,
                                  icon: const Icon(Icons.search),
                                  label: const Text('Récupérer la notice'),
                                ),
                                if (_usesNativeScanner)
                                  OutlinedButton.icon(
                                    onPressed: _scannerReady ? _scanIsbn : null,
                                    icon: const Icon(Icons.qr_code_scanner),
                                    label: const Text(
                                      'Scanner avec le lecteur',
                                    ),
                                  ),
                                TextButton(
                                  onPressed: _manualDescription,
                                  child: const Text(
                                    'Saisie manuelle / sans ISBN',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _Step.lookup => Column(
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              const Text('2 · Récupération de la notice…'),
                              TextButton(
                                onPressed: _cancelSearch,
                                child: const Text('Annuler la recherche'),
                              ),
                            ],
                          ),
                          _Step.choice => _choices(),
                          _Step.description => _descriptionForm(),
                        },
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_step == _Step.description)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_saveError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _saveError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        if (widget.book == null && _savedBook == null)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _setStep(_Step.isbn)),
                            child: const Text('Retour à l’ISBN'),
                          ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _save(),
                          child: const Text('Enregistrer et fermer'),
                        ),
                        if (widget.manageSaving && widget.book == null)
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _save(encodeNext: true),
                            icon: const Icon(Icons.sensors),
                            label: const Text(
                              'Enregistrer, encoder et cataloguer le suivant',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
