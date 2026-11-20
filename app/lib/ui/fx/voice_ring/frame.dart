// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// What one rendered instant is (core.ts): screen-space polylines with an
// opacity per point, plus how the painter lights them — as coloured light
// (the ring) or as solid tubes (mono). Buffers are allocated once per ring
// and rewritten every frame. Also the shared maths: the skin field, the hash
// and the size scaling.

import 'dart:math' as math;
import 'dart:typed_data';

const double tau = math.pi * 2;

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double smoothstep(double e0, double e1, double x) {
  final t = clamp01((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

/// Deterministic hash in [0, 1).
double hashD(double a, double b) {
  final h = math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - h.floorToDouble();
}

/// Line widths are tuned for a 200px ring; sub-linear so small rings stay legible.
double radiusScale(double size, [double pow = 0.6]) => math.pow(size / 200, pow).toDouble();

/// A closed polyline in screen space whose opacity varies point to point.
class RingStroke {
  RingStroke(int n, {bool depth = false})
    : pts = Float64List(2 * n),
      a = Float64List(n),
      z = depth ? Float64List(n) : null;

  /// `[x0, y0, x1, y1, …]` in logical px.
  final Float64List pts;

  /// Opacity per point (for a tube: its light, 0–1).
  final Float64List a;

  /// Depth per point, −1 far … 1 near (tubes only).
  final Float64List? z;

  /// Width in logical px.
  double w = 1;

  int get length => a.length;
}

/// A specular hot spot: white light pooled where it touches the rings.
class LightSpec {
  double x = 0;
  double y = 0;
  double r = 0;
  double a = 0;
}

/// A spectrum stop: offset 0–1 round the ring and an RGB colour, 0–255.
typedef SpectrumStop = (double, double, double, double);

/// How a luminous frame is lit.
class FrameLight {
  /// Ring centre and rest radius.
  double cx = 0;
  double cy = 0;
  double r = 0;

  /// The spectrum, read clockwise from [angle].
  List<SpectrumStop> stops = const [];

  /// Radians clockwise from +x.
  double angle = 0;

  /// Overall brightness, ~0.6 at rest to ~1.3 in full voice.
  double intensity = 0;

  /// Strength of the soft halo, 0 for none.
  double halo = 0;

  final LightSpec spec = LightSpec();

  /// Chromatic fringe offset, a share of [r].
  double fringe = 0;
}

/// How a tube frame is lit (the mono type's look, fixed).
class FrameTube {
  const FrameTube({
    required this.shine,
    required this.contrast,
    required this.depth,
    required this.saturation,
    required this.gradient,
    required this.gradientAngle,
    required this.gradientSpin,
    required this.colorBrightness,
    required this.positiveBrightness,
    required this.negativeBrightness,
    required this.calmBrightness,
  });

  final double shine;
  final double contrast;
  final double depth;
  final double saturation;
  final double gradient;
  final double gradientAngle;
  final double gradientSpin;
  final double colorBrightness;
  final double positiveBrightness;
  final double negativeBrightness;
  final double calmBrightness;
}

/// The lens a pressing ring is refracted through, logical px.
class OrbLens {
  const OrbLens({
    required this.zone,
    required this.gap,
    required this.flare,
    required this.split,
    required this.blur,
    required this.cy,
  });

  final double zone;
  final double gap;
  final double flare;
  final double split;
  final double blur;
  final double cy;
}

/// Where a leaning ring meets the screen's edge, and how hard it presses.
class OrbContact {
  const OrbContact({required this.side, required this.x, required this.press, this.lens});

  /// −1 the left edge, 1 the right.
  final double side;

  /// The edge, logical px from the ring box's left.
  final double x;

  /// 0 just touching … 1 pressing hard.
  final double press;

  final OrbLens? lens;
}

/// One rendered instant.
class OrbFrame {
  OrbFrame(this.strokes, {this.light, this.tube});

  final List<RingStroke> strokes;

  /// Present on the ring: paint the strokes as light.
  final FrameLight? light;

  /// Present on mono: paint the strokes as lit tubes.
  final FrameTube? tube;

  /// Set by the lean while the ring presses on the screen's edge.
  OrbContact? contact;
}

double _sinc(double a) => a < 1e-6 ? 1 : math.sin(a) / a;
// |wave vector| of each term of the skin field, for its sphere average
final double _kLobe1 = math.sqrt(2.1 * 2.1 + 1.3 * 1.3);
final double _kLobe2 = math.sqrt(1.9 * 1.9 + 1.7 * 1.7);
final double _kFineDiff = math.sqrt(1.4 * 1.4 + 3.7 * 3.7 + 3.1 * 3.1);
final double _kFineSum = math.sqrt(7.2 * 7.2 + 3.7 * 3.7 + 3.1 * 3.1);

/// The skin deformation: one smooth field over the unit sphere — broad lobes
/// plus a finer ripple — so every ring sampling it bends together like a
/// surface. Its sphere average is taken out exactly, so it changes the
/// shape, never the size.
class SkinField {
  double _aLobe = 0;
  double _aFine = 0;
  double _k = 1;
  double _p1 = 0;
  double _p2 = 0;
  double _p3 = 0;
  double _p4 = 0;
  double _mean = 0;

  void set(double aLobe, double aFine, double t, [double radius = 1]) {
    _aLobe = aLobe;
    _aFine = aFine;
    final k = _k = 1 / math.max(0.05, radius);
    _p1 = 0.9 * t;
    _p2 = -0.7 * t + 1.3;
    _p3 = 2.1 * t;
    _p4 = -1.6 * t;
    _mean =
        aLobe * (0.55 * math.sin(_p1) * _sinc(_kLobe1 * k) + 0.45 * math.sin(_p2) * _sinc(_kLobe2 * k)) +
        aFine * 0.5 * (math.cos(_p3 - _p4) * _sinc(_kFineDiff * k) - math.cos(_p3 + _p4) * _sinc(_kFineSum * k));
  }

  double at(double x, double y, double z) {
    x *= _k;
    y *= _k;
    z *= _k;
    return _aLobe * (0.55 * math.sin(2.1 * x + 1.3 * y + _p1) + 0.45 * math.sin(1.7 * z - 1.9 * y + _p2)) +
        _aFine * math.sin(4.3 * x - 3.1 * z + _p3) * math.sin(3.7 * y + 2.9 * x + _p4) -
        _mean;
  }
}
