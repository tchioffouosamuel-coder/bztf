import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/library_controller.dart';
import '../services/locator_direction.dart';

class LocatorScreen extends StatelessWidget {
  const LocatorScreen({
    required this.controller,
    required this.onChooseBook,
    super.key,
  });

  final LibraryController controller;
  final VoidCallback onChooseBook;

  @override
  Widget build(BuildContext context) {
    final book = controller.locatorBook;
    if (book == null) {
      return Center(
        child: FilledButton.icon(
          onPressed: onChooseBook,
          icon: const Icon(Icons.search),
          label: const Text('Choisir un livre'),
        ),
      );
    }

    final tag = controller.locatorTag;
    final live = controller.locatorSignalLive;
    final reading = controller.reading;
    final strength = controller.locatorSignal.strength;
    final confidence = controller.locatorSignal.confidence;
    final colors = Theme.of(context).colorScheme;
    final signalColor = live
        ? _strengthColor(strength, colors)
        : colors.outline;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Localiser un livre',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    controller.transport == 'serial'
                        ? 'Maintenez la gâchette et balayez lentement le rayon.'
                        : 'Lancez la lecture et balayez lentement le rayon.',
                  ),
                ],
              ),
            ),
            IconButton.outlined(
              tooltip: 'Choisir un autre livre',
              onPressed: onChooseBook,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LIVRE RECHERCHÉ',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  book.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${book.accession} · ${book.author.isEmpty ? 'Auteur non renseigné' : book.author}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (book.shelf.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 18,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          book.shelf,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            child: Column(
              children: [
                Text(
                  _stateTitle(
                    reading: reading,
                    live: live,
                    hasSignal: tag != null,
                    strength: strength,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: live ? signalColor : null,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _stateMessage(
                    reading: reading,
                    live: live,
                    hasSignal: tag != null,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                _DirectionRadar(
                  direction: controller.locatorDirection,
                  strength: strength,
                  hasSignal: tag != null,
                  live: live,
                ),
                const SizedBox(height: 14),
                _SignalBar(strength: tag == null ? 0 : strength, live: live),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    _Metric(
                      label: 'Signal lissé',
                      value: tag == null ? '--' : '${tag.rssi} dBm',
                    ),
                    _Metric(
                      label: 'Confiance',
                      value: tag == null
                          ? '--'
                          : '${(confidence * 100).round()} %',
                    ),
                    _Metric(
                      label: 'Mesures',
                      value: '${controller.locatorSignal.sampleCount}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!controller.readerConnected) ...[
          const SizedBox(height: 14),
          const Card(
            child: ListTile(
              leading: Icon(Icons.sensors_off),
              title: Text('Lecteur RFID non connecté'),
              subtitle: Text(
                'Connectez le lecteur pour commencer la recherche.',
              ),
            ),
          ),
        ] else if (controller.transport != 'serial') ...[
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: reading
                ? controller.stopInventory
                : controller.startInventory,
            icon: Icon(reading ? Icons.stop : Icons.play_arrow),
            label: Text(
              reading ? 'Arrêter la recherche' : 'Démarrer la recherche',
            ),
          ),
        ],
      ],
    );
  }

  static Color _strengthColor(double strength, ColorScheme colors) {
    if (strength >= .72) return colors.primary;
    if (strength >= .42) return const Color(0xFFB26A00);
    return colors.error;
  }

  static String _stateTitle({
    required bool reading,
    required bool live,
    required bool hasSignal,
    double strength = 0,
  }) {
    if (live) return 'Tag trouvé · ${_proximityLabel(strength)}';
    if (reading && hasSignal) return 'Signal perdu';
    if (reading) return 'Recherche ciblée en cours';
    if (hasSignal) return 'Dernière zone détectée';
    return 'Prêt à rechercher';
  }

  static String _stateMessage({
    required bool reading,
    required bool live,
    required bool hasSignal,
  }) {
    if (live) {
      return 'Le point jaune indique la direction du livre ; il se rapproche '
          'du centre quand le signal augmente.';
    }
    if (reading && hasSignal) {
      return 'Revenez vers la dernière zone puis pointez le lecteur devant vous.';
    }
    if (reading) return 'Seul le tag de ce livre est recherché.';
    if (hasSignal) {
      return 'Maintenez à nouveau la gâchette pour actualiser la proximité.';
    }
    return 'Pointez le lecteur vers les rayons puis maintenez la gâchette.';
  }

  static String _proximityLabel(double strength) {
    if (strength >= .86) return 'très proche';
    if (strength >= .68) return 'proche';
    if (strength >= .42) return 'à proximité';
    return 'éloigné';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
    ],
  );
}

/// Radar orienté nord comme la démo du terminal : secteur bleu = direction
/// visée par le lecteur, point jaune = livre (plus il est proche du centre,
/// plus le signal est fort), traces bleues = force mesurée dans chaque
/// direction balayée.
class _DirectionRadar extends StatelessWidget {
  const _DirectionRadar({
    required this.direction,
    required this.strength,
    required this.hasSignal,
    required this.live,
  });

  final LocatorDirection direction;
  final double strength;
  final bool hasSignal;
  final bool live;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: direction,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final heading = direction.heading;
      final estimate = direction.estimate;
      final turn = direction.turn;
      final (guidance, guidanceIcon) = _guidance(
        heading: heading,
        estimate: estimate,
        turn: turn,
        compass: direction.compassAvailable,
        hasSignal: hasSignal,
      );
      return Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AspectRatio(
              aspectRatio: 1,
              child: Semantics(
                label: guidance,
                child: CustomPaint(
                  painter: _CompassRadarPainter(
                    heading: heading,
                    sectors: direction.sectors,
                    estimate: estimate,
                    strength: strength,
                    hasSignal: hasSignal,
                    live: live,
                    colors: colors,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(guidanceIcon, color: colors.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  guidance,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );

  static (String, IconData) _guidance({
    required double? heading,
    required LocatorEstimate? estimate,
    required double? turn,
    required bool compass,
    required bool hasSignal,
  }) {
    if (!compass) {
      return (
        'Boussole indisponible : suivez la force du signal.',
        Icons.explore_off_outlined,
      );
    }
    if (heading == null) {
      return ('Calibrage de la boussole…', Icons.explore_outlined);
    }
    if (estimate == null || turn == null) {
      return hasSignal
          ? (
              'Tournez lentement sur vous-même pour situer le livre.',
              Icons.threesixty,
            )
          : ('Balayez lentement les rayons autour de vous.', Icons.threesixty);
    }
    if (estimate.confidence < 0.25) {
      return (
        'Direction à confirmer : balayez de part et d’autre.',
        Icons.threesixty,
      );
    }
    final degrees = turn.abs().round();
    if (degrees <= 15) return ('Droit devant', Icons.arrow_upward);
    if (degrees >= 150) {
      return ('Derrière vous : faites demi-tour', Icons.u_turn_left);
    }
    return turn > 0
        ? ('Tournez de $degrees° à droite', Icons.turn_right)
        : ('Tournez de $degrees° à gauche', Icons.turn_left);
  }
}

/// Barre de force du signal, en pourcentage.
class _SignalBar extends StatelessWidget {
  const _SignalBar({required this.strength, required this.live});

  final double strength;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = !live
        ? colors.outline
        : strength >= .72
        ? const Color(0xFF2E9D57)
        : strength >= .42
        ? const Color(0xFFE0A100)
        : const Color(0xFFE53935);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: strength,
              minHeight: 22,
              color: color,
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 60,
          child: Text(
            '${(strength * 100).round()} %',
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _CompassRadarPainter extends CustomPainter {
  _CompassRadarPainter({
    required this.heading,
    required this.sectors,
    required this.estimate,
    required this.strength,
    required this.hasSignal,
    required this.live,
    required this.colors,
  });

  final double? heading;
  final List<double> sectors;
  final LocatorEstimate? estimate;
  final double strength;
  final bool hasSignal;
  final bool live;
  final ColorScheme colors;

  static const _dial = Color(0xFF2F6FE4);
  static const _target = Color(0xFFFFD600);

  /// Angle du canevas pour un cap (0° = nord en haut, sens horaire).
  static double _angle(double bearing) => (bearing - 90) * math.pi / 180;

  static Offset _at(Offset center, double bearing, double distance) => Offset(
    center.dx + math.cos(_angle(bearing)) * distance,
    center.dy + math.sin(_angle(bearing)) * distance,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = math.min(size.width, size.height) / 2 - 2;
    final radius = outer * .86;

    // Cadran.
    canvas.drawCircle(
      center,
      outer,
      Paint()
        ..shader = RadialGradient(
          colors: [_dial.withValues(alpha: .10), _dial.withValues(alpha: .32)],
        ).createShader(Rect.fromCircle(center: center, radius: outer)),
    );
    canvas.drawCircle(
      center,
      outer,
      Paint()
        ..color = _dial
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Force mesurée dans chaque direction balayée.
    final width = 360 / sectors.length;
    for (var index = 0; index < sectors.length; index++) {
      final value = sectors[index];
      if (value <= 0.02) continue;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * (.25 + .75 * value)),
        _angle(index * width),
        width * math.pi / 180,
        true,
        Paint()..color = _dial.withValues(alpha: .12 + .25 * value),
      );
    }

    // Direction visée par le lecteur.
    final current = heading;
    if (current != null) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: outer),
        _angle(current - 22),
        44 * math.pi / 180,
        true,
        Paint()..color = _dial.withValues(alpha: .55),
      );
    }

    // Cercles et axes.
    final grid = Paint()
      ..color = _dial.withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var ring = 1; ring <= 4; ring++) {
      canvas.drawCircle(center, radius * ring / 4, grid);
    }
    for (final bearing in const [0.0, 90.0, 180.0, 270.0]) {
      canvas.drawLine(center, _at(center, bearing, outer), grid);
    }

    // Graduations et repères.
    final ticks = Paint()
      ..color = _dial
      ..strokeWidth = 1.2;
    for (var degrees = 0; degrees < 360; degrees += 10) {
      final long = degrees % 30 == 0;
      canvas.drawLine(
        _at(center, degrees.toDouble(), outer - (long ? 10 : 5)),
        _at(center, degrees.toDouble(), outer),
        ticks,
      );
    }
    void label(String text, double bearing, double distance, double fontSize) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: _dial,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final position = _at(center, bearing, distance);
      painter.paint(
        canvas,
        position - Offset(painter.width / 2, painter.height / 2),
      );
    }

    for (final (text, bearing) in const [
      ('N', 0.0),
      ('E', 90.0),
      ('S', 180.0),
      ('O', 270.0),
    ]) {
      label(text, bearing, outer - 20, 14);
    }
    for (var degrees = 30; degrees < 360; degrees += 30) {
      if (degrees % 90 == 0) continue;
      label('$degrees', degrees.toDouble(), outer - 20, 9);
    }

    // Terminal au centre, orienté selon son cap.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate((current ?? 0) * math.pi / 180);
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 20, height: 34),
      const Radius.circular(4),
    );
    canvas.drawCircle(Offset.zero, 24, Paint()..color = colors.surface);
    canvas.drawRRect(phone, Paint()..color = const Color(0xFF263238));
    canvas.drawRect(
      Rect.fromCenter(center: const Offset(0, -2), width: 14, height: 22),
      Paint()..color = const Color(0xFF90CAF9),
    );
    canvas.drawCircle(const Offset(0, -21), 3, Paint()..color = _dial);
    canvas.restore();

    // Livre recherché.
    final target = estimate;
    if (target != null) {
      final distance = 30 + (1 - target.strength) * (radius - 38);
      final position = _at(center, target.bearing, distance);
      final alpha = live ? 1.0 : .55;
      canvas.drawCircle(
        position,
        14 + (1 - target.confidence) * 14,
        Paint()..color = _target.withValues(alpha: .25 * alpha),
      );
      canvas.drawCircle(
        position,
        11,
        Paint()..color = _target.withValues(alpha: alpha),
      );
      canvas.drawCircle(
        position,
        11,
        Paint()
          ..color = const Color(0xFFB08800).withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    } else if (hasSignal) {
      // Direction encore inconnue : distance seule, en anneau.
      canvas.drawCircle(
        center,
        30 + (1 - strength) * (radius - 38),
        Paint()
          ..color = _target.withValues(alpha: live ? .9 : .4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CompassRadarPainter oldDelegate) => true;
}
