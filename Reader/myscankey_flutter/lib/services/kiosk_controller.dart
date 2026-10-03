import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/epc.dart';
import '../models/book.dart';
import '../models/lending.dart';
import 'desk_reader_service.dart';
import 'library_controller.dart';
import 'reader_service.dart';

enum KioskStage { home, browse, borrow, giveBack, receipt }

enum KioskItemState {
  /// Disponible : sera emprunté.
  available,

  /// Au-delà du nombre de livres encore autorisés.
  overQuota,

  /// Déjà emprunté par l'abonné de la session.
  alreadyYours,

  /// Emprunté par quelqu'un d'autre ou retiré du prêt.
  unavailable,

  /// Emprunt en cours : sera rendu.
  returnable,

  /// Livre posé au retour sans emprunt en cours.
  notBorrowed,
}

/// Livre posé sur le lecteur pendant une session du poste.
class KioskItem {
  const KioskItem({required this.epc, required this.book, this.loan});

  final String epc;
  final Book book;

  /// Emprunt en cours du livre au moment de la lecture.
  final Loan? loan;
}

/// Ticket affiché à la fin d'un emprunt ou d'un retour.
class KioskReceipt {
  const KioskReceipt({
    required this.borrow,
    required this.loans,
    this.subscriber,
  });

  final bool borrow;
  final Subscriber? subscriber;
  final List<Loan> loans;
}

/// Poste d'emprunt en libre-service : l'abonné pose sa carte et ses livres
/// sur le lecteur de bureau, ou seulement les livres pour les rendre.
class KioskController extends ChangeNotifier {
  KioskController(this.library, {DeskReaderService? reader})
    : reader = reader ?? DeskReaderService() {
    _tagSubscription = this.reader.tags.listen(
      (tag) => unawaited(_onTag(tag)),
      onError: _onReaderError,
    );
  }

  static const defaultPin = '1234';
  static const sessionTimeout = Duration(seconds: 90);
  static const receiptDuration = Duration(seconds: 20);

  /// Anti-rebond par défaut : un livre retiré quitte l'écran après
  /// [defaultPresenceMs] sans lecture.
  static const defaultPresenceMs = 400;
  static const defaultReleaseMs = 1500;

  /// Les tags détectés dans cet intervalle sont annoncés par un seul bip.
  static const _beepGrouping = Duration(milliseconds: 140);

  /// Fréquence de recherche des livres retirés du lecteur.
  static const _presenceSweep = Duration(milliseconds: 50);
  static const beepSources = ['reader', 'tablet', 'both', 'off'];

  final LibraryController library;
  final DeskReaderService reader;
  late final StreamSubscription<ReaderTag> _tagSubscription;

  // Réglages du poste.
  String transport = 'tcp';
  String endpoint = '';
  int power = 20;
  int maxLoans = 3;
  int loanDays = 14;

  /// Bip d'un livre ou d'une carte détecté : buzzer du lecteur, son de la
  /// tablette, les deux ou aucun.
  String beepSource = 'reader';

  /// Délai après le retrait d'un tag avant qu'il puisse bipper de nouveau.
  int beepRearmSeconds = 5;

  /// Anti-rebond : un tag est absent après [presenceMs] sans lecture, puis
  /// retiré après [releaseMs] de confirmation. Une disparition plus brève
  /// ne relance ni session, ni bip.
  int presenceMs = defaultPresenceMs;
  int releaseMs = defaultReleaseMs;

  Duration get _releaseAfter => Duration(milliseconds: presenceMs + releaseMs);
  String _pinHash = _hash(defaultPin);

  // État du poste.
  bool active = false;
  bool connecting = false;
  String? readerError;
  KioskStage stage = KioskStage.home;
  Subscriber? subscriber;

  /// EPC de la carte de [subscriber], suivie comme les livres posés.
  String? _cardEpc;
  BorrowerStatus? borrower;
  final Map<String, KioskItem> _items = {};
  final Set<String> _unknown = {};
  String? notice;
  bool processing = false;
  bool _encoding = false;
  KioskReceipt? receipt;
  int receiptSecondsLeft = 0;

  int _session = 0;
  final Set<String> _seen = {};
  final Set<String> _pending = {};
  final Map<String, DateTime> _lingering = {};
  final Map<String, DateTime> _lastSeen = {};

  /// Plus long intervalle récent entre deux lectures de chaque tag posé,
  /// en ms. Beaucoup de livres posés : chaque tag est lu moins souvent.
  final Map<String, int> _readGapMs = {};
  final Set<String> _beeped = {};
  Timer? _beepTimer;
  Timer? _idleTimer;
  Timer? _receiptTimer;
  Timer? _reconnectTimer;
  Timer? _presenceTimer;

  bool get usesDefaultPin => _pinHash == _hash(defaultPin);
  bool get readerConnected => reader.connected;
  bool get simulation => transport == 'simulation';
  List<KioskItem> get items => _items.values.toList();

  /// Étiquettes inconnues encore posées sur le lecteur.
  int get unknownTags => _unknown.length;

  /// Échéance d'un emprunt fait maintenant : fin de journée, dans
  /// [loanDays] jours.
  DateTime get dueDate {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + loanDays, 23, 59);
  }

  List<KioskItem> get _borrowCandidates => _items.values
      .where((item) => item.loan == null && item.book.status == 'encode')
      .toList();

  KioskItemState stateOf(KioskItem item) {
    if (stage == KioskStage.giveBack) {
      return item.loan == null
          ? KioskItemState.notBorrowed
          : KioskItemState.returnable;
    }
    final loan = item.loan;
    if (loan != null) {
      return loan.subscriberId == subscriber?.id
          ? KioskItemState.alreadyYours
          : KioskItemState.unavailable;
    }
    if (item.book.status != 'encode') return KioskItemState.unavailable;
    final status = borrower;
    if (status != null && status.eligible) {
      final index = _borrowCandidates.indexWhere((c) => c.epc == item.epc);
      if (index >= status.remaining) return KioskItemState.overQuota;
    }
    return KioskItemState.available;
  }

  List<KioskItem> get borrowableItems => _items.values
      .where((item) => stateOf(item) == KioskItemState.available)
      .toList();

  List<KioskItem> get returnableItems =>
      _items.values.where((item) => item.loan != null).toList();

  /// Ce qui empêche de valider l'emprunt, ou `null` si c'est possible.
  String? get borrowBlocker {
    final status = borrower;
    if (subscriber == null || status == null) {
      return 'Posez votre carte d’abonné sur le lecteur.';
    }
    if (!status.eligible) return status.reasons.join(' ');
    final candidates = _borrowCandidates.length;
    if (candidates == 0) return 'Posez les livres à emprunter sur le lecteur.';
    if (candidates > status.remaining) {
      final extra = candidates - status.remaining;
      return 'Vous pouvez emprunter ${status.remaining} livre(s) de plus : '
          'retirez-en $extra.';
    }
    return null;
  }

  bool get canConfirmBorrow =>
      stage == KioskStage.borrow && !processing && borrowBlocker == null;

  bool get canConfirmReturn =>
      stage == KioskStage.giveBack && !processing && returnableItems.isNotEmpty;

  Future<void> initialize() async {
    final settings = await SharedPreferences.getInstance();
    transport = settings.getString('kiosk_transport') ?? 'tcp';
    endpoint = settings.getString('kiosk_endpoint') ?? '';
    power = settings.getInt('kiosk_power') ?? 20;
    maxLoans = settings.getInt('kiosk_max_loans') ?? 3;
    loanDays = settings.getInt('kiosk_loan_days') ?? 14;
    final source = settings.getString('kiosk_beep_source');
    beepSource = beepSources.contains(source) ? source! : 'reader';
    beepRearmSeconds = settings.getInt('kiosk_beep_rearm') ?? 5;
    final presence = settings.getInt('kiosk_presence_ms');
    // 700 ms était l'ancienne valeur par défaut : remplacée par la nouvelle.
    presenceMs = presence == null || presence == 700
        ? defaultPresenceMs
        : presence;
    releaseMs = settings.getInt('kiosk_release_ms') ?? defaultReleaseMs;
    _pinHash = settings.getString('kiosk_pin_hash') ?? _hash(defaultPin);
    notifyListeners();
  }

  /// Ouvre le poste : lecteur de bureau connecté et en lecture continue.
  Future<void> enter() async {
    if (active) return;
    active = true;
    library.kioskActive = true;
    _goHome(linger: false);
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(_presenceSweep, (_) => _dropAbsentItems());
    unawaited(_keepScreenOn(true));
    await _ensureReading();
  }

  Future<void> leave() async {
    if (!active) return;
    active = false;
    library.kioskActive = false;
    _idleTimer?.cancel();
    _receiptTimer?.cancel();
    _reconnectTimer?.cancel();
    _presenceTimer?.cancel();
    _resetSession();
    stage = KioskStage.home;
    unawaited(_keepScreenOn(false));
    try {
      if (reader.reading) await reader.stopInventory();
    } catch (error) {
      debugPrint('Arrêt du lecteur de bureau impossible : $error');
    }
    notifyListeners();
  }

  bool verifyPin(String pin) => _hash(pin.trim()) == _pinHash;

  Future<void> changePin({
    required String current,
    required String next,
  }) async {
    if (!verifyPin(current)) throw StateError('Code actuel incorrect.');
    if (!RegExp(r'^\d{4,8}$').hasMatch(next.trim())) {
      throw ArgumentError('Le code doit contenir 4 à 8 chiffres.');
    }
    _pinHash = _hash(next.trim());
    final settings = await SharedPreferences.getInstance();
    await settings.setString('kiosk_pin_hash', _pinHash);
    notifyListeners();
  }

  Future<void> configurePolicy({
    required int nextMaxLoans,
    required int nextLoanDays,
  }) async {
    if (nextMaxLoans < 1 || nextMaxLoans > 50) {
      throw RangeError.range(nextMaxLoans, 1, 50, 'emprunts');
    }
    if (nextLoanDays < 1 || nextLoanDays > 365) {
      throw RangeError.range(nextLoanDays, 1, 365, 'jours');
    }
    maxLoans = nextMaxLoans;
    loanDays = nextLoanDays;
    final settings = await SharedPreferences.getInstance();
    await settings.setInt('kiosk_max_loans', maxLoans);
    await settings.setInt('kiosk_loan_days', loanDays);
    notifyListeners();
  }

  Future<void> configureFeedback({
    required String nextSource,
    required int nextRearmSeconds,
    int? nextPresenceMs,
    int? nextReleaseMs,
  }) async {
    if (!beepSources.contains(nextSource)) {
      throw ArgumentError('Source de bip inconnue.');
    }
    if (nextRearmSeconds < 1 || nextRearmSeconds > 600) {
      throw RangeError.range(nextRearmSeconds, 1, 600, 'secondes');
    }
    final presence = nextPresenceMs ?? presenceMs;
    final release = nextReleaseMs ?? releaseMs;
    if (presence < 100 || presence > 5000) {
      throw RangeError.range(presence, 100, 5000, 'délai d’absence (ms)');
    }
    if (release < 0 || release > 10000) {
      throw RangeError.range(release, 0, 10000, 'confirmation du retrait (ms)');
    }
    beepSource = nextSource;
    beepRearmSeconds = nextRearmSeconds;
    presenceMs = presence;
    releaseMs = release;
    final settings = await SharedPreferences.getInstance();
    await settings.setString('kiosk_beep_source', beepSource);
    await settings.setInt('kiosk_beep_rearm', beepRearmSeconds);
    await settings.setInt('kiosk_presence_ms', presenceMs);
    await settings.setInt('kiosk_release_ms', releaseMs);
    notifyListeners();
  }

  /// Joue le bip configuré, pour l'essayer depuis le terminal admin.
  Future<void> testBeep() => _beep();

  /// Enregistre la connexion du lecteur de bureau puis la teste.
  Future<Map<Object?, Object?>> configureReader({
    required String nextTransport,
    required String nextEndpoint,
    required int nextPower,
  }) async {
    if (nextPower < DeskReaderService.minPower ||
        nextPower > DeskReaderService.maxPower) {
      throw RangeError.range(
        nextPower,
        DeskReaderService.minPower,
        DeskReaderService.maxPower,
        'puissance',
      );
    }
    final normalized = nextTransport == 'simulation'
        ? ''
        : DeskReaderService.normalizeEndpoint(nextTransport, nextEndpoint);
    transport = nextTransport;
    endpoint = normalized;
    power = nextPower;
    final settings = await SharedPreferences.getInstance();
    await settings.setString('kiosk_transport', transport);
    await settings.setString('kiosk_endpoint', endpoint);
    await settings.setInt('kiosk_power', power);
    final info = await _connect();
    if (active) await _ensureReading();
    return info;
  }

  Future<void> reconnect() => _ensureReading();

  /// Encode la carte de [target] avec le lecteur du poste : un seul tag posé,
  /// ni livre ni carte d'un autre abonné, écriture vérifiée par relecture.
  Future<Subscriber> encodeCard(Subscriber target) async {
    final cardEpc = target.cardEpc;
    if (cardEpc == null || !isCardEpc(cardEpc)) {
      throw StateError('Cet abonné n’a pas d’identifiant de carte.');
    }
    if (_encoding) throw StateError('Un encodage est déjà en cours.');
    if (transport != 'simulation' && endpoint.isEmpty) {
      throw StateError('Configurez d’abord le lecteur RFID de bureau.');
    }
    _encoding = true;
    _reconnectTimer?.cancel();
    notifyListeners();
    try {
      if (!reader.connected) await _connect();
      final tags = (await reader.capture(power: power)).where(
        (tag) => tag.epc != ReaderService.emptyEpc || tag.tid.isNotEmpty,
      );
      if (tags.isEmpty) {
        throw StateError('Aucun tag détecté. Posez la carte sur le lecteur.');
      }
      if (tags.length > 1) {
        throw StateError('Plusieurs tags détectés. Ne laissez que la carte.');
      }
      final tag = tags.single;
      if (tag.tid.isEmpty) {
        throw StateError(
          'Le tag ne fournit pas de TID; l’écriture sécurisée est annulée.',
        );
      }
      final book = await library.database.bookForTag(tag.epc, tag.tid);
      if (book != null) {
        throw StateError(
          'Ce tag est le livre ${book.accession}. Utilisez une carte vierge.',
        );
      }
      final owner = await library.database.cardForTag(tag.epc, tag.tid);
      if (owner != null && owner.id != target.id) {
        throw StateError('Ce tag est déjà la carte de ${owner.name}.');
      }
      // Encodé sur un autre appareil et pas encore synchronisé ici.
      if (isBadgeEpc(tag.epc)) {
        throw StateError(
          'Ce tag est un badge du personnel. Utilisez une carte vierge.',
        );
      }
      if (isValidEpc(tag.epc)) {
        throw StateError(
          'Ce tag est un livre encodé sur un autre appareil. '
          'Utilisez une carte vierge.',
        );
      }
      if (owner == null && isCardEpc(tag.epc) && tag.epc != cardEpc) {
        throw StateError(
          'Ce tag est la carte d’un autre abonné, pas encore synchronisée '
          'sur ce poste.',
        );
      }
      final result = await reader.writeEpc(cardEpc, tag.tid);
      if (result['verified'] != true || result['epc'] != cardEpc) {
        throw StateError('L’écriture de la carte n’a pas été vérifiée.');
      }
      final updated = await library.database.markCardTagged(target.id, tag.tid);
      await library.database.addActivity(
        'carte',
        'succes',
        'Carte encodée pour ${updated.name} (${updated.memberNumber})',
      );
      // La carte encore posée ne doit pas ouvrir une session d'emprunt.
      _lingering[cardEpc] = DateTime.now();
      return updated;
    } finally {
      _encoding = false;
      if (active) {
        await _ensureReading();
      } else if (reader.reading) {
        await reader.stopInventory();
      }
      notifyListeners();
    }
  }

  /// Consultation du catalogue : titres, disponibilité et emplacement.
  void startBrowse() => _beginSession(KioskStage.browse);

  void startBorrow() => _beginSession(KioskStage.borrow);

  void startReturn() => _beginSession(KioskStage.giveBack);

  void cancelSession() => _goHome();

  void finish() => _goHome();

  void removeItem(String epc) {
    if (_items.remove(epc) == null) return;
    // Ignoré tant qu'il reste posé ; reposé plus tard, il est relu.
    _seen.remove(epc);
    _lingering[epc] = DateTime.now();
    _restartIdleTimer();
    notifyListeners();
  }

  void touch() => _restartIdleTimer();

  Future<void> confirmBorrow() async {
    if (!canConfirmBorrow) return;
    final member = subscriber!;
    final books = [for (final item in borrowableItems) item.book];
    processing = true;
    notice = null;
    notifyListeners();
    try {
      final loans = await library.checkoutBooks(
        member,
        books,
        dueAt: dueDate,
        maxLoans: maxLoans,
      );
      _showReceipt(
        KioskReceipt(borrow: true, subscriber: member, loans: loans),
      );
    } catch (error) {
      notice = _describe(error);
      await _refreshSession();
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<void> confirmReturn() async {
    if (!canConfirmReturn) return;
    final books = [for (final item in returnableItems) item.book];
    processing = true;
    notice = null;
    notifyListeners();
    try {
      final loans = await library.returnBooks(books);
      if (loans.isEmpty) throw StateError('Aucun emprunt en cours à clôturer.');
      _showReceipt(KioskReceipt(borrow: false, loans: loans));
    } catch (error) {
      notice = _describe(error);
      await _refreshSession();
    } finally {
      processing = false;
      notifyListeners();
    }
  }

  Future<void> _onTag(ReaderTag tag) async {
    final epc = tag.epc.trim().toUpperCase();
    if (epc.isEmpty || epc == ReaderService.emptyEpc) return;
    // Badge du personnel : ni carte ni livre, ignoré par le poste.
    if (isBadgeEpc(epc)) return;
    final now = DateTime.now();
    // La présence est suivie même pendant un reçu ou un traitement : c'est
    // elle qui mesure le retrait réel du tag.
    _trackPresence(epc, now);
    if (!active || processing || _encoding || stage == KioskStage.receipt) {
      return;
    }
    final lingeredAt = _lingering[epc];
    if (lingeredAt != null) {
      if (now.difference(lingeredAt) < _releaseAfter) {
        _lingering[epc] = now;
        return;
      }
      _lingering.remove(epc);
    }
    if (_seen.contains(epc) || _pending.contains(epc)) return;
    _pending.add(epc);
    var session = _session;
    final timer = Stopwatch()..start();
    try {
      // Le format de l'EPC dit s'il s'agit d'une carte : un livre évite la
      // recherche d'abonné.
      final card = isCardEpc(epc)
          ? await library.database.cardForTag(epc, tag.tid)
          : null;
      if (session != _session) return;
      if (card != null) {
        if (_idle) {
          _beginSession(KioskStage.borrow);
          session = _session;
        }
        if (await _onCard(card)) {
          _cardEpc = epc;
          _announce(epc);
        }
        if (session == _session) _seen.add(epc);
        return;
      }
      if (isCardEpc(epc)) {
        // TID manquant : la carte sera reconnue au prochain passage.
        if (tag.tid.isEmpty) return;
        notice = 'Carte non reconnue. Adressez-vous à l’accueil.';
        _seen.add(epc);
        return;
      }
      final book = await library.database.bookForTag(epc, tag.tid);
      if (session != _session) return;
      if (book == null) {
        _seen.add(epc);
        if (!_idle) _unknown.add(epc);
        return;
      }
      final loan = await library.database.activeLoanForBook(book.id);
      if (session != _session) return;
      if (_idle) {
        // Un livre emprunté posé seul est rendu ; sinon il sera emprunté.
        _beginSession(loan != null ? KioskStage.giveBack : KioskStage.borrow);
        session = _session;
      }
      _items[epc] = KioskItem(epc: epc, book: book, loan: loan);
      _seen.add(epc);
      _restartIdleTimer();
      _announce(epc);
      debugPrint(
        'Poste : livre ${book.accession} pris en compte en '
        '${timer.elapsedMilliseconds} ms (RSSI ${tag.rssi}).',
      );
    } catch (error) {
      notice = _describe(error);
    } finally {
      _pending.remove(epc);
      if (active) notifyListeners();
    }
  }

  /// `true` si la carte ouvre l'emprunt de cet abonné.
  Future<bool> _onCard(Subscriber card) async {
    if (stage == KioskStage.giveBack) {
      notice = 'Aucune carte n’est nécessaire pour rendre des livres.';
      return false;
    }
    final current = subscriber;
    if (current != null) {
      if (current.id != card.id) {
        notice = 'Une autre carte a été détectée ; elle est ignorée.';
      }
      return false;
    }
    subscriber = card;
    borrower = await library.database.borrowerStatus(
      card.id,
      maxLoans: maxLoans,
    );
    notice = null;
    _restartIdleTimer();
    return true;
  }

  /// Accueil ou consultation : une carte ou un livre posé ouvre la session
  /// correspondante.
  bool get _idle => stage == KioskStage.home || stage == KioskStage.browse;

  void _trackPresence(String epc, DateTime now) {
    final previous = _lastSeen[epc];
    _lastSeen[epc] = now;
    final rearmAfter = _releaseAfter + Duration(seconds: beepRearmSeconds);
    // Retiré assez longtemps : le tag pourra de nouveau bipper.
    if (previous != null && now.difference(previous) >= rearmAfter) {
      _beeped.remove(epc);
    }
    if (previous != null) {
      final gap = now.difference(previous).inMilliseconds;
      if (gap < _releaseAfter.inMilliseconds) {
        // Le tag n'a pas bougé : on retient son plus long silence, oublié
        // peu à peu (moitié en ~70 lectures).
        final remembered = ((_readGapMs[epc] ?? 0) * 0.99).round();
        _readGapMs[epc] = math.max(gap, remembered);
      } else {
        _readGapMs.remove(epc);
      }
    }
    if (_lastSeen.length > 500) {
      _lastSeen.removeWhere((_, seen) => now.difference(seen) >= rearmAfter);
      _beeped.removeWhere((key) => !_lastSeen.containsKey(key));
      _readGapMs.removeWhere((key, _) => !_lastSeen.containsKey(key));
    }
  }

  /// Silence au-delà duquel [epc] est considéré retiré : [presenceMs] pour
  /// un tag lu régulièrement, plus long pour un tag qui décroche par
  /// moments, sans dépasser absence + confirmation.
  Duration _absentAfter(String epc) {
    final tolerated = ((_readGapMs[epc] ?? 0) * 1.5).round();
    return Duration(
      milliseconds: tolerated.clamp(presenceMs, presenceMs + releaseMs),
    );
  }

  /// Retire de l'écran les livres, étiquettes inconnues et la carte que le
  /// lecteur ne voit plus depuis [_absentAfter] : un livre mal lu qui
  /// réapparaît est simplement relu, sans bip ni nouvelle session.
  void _dropAbsentItems() {
    final card = _cardEpc;
    if (!active ||
        processing ||
        (_items.isEmpty && _unknown.isEmpty && card == null)) {
      return;
    }
    if (stage != KioskStage.borrow && stage != KioskStage.giveBack) return;
    final now = DateTime.now();
    final absent = [
      for (final epc in [..._items.keys, ..._unknown, ?card])
        if (now.difference(_lastSeen[epc] ?? now) >= _absentAfter(epc)) epc,
    ];
    if (absent.isEmpty) return;
    for (final epc in absent) {
      debugPrint(
        'Poste : tag $epc retiré après '
        '${now.difference(_lastSeen[epc] ?? now).inMilliseconds} ms sans '
        'lecture (seuil ${_absentAfter(epc).inMilliseconds} ms).',
      );
      _items.remove(epc);
      _unknown.remove(epc);
      _seen.remove(epc);
    }
    final cardRemoved = card != null && absent.contains(card);
    unawaited(_playRemovalTone(cardRemoved ? 'card' : 'book'));
    if (cardRemoved) {
      _cardEpc = null;
      subscriber = null;
      borrower = null;
      // Carte et livres retirés : l'abonné est parti.
      if (_items.isEmpty && _unknown.isEmpty) return _goHome();
    }
    notice = null;
    _restartIdleTimer();
    notifyListeners();
  }

  /// Un bip par tag nouvellement posé ; plusieurs tags posés ensemble
  /// n'en déclenchent qu'un. Un tag resté posé (ou qui clignote) ne rebipe
  /// pas avant son retrait confirmé et le délai de réarmement.
  void _announce(String epc) {
    if (!_beeped.add(epc)) return;
    _beepTimer ??= Timer(_beepGrouping, () {
      _beepTimer = null;
      unawaited(_beep());
    });
  }

  /// Relit l'éligibilité et l'état des livres après un refus.
  Future<void> _refreshSession() async {
    final member = subscriber;
    if (member != null) {
      borrower = await library.database.borrowerStatus(
        member.id,
        maxLoans: maxLoans,
      );
    }
    for (final entry in _items.entries.toList()) {
      final book = await library.database.getBook(entry.value.book.id);
      if (book == null) {
        _items.remove(entry.key);
        continue;
      }
      _items[entry.key] = KioskItem(
        epc: entry.key,
        book: book,
        loan: await library.database.activeLoanForBook(book.id),
      );
    }
  }

  void _beginSession(KioskStage next) {
    _receiptTimer?.cancel();
    _resetSession();
    stage = next;
    _restartIdleTimer();
    notifyListeners();
  }

  void _resetSession() {
    _session++;
    _items.clear();
    _seen.clear();
    _pending.clear();
    subscriber = null;
    _cardEpc = null;
    borrower = null;
    _unknown.clear();
    notice = null;
    receipt = null;
  }

  /// Retour à l'accueil. Les tags encore posés ne relancent pas de session
  /// tant qu'ils ne sont pas retirés.
  void _goHome({bool linger = true}) {
    _idleTimer?.cancel();
    _receiptTimer?.cancel();
    final now = DateTime.now();
    if (linger) {
      for (final epc in _seen) {
        _lingering[epc] = now;
      }
    } else {
      _lingering.clear();
    }
    _resetSession();
    stage = KioskStage.home;
    notifyListeners();
  }

  void _showReceipt(KioskReceipt next) {
    // Les tags de la session restent ignorés jusqu'à leur retrait.
    final now = DateTime.now();
    for (final epc in _seen) {
      _lingering[epc] = now;
    }
    _idleTimer?.cancel();
    receipt = next;
    stage = KioskStage.receipt;
    receiptSecondsLeft = receiptDuration.inSeconds;
    _receiptTimer?.cancel();
    _receiptTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      receiptSecondsLeft--;
      if (receiptSecondsLeft <= 0) {
        timer.cancel();
        _goHome();
      } else {
        notifyListeners();
      }
    });
    unawaited(_beep());
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    if (stage == KioskStage.home || stage == KioskStage.receipt) return;
    _idleTimer = Timer(sessionTimeout, () {
      if (active && !processing) _goHome();
    });
  }

  Future<Map<Object?, Object?>> _connect() async {
    connecting = true;
    readerError = null;
    notifyListeners();
    try {
      final info = await reader.connect(
        transport: transport,
        endpoint: endpoint,
      );
      await library.database.addActivity(
        'connexion',
        'succes',
        'Lecteur du poste d’emprunt connecté (${transport.toUpperCase()})',
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
        if (transport != 'simulation' && endpoint.isEmpty) {
          throw StateError(
            'Configurez le lecteur de bureau dans le terminal admin.',
          );
        }
        await _connect();
      }
      if (!reader.reading) await reader.startInventory(power: power);
      readerError = null;
    } catch (error) {
      readerError = _describe(error);
      _scheduleReconnect();
    }
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (!active || (transport != 'simulation' && endpoint.isEmpty)) return;
    _reconnectTimer = Timer(const Duration(seconds: 10), _ensureReading);
  }

  void _onReaderError(Object error) {
    readerError = _describe(error);
    if (active && !reader.connected) _scheduleReconnect();
    notifyListeners();
  }

  Future<void> _beep() async {
    if (beepSource == 'off') return;
    var played = false;
    if (beepSource != 'tablet') played = await reader.beep();
    // Son de la tablette demandé, ou buzzer du lecteur indisponible.
    if (beepSource != 'reader' || !played) {
      try {
        await library.reader.playScanBeep();
      } catch (error) {
        debugPrint('Bip du poste indisponible : $error');
      }
    }
  }

  /// Son de retrait d'une carte ou d'un livre, joué par la tablette : le
  /// buzzer du lecteur ne sait faire qu'un bip.
  Future<void> _playRemovalTone(String kind) async {
    if (beepSource == 'off') return;
    try {
      await reader.playRemovalTone(kind);
    } catch (error) {
      debugPrint('Son de retrait indisponible : $error');
    }
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

  static String _hash(String pin) =>
      sha256.convert(utf8.encode('bibliorfid-kiosk:$pin')).toString();

  bool _disposed = false;

  /// Une lecture en cours peut se terminer après la fermeture du poste.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _beepTimer?.cancel();
    _idleTimer?.cancel();
    _receiptTimer?.cancel();
    _reconnectTimer?.cancel();
    _presenceTimer?.cancel();
    unawaited(_tagSubscription.cancel());
    unawaited(reader.dispose());
    super.dispose();
  }
}
