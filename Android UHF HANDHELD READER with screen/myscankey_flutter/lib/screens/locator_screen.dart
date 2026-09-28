import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/library_controller.dart';

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
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 310),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Semantics(
                      label: tag == null
                          ? 'Aucun signal RFID'
                          : 'Proximité ${_proximityLabel(strength)}',
                      child: CustomPaint(
                        painter: _RadarPainter(
                          strength: strength,
                          confidence: confidence,
                          hasSignal: tag != null,
                          live: live,
                          colors: colors,
                        ),
                      ),
                    ),
                  ),
                ),
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
      return 'Le point rouge se rapproche du centre lorsque le signal augmente.';
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

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.strength,
    required this.confidence,
    required this.hasSignal,
    required this.live,
    required this.colors,
  });

  final double strength;
  final double confidence;
  final bool hasSignal;
  final bool live;
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * .42;
    final grid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: .72)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fill = Paint()
      ..color = colors.surfaceContainerLow
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, fill);

    final sector = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(
        center.dx + math.cos(-math.pi * .68) * radius,
        center.dy + math.sin(-math.pi * .68) * radius,
      )
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi * .68,
        math.pi * .36,
        false,
      )
      ..close();
    canvas.drawPath(
      sector,
      Paint()
        ..color = colors.primary.withValues(alpha: .08)
        ..style = PaintingStyle.fill,
    );

    for (var ring = 1; ring <= 4; ring++) {
      canvas.drawCircle(center, radius * ring / 4, grid);
    }
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4;
      canvas.drawLine(
        center,
        Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        ),
        grid,
      );
    }

    final forwardPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center,
      Offset(center.dx, center.dy - radius),
      forwardPaint,
    );

    canvas.drawCircle(
      center,
      10,
      Paint()..color = colors.primary.withValues(alpha: .18),
    );
    canvas.drawCircle(center, 4, Paint()..color = colors.primary);

    if (hasSignal) {
      final targetRadius = 18 + ((1 - strength) * (radius - 30));
      final target = Offset(center.dx, center.dy - targetRadius);
      final alpha = live ? 1.0 : .46;
      final haloRadius = 20 + ((1 - confidence) * 15);
      canvas.drawCircle(
        target,
        haloRadius,
        Paint()..color = const Color(0xFFD64545).withValues(alpha: .12 * alpha),
      );
      canvas.drawCircle(
        target,
        10,
        Paint()
          ..color = colors.surface
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        target,
        7,
        Paint()..color = const Color(0xFFD64545).withValues(alpha: alpha),
      );
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'AVANT',
        style: TextStyle(
          color: colors.primary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy - radius - 19),
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.strength != strength ||
      oldDelegate.confidence != confidence ||
      oldDelegate.hasSignal != hasSignal ||
      oldDelegate.live != live ||
      oldDelegate.colors != colors;
}
