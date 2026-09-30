import '../models/staff.dart';

/// Sens de passage déduit de l'ordre de coupure des deux barrières
/// infrarouges du portail (entrées GPI) : barrière extérieure puis
/// intérieure = entrée, l'inverse = sortie.
///
/// Le niveau « au repos » de chaque barrière est relevé à la connexion ; à
/// défaut, le premier changement signalé est pris pour une coupure. Seul le
/// passage du repos à la coupure compte.
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

  void reset() {
    _outsideAt = null;
    _insideAt = null;
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
    final idle = _idle.putIfAbsent(
      sensor,
      () => previous ?? (level == 0 ? 1 : 0),
    );
    final wasCut = (previous ?? idle) != idle;
    if (level == idle || wasCut || !enabled) return null;
    bool recent(DateTime? cut) => cut != null && at.difference(cut) <= window;
    if (sensor == outsideSensor) {
      if (recent(_insideAt)) {
        reset();
        return PassageDirection.exit;
      }
      _outsideAt = at;
    } else {
      if (recent(_outsideAt)) {
        reset();
        return PassageDirection.entry;
      }
      _insideAt = at;
    }
    return null;
  }
}
