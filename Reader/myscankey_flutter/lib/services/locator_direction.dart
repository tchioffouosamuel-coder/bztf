import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Direction estimée d'un livre recherché.
class LocatorEstimate {
  const LocatorEstimate({
    required this.bearing,
    required this.strength,
    required this.confidence,
  });

  /// Cap du livre en degrés (0 = nord, sens horaire).
  final double bearing;

  /// Force du signal dans cette direction (0 à 1).
  final double strength;

  /// Fiabilité de la direction (0 à 1) : écart avec les autres directions
  /// balayées et nombre de directions essayées.
  final double confidence;
}

/// Radar de localisation : le lecteur n'a qu'une antenne, la direction vient
/// de la boussole du terminal. Chaque lecture du tag est rangée dans le
/// secteur du cap pointé ; le livre est vers le secteur où le signal est le
/// plus fort. Les mesures s'estompent quand on se déplace, et pointer une
/// direction sans lire le tag l'affaiblit.
class LocatorDirection extends ChangeNotifier {
  LocatorDirection({
    DateTime Function()? clock,
    this.sectorCount = 24,
    this.memory = const Duration(seconds: 12),
  }) : _clock = clock ?? DateTime.now,
       _strength = List.filled(sectorCount, 0),
       _samples = List.filled(sectorCount, 0),
       _updatedAt = List.filled(sectorCount, null);

  final DateTime Function() _clock;
  final int sectorCount;

  /// Durée au bout de laquelle une mesure ne compte plus qu'à 37 %.
  final Duration memory;
  final List<double> _strength;
  final List<int> _samples;
  final List<DateTime?> _updatedAt;
  double? _heading;
  bool compassAvailable = true;
  DateTime? _notifiedAt;

  /// Cap du terminal en degrés, `null` tant que la boussole n'a rien donné.
  double? get heading => _heading;

  double get sectorWidth => 360 / sectorCount;

  int _sector(double degrees) =>
      (_normalize(degrees) / sectorWidth).floor() % sectorCount;

  double _decayed(int index, DateTime now) {
    final at = _updatedAt[index];
    if (at == null) return 0;
    final age = now.difference(at).inMilliseconds / memory.inMilliseconds;
    return _strength[index] * math.exp(-age);
  }

  /// Force actuelle de chaque secteur (0 : non balayé ou sans signal).
  List<double> get sectors {
    final now = _clock();
    return [
      for (var index = 0; index < sectorCount; index++) _decayed(index, now),
    ];
  }

  /// Nouveau cap de la boussole ; [signalLive] faux : on pointe cette
  /// direction sans lire le tag, elle perd du poids.
  void updateHeading(double degrees, {required bool signalLive}) {
    final previous = _heading;
    _heading = _normalize(degrees);
    compassAvailable = true;
    if (!signalLive) _record(0, weight: 0.25);
    final now = _clock();
    final moved =
        previous == null || _difference(previous, _heading!).abs() >= 2;
    if (moved ||
        _notifiedAt == null ||
        now.difference(_notifiedAt!) >= const Duration(milliseconds: 250)) {
      _notifiedAt = now;
      notifyListeners();
    }
  }

  /// Lecture du tag, force normalisée (0 à 1), dans la direction pointée.
  void addSample(double strength) {
    if (_heading == null) return;
    _record(strength.clamp(0.0, 1.0), weight: 0.45);
    notifyListeners();
  }

  void _record(double value, {required double weight}) {
    final heading = _heading;
    if (heading == null) return;
    final index = _sector(heading);
    final now = _clock();
    final current = _decayed(index, now);
    _strength[index] = _samples[index] == 0
        ? value
        : current * (1 - weight) + value * weight;
    _samples[index]++;
    _updatedAt[index] = now;
  }

  LocatorEstimate? get estimate {
    final values = sectors;
    var best = 0;
    for (var index = 1; index < sectorCount; index++) {
      if (values[index] > values[best]) best = index;
    }
    final peak = values[best];
    if (peak < 0.05) return null;
    // Moyenne circulaire du secteur le plus fort et de ses voisins.
    var x = 0.0;
    var y = 0.0;
    for (final offset in const [-1, 0, 1]) {
      final index = (best + offset) % sectorCount;
      final angle = (index + 0.5) * sectorWidth * math.pi / 180;
      x += math.sin(angle) * values[index];
      y += math.cos(angle) * values[index];
    }
    final bearing = _normalize(math.atan2(x, y) * 180 / math.pi);
    final others = [
      for (var index = 0; index < sectorCount; index++)
        if (_updatedAt[index] != null && (index - best).abs() > 1)
          values[index],
    ];
    final contrast = others.isEmpty
        ? 0.0
        : (peak - others.reduce((a, b) => a + b) / others.length) / peak;
    final coverage = math.min(1.0, others.length / 6);
    return LocatorEstimate(
      bearing: bearing,
      strength: peak,
      confidence: (contrast.clamp(0.0, 1.0) * 0.7 + coverage * 0.3).clamp(
        0.0,
        1.0,
      ),
    );
  }

  /// Rotation à faire (degrés, négatif = à gauche) pour faire face au livre.
  double? get turn {
    final heading = _heading;
    final target = estimate;
    if (heading == null || target == null) return null;
    return _difference(heading, target.bearing);
  }

  void reset() {
    for (var index = 0; index < sectorCount; index++) {
      _strength[index] = 0;
      _samples[index] = 0;
      _updatedAt[index] = null;
    }
    notifyListeners();
  }

  static double _normalize(double degrees) => ((degrees % 360) + 360) % 360;

  /// Écart signé de [from] vers [to], entre -180 et 180.
  static double _difference(double from, double to) =>
      ((to - from + 540) % 360) - 180;
}
