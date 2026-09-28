import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/library_database.dart';
import '../models/book.dart';
import 'locator_signal.dart';
import 'reader_service.dart';
import 'sync_service.dart';

class LibraryController extends ChangeNotifier {
  LibraryController({LibraryDatabase? database, ReaderService? reader})
    : database = database ?? LibraryDatabase.instance,
      reader = reader ?? ReaderService() {
    sync = SyncService(this.database);
    sync.addListener(_onSyncChanged);
    _tagSubscription = this.reader.tags.listen(_onTag, onError: _onReaderError);
    _nativeKeySubscription = this.reader.nativeRfidKeyEvents.listen(
      _handleNativeRfidKey,
      onError: _onReaderError,
    );
  }

  final LibraryDatabase database;
  final ReaderService reader;
  late final SyncService sync;
  final Map<String, ReaderTag> _observed = {};
  final Map<String, ReaderTag> _stationSessionTags = {};
  final Map<String, Book?> _recognized = {};
  final Map<String, Timer> _releaseTimers = {};
  final Map<String, DateTime> _lastTagRecognitionAt = {};
  final Map<String, InventoryRecord> _inventoryRecords = {};
  final List<String> _viewHistory = ['dashboard'];
  late final StreamSubscription<ReaderTag> _tagSubscription;
  late final StreamSubscription<String> _nativeKeySubscription;
  bool _navigatingBack = false;
  bool _nativeRfidKeyHeld = false;
  bool _startingNativeRead = false;
  Timer? _locatorLossTimer;
  final LocatorSignalTracker locatorSignal = LocatorSignalTracker();

  String view = 'dashboard';
  String statusFilter = 'tous';
  String search = '';
  String transport = 'serial';
  String endpoint = 'dev/ttyS5';
  bool darkTheme = false;
  int readPower = 15;
  int writePower = 25;
  int inventoryPower = 20;
  bool busy = false;
  String? readerError;
  Book? pendingBook;
  String? pendingAction;
  Book? locatorBook;
  ReaderTag? locatorTag;
  bool locatorSignalLive = false;
  Map<String, int> counts = {'total': 0, 'tagged': 0, 'pending': 0, 'today': 0};
  List<Book> books = [];
  List<Book> recentBooks = [];
  List<ActivityEntry> activities = [];
  int totalBooks = 0;
  int offset = 0;

  bool get readerConnected => reader.connected;
  bool get reading => reader.reading;
  bool get canNavigateBack => _viewHistory.length > 1;
  bool get syncConfigured => sync.configured;
  List<ReaderTag> get observedTags => view == 'station'
      ? _stationSessionTags.values.toList()
      : _observed.values.toList();
  List<InventoryRecord> get inventoryRecords {
    final records = _inventoryRecords.values.toList();
    records.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return records;
  }

  List<InventoryRecord> get referencedInventoryRecords =>
      inventoryRecords.where((record) => record.book != null).toList();

  int get inventoryRecognizedCount =>
      _inventoryRecords.values.where((record) => record.book != null).length;
  int get inventoryUnknownCount =>
      _inventoryRecords.length - inventoryRecognizedCount;
  Book? recognizedBook(ReaderTag tag) => _recognized[_key(tag)];

  Future<void> initialize() async {
    reader.listenForNativeRfidKeys();
    final settings = await SharedPreferences.getInstance();
    transport = settings.getString('reader_transport') ?? 'serial';
    endpoint = settings.getString('reader_endpoint') ?? 'dev/ttyS5';
    if (transport == 'serial' && endpoint == '/dev/ttyS5') {
      endpoint = 'dev/ttyS5';
      await settings.setString('reader_endpoint', endpoint);
    }
    darkTheme = settings.getBool('dark_theme') ?? false;
    readPower = settings.getInt('rfid_read_power') ?? 15;
    writePower = settings.getInt('rfid_write_power') ?? 25;
    inventoryPower = settings.getInt('rfid_inventory_power') ?? 20;
    await sync.initialize();
    await Future.wait([refreshDashboard(), loadBooks(), loadActivity()]);
  }

  Future<void> refreshDashboard() async {
    counts = await database.dashboardCounts();
    recentBooks = await database.recentBooks();
    activities = await database.activity(limit: 8);
    notifyListeners();
  }

  Future<void> loadActivity() async {
    activities = await database.activity();
    notifyListeners();
  }

  Future<void> loadBooks({bool reset = true}) async {
    final pageOffset = reset ? 0 : offset;
    final page = await database.listBooks(
      search: search,
      status: statusFilter,
      limit: 200,
      offset: pageOffset,
    );
    books = reset ? page : [...books, ...page];
    offset = pageOffset + page.length;
    totalBooks = await database.countBooks(
      search: search,
      status: statusFilter,
    );
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    unawaited(loadBooks());
  }

  void setStatusFilter(String value) {
    statusFilter = value;
    unawaited(loadBooks());
  }

  Future<void> setView(String value) async {
    if (value == view) return;
    final addedToHistory = _viewHistory.last != value;
    if (addedToHistory) _viewHistory.add(value);
    try {
      await _activateView(value);
    } catch (_) {
      if (addedToHistory && _viewHistory.last == value) {
        _viewHistory.removeLast();
      }
      rethrow;
    }
  }

  Future<bool> navigateBack() async {
    if (!canNavigateBack || _navigatingBack) return false;
    _navigatingBack = true;
    final current = _viewHistory.removeLast();
    try {
      await _activateView(_viewHistory.last);
      return true;
    } catch (_) {
      _viewHistory.add(current);
      rethrow;
    } finally {
      _navigatingBack = false;
    }
  }

  Future<void> _activateView(String value) async {
    if (view != value && reader.reading) {
      await reader.stopInventory();
    }
    view = value;
    if ((value == 'station' || value == 'locator') &&
        reader.connected &&
        !reader.reading &&
        transport != 'serial') {
      await startInventory();
    }
    if (value == 'dashboard') await refreshDashboard();
    if (value == 'catalogue') await loadBooks();
    if (value == 'history') await loadActivity();
    notifyListeners();
  }

  void _handleNativeRfidKey(String action) {
    if (action == 'down') {
      if (_nativeRfidKeyHeld) return;
      _nativeRfidKeyHeld = true;
      unawaited(_startNativeRead());
      return;
    }
    if (action == 'up') {
      _nativeRfidKeyHeld = false;
      unawaited(_stopNativeRead());
    }
  }

  Future<void> _startNativeRead() async {
    if (_startingNativeRead) return;
    _startingNativeRead = true;
    try {
      if (!reader.connected) {
        await connectReader(nextTransport: 'serial', nextEndpoint: '');
      }
      if (!_nativeRfidKeyHeld) return;
      if (view != 'station' && view != 'inventory' && view != 'locator') {
        await setView('station');
      }
      if (_nativeRfidKeyHeld && !reader.reading) {
        await startInventory(fromHardwareTrigger: true);
      }
    } catch (error) {
      readerError = error.toString();
      notifyListeners();
    } finally {
      _startingNativeRead = false;
      if (!_nativeRfidKeyHeld && reader.reading && transport == 'serial') {
        await _stopNativeRead();
      }
    }
  }

  Future<void> _stopNativeRead() async {
    if (transport != 'serial' || !reader.reading) return;
    try {
      await stopInventory();
    } catch (error) {
      readerError = error.toString();
      notifyListeners();
    }
  }

  Future<void> toggleTheme() async {
    darkTheme = !darkTheme;
    final settings = await SharedPreferences.getInstance();
    await settings.setBool('dark_theme', darkTheme);
    notifyListeners();
  }

  Future<void> connectReader({
    String? nextTransport,
    String? nextEndpoint,
  }) async {
    busy = true;
    readerError = null;
    notifyListeners();
    try {
      transport = nextTransport ?? transport;
      endpoint = nextEndpoint ?? endpoint;
      final settings = await SharedPreferences.getInstance();
      await settings.setString('reader_transport', transport);
      await settings.setString('reader_endpoint', endpoint);
      await reader.connect(transport: transport, endpoint: endpoint);
      await reader.configurePower(readPower: readPower, writePower: writePower);
      await database.addActivity(
        'connexion',
        'succes',
        'Lecteur connecté en ${transport.toUpperCase()}',
      );
      if ((view == 'station' || view == 'locator') && transport != 'serial') {
        await startInventory();
      }
    } catch (error) {
      readerError = error.toString();
      await database.addActivity('connexion', 'echec', readerError!);
      rethrow;
    } finally {
      busy = false;
      await refreshDashboard();
      notifyListeners();
    }
  }

  Future<void> disconnectReader() async {
    await reader.disconnect();
    await database.addActivity('connexion', 'succes', 'Lecteur déconnecté');
    await refreshDashboard();
    notifyListeners();
  }

  Future<void> startInventory({bool fromHardwareTrigger = false}) async {
    if (view == 'inventory' && !fromHardwareTrigger) {
      throw StateError(
        'L’inventaire RFID démarre uniquement avec la gâchette du lecteur.',
      );
    }
    readerError = null;
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    _releaseTimers.clear();
    _observed.clear();
    _recognized.clear();
    _lastTagRecognitionAt.clear();
    if (view == 'station') {
      _stationSessionTags.clear();
    }
    if (view == 'locator') {
      _locatorLossTimer?.cancel();
      locatorTag = null;
      locatorSignalLive = false;
      locatorSignal.reset();
    }
    try {
      await reader.startInventory(
        power: view == 'inventory' ? inventoryPower : readPower,
        targetEpc: view == 'locator' ? locatorBook?.epc : null,
      );
    } catch (error) {
      readerError = error.toString();
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  void selectForEncoding(Book book) {
    pendingBook = book;
    pendingAction = 'encode';
    notifyListeners();
  }

  void selectForErasure(Book book) {
    pendingBook = book;
    pendingAction = 'erase';
    notifyListeners();
  }

  void clearPendingOperation() {
    pendingBook = null;
    pendingAction = null;
    notifyListeners();
  }

  Future<void> stopInventory() async {
    await reader.stopInventory();
    if (view == 'station' && transport == 'serial') {
      await _resolveStationTids();
    }
    if (view == 'locator') {
      _locatorLossTimer?.cancel();
      locatorSignalLive = false;
    }
    notifyListeners();
  }

  Future<void> locateBook(Book book) async {
    if (book.status != 'encode' || book.tid == null || book.tid!.isEmpty) {
      throw StateError('Ce livre ne possède pas encore de tag RFID encodé.');
    }
    final restartSearch = view == 'locator' && reader.reading;
    locatorBook = book;
    locatorTag = null;
    locatorSignalLive = false;
    locatorSignal.reset();
    _locatorLossTimer?.cancel();
    if (view == 'locator') {
      if (restartSearch) {
        await reader.stopInventory();
        await startInventory();
      }
      notifyListeners();
      return;
    }
    await setView('locator');
  }

  Future<void> _resolveStationTids() async {
    final pending = _stationSessionTags.entries
        .where((entry) => entry.value.tid.isEmpty)
        .toList();
    for (final entry in pending) {
      await _resolveStationTag(entry.key, entry.value);
    }
  }

  Future<bool> refreshStationTid(ReaderTag tag) async {
    if (reader.reading) return false;
    final resolved = await _resolveStationTag(_stationKey(tag), tag);
    notifyListeners();
    return resolved;
  }

  Future<bool> _resolveStationTag(String stationKey, ReaderTag tag) async {
    final current = _stationSessionTags[stationKey];
    if (current == null) return false;
    if (current.tid.isNotEmpty) return true;
    final tid = await reader.resolveTid(current.epc);
    if (tid.isEmpty) return false;
    final resolved = ReaderTag(
      epc: current.epc,
      tid: tid,
      rssi: current.rssi,
      antenna: current.antenna,
      count: current.count,
    );
    _stationSessionTags[stationKey] = resolved;
    _recognized[_key(resolved)] = await database.recognizeTag(
      resolved.epc,
      resolved.tid,
    );
    return true;
  }

  Future<void> configureReaderPowers({
    required int nextReadPower,
    required int nextWritePower,
    required int nextInventoryPower,
  }) async {
    for (final value in [nextReadPower, nextWritePower, nextInventoryPower]) {
      if (value < ReaderService.minPower || value > ReaderService.maxPower) {
        throw RangeError.range(
          value,
          ReaderService.minPower,
          ReaderService.maxPower,
          'puissance',
        );
      }
    }
    final wasReading = reader.reading;
    if (wasReading) await reader.stopInventory();
    readPower = nextReadPower;
    writePower = nextWritePower;
    inventoryPower = nextInventoryPower;
    final settings = await SharedPreferences.getInstance();
    await Future.wait([
      settings.setInt('rfid_read_power', readPower),
      settings.setInt('rfid_write_power', writePower),
      settings.setInt('rfid_inventory_power', inventoryPower),
    ]);
    if (reader.connected) {
      await reader.configurePower(
        readPower: view == 'inventory' ? inventoryPower : readPower,
        writePower: writePower,
      );
      if (wasReading && (view != 'inventory' || _nativeRfidKeyHeld)) {
        await startInventory(fromHardwareTrigger: view == 'inventory');
      }
    }
    notifyListeners();
  }

  void clearInventorySession() {
    _inventoryRecords.clear();
    notifyListeners();
  }

  Future<Book> createBook(Map<String, Object?> values) async {
    final book = await database.createBook(values);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return book;
  }

  Future<Book> updateBook(int id, Map<String, Object?> values) async {
    final book = await database.updateBook(id, values);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return book;
  }

  Future<void> deleteBook(Book book) async {
    await database.deleteBook(book);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
  }

  Future<Book> createAndEncode(
    Map<String, Object?> values,
    ReaderTag tag,
  ) async {
    final book = await database.createBook(values);
    await loadBooks();
    await encodeBook(book, tag);
    return (await database.getBook(book.id))!;
  }

  Future<void> encodeBook(Book book, ReaderTag tag) async {
    _requireSingleTag(tag, expectedEpc: tag.epc);
    final result = await reader.writeEpc(
      book.epc,
      tag.tid,
      currentEpc: tag.epc,
      writePower: writePower,
      restorePower: readPower,
    );
    if (result['verified'] != true ||
        result['epc'] != book.epc ||
        result['tid'] != tag.tid) {
      throw StateError('L’écriture EPC n’a pas été vérifiée.');
    }
    await database.markTagged(book.id, tag.tid);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
  }

  Future<void> unencodeBook(Book book) async {
    final tags = observedTags;
    if (tags.length != 1) throw StateError('Posez un seul tag sur le lecteur.');
    final tag = tags.single;
    if (tag.tid != book.tid || tag.epc != book.epc) {
      throw StateError('Le tag détecté ne correspond pas à ce livre.');
    }
    final result = await reader.writeEpc(
      ReaderService.emptyEpc,
      tag.tid,
      currentEpc: tag.epc,
      writePower: writePower,
      restorePower: readPower,
    );
    if (result['verified'] != true ||
        result['epc'] != ReaderService.emptyEpc ||
        result['tid'] != book.tid) {
      throw StateError('Le désencodage n’a pas été vérifié par relecture.');
    }
    await database.markUntagged(book.id);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
  }

  Future<void> catalogImported() async {
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
  }

  Future<void> configureSync({
    required String serverUrl,
    required String apiKey,
    required String deviceName,
  }) async {
    await sync.configure(
      nextServerUrl: serverUrl,
      nextApiKey: apiKey,
      nextDeviceName: deviceName,
    );
    await _reloadAfterMutation();
  }

  void _onSyncChanged() {
    notifyListeners();
    if (sync.connected && !sync.syncing) {
      unawaited(loadBooks());
      unawaited(refreshDashboard());
    }
  }

  void _requireSingleTag(ReaderTag target, {required String expectedEpc}) {
    final tags = observedTags;
    if (tags.length != 1) throw StateError('Posez un seul tag sur le lecteur.');
    if (tags.single.tid != target.tid ||
        tags.single.epc != expectedEpc ||
        target.tid.isEmpty) {
      throw StateError(
        'Le tag détecté a changé. Relancez une lecture avant l’écriture.',
      );
    }
  }

  Future<void> _onTag(ReaderTag tag) async {
    if (view == 'locator') {
      _onLocatorTag(tag);
      return;
    }
    final key = _key(tag);
    if (key.isEmpty) return;
    final startsNewDetection = _observed.isEmpty;
    _observed[key] = tag;
    if (view == 'station') {
      _stationSessionTags[_stationKey(tag)] = tag;
    }
    final now = DateTime.now();
    if (view == 'inventory') {
      _recordInventoryObservation(key, tag, now);
    }
    _releaseTimers.remove(key)?.cancel();
    _releaseTimers[key] = Timer(const Duration(milliseconds: 1500), () {
      _observed.remove(key);
      _lastTagRecognitionAt.remove(key);
      _releaseTimers.remove(key);
      notifyListeners();
    });
    final lastRecognizedAt = _lastTagRecognitionAt[key];
    if (lastRecognizedAt != null &&
        now.difference(lastRecognizedAt) < const Duration(milliseconds: 400)) {
      notifyListeners();
      return;
    }
    _lastTagRecognitionAt[key] = now;
    if (startsNewDetection) {
      unawaited(_playScanBeep());
    }
    try {
      _recognized[key] = await database.recognizeTag(tag.epc, tag.tid);
      if (view == 'inventory') {
        _setInventoryBook(key, tag, _recognized[key]);
      }
      await refreshDashboard();
      if (view == 'catalogue' && _recognized[key] != null) await loadBooks();
    } catch (error) {
      readerError = error.toString();
    }
    notifyListeners();
  }

  void _onLocatorTag(ReaderTag tag) {
    final target = locatorBook;
    if (target == null ||
        tag.epc.trim().toUpperCase() != target.epc.trim().toUpperCase()) {
      return;
    }
    final targetTid = target.tid;
    if (tag.tid.isNotEmpty &&
        targetTid != null &&
        targetTid.isNotEmpty &&
        tag.tid.trim().toUpperCase() != targetTid.trim().toUpperCase()) {
      return;
    }
    final firstDetection = locatorTag == null;
    locatorSignal.add(tag.rssi);
    locatorTag = ReaderTag(
      epc: tag.epc,
      tid: tag.tid,
      rssi: locatorSignal.rssi ?? tag.rssi,
      antenna: tag.antenna,
      count: tag.count,
    );
    locatorSignalLive = true;
    _locatorLossTimer?.cancel();
    _locatorLossTimer = Timer(const Duration(milliseconds: 900), () {
      locatorSignalLive = false;
      notifyListeners();
    });
    if (firstDetection) unawaited(_playScanBeep());
    notifyListeners();
  }

  void _recordInventoryObservation(String key, ReaderTag tag, DateTime seenAt) {
    if (tag.epc == ReaderService.emptyEpc && tag.tid.isEmpty) return;
    final inventoryKey = _inventoryKey(key, tag);
    final existing = _inventoryRecords[inventoryKey];
    if (existing == null) {
      _inventoryRecords[inventoryKey] = InventoryRecord(
        tag: tag,
        book: null,
        firstSeen: seenAt,
        lastSeen: seenAt,
        readCount: 1,
      );
      return;
    }
    _inventoryRecords[inventoryKey] = existing.copyWith(
      tag: tag,
      lastSeen: seenAt,
      readCount: existing.readCount + 1,
    );
  }

  void _setInventoryBook(String key, ReaderTag tag, Book? book) {
    final inventoryKey = _inventoryKey(key, tag);
    final existing = _inventoryRecords[inventoryKey];
    if (existing == null) return;
    if (existing.tag.epc != tag.epc ||
        (existing.tag.tid.isNotEmpty && existing.tag.tid != tag.tid)) {
      return;
    }
    _inventoryRecords[inventoryKey] = existing.copyWith(
      book: book,
      preserveBook: false,
    );
  }

  static String _inventoryKey(String fallback, ReaderTag tag) =>
      tag.epc.isNotEmpty && tag.epc != ReaderService.emptyEpc
      ? 'epc:${tag.epc}'
      : 'tid:${tag.tid.isNotEmpty ? tag.tid : fallback}';

  Future<void> _playScanBeep() async {
    try {
      await reader.playScanBeep();
    } catch (error) {
      debugPrint('Bip de lecture indisponible : $error');
    }
  }

  void _onReaderError(Object error) {
    readerError = error.toString();
    notifyListeners();
  }

  Future<void> _reloadAfterMutation() async {
    await Future.wait([refreshDashboard(), loadBooks(), loadActivity()]);
  }

  static String _key(ReaderTag tag) => tag.tid.isNotEmpty ? tag.tid : tag.epc;

  static String _stationKey(ReaderTag tag) =>
      tag.epc.isNotEmpty && tag.epc != ReaderService.emptyEpc
      ? tag.epc
      : (tag.tid.isNotEmpty ? tag.tid : tag.epc);

  @override
  void dispose() {
    _locatorLossTimer?.cancel();
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    unawaited(_tagSubscription.cancel());
    unawaited(_nativeKeySubscription.cancel());
    sync.removeListener(_onSyncChanged);
    sync.dispose();
    unawaited(reader.dispose());
    super.dispose();
  }
}
