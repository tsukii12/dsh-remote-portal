// Two small figures of view v2 (docs/design/plugin-ui-v3.md §4.2): a metric's
// trend line and a ring progress. Both are drawn by the app in the app's
// geometry; a plugin only gives numbers.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The measured geometry (`plugin_view_figures_test.dart`).
abstract final class DshUiFigureMetrics {
  static const trendHeight = 24.0;
  static const trendStroke = 1.5;
  static const trendDot = 4.0;

  static const ringSize = 64.0;
  static const ringStroke = 6.0;
}

/// A trend under a metric's value: as wide as the metric, 24 high, no axes.
/// Nulls break the line; the last point gets a dot.
class DshUiTrendLine extends StatelessWidget {
  const DshUiTrendLine({super.key, required this.points, required this.color});

  final List<double?> points;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('dsh-ui-trend'),
    height: DshUiFigureMetrics.trendHeight,
    width: double.infinity,
    child: CustomPaint(painter: _TrendPainter(points, color)),
  );
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points, this.color);

  final List<double?> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final values = points.whereType<double>();
    if (values.length < 2 || points.length < 2) return;
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    // Room for half the dot at either end, so the line ends inside the box.
    const inset = DshUiFigureMetrics.trendDot / 2;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;
    Offset at(int i, double v) =>
        Offset(inset + w * i / (points.length - 1), inset + (hi == lo ? h / 2 : h * (1 - (v - lo) / (hi - lo))));
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = DshUiFigureMetrics.trendStroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    var open = false;
    Offset? last;
    for (var i = 0; i < points.length; i++) {
      final v = points[i];
      if (v == null) {
        open = false;
        continue;
      }
      final p = at(i, v);
      if (open) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
        open = true;
      }
      last = p;
    }
    canvas.drawPath(path, line);
    if (last != null) canvas.drawCircle(last, DshUiFigureMetrics.trendDot / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.color != color || !_same(old.points, points);

  static bool _same(List<double?> a, List<double?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A ring progress: 64 across, 6 thick, the figure in the middle (tabular
/// digits), the label centred under it.
class DshUiRing extends StatelessWidget {
  const DshUiRing({
    super.key,
    required this.fraction,
    required this.shown,
    required this.color,
    required this.track,
    this.label,
  });

  /// 0–1; null draws only the track.
  final double? fraction;
  final String shown;
  final Color color;
  final Color track;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final figure = AppType.tabular(theme.textTheme.titleSmall!.copyWith(color: colors.onSurface));
    return Semantics(
      container: true,
      label: label == null ? shown : '$label $shown',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              key: const ValueKey('dsh-ui-ring'),
              dimension: DshUiFigureMetrics.ringSize,
              child: CustomPaint(
                painter: _RingPainter(fraction, color, track),
                child: Center(
                  child: Padding(
                    // The figure's box stays inside the ring's hole.
                    padding: const EdgeInsets.all(DshUiFigureMetrics.ringStroke + 4),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(shown, maxLines: 1, style: figure),
                    ),
                  ),
                ),
              ),
            ),
            if (label case final label?) ...[
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color, this.track);

  final double? fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = DshUiFigureMetrics.ringStroke;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: (size.shortestSide - stroke) / 2);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final f = fraction;
    if (f == null || f <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = f >= 1 ? StrokeCap.butt : StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * f.clamp(0.0, 1.0), false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color || old.track != track;
}
