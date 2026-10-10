import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/epc.dart';
import '../models/book.dart';
import '../models/staff.dart';
import 'gate_direction.dart';
import 'gate_reader_service.dart';
import 'library_controller.dart';
import 'reader_service.dart';

enum GateEventKind { alarm, borrowedBook, staff, unknownBadge }

/// Événement affiché dans le fil du portail.
class GateEvent {
  const GateEvent({
    required this.kind,
    required this.at,
    required this.title,
    this.detail = '',
    this.direction,
  });

  final GateEventKind kind;
  final DateTime at;
  final String title;
  final String detail;
  final PassageDirection? direction;
}

/// Alarme en cours : un livre non emprunté passe le portail.
class GateAlarm {
  const GateAlarm({required this.at, required this.epc, this.book});

  final DateTime at;
  final String epc;

  /// `null` : livre signé « BCM » absent du catalogue de ce portail.
  final Book? book;
}

/// Portail antivol : alarme vocale pour un livre non emprunté, compteurs
/// d'entrées et de sorties du jour, passages du personnel par badge.
class GateController extends ChangeNotifier {
  GateController(
    this.library, {
    GateReaderService? reader,
    DateTime Function()? clock,
    this.staffDirectionWait = const Duration(milliseconds: 2500),
    this.healthCheckInterval = const Duration(seconds: 30),
  }) : reader = reader ?? GateReaderService(),
       _clock = clock ?? DateTime.now {
    _tagSubscription = this.reader.tags.listen(
      (tag) => unawaited(_onTag(tag)),
      onError: _onReaderError,
    );
    _sensorSubscription = this.reader.sensors.listen(
      (event) => unawaited(_onSensor(event)),
    );
  }

  /// Durée minimale d'affichage d'une alarme.
  static const alarmDisplay = Duration(seconds: 10);

  /// Un badge lu reste ignoré pendant ce délai après son passage enregistré.
  static const staffRearm = Duration(seconds: 30);

  /// Intervalle minimal entre deux relectures du TID d'un même badge : la
  /// lecture continue est suspendue pendant chacune.
  static const tidRetry = Duration(seconds: 2);

  /// Un sens mesuré par les barrières peu avant la lecture d'un badge lui
  /// est attribué.
  static const directionLookback = Duration(seconds: 4);

  final LibraryController library;
  final GateReaderService reader;
  final DateTime Function() _clock;

  /// Attente d'un sens mesuré par les barrières après la lecture d'un badge.
  final Duration staffDirectionWait;
  final Duration healthCheckInterval;
  late final StreamSubscription<ReaderTag> _tagSubscription;
  late final StreamSubscription<GateSensorEvent> _sensorSubscription;
  final GateDirectionTracker tracker = GateDirectionTracker(
    outsideSensor: 1,
    insideSensor: 2,
  );

  // Réglages du portail.
  String transport = 'tcp';
  String endpoint = '';
  int power = 30;
  String gateName = 'Portail antivol';
  double alarmVolume = 0.8;

  /// Sortie du voyant allumé pendant l'alarme (0 : aucun). GPO1 = voyant
  /// rouge d'après le manuel du portail.
  int lightGpo = 1;

  /// Buzzer du portail pendant l'alarme : coupé par défaut, le message vocal
  /// et la sirène de la tablette suffisent.
  bool buzzerEnabled = false;

  /// Sortie du buzzer (GPO3 d'après le manuel ; à vérifier selon le câblage).
  int buzzerGpo = 3;

  /// Durée du bip du buzzer, en secondes.
  int buzzerSeconds = 2;

  bool get alarmLight => lightGpo > 0;

  /// Délai de réarmement de l'alarme d'un même livre, en secondes.
  int bookRearmSeconds = 20;

  // État.
  bool active = false;
  bool connecting = false;
  String? readerError;
  String? readerInfo;
  bool? buzzerSilenced;
  bool? sensorReport;
  GateAlarm? alarm;
  late GateDayCounts today = GateDayCounts(day: GateDayCounts.dayOf(_clock()));
  List<StaffPassage> staffToday = const [];
  final List<GateEvent> _events = [];

  final Map<String, DateTime> _bookSeenAt = {};
  final Map<String, DateTime> _staffSeenAt = {};
  final Map<String, DateTime> _unknownBadgeAt = {};
  final Map<String, DateTime> _tidReadAt = {};
  final Set<String> _checking = {};
  final List<(DateTime, PassageDirection)> _recentDirections = [];
  final List<Completer<PassageDirection?>> _directionWaiters = [];
  Timer? _alarmTimer;
  Timer? _reconnectTimer;
  Timer? _housekeeping;
  DateTime? _lastEventAt;
  int _failedPings = 0;

  bool get readerConnected => reader.connected;
  bool get simulation => transport == 'simulation';
  bool get countsPeople => tracker.enabled;
  int get outsideSensor => tracker.outsideSensor;
  int get insideSensor => tracker.insideSensor;
  List<GateEvent> get events => List.unmodifiable(_events);

  /// Identifiant du portail : celui de l'appareil pour la synchronisation.
  String get gateId =>
      library.sync.deviceId.isEmpty ? 'portail' : library.sync.deviceId;

  /// Membres du personnel présents d'après leur dernier passage du jour.
  List<StaffPassage> get staffInside {
    final latest = <String, StaffPassage>{};
    for (final passage in staffToday) {
      latest.putIfAbsent(passage.staffServerId, () => passage);
    }
    return latest.values
        .where((passage) => passage.direction == PassageDirection.entry)
        .toList();
  }

  Future<void> initialize() async {
    final settings = await SharedPreferences.getInstance();
    transport = settings.getString('gate_transport') ?? 'tcp';
    endpoint = settings.getString('gate_endpoint') ?? '';
    power = settings.getInt('gate_power') ?? 30;
    gateName = settings.getString('gate_name') ?? 'Portail antivol';
    alarmVolume = settings.getDouble('gate_alarm_volume') ?? 0.8;
    lightGpo = settings.getBool('gate_alarm_light') == false
        ? 0
        : settings.getInt('gate_light_gpo') ?? 1;
    buzzerEnabled = settings.getBool('gate_buzzer_enabled') ?? false;
    buzzerGpo = settings.getInt('gate_buzzer_gpo') ?? 3;
    buzzerSeconds = settings.getInt('gate_buzzer_seconds') ?? 2;
    bookRearmSeconds = settings.getInt('gate_book_rearm') ?? 20;
    tracker
      ..outsideSensor = settings.getInt('gate_outside_sensor') ?? 1
      ..insideSensor = settings.getInt('gate_inside_sensor') ?? 2;
    debugPrint(
      'Portail : réglages chargés ($transport, '
      '${endpoint.isEmpty ? 'adresse vide' : endpoint}, '
      'barrières $outsideSensor/$insideSensor).',
    );
    await refreshToday();
    // L'écran du portail peut ouvrir la surveillance avant le chargement de
    // ces réglages : la lecture démarre dès qu'ils sont connus.
    if (active) await _ensureReading();
  }

  /// Relit les compteurs et les passages du personnel du jour.
  Future<void> refreshToday() async {
    final now = _clock();
    today = await library.database.gateDay(gateId, GateDayCounts.dayOf(now));
    staffToday = await library.database.staffPassagesOn(now);
    notifyListeners();
  }

  /// Ouvre le portail : lecture continue, écran allumé.
  Future<void> enter() async {
    if (active) return;
    active = true;
    debugPrint('Portail : surveillance ouverte.');
    library.kioskActive = true;
    unawaited(_keepScreenOn(true));
    _housekeeping?.cancel();
    _housekeeping = Timer.periodic(
      healthCheckInterval,
      (_) => unawaited(_housekeep()),
    );
    await refreshToday();
    await _ensureReading();
  }

  Future<void> leave() async {
    if (!active) return;
    active = false;
    debugPrint('Portail : surveillance en pause (terminal admin ou sortie).');
    library.kioskActive = false;
    _housekeeping?.cancel();
    _reconnectTimer?.cancel();
    _alarmTimer?.cancel();
    alarm = null;
    unawaited(_keepScreenOn(false));
    try {
      if (reader.reading) await reader.stopInventory();
    } catch (error) {
      debugPrint('Arrêt du portail impossible : $error');
    }
    notifyListeners();
  }

  Future<void> reconnect() => _ensureReading();

  /// Enregistre la connexion du portail puis la teste.
  Future<Map<Object?, Object?>> configureReader({
    required String nextTransport,
    required String nextEndpoint,
    required int nextPower,
  }) async {
    if (nextPower < GateReaderService.minPower ||
        nextPower > GateReaderService.maxPower) {
      throw RangeError.range(
        nextPower,
        GateReaderService.minPower,
        GateReaderService.maxPower,
        'puissance',
      );
    }
    endpoint = nextTransport == 'simulation'
        ? ''
        : GateReaderService.normalizeEndpoint(nextTransport, nextEndpoint);
    transport = nextTransport;
    power = nextPower;
    final settings = await SharedPreferences.getInstance();
    await settings.setString('gate_transport', transport);
    await settings.setString('gate_endpoint', endpoint);
    await settings.setInt('gate_power', power);
    debugPrint('Portail : réglages enregistrés ($transport, $endpoint).');
    final info = await _connect();
    if (active) await _ensureReading();
    return info;
  }

  /// Barrières infrarouges : entrée GPI côté extérieur et côté intérieur
  /// (0 : pas de comptage des personnes).
  Future<void> configureSensors({
    required int nextOutside,
    required int nextInside,
  }) async {
    for (final value in [nextOutside, nextInside]) {
      if (value < 0 || value > 4) throw RangeError.range(value, 0, 4, 'GPI');
    }
    if (nextOutside > 0 && nextOutside == nextInside) {
      throw ArgumentError(
        'Les deux barrières doivent être sur des entrées différentes.',
      );
    }
    tracker
      ..outsideSensor = nextOutside
      ..insideSensor = nextInside
      ..reset();
    final settings = await SharedPreferences.getInstance();
    await settings.setInt('gate_outside_sensor', nextOutside);
    await settings.setInt('gate_inside_sensor', nextInside);
    notifyListeners();
  }

  Future<void> configureAlarm({
    required double nextVolume,
    required int nextLightGpo,
    required int nextRearmSeconds,
    required String nextGateName,
  }) async {
    if (nextRearmSeconds < 5 || nextRearmSeconds > 600) {
      throw RangeError.range(nextRearmSeconds, 5, 600, 'secondes');
    }
    final name = nextGateName.trim();
    if (name.isEmpty) throw ArgumentError('Donnez un nom au portail.');
    if (nextLightGpo < 0 || nextLightGpo > 4) {
      throw RangeError.range(nextLightGpo, 0, 4, 'GPO');
    }
    alarmVolume = nextVolume.clamp(0.1, 1.0);
    lightGpo = nextLightGpo;
    bookRearmSeconds = nextRearmSeconds;
    gateName = name.length > 60 ? name.substring(0, 60) : name;
    final settings = await SharedPreferences.getInstance();
    await settings.setDouble('gate_alarm_volume', alarmVolume);
    await settings.setBool('gate_alarm_light', alarmLight);
    await settings.setInt('gate_light_gpo', lightGpo);
    await settings.setInt('gate_book_rearm', bookRearmSeconds);
    await settings.setString('gate_name', gateName);
    notifyListeners();
  }

  /// Buzzer du portail pendant l'alarme. Désactivé, sa sortie est aussi
  /// retirée de ce que le portail déclenche de lui-même.
  Future<void> configureBuzzer({
    required bool nextEnabled,
    required int nextGpo,
    required int nextSeconds,
  }) async {
    if (nextGpo < 1 || nextGpo > 4) {
      throw RangeError.range(nextGpo, 1, 4, 'GPO');
    }
    if (nextSeconds < 1 || nextSeconds > 10) {
      throw RangeError.range(nextSeconds, 1, 10, 'secondes');
    }
    buzzerEnabled = nextEnabled;
    buzzerGpo = nextGpo;
    buzzerSeconds = nextSeconds;
    final settings = await SharedPreferences.getInstance();
    await settings.setBool('gate_buzzer_enabled', buzzerEnabled);
    await settings.setInt('gate_buzzer_gpo', buzzerGpo);
    await settings.setInt('gate_buzzer_seconds', buzzerSeconds);
    if (!buzzerEnabled && reader.connected) {
      buzzerSilenced = await reader.silenceBuzzer(buzzerGpo);
    }
    notifyListeners();
  }

  /// Fait sonner le buzzer une fois, pour identifier sa sortie.
  Future<bool> testBuzzer({int? gpo}) =>
      reader.pulseGpo(gpo ?? buzzerGpo, Duration(seconds: buzzerSeconds));

  Future<Map<String, Object?>> readN01Settings() => reader.readN01Settings();

  Future<Map<String, Object?>> applyN01Settings(
    Map<String, Object?> settings,
  ) => reader.applyN01Settings(settings);

  /// Joue l'alarme (message et voyant) sans la compter.
  Future<void> testAlarm() => _signalAlarm();

  void dismissAlarm() {
    _alarmTimer?.cancel();
    alarm = null;
    unawaited(reader.stopAlarm().catchError((_) {}));
    notifyListeners();
  }

  /// Simulation : passage complet d'une personne entre les barrières.
  void simulatePassage(PassageDirection direction) {
    final first = direction == PassageDirection.entry
        ? tracker.outsideSensor
        : tracker.insideSensor;
    final second = direction == PassageDirection.entry
        ? tracker.insideSensor
        : tracker.outsideSensor;
    for (final sensor in [first, second]) {
      reader.simulateSensor(sensor, 1);
    }
    for (final sensor in [first, second]) {
      reader.simulateSensor(sensor, 0);
    }
  }

  Future<void> _onTag(ReaderTag tag) async {
    final epc = tag.epc.trim().toUpperCase();
    if (!active || epc.isEmpty || epc == ReaderService.emptyEpc) return;
    final now = _clock();
    _lastEventAt = now;
    if (isBadgeEpc(epc)) {
      await _onBadge(epc, tag.tid, now);
      return;
    }
    // Cartes d'abonné et tags étrangers à la bibliothèque : ignorés.
    if (!isValidEpc(epc)) {
      debugPrint(
        'Portail : tag $epc ignoré '
        '(${isCardEpc(epc) ? 'carte abonné' : 'EPC hors format livre BCM ou CRC invalide'}).',
      );
      return;
    }
    final last = _bookSeenAt[epc];
    _bookSeenAt[epc] = now;
    if (_bookSeenAt.length > 2000) {
      _bookSeenAt.removeWhere((_, seen) => now.difference(seen).inMinutes > 10);
    }
    // Un livre resté dans le champ n'alarme qu'une fois ; il se réarme
    // après une absence de [bookRearmSeconds].
    if (last != null && now.difference(last).inSeconds < bookRearmSeconds) {
      return;
    }
    if (!_checking.add(epc)) return;
    try {
      final book = await library.database.bookForEpc(epc);
      final loan = book == null
          ? null
          : await library.database.activeLoanForBook(book.id);
      debugPrint(
        'Portail : tag $epc → '
        '${book == null ? 'livre inconnu' : book.accession} '
        '${loan == null ? '→ alarme' : '→ emprunté'} (RSSI ${tag.rssi}).',
      );
      if (loan != null) {
        _addEvent(
          GateEvent(
            kind: GateEventKind.borrowedBook,
            at: now,
            title: book!.title,
            detail: 'Emprunté par ${loan.subscriberName ?? 'un abonné'}',
          ),
        );
        notifyListeners();
        return;
      }
      await _raiseAlarm(epc, book, now);
    } catch (error) {
      readerError = error.toString();
      notifyListeners();
    } finally {
      _checking.remove(epc);
    }
  }

  Future<void> _raiseAlarm(String epc, Book? book, DateTime now) async {
    alarm = GateAlarm(at: now, epc: epc, book: book);
    _addEvent(
      GateEvent(
        kind: GateEventKind.alarm,
        at: now,
        title: book?.title ?? 'Livre non référencé sur ce portail',
        detail: book == null ? epc : '${book.accession} · non emprunté',
      ),
    );
    notifyListeners();
    // Le son d'abord : la base passe après.
    await _signalAlarm();
    today = await library.database.addGateCounts(
      gateId: gateId,
      gateName: gateName,
      at: now,
      alarms: 1,
    );
    await library.database.addActivity(
      'portail',
      'echec',
      book == null
          ? 'Alarme antivol : livre non référencé sur ce portail'
          : 'Alarme antivol : « ${book.title} » (${book.accession}) non emprunté',
      bookId: book?.id,
      epc: epc,
    );
    notifyListeners();
  }

  /// Message vocal, voyant et, s'il est activé, buzzer du portail. Buzzer
  /// désactivé : sa sortie n'est jamais actionnée, même si c'est aussi celle
  /// du voyant.
  Future<void> _signalAlarm() async {
    var shown = alarmDisplay;
    try {
      final remaining = await reader.playAlarm(alarmVolume);
      if (remaining > shown) shown = remaining;
    } catch (error) {
      debugPrint('Message d’alarme indisponible : $error');
    }
    final lightAllowed = buzzerEnabled || lightGpo != buzzerGpo;
    if (alarmLight && lightAllowed) {
      unawaited(reader.pulseGpo(lightGpo, shown));
    }
    if (buzzerEnabled && buzzerGpo != lightGpo) {
      unawaited(reader.pulseGpo(buzzerGpo, Duration(seconds: buzzerSeconds)));
    }
    _alarmTimer?.cancel();
    _alarmTimer = Timer(shown, () {
      alarm = null;
      notifyListeners();
    });
  }

  Future<void> _onBadge(String epc, String tid, DateTime now) async {
    if (tid.trim().isEmpty) {
      // Relu une fois, le TID est ensuite joint par le portail à chaque
      // lecture du badge ; un échec est retenté après [tidRetry].
      final tried = _tidReadAt[epc];
      if (tried != null && now.difference(tried) < tidRetry) return;
      _tidReadAt[epc] = now;
      if (_tidReadAt.length > 500) {
        _tidReadAt.removeWhere((_, at) => now.difference(at) > staffRearm);
      }
      // Le portail ne transmet pas le TID en lecture continue : relu à la
      // demande pour authentifier le badge.
      tid = await reader.readTid(epc);
      debugPrint(
        'Portail : badge $epc, TID ${tid.isEmpty ? 'non relu' : 'relu'}.',
      );
      if (tid.isEmpty) return;
    }
    final staff = await library.database.staffForBadge(epc, tid);
    if (staff == null) {
      final last = _unknownBadgeAt[epc];
      _unknownBadgeAt[epc] = now;
      if (last == null || now.difference(last) >= staffRearm) {
        _addEvent(
          GateEvent(
            kind: GateEventKind.unknownBadge,
            at: now,
            title: 'Badge non reconnu',
            detail: 'Badge désactivé ou pas encore synchronisé',
          ),
        );
        notifyListeners();
      }
      return;
    }
    final last = _staffSeenAt[staff.serverId];
    _staffSeenAt[staff.serverId] = now;
    if (last != null && now.difference(last) < staffRearm) return;
    final direction =
        _takeRecentDirection(now) ??
        await _awaitDirection() ??
        await _alternateDirection(staff, now);
    final passage = await library.database.recordStaffPassage(
      staff: staff,
      direction: direction,
      at: now,
      gateId: gateId,
      gateName: gateName,
    );
    staffToday = [passage, ...staffToday];
    final verb = direction == PassageDirection.entry ? 'Entrée' : 'Sortie';
    await library.database.addActivity(
      'portail',
      'succes',
      '$verb de ${staff.name} (${staff.staffNumber})',
      epc: epc,
      tid: tid,
    );
    _addEvent(
      GateEvent(
        kind: GateEventKind.staff,
        at: now,
        title: staff.name,
        detail: staff.position.isEmpty ? staff.staffNumber : staff.position,
        direction: direction,
      ),
    );
    notifyListeners();
  }

  PassageDirection? _takeRecentDirection(DateTime now) {
    for (var index = _recentDirections.length - 1; index >= 0; index--) {
      final (at, direction) = _recentDirections[index];
      if (now.difference(at) <= directionLookback) {
        _recentDirections.removeAt(index);
        return direction;
      }
    }
    return null;
  }

  /// Sens mesuré par les barrières dans les secondes qui suivent le badge.
  Future<PassageDirection?> _awaitDirection() async {
    if (!tracker.enabled) return null;
    final waiter = Completer<PassageDirection?>();
    _directionWaiters.add(waiter);
    final timer = Timer(staffDirectionWait, () {
      if (!waiter.isCompleted) waiter.complete(null);
    });
    final direction = await waiter.future;
    timer.cancel();
    _directionWaiters.remove(waiter);
    return direction;
  }

  /// Sans barrière : premier passage du jour = entrée, puis alternance.
  Future<PassageDirection> _alternateDirection(
    StaffMember staff,
    DateTime now,
  ) async {
    final last = await library.database.lastStaffPassage(
      staff.serverId,
      since: DateTime(now.year, now.month, now.day),
    );
    return last?.direction.opposite ?? PassageDirection.entry;
  }

  Future<void> _onSensor(GateSensorEvent event) async {
    if (!active) {
      // Terminal admin ouvert : état des barrières affiché pour le test.
      tracker.observe(event.sensor, event.level);
      notifyListeners();
      return;
    }
    final now = _clock();
    _lastEventAt = now;
    final direction = tracker.onLevel(event.sensor, event.level, now);
    debugPrint(
      'Portail : barrière GPI${event.sensor} = ${event.level}'
      '${direction == null ? '' : ' → ${direction == PassageDirection.entry ? 'entrée' : 'sortie'}'}.',
    );
    if (direction == null) {
      notifyListeners();
      return;
    }
    final waiter = _directionWaiters
        .where((item) => !item.isCompleted)
        .firstOrNull;
    if (waiter != null) {
      waiter.complete(direction);
    } else {
      _recentDirections
        ..add((now, direction))
        ..removeWhere((item) => now.difference(item.$1) > directionLookback);
    }
    today = await library.database.addGateCounts(
      gateId: gateId,
      gateName: gateName,
      at: now,
      entries: direction == PassageDirection.entry ? 1 : 0,
      exits: direction == PassageDirection.exit ? 1 : 0,
    );
    notifyListeners();
  }

  void _addEvent(GateEvent event) {
    _events.insert(0, event);
    if (_events.length > 40) _events.removeRange(40, _events.length);
  }

  Future<Map<Object?, Object?>> _connect() async {
    connecting = true;
    readerError = null;
    notifyListeners();
    try {
      final sensors = [
        tracker.outsideSensor,
        tracker.insideSensor,
      ].where((sensor) => sensor > 0).toList();
      final info = await reader.connect(
        transport: transport,
        endpoint: endpoint,
        sensors: sensors,
        buzzerGpo: buzzerGpo,
        silenceBuzzer: !buzzerEnabled,
      );
      final levels = <int, int>{};
      final raw = info['gpiLevels'];
      if (raw is Map) {
        for (final entry in raw.entries) {
          final sensor = int.tryParse(entry.key.toString());
          final level = (entry.value as num?)?.toInt();
          if (sensor != null && level != null) levels[sensor] = level;
        }
      }
      tracker.setIdleLevels(levels);
      buzzerSilenced = info['buzzerSilenced'] as bool?;
      sensorReport = info['gpiReport'] as bool?;
      final id = info['readerId']?.toString() ?? '';
      final version = info['version']?.toString() ?? '';
      readerInfo = [
        'Portail connecté',
        if (id.isNotEmpty) 'n° $id',
        if (version.isNotEmpty) 'version $version',
      ].join(' · ');
      _failedPings = 0;
      _lastEventAt = _clock();
      await library.database.addActivity(
        'connexion',
        'succes',
        'Portail antivol connecté (${transport.toUpperCase()})',
      );
      return info;
    } catch (error) {
      readerError = _describe(error);
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> _ensureReading() async {
    _reconnectTimer?.cancel();
    if (!active) return;
    try {
      if (!reader.connected) {
        if (!simulation && endpoint.isEmpty) {
          throw StateError('Configurez le portail dans le terminal admin.');
        }
        await _connect();
      }
      if (!reader.reading) {
        await reader.startInventory(power: power);
        debugPrint('Portail : lecture démarrée ($power dBm).');
      }
      readerError = null;
    } catch (error) {
      readerError = _describe(error);
      debugPrint('Portail : lecture impossible : $readerError');
      _scheduleReconnect();
    }
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (!active || (!simulation && endpoint.isEmpty)) return;
    _reconnectTimer = Timer(const Duration(seconds: 10), _ensureReading);
  }

  /// Changement de jour et contrôle de la liaison avec le portail.
  Future<void> _housekeep() async {
    if (!active) return;
    final now = _clock();
    if (GateDayCounts.dayOf(now) != today.day) await refreshToday();
    if (!reader.connected || simulation) return;
    final quietFor = now.difference(_lastEventAt ?? now);
    if (quietFor < healthCheckInterval * 2) return;
    if (await reader.ping()) {
      _failedPings = 0;
      _lastEventAt = now;
      return;
    }
    if (++_failedPings < 2) return;
    _failedPings = 0;
    readerError = 'Le portail ne répond plus : reconnexion…';
    notifyListeners();
    try {
      await reader.disconnect();
    } catch (_) {}
    await _ensureReading();
  }

  void _onReaderError(Object error) {
    readerError = _describe(error);
    if (active && !reader.connected) _scheduleReconnect();
    notifyListeners();
  }

  Future<void> _keepScreenOn(bool enabled) async {
    try {
      await reader.setKeepScreenOn(enabled);
    } catch (error) {
      debugPrint('Maintien de l’écran impossible : $error');
    }
  }

  static String _describe(Object error) {
    final text = error.toString();
    final platform = RegExp(
      r'^PlatformException\([^,]+,\s*(.*),\s*null,\s*null\)$',
    ).firstMatch(text);
    return (platform?.group(1) ?? text).replaceFirst(
      RegExp(r'^(Bad state|Invalid argument\(s\)|RangeError[^:]*):?\s*'),
      '',
    );
  }

  bool _disposed = false;

  /// Une lecture en cours peut se terminer après la fermeture de l'écran.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _alarmTimer?.cancel();
    _reconnectTimer?.cancel();
    _housekeeping?.cancel();
    for (final waiter in _directionWaiters) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    unawaited(_tagSubscription.cancel());
    unawaited(_sensorSubscription.cancel());
    unawaited(reader.dispose());
    super.dispose();
  }
}
