import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../main.dart';

class TirRingWidget extends StatelessWidget {
  final double? inRangePercent;
  final double? belowPercent;
  final double? abovePercent;
  final double size;
  final double strokeWidth;

  const TirRingWidget({
    super.key,
    required this.inRangePercent,
    required this.belowPercent,
    required this.abovePercent,
    this.size = 112,
    this.strokeWidth = 11,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = inRangePercent != null;
    final pctLabel = hasData ? '${inRangePercent!.round()}%' : '--%';

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TirArcPainter(
          inRangePercent: inRangePercent ?? 0.0,
          belowPercent: belowPercent ?? 0.0,
          abovePercent: abovePercent ?? 0.0,
          hasData: hasData,
          strokeWidth: strokeWidth,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pctLabel,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'no alvo',
                style: TextStyle(
                  fontSize: 10.5,
                  color: EspressoPalette.sandAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TirArcPainter extends CustomPainter {
  final double inRangePercent;
  final double belowPercent;
  final double abovePercent;
  final bool hasData;
  final double strokeWidth;

  const _TirArcPainter({
    required this.inRangePercent,
    required this.belowPercent,
    required this.abovePercent,
    required this.hasData,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final bgPaint = Paint()
      ..color = EspressoPalette.batteryTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    if (!hasData) return;

    final total = inRangePercent + belowPercent + abovePercent;
    if (total <= 0) return;

    const startAngle = -math.pi / 2;
    final belowSweep = (belowPercent / total) * (2 * math.pi);
    final inSweep = (inRangePercent / total) * (2 * math.pi);
    final aboveSweep = (abovePercent / total) * (2 * math.pi);

    var cursor = startAngle;

    void drawSeg(double sweep, Color color) {
      if (sweep <= 0.01) return;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, cursor, sweep, false, paint);
      cursor += sweep;
    }

    drawSeg(belowSweep, const Color(0xFFFFB4AB));
    drawSeg(inSweep, EspressoPalette.batteryFill);
    drawSeg(aboveSweep, EspressoPalette.peachAccent);
  }

  @override
  bool shouldRepaint(covariant _TirArcPainter oldDelegate) {
    return inRangePercent != oldDelegate.inRangePercent ||
        belowPercent != oldDelegate.belowPercent ||
        abovePercent != oldDelegate.abovePercent ||
        hasData != oldDelegate.hasData;
  }
}
