// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Shared primitives for the dotted 3D thought-orbs, translated from
// thinking-orbs `src/engine/core.ts`. Honestly 3D: rotated, depth-shaded,
// z-sorted; depth is carried by dot size and ink weight alone.
//
// One deliberate change of shape, not of maths: the web engine returns a
// fresh array of dot objects per frame. Here a mode writes into an
// [OrbFrame] that the orb keeps and reuses, so a running orb allocates no
// per-dot objects. The numbers and the draw order are the web engine's.

import 'dart:math' as math;
import 'dart:typed_data';

/// Draw options of one mode: the engine's knobs by name (`latRings`, `rBase`,
/// ...). A missing key means the mode's built-in default.
typedef ModeOpts = Map<String, double>;

double lerp(double a, double b, double f) => a + (b - a) * f;

double frac(double x) => x - x.floorToDouble();

/// Deterministic hash in [0, 1).
double hashD(double a, double b) {
  final h = math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - h.floorToDouble();
}

/// Value noise on a 2D lattice: smooth, deterministic, cheap.
double vnoise(double x, double y) {
  final xi = x.floorToDouble();
  final yi = y.floorToDouble();
  var fx = x - xi;
  var fy = y - yi;
  fx = fx * fx * (3 - 2 * fx);
  fy = fy * fy * (3 - 2 * fy);
  final a = hashD(xi, yi);
  final b = hashD(xi + 1, yi);
  final c = hashD(xi, yi + 1);
  final d = hashD(xi + 1, yi + 1);
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

final double _golden = math.pi * (3 - math.sqrt(5));

/// Stable direction [i] of [n] on a unit sphere (Fibonacci lattice), written
/// to `out[0..2]`.
void fibDir(int i, num n, Float64List out) {
  final y = 1 - (2 * (i + 0.5)) / n;
  final rad = math.sqrt(1 - y * y);
  final a = i * _golden;
  out[0] = rad * math.cos(a);
  out[1] = y;
  out[2] = rad * math.sin(a);
}

/// Shortest signed angular distance, wrapped to (-pi, pi].
double angleDelta(double a, double b) => math.atan2(math.sin(a - b), math.cos(a - b));

/// Dot radii were tuned for a 300px frame; sub-linear scaling keeps small
/// spinners legible. Lower pow = radii shrink less with size.
double radiusScale(double size, double pow) => math.pow(size / 300, pow).toDouble();

/// Shared spin + tilt + orthographic projection (`makeProj`). Call [set] once
/// per frame, then [call] per point and read [px], [py], [pz].
final class Projector {
  double _st = 0, _ct = 1, _sy = 0, _cyw = 1, _cx = 0, _cy = 0, _scale = 1;

  /// Projected screen x, y and depth z of the last [call].
  double px = 0, py = 0, pz = 0;

  void set(double yaw, double tilt, double cx, double cy, double scale) {
    _st = math.sin(tilt);
    _ct = math.cos(tilt);
    _sy = math.sin(yaw);
    _cyw = math.cos(yaw);
    _cx = cx;
    _cy = cy;
    _scale = scale;
  }

  void call(double x, double y, double z) {
    final x1 = x * _cyw + z * _sy;
    final z1 = -x * _sy + z * _cyw;
    final y1 = y * _ct - z1 * _st;
    final z2 = y * _st + z1 * _ct;
    px = _cx + x1 * _scale;
    py = _cy - y1 * _scale;
    pz = z2;
  }
}

/// One rendered instant, reused frame after frame.
///
/// A mode calls [begin], adds raw dots and lines, then [finalize]: invisible
/// marks dropped, radii clamped to the mode's floor, dots z-sorted far to near
/// (stable, as JavaScript's sort is). After that, dot `k` in draw order is read
/// with [x], [y], [z], [r], [white], [a]; lines draw first, nodes on top.
///
/// Ink convention: `white` is the ink on paper in [0, 1] (0 = darkest); a dark
/// substrate mirrors it so near dots read bright.
final class OrbFrame {
  static const _dotStride = 6;
  static const _lineStride = 7;

  /// Scratch the modes share: one projector and a few small buffers.
  final Projector proj = Projector();
  final Float64List v3 = Float64List(3);
  Float64List scratch = Float64List(512);

  Float64List _d = Float64List(_dotStride * 256);
  int _raw = 0;
  Float64List _l = Float64List(_lineStride * 64);
  int _lines = 0;
  final List<int> _order = <int>[];
  late final int Function(int, int) _byDepth = _compareDepth;

  /// Dots in draw order after [finalize].
  int get dotCount => _order.length;

  /// Lines after [finalize].
  int get lineCount => _lines;

  void begin() {
    _raw = 0;
    _lines = 0;
    _order.clear();
  }

  /// Grows [scratch] to hold at least [n] values and returns it.
  Float64List scratchOf(int n) {
    if (scratch.length < n) scratch = Float64List(n * 2);
    return scratch;
  }

  void dot(double x, double y, double z, double r, double white, [double a = 1]) {
    final o = _raw * _dotStride;
    if (o + _dotStride > _d.length) _d = _grow(_d);
    _d[o] = x;
    _d[o + 1] = y;
    _d[o + 2] = z;
    _d[o + 3] = r;
    _d[o + 4] = white;
    _d[o + 5] = a;
    _raw++;
  }

  void line(double x1, double y1, double x2, double y2, double white, double a, double w) {
    // Invisible edges are dropped here rather than in finalize: same result.
    if (a < 0.02) return;
    final o = _lines * _lineStride;
    if (o + _lineStride > _l.length) _l = _grow(_l);
    _l[o] = x1;
    _l[o + 1] = y1;
    _l[o + 2] = x2;
    _l[o + 3] = y2;
    _l[o + 4] = white;
    _l[o + 5] = a;
    _l[o + 6] = w;
    _lines++;
  }

  void finalize(double rMin) {
    for (var i = 0; i < _raw; i++) {
      final o = i * _dotStride;
      if (_d[o + 5] < 0.02) continue;
      if (_d[o + 3] < rMin) _d[o + 3] = rMin;
      _order.add(i);
    }
    _order.sort(_byDepth);
  }

  int _compareDepth(int a, int b) {
    final za = _d[a * _dotStride + 2];
    final zb = _d[b * _dotStride + 2];
    return za < zb ? -1 : (za > zb ? 1 : a - b);
  }

  double x(int k) => _d[_order[k] * _dotStride];
  double y(int k) => _d[_order[k] * _dotStride + 1];
  double z(int k) => _d[_order[k] * _dotStride + 2];
  double r(int k) => _d[_order[k] * _dotStride + 3];
  double white(int k) => _d[_order[k] * _dotStride + 4];
  double a(int k) => _d[_order[k] * _dotStride + 5];

  double lineX1(int k) => _l[k * _lineStride];
  double lineY1(int k) => _l[k * _lineStride + 1];
  double lineX2(int k) => _l[k * _lineStride + 2];
  double lineY2(int k) => _l[k * _lineStride + 3];
  double lineWhite(int k) => _l[k * _lineStride + 4];
  double lineA(int k) => _l[k * _lineStride + 5];
  double lineW(int k) => _l[k * _lineStride + 6];

  static Float64List _grow(Float64List old) => Float64List(old.length * 2)..setRange(0, old.length, old);
}
