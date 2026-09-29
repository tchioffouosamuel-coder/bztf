import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/epc.dart';
import '../models/book.dart';
import '../models/lending.dart';
import 'desk_reader_service.dart';
import 'library_controller.dart';
import 'reader_service.dart';

enum KioskStage { home, borrow, giveBack, receipt }

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

  /// Délai après lequel une carte ou un livre resté posé depuis la session
  /// précédente est considéré comme reposé.
  static const _lingerDelay = Duration(seconds: 3);

  final LibraryController library;
  final DeskReaderService reader;
  late final StreamSubscription<ReaderTag> _tagSubscription;

  // Réglages du poste.
  String transport = 'tcp';
  String endpoint = '';
  int power = 20;
  int maxLoans = 3;
  int loanDays = 14;
  String _pinHash = _hash(defaultPin);

  // État du poste.
  bool active = false;
  bool connecting = false;
  String? readerError;
  KioskStage stage = KioskStage.home;
  Subscriber? subscriber;
  BorrowerStatus? borrower;
  final Map<String, KioskItem> _items = {};
  int unknownTags = 0;
  String? notice;
  bool processing = false;
  KioskReceipt? receipt;
  int receiptSecondsLeft = 0;

  int _session = 0;
  final Set<String> _seen = {};
  final Set<String> _pending = {};
  final Map<String, DateTime> _lingering = {};
  Timer? _idleTimer;
  Timer? _receiptTimer;
  Timer? _reconnectTimer;

  bool get usesDefaultPin => _pinHash == _hash(defaultPin);
  bool get readerConnected => reader.connected;
  bool get simulation => transport == 'simulation';
  List<KioskItem> get items => _items.values.toList();

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
    _pinHash = settings.getString('kiosk_pin_hash') ?? _hash(defaultPin);
    notifyListeners();
  }

  /// Ouvre le poste : lecteur de bureau connecté et en lecture continue.
  Future<void> enter() async {
    if (active) return;
    active = true;
    library.kioskActive = true;
    _goHome(linger: false);
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
    if (!active || processing || stage == KioskStage.receipt) return;
    final epc = tag.epc.trim().toUpperCase();
    if (epc.isEmpty || epc == ReaderService.emptyEpc) return;
    final now = DateTime.now();
    final lingeredAt = _lingering[epc];
    if (lingeredAt != null) {
      if (now.difference(lingeredAt) < _lingerDelay) {
        _lingering[epc] = now;
        return;
      }
      _lingering.remove(epc);
    }
    if (_seen.contains(epc) || _pending.contains(epc)) return;
    _pending.add(epc);
    var session = _session;
    try {
      final card = await library.database.cardForTag(epc, tag.tid);
      if (session != _session) return;
      if (card != null) {
        if (stage == KioskStage.home) {
          _beginSession(KioskStage.borrow);
          session = _session;
        }
        await _onCard(card);
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
        if (stage != KioskStage.home) unknownTags++;
        return;
      }
      final loan = await library.database.activeLoanForBook(book.id);
      if (session != _session) return;
      if (stage == KioskStage.home) {
        // Un livre emprunté posé seul est rendu ; sinon il sera emprunté.
        _beginSession(loan != null ? KioskStage.giveBack : KioskStage.borrow);
        session = _session;
      }
      _items[epc] = KioskItem(epc: epc, book: book, loan: loan);
      _seen.add(epc);
      _restartIdleTimer();
      unawaited(_beep());
    } catch (error) {
      notice = _describe(error);
    } finally {
      _pending.remove(epc);
      if (active) notifyListeners();
    }
  }

  Future<void> _onCard(Subscriber card) async {
    if (stage == KioskStage.giveBack) {
      notice = 'Aucune carte n’est nécessaire pour rendre des livres.';
      return;
    }
    final current = subscriber;
    if (current != null) {
      if (current.id != card.id) {
        notice = 'Une autre carte a été détectée ; elle est ignorée.';
      }
      return;
    }
    subscriber = card;
    borrower = await library.database.borrowerStatus(
      card.id,
      maxLoans: maxLoans,
    );
    notice = null;
    _restartIdleTimer();
    unawaited(_beep());
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
    borrower = null;
    unknownTags = 0;
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
    try {
      await library.reader.playScanBeep();
    } catch (error) {
      debugPrint('Bip du poste indisponible : $error');
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

  @override
  void dispose() {
    _idleTimer?.cancel();
    _receiptTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_tagSubscription.cancel());
    unawaited(reader.dispose());
    super.dispose();
  }
}
