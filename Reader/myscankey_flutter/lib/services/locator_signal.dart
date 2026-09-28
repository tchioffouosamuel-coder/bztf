class LocatorSignalTracker {
  LocatorSignalTracker({this.windowSize = 7, this.smoothing = 0.38});

  final int windowSize;
  final double smoothing;
  final List<int> _window = [];
  double? _smoothedRssi;
  double _spread = 0;
  int _sampleCount = 0;

  int get sampleCount => _sampleCount;
  int? get rssi => _smoothedRssi?.round();
  double get strength =>
      _smoothedRssi == null ? 0 : normalizeRssi(_smoothedRssi!);

  double get confidence {
    if (_sampleCount == 0) return 0;
    final history = (_sampleCount / windowSize).clamp(0.0, 1.0);
    final stability = (1 - (_spread / 28)).clamp(0.0, 1.0);
    return (history * (0.55 + (0.45 * stability))).clamp(0.0, 1.0);
  }

  void add(int rawRssi) {
    _window.add(rawRssi);
    if (_window.length > windowSize) _window.removeAt(0);
    _sampleCount++;

    final sorted = [..._window]..sort();
    final middle = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[middle].toDouble()
        : (sorted[middle - 1] + sorted[middle]) / 2;
    _smoothedRssi = _smoothedRssi == null
        ? median
        : (_smoothedRssi! * (1 - smoothing)) + (median * smoothing);
    _spread = (sorted.last - sorted.first).abs().toDouble();
  }

  void reset() {
    _window.clear();
    _smoothedRssi = null;
    _spread = 0;
    _sampleCount = 0;
  }

  static double normalizeRssi(double rssi) {
    if (rssi < 0) {
      return ((rssi + 85) / 75).clamp(0.0, 1.0);
    }
    if (rssi == 0) return 0;
    return ((rssi - 15) / 85).clamp(0.0, 1.0);
  }
}
