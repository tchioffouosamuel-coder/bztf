import '../models/staff.dart';

/// Sens de passage déduit de l'ordre de coupure des deux barrières
/// infrarouges du portail (entrées GPI) : barrière extérieure puis
/// intérieure = entrée, l'inverse = sortie.
///
/// Le niveau « au repos » de chaque barrière est relevé à la connexion ; à
/// défaut, il vaut 0. Seul le passage du repos à la coupure compte.
class GateDirectionTracker {
  GateDirectionTracker({
    required this.outsideSensor,
    required this.insideSensor,
    this.window = const Duration(milliseconds: 2500),
  });

  /// Entrée GPI de la barrière côté extérieur (0 : aucune).
  int outsideSensor;

  /// Entrée GPI de la barrière côté intérieur (0 : aucune).
  int insideSensor;

  /// Délai maximal entre les deux coupures d'un même passage.
  Duration window;

  final Map<int, int> _idle = {};
  final Map<int, int> _level = {};
  DateTime? _outsideAt;
  DateTime? _insideAt;

  /// Passage compté : les rebonds des barrières sont ignorés jusqu'à ce que
  /// les deux soient de nouveau libres.
  bool _awaitingClear = false;

  bool get enabled =>
      outsideSensor > 0 && insideSensor > 0 && outsideSensor != insideSensor;

  /// Dernier niveau connu de chaque entrée (affichage du test des capteurs).
  Map<int, int> get levels => Map.unmodifiable(_level);

  /// `true` si la barrière est coupée d'après son niveau au repos.
  bool isActive(int sensor) {
    final level = _level[sensor];
    final idle = _idle[sensor];
    return level != null && idle != null && level != idle;
  }

  /// Niveaux relevés à la connexion (valeur négative : inconnu).
  void setIdleLevels(Map<int, int> levels) {
    _idle.clear();
    _level.clear();
    for (final entry in levels.entries) {
      if (entry.value < 0) continue;
      _idle[entry.key] = entry.value;
      _level[entry.key] = entry.value;
    }
    reset();
  }

  /// Niveau relevé hors surveillance (terminal admin) : affiché, jamais
  /// compté.
  void observe(int sensor, int level) => _level[sensor] = level;

  void reset() {
    _outsideAt = null;
    _insideAt = null;
    _awaitingClear = false;
  }

  bool _isIdle(int sensor) {
    final idle = _idle[sensor];
    return idle == null || _level[sensor] == null || _level[sensor] == idle;
  }

  PassageDirection _counted(PassageDirection direction) {
    reset();
    _awaitingClear = true;
    return direction;
  }

  /// Traite un changement de niveau ; renvoie le sens quand un passage
  /// complet est reconnu.
  PassageDirection? onLevel(int sensor, int level, DateTime at) {
    if (sensor != outsideSensor && sensor != insideSensor) {
      _level[sensor] = level;
      return null;
    }
    final previous = _level[sensor];
    _level[sensor] = level;
    // Niveau au repos inconnu : 0, celui du portail N01 (« gpis »
    // 0000000 sans personne), plutôt qu'un niveau relevé pendant une
    // coupure.
    final idle = _idle.putIfAbsent(sensor, () => 0);
    final wasCut = (previous ?? idle) != idle;
    if (_awaitingClear) {
      if (_isIdle(outsideSensor) && _isIdle(insideSensor)) {
        _awaitingClear = false;
      }
      return null;
    }
    if (level == idle || wasCut || !enabled) return null;
    bool recent(DateTime? cut) => cut != null && at.difference(cut) <= window;
    if (sensor == outsideSensor) {
      if (recent(_insideAt)) return _counted(PassageDirection.exit);
      _outsideAt = at;
    } else {
      if (recent(_outsideAt)) return _counted(PassageDirection.entry);
      _insideAt = at;
    }
    return null;
  }
}
