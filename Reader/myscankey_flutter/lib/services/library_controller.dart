import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/library_database.dart';
import '../models/book.dart';
import '../models/lending.dart';
import '../models/user.dart';
import 'desk_reader_service.dart';
import 'gate_controller.dart';
import 'gate_reader_service.dart';
import 'heading_service.dart';
import 'locator_direction.dart';
import 'kiosk_controller.dart';
import 'locator_signal.dart';
import 'reader_service.dart';
import 'log_shipper.dart';
import 'sync_service.dart';

class LibraryController extends ChangeNotifier {
  LibraryController({
    LibraryDatabase? database,
    ReaderService? reader,
    DeskReaderService? deskReader,
    GateReaderService? gateReader,
    HeadingService? heading,
  }) : database = database ?? LibraryDatabase.instance,
       _headingService = heading ?? HeadingService(),
       reader = reader ?? ReaderService() {
    sync = SyncService(this.database);
    logs = LogShipper(sync);
    kiosk = KioskController(this, reader: deskReader);
    gate = GateController(this, reader: gateReader);
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

  /// Logs de l'application envoyés au serveur (débogage à distance).
  late final LogShipper logs;
  late final KioskController kiosk;
  late final GateController gate;
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
  bool _capturingCard = false;

  /// Plusieurs tags remontent chacun plusieurs fois par seconde : l'écran
  /// n'est rafraîchi qu'une fois par intervalle, pas à chaque lecture.
  static const _tagRefreshInterval = Duration(milliseconds: 150);

  /// Un tag présent n'est reconnu de nouveau dans le catalogue qu'après ce
  /// délai (le résultat est gardé en mémoire entre-temps).
  static const _recognitionInterval = Duration(seconds: 3);
  Timer? _tagRefreshTimer;
  Timer? _catalogueRefreshTimer;

  void _notifyTagChange() {
    _tagRefreshTimer ??= Timer(_tagRefreshInterval, () {
      _tagRefreshTimer = null;
      _inventoryCache = null;
      notifyListeners();
    });
  }

  /// Tableau de bord ou catalogue affiché : relu au plus une fois par
  /// seconde pendant une lecture, jamais s'il n'est pas à l'écran.
  void _scheduleCatalogueRefresh({required bool books}) {
    if (view != 'dashboard' && !(books && view == 'catalogue')) return;
    _catalogueRefreshTimer ??= Timer(const Duration(seconds: 1), () {
      _catalogueRefreshTimer = null;
      if (view == 'dashboard') unawaited(refreshDashboard());
      if (view == 'catalogue') unawaited(loadBooks());
    });
  }

  /// Le poste d'emprunt occupe l'écran : la gâchette du terminal est ignorée.
  bool kioskActive = false;
  Timer? _locatorLossTimer;
  final LocatorSignalTracker locatorSignal = LocatorSignalTracker();

  /// Direction du livre recherché d'après la boussole du terminal.
  final LocatorDirection locatorDirection = LocatorDirection();
  final HeadingService _headingService;
  StreamSubscription<double>? _headingSubscription;

  /// Rôle de l'appareil choisi à la première ouverture : `kiosk` (poste
  /// d'emprunt), `mobile` (lecteur mobile) ou `gate` (portail antivol).
  /// `null` tant qu'il n'est pas choisi.
  String? deviceRole;
  bool initialized = false;

  /// L'application ne s'ouvre qu'après identification d'un compte.
  AppUser? currentUser;
  bool hasAccounts = false;
  int _failedSignIns = 0;
  DateTime? _signInLockedUntil;

  String view = 'dashboard';
  String statusFilter = 'tous';
  String catalogueWorkList = 'all';
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

  /// Livres de l'inventaire, les derniers apparus en tête. L'ordre ne
  /// dépend pas des relectures : les lignes ne sautent pas pendant la
  /// lecture. Calculé une fois par rafraîchissement de l'écran.
  List<InventoryRecord> get inventoryRecords =>
      _inventoryCache ??= _inventoryRecords.values.toList()
        ..sort((a, b) => b.firstSeen.compareTo(a.firstSeen));
  List<InventoryRecord>? _inventoryCache;

  List<InventoryRecord> get referencedInventoryRecords =>
      inventoryRecords.where((record) => record.book != null).toList();

  int get inventoryRecognizedCount =>
      _inventoryRecords.values.where((record) => record.book != null).length;
  int get inventoryUnknownCount =>
      _inventoryRecords.length - inventoryRecognizedCount;
  Book? recognizedBook(ReaderTag tag) =>
      (tag.tid.isNotEmpty ? _recognized[tag.tid] : null) ??
      _recognized[tag.epc];

  /// Erreur survenue à l'ouverture (base locale, réglages), affichée à la
  /// place de l'application.
  String? startupError;

  Future<void> initialize() async {
    startupError = null;
    notifyListeners();
    try {
      await _initialize();
    } catch (error, stack) {
      debugPrint('Ouverture impossible : $error $stack');
      startupError = error.toString();
      notifyListeners();
    }
  }

  Future<void> _initialize() async {
    reader.listenForNativeRfidKeys();
    final settings = await SharedPreferences.getInstance();
    transport = settings.getString('reader_transport') ?? 'serial';
    endpoint = settings.getString('reader_endpoint') ?? 'dev/ttyS5';
    if (transport == 'serial' && endpoint == '/dev/ttyS5') {
      endpoint = 'dev/ttyS5';
      await settings.setString('reader_endpoint', endpoint);
    }
    darkTheme = settings.getBool('dark_theme') ?? false;
    deviceRole = switch (settings.getString('device_role')) {
      final role? when deviceRoles.contains(role) => role,
      _ => null,
    };
    readPower = settings.getInt('rfid_read_power') ?? 15;
    writePower = settings.getInt('rfid_write_power') ?? 25;
    inventoryPower = settings.getInt('rfid_inventory_power') ?? 20;
    await sync.initialize();
    logs.start();
    await kiosk.initialize();
    await gate.initialize();
    hasAccounts = await database.countUsers() > 0;
    await Future.wait([refreshDashboard(), loadBooks(), loadActivity()]);
    initialized = true;
    notifyListeners();
  }

  static const deviceRoles = ['kiosk', 'mobile', 'gate'];
  static const _maxFailedSignIns = 5;
  static const _signInLockDuration = Duration(seconds: 30);

  /// Première ouverture : crée le compte administrateur et l'ouvre.
  Future<void> createFirstAdmin({
    required String name,
    required String email,
    required String password,
  }) async {
    if (await database.countUsers() > 0) {
      throw StateError('Un compte administrateur existe déjà.');
    }
    currentUser = await database.createUser(
      name: name,
      email: email,
      password: password,
      role: 'admin',
    );
    hasAccounts = true;
    await database.addActivity(
      'connexion',
      'succes',
      'Connexion de ${currentUser!.name}',
    );
    notifyListeners();
  }

  Future<void> signIn(String email, String password) async {
    final lockedUntil = _signInLockedUntil;
    if (lockedUntil != null && DateTime.now().isBefore(lockedUntil)) {
      final seconds = lockedUntil.difference(DateTime.now()).inSeconds + 1;
      throw StateError('Trop d’essais. Réessayez dans $seconds s.');
    }
    final user = await database.authenticateUser(email, password);
    if (user == null) {
      _failedSignIns++;
      if (_failedSignIns >= _maxFailedSignIns) {
        _failedSignIns = 0;
        _signInLockedUntil = DateTime.now().add(_signInLockDuration);
      }
      await database.addActivity(
        'connexion',
        'echec',
        'Échec de connexion pour ${email.trim().toLowerCase()}',
      );
      throw StateError('E-mail ou mot de passe incorrect.');
    }
    _failedSignIns = 0;
    _signInLockedUntil = null;
    currentUser = user;
    await database.addActivity(
      'connexion',
      'succes',
      'Connexion de ${user.name}',
    );
    notifyListeners();
  }

  Future<void> signOut() async {
    final user = currentUser;
    if (user == null) return;
    if (reader.reading) await reader.stopInventory();
    currentUser = null;
    _viewHistory
      ..clear()
      ..add('dashboard');
    view = 'dashboard';
    await database.addActivity(
      'connexion',
      'succes',
      'Déconnexion de ${user.name}',
    );
    notifyListeners();
  }

  /// Enregistre le rôle de l'appareil ; `null` le fait choisir de nouveau.
  Future<void> setDeviceRole(String? role) async {
    if (role != null && !deviceRoles.contains(role)) {
      throw ArgumentError('Rôle d’appareil inconnu : $role');
    }
    final settings = await SharedPreferences.getInstance();
    if (role == null) {
      await settings.remove('device_role');
    } else {
      await settings.setString('device_role', role);
      await database.addActivity('connexion', 'succes', switch (role) {
        'kiosk' => 'Appareil configuré en poste d’emprunt',
        'gate' => 'Appareil configuré en portail antivol',
        _ => 'Appareil configuré en lecteur mobile',
      });
    }
    deviceRole = role;
    notifyListeners();
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
      workList: catalogueWorkList,
      limit: 200,
      offset: pageOffset,
    );
    books = reset ? page : [...books, ...page];
    offset = pageOffset + page.length;
    totalBooks = await database.countBooks(
      search: search,
      status: statusFilter,
      workList: catalogueWorkList,
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

  void setCatalogueWorkList(String value) {
    catalogueWorkList = value;
    statusFilter = value == 'unencoded' ? 'a_encoder' : 'tous';
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
    _followHeading(value == 'locator');
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

  /// Boussole écoutée seulement pendant la localisation (économie d'énergie).
  void _followHeading(bool enabled) {
    if (!enabled) {
      unawaited(_headingSubscription?.cancel());
      _headingSubscription = null;
      return;
    }
    if (_headingSubscription != null) return;
    // Sans boussole, la recherche continue avec la seule force du signal.
    try {
      _headingSubscription = _headingService.headings.listen(
        (degrees) => locatorDirection.updateHeading(
          degrees,
          signalLive: locatorSignalLive,
        ),
        onError: (Object _) {
          locatorDirection.compassAvailable = false;
          _headingSubscription = null;
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (error) {
      locatorDirection.compassAvailable = false;
      debugPrint('Boussole indisponible : $error');
    }
  }

  void _handleNativeRfidKey(String action) {
    // Pendant la lecture d'une carte d'abonné ou sur le poste d'emprunt, la
    // gâchette ne change pas d'écran.
    if (_capturingCard || kioskActive) return;
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
      locatorDirection.reset();
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
    locatorDirection.reset();
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
    _inventoryCache = null;
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

  Future<Loan> borrowBook(
    Book book, {
    required String memberNumber,
    required String name,
    required DateTime dueAt,
    String email = '',
    String phone = '',
    String notes = '',
  }) async {
    final loan = await database.borrowBook(
      book.id,
      memberNumber: memberNumber,
      name: name,
      dueAt: dueAt,
      email: email,
      phone: phone,
      notes: notes,
    );
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return loan;
  }

  Future<Book> returnBook(Book book) async {
    final returned = await database.returnBook(book.id);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return returned;
  }

  /// Emprunt en libre-service de plusieurs livres (poste d'emprunt).
  Future<List<Loan>> checkoutBooks(
    Subscriber subscriber,
    List<Book> books, {
    required DateTime dueAt,
    required int maxLoans,
  }) async {
    final loans = await database.checkoutBooks(
      subscriber.id,
      [for (final book in books) book.id],
      dueAt: dueAt,
      maxLoans: maxLoans,
    );
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return loans;
  }

  /// Retour en libre-service de plusieurs livres (poste d'emprunt).
  Future<List<Loan>> returnBooks(List<Book> books) async {
    final loans = await database.returnBooks([
      for (final book in books) book.id,
    ]);
    await _reloadAfterMutation();
    unawaited(sync.syncNow());
    return loans;
  }

  Future<Book> createAndEncode(
    Map<String, Object?> values,
    ReaderTag tag, {
    void Function(Book book)? onCreated,
  }) async {
    final book = await database.createBook(values);
    onCreated?.call(book);
    await loadBooks();
    await encodeBook(book, tag);
    return (await database.getBook(book.id))!;
  }

  Future<void> encodeBook(Book book, ReaderTag tag) async {
    _requireSingleTag(tag, expectedEpc: tag.epc);
    final card = await database.recognizeCard(tag.epc, tag.tid);
    if (card != null) {
      throw StateError(
        'Ce tag est la carte de l’abonné ${card.name}. Utilisez un tag de livre.',
      );
    }
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

  /// Lit le tag unique posé sur le lecteur, indépendamment de l'écran
  /// courant (formulaire d'emprunt).
  Future<ReaderTag> captureSingleTag({
    Duration timeout = const Duration(seconds: 5),
    String? noTagMessage,
  }) async {
    if (_capturingCard) throw StateError('Une lecture de carte est en cours.');
    if (!reader.connected) await connectReader();
    if (reader.reading) await reader.stopInventory();
    _capturingCard = true;
    final seen = <String, ReaderTag>{};
    final detected = Completer<void>();
    final subscription = reader.tags.listen((tag) {
      if (tag.epc.isEmpty && tag.tid.isEmpty) return;
      final key = _stationKey(tag);
      final previous = seen[key];
      seen[key] = tag.tid.isEmpty && previous != null && previous.tid.isNotEmpty
          ? ReaderTag(
              epc: tag.epc,
              tid: previous.tid,
              rssi: tag.rssi,
              antenna: tag.antenna,
              count: tag.count,
            )
          : tag;
      if (!detected.isCompleted) detected.complete();
    });
    try {
      await reader.startInventory(power: readPower);
      try {
        await detected.future.timeout(timeout);
      } on TimeoutException {
        throw StateError(
          noTagMessage ?? 'Aucune carte détectée. Posez-la sur le lecteur.',
        );
      }
      // Laisse le temps à d'éventuels autres tags de se manifester.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } finally {
      try {
        await reader.stopInventory();
      } finally {
        await subscription.cancel();
        _capturingCard = false;
      }
    }
    if (seen.length != 1) {
      throw StateError(
        'Plusieurs tags détectés. Ne laissez que la carte sur le lecteur.',
      );
    }
    final tag = seen.values.single;
    if (tag.tid.isNotEmpty) return tag;
    return ReaderTag(
      epc: tag.epc,
      tid: await reader.resolveTid(tag.epc),
      rssi: tag.rssi,
      antenna: tag.antenna,
      count: tag.count,
    );
  }

  /// Capture un tag unique avec la routine existante (y compris la résolution
  /// du TID en série), puis expose cette lecture à la vérification d'encodage.
  Future<ReaderTag> captureEncodingTag() async {
    final tag = await captureSingleTag(
      noTagMessage: 'Aucun tag de livre détecté. Posez-en un sur le lecteur.',
    );
    if (tag.tid.isEmpty) {
      throw StateError(
        'Le TID du tag n’est pas lisible. Réessayez avec un seul tag.',
      );
    }
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    _releaseTimers.clear();
    _observed.clear();
    _observed[_key(tag)] = tag;
    if (view == 'station') {
      _stationSessionTags.clear();
      _stationSessionTags[_stationKey(tag)] = tag;
    }
    notifyListeners();
    return tag;
  }

  /// Identifie l'abonné à partir de sa carte RFID.
  Future<Subscriber> readSubscriberCard() async {
    final tag = await captureSingleTag();
    final subscriber = await database.recognizeCard(tag.epc, tag.tid);
    if (subscriber != null) return subscriber;
    final book = await database.recognizeTag(tag.epc, tag.tid);
    if (book != null) {
      throw StateError(
        'Ce tag est le livre ${book.accession}. Posez la carte de l’abonné.',
      );
    }
    throw StateError('Carte vierge ou inconnue : encodez-la pour cet abonné.');
  }

  /// Enregistre l'abonné et écrit l'EPC de sa carte sur le tag posé sur le
  /// lecteur (écriture ciblée par TID puis vérifiée par relecture).
  Future<Subscriber> encodeSubscriberCard({
    required String memberNumber,
    required String name,
    String email = '',
    String phone = '',
  }) async {
    final subscriber = await database.saveSubscriber(
      memberNumber: memberNumber,
      name: name,
      email: email,
      phone: phone,
    );
    final tag = await captureSingleTag();
    if (tag.tid.isEmpty) {
      throw StateError(
        'Le tag ne fournit pas de TID; l’écriture sécurisée est annulée.',
      );
    }
    final book = await database.recognizeTag(tag.epc, tag.tid);
    if (book != null) {
      throw StateError(
        'Ce tag appartient au livre ${book.accession}. Utilisez une carte vierge.',
      );
    }
    final owner = await database.recognizeCard(tag.epc, tag.tid);
    if (owner != null && owner.id != subscriber.id) {
      throw StateError('Ce tag est déjà la carte de ${owner.name}.');
    }
    final cardEpc = subscriber.cardEpc!;
    final result = await reader.writeEpc(
      cardEpc,
      tag.tid,
      currentEpc: tag.epc,
      writePower: writePower,
      restorePower: readPower,
    );
    if (result['verified'] != true ||
        result['epc'] != cardEpc ||
        result['tid'] != tag.tid) {
      throw StateError('L’écriture de la carte n’a pas été vérifiée.');
    }
    final updated = await database.markCardTagged(subscriber.id, tag.tid);
    await loadActivity();
    return updated;
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

  Future<void> _onTag(ReaderTag receivedTag) async {
    if (_capturingCard) return;
    var tag = receivedTag;
    if (view == 'locator') {
      _onLocatorTag(tag);
      return;
    }
    if (view == 'station') {
      final stationKey = _stationKey(tag);
      final previous = _stationSessionTags[stationKey];
      if (tag.tid.isEmpty && previous != null && previous.tid.isNotEmpty) {
        tag = ReaderTag(
          epc: tag.epc,
          tid: previous.tid,
          rssi: tag.rssi,
          antenna: tag.antenna,
          count: tag.count,
        );
      }
      _stationSessionTags[stationKey] = tag;
    }
    final key = _key(tag);
    if (key.isEmpty) return;
    final startsNewDetection = _observed.isEmpty;
    _observed[key] = tag;
    final now = DateTime.now();
    if (view == 'inventory') {
      _recordInventoryObservation(key, tag, now);
    }
    _releaseTimers.remove(key)?.cancel();
    _releaseTimers[key] = Timer(const Duration(milliseconds: 1500), () {
      _observed.remove(key);
      _lastTagRecognitionAt.remove(key);
      _releaseTimers.remove(key);
      _notifyTagChange();
    });
    final lastRecognizedAt = _lastTagRecognitionAt[key];
    if (lastRecognizedAt != null &&
        now.difference(lastRecognizedAt) < _recognitionInterval) {
      _notifyTagChange();
      return;
    }
    _lastTagRecognitionAt[key] = now;
    if (startsNewDetection) {
      unawaited(_playScanBeep());
    }
    try {
      final recognized = await database.recognizeTag(tag.epc, tag.tid);
      _recognized[key] = recognized;
      if (tag.epc.isNotEmpty) _recognized[tag.epc] = recognized;
      if (tag.tid.isNotEmpty) _recognized[tag.tid] = recognized;
      if (view == 'inventory') {
        _setInventoryBook(key, tag, recognized);
      }
      _scheduleCatalogueRefresh(books: recognized != null);
    } catch (error) {
      readerError = error.toString();
    }
    _notifyTagChange();
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
    locatorDirection.addSample(
      LocatorSignalTracker.normalizeRssi(tag.rssi.toDouble()),
    );
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
    _inventoryCache = null;
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
    _inventoryCache = null;
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
    _tagRefreshTimer?.cancel();
    _catalogueRefreshTimer?.cancel();
    unawaited(_headingSubscription?.cancel());
    locatorDirection.dispose();
    for (final timer in _releaseTimers.values) {
      timer.cancel();
    }
    unawaited(_tagSubscription.cancel());
    unawaited(_nativeKeySubscription.cancel());
    sync.removeListener(_onSyncChanged);
    logs.dispose();
    sync.dispose();
    kiosk.dispose();
    gate.dispose();
    unawaited(reader.dispose());
    super.dispose();
  }
}
