// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The body outlines as SVG path data, read once into moves, lines, cubics
   and quads (arcs as cubics). The same outline gives a Flutter Path for the
   canvas and polygons for the material's raster, which is made in pure Dart
   so it can run off the UI isolate. */

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Path;

const _move = 0, _line = 1, _cubic = 2, _quad = 3, _close = 4;

/// A parsed outline in the 100×100 body box.
class BotAvatarOutline {
  BotAvatarOutline._(this._ops);

  /// Parses absolute SVG path data (M L H V C Q A Z), as the stock outlines use.
  factory BotAvatarOutline.parse(String d) {
    final tokens = RegExp(
      r'[MLHVCQAZ]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?',
      caseSensitive: false,
    ).allMatches(d).map((m) => m[0]!).toList();
    final ops = <double>[];
    var i = 0, x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
    var cmd = 'M';
    double next() => double.parse(tokens[i++]);
    while (i < tokens.length) {
      final t = tokens[i];
      if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
        cmd = t.toUpperCase();
        i++;
        if (cmd == 'Z') {
          ops.add(_close.toDouble());
          x = sx;
          y = sy;
          continue;
        }
      }
      switch (cmd) {
        case 'M':
          x = sx = next();
          y = sy = next();
          ops.addAll([_move.toDouble(), x, y]);
          cmd = 'L';
        case 'L':
          x = next();
          y = next();
          ops.addAll([_line.toDouble(), x, y]);
        case 'H':
          x = next();
          ops.addAll([_line.toDouble(), x, y]);
        case 'V':
          y = next();
          ops.addAll([_line.toDouble(), x, y]);
        case 'C':
          final x1 = next(), y1 = next(), x2 = next(), y2 = next();
          x = next();
          y = next();
          ops.addAll([_cubic.toDouble(), x1, y1, x2, y2, x, y]);
        case 'Q':
          final x1 = next(), y1 = next();
          x = next();
          y = next();
          ops.addAll([_quad.toDouble(), x1, y1, x, y]);
        case 'A':
          final rx = next(), ry = next(), rot = next(), large = next() != 0, sweep = next() != 0;
          final x2 = next(), y2 = next();
          _arc(ops, x, y, rx, ry, rot, large, sweep, x2, y2);
          x = x2;
          y = y2;
        default:
          throw FormatException('Unsupported path command $cmd');
      }
    }
    return BotAvatarOutline._(ops);
  }

  final List<double> _ops;

  /// The outline as a Flutter path (non-zero fill, as SVG's default).
  Path toPath() {
    final p = Path();
    var i = 0;
    while (i < _ops.length) {
      switch (_ops[i].toInt()) {
        case _move:
          p.moveTo(_ops[i + 1], _ops[i + 2]);
          i += 3;
        case _line:
          p.lineTo(_ops[i + 1], _ops[i + 2]);
          i += 3;
        case _cubic:
          p.cubicTo(_ops[i + 1], _ops[i + 2], _ops[i + 3], _ops[i + 4], _ops[i + 5], _ops[i + 6]);
          i += 7;
        case _quad:
          p.quadraticBezierTo(_ops[i + 1], _ops[i + 2], _ops[i + 3], _ops[i + 4]);
          i += 5;
        default:
          p.close();
          i += 1;
      }
    }
    return p;
  }

  /// The closed contours, flattened to within about a tenth of a unit.
  List<Float64List> polygons() {
    final out = <Float64List>[];
    var cur = <double>[];
    var x = 0.0, y = 0.0;
    void flush() {
      if (cur.length >= 6) out.add(Float64List.fromList(cur));
      cur = <double>[];
    }

    var i = 0;
    while (i < _ops.length) {
      switch (_ops[i].toInt()) {
        case _move:
          flush();
          x = _ops[i + 1];
          y = _ops[i + 2];
          cur.addAll([x, y]);
          i += 3;
        case _line:
          x = _ops[i + 1];
          y = _ops[i + 2];
          cur.addAll([x, y]);
          i += 3;
        case _cubic:
          final x1 = _ops[i + 1], y1 = _ops[i + 2], x2 = _ops[i + 3], y2 = _ops[i + 4], x3 = _ops[i + 5];
          final y3 = _ops[i + 6];
          final len = _dist(x, y, x1, y1) + _dist(x1, y1, x2, y2) + _dist(x2, y2, x3, y3);
          final n = (len / 0.6).ceil().clamp(2, 48);
          for (var s = 1; s <= n; s++) {
            final t = s / n, q = 1 - t;
            cur.add(q * q * q * x + 3 * q * q * t * x1 + 3 * q * t * t * x2 + t * t * t * x3);
            cur.add(q * q * q * y + 3 * q * q * t * y1 + 3 * q * t * t * y2 + t * t * t * y3);
          }
          x = x3;
          y = y3;
          i += 7;
        case _quad:
          final x1 = _ops[i + 1], y1 = _ops[i + 2], x2 = _ops[i + 3], y2 = _ops[i + 4];
          final n = ((_dist(x, y, x1, y1) + _dist(x1, y1, x2, y2)) / 0.6).ceil().clamp(2, 48);
          for (var s = 1; s <= n; s++) {
            final t = s / n, q = 1 - t;
            cur.add(q * q * x + 2 * q * t * x1 + t * t * x2);
            cur.add(q * q * y + 2 * q * t * y1 + t * t * y2);
          }
          x = x2;
          y = y2;
          i += 5;
        default:
          i += 1;
      }
    }
    flush();
    return out;
  }

  /// Each subpath as an outline of its own (the author's thin parts: each
  /// piece rounds on its own).
  static List<BotAvatarOutline> parts(String d) =>
      d.split(RegExp(r'(?=M)')).where((s) => s.trim().isNotEmpty).map(BotAvatarOutline.parse).toList(growable: false);
}

double _dist(double ax, double ay, double bx, double by) => math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));

/* An SVG endpoint arc as cubics (the SVG spec's centre parametrisation, split
   into quarter turns at most). */
void _arc(
  List<double> ops,
  double x1,
  double y1,
  double rx,
  double ry,
  double rotDeg,
  bool large,
  bool sweep,
  double x2,
  double y2,
) {
  if (x1 == x2 && y1 == y2) return;
  rx = rx.abs();
  ry = ry.abs();
  if (rx == 0 || ry == 0) {
    ops.addAll([_line.toDouble(), x2, y2]);
    return;
  }
  final phi = rotDeg * math.pi / 180, cp = math.cos(phi), sp = math.sin(phi);
  final dx2 = (x1 - x2) / 2, dy2 = (y1 - y2) / 2;
  final x1p = cp * dx2 + sp * dy2, y1p = -sp * dx2 + cp * dy2;
  final lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    final s = math.sqrt(lambda);
    rx *= s;
    ry *= s;
  }
  final num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  final den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  final coef = (large == sweep ? -1 : 1) * math.sqrt(math.max(0, num / den));
  final cxp = coef * (rx * y1p / ry), cyp = coef * (-ry * x1p / rx);
  final cx = cp * cxp - sp * cyp + (x1 + x2) / 2, cy = sp * cxp + cp * cyp + (y1 + y2) / 2;
  double angle(double ux, double uy, double vx, double vy) {
    final a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    return a;
  }

  final th1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  var dth = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!sweep && dth > 0) dth -= 2 * math.pi;
  if (sweep && dth < 0) dth += 2 * math.pi;
  final n = (dth.abs() / (math.pi / 2) - 1e-9).ceil().clamp(1, 8);
  final d = dth / n, k = 4 / 3 * math.tan(d / 4);
  (double, double) at(double t) =>
      (cx + rx * cp * math.cos(t) - ry * sp * math.sin(t), cy + rx * sp * math.cos(t) + ry * cp * math.sin(t));
  (double, double) dir(double t) =>
      (-rx * cp * math.sin(t) - ry * sp * math.cos(t), -rx * sp * math.sin(t) + ry * cp * math.cos(t));
  for (var s = 0; s < n; s++) {
    final a = th1 + d * s, b = a + d;
    final (ax, ay) = at(a);
    final (bx, by) = at(b);
    final (dax, day) = dir(a);
    final (dbx, dby) = dir(b);
    final last = s == n - 1;
    ops.addAll([
      _cubic.toDouble(),
      ax + k * dax,
      ay + k * day,
      bx - k * dbx,
      by - k * dby,
      last ? x2 : bx,
      last ? y2 : by,
    ]);
  }
}
