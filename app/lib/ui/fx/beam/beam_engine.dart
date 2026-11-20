// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import 'beam_data.dart';

/// Everything about one beam except time: what the painters draw from.
@immutable
class BeamConfig {
  const BeamConfig({
    required this.size,
    required this.palette,
    required this.mono,
    required this.dark,
    required this.staticColors,
    required this.duration,
    required this.radius,
    required this.brightness,
    required this.saturation,
    required this.hueRange,
    required this.hueShift,
    required this.glowSize,
    required this.strength,
  });

  final BorderBeamSize size;
  final BeamPalette palette;

  /// The `mono` preset: halves the layer opacities and softens the line bloom.
  final bool mono;
  final bool dark;

  /// No hue motion. For the rotate and line types this also drops the
  /// brightness/saturate filter on the stroke and inner layers (web parity).
  final bool staticColors;

  /// Seconds per rotation / travel / breathing base period.
  final double duration;
  final double radius;
  final double brightness;
  final double saturation;

  /// ± degrees of the hue drift (already capped at 13 for `line`).
  final double hueRange;

  /// Base hue rotation in degrees (`--beam-hue-base`).
  final double hueShift;

  /// Multiplies every blur radius.
  final double glowSize;

  /// 0..1, the beam layers' opacity only.
  final double strength;

  BeamThemePreset get preset => BeamThemePreset.of(size, dark: dark);

  /// A representative moment for the still frame shown under reduced motion:
  /// the rotate beam sweeping the top-right, the line beam mid-travel, the
  /// pulse at rest.
  double get stillTime => size.isPulse ? 0 : duration * 0.5;

  @override
  bool operator ==(Object other) =>
      other is BeamConfig &&
      other.size == size &&
      identical(other.palette, palette) &&
      other.mono == mono &&
      other.dark == dark &&
      other.staticColors == staticColors &&
      other.duration == duration &&
      other.radius == radius &&
      other.brightness == brightness &&
      other.saturation == saturation &&
      other.hueRange == hueRange &&
      other.hueShift == hueShift &&
      other.glowSize == glowSize &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(
    size,
    identityHashCode(palette),
    mono,
    dark,
    staticColors,
    duration,
    radius,
    brightness,
    saturation,
    hueRange,
    hueShift,
    glowSize,
    strength,
  );
}

/// Default duration per family (BorderBeam.tsx `finalDuration`).
double beamDefaultDuration(BorderBeamSize size) => switch (size) {
  BorderBeamSize.line => 3.1,
  BorderBeamSize.pulseInner || BorderBeamSize.pulseOutside => 2.3,
  _ => 1.96,
};

/// Fade-in 0.6 s, fade-out 0.5 s, CSS `ease`.
const beamFadeIn = 0.6;
const beamFadeOut = 0.5;

/// `scaleBlur`: a tuned blur radius times `glowSize`, never below 0.5 px.
double beamBlur(double px, double glowSize) => math.max(0.5, (px * glowSize * 100).round() / 100);

/// Samples a CSS keyframe table `(percent, value)` at cycle progress [p]
/// (0..1), with [curve] as the per-segment timing function.
double beamKeyframes(List<(double, double)> table, double p, Curve curve) {
  final pct = p * 100;
  if (pct <= table.first.$1) return table.first.$2;
  for (var i = 1; i < table.length; i++) {
    final (p0, v0) = table[i - 1];
    final (p1, v1) = table[i];
    if (pct <= p1) {
      final f = p1 > p0 ? (pct - p0) / (p1 - p0) : 1.0;
      return v0 + (v1 - v0) * curve.transform(f);
    }
  }
  return table.last.$2;
}

double _cycle(double t, double period) {
  final c = (t / period) % 1;
  return c < 0 ? c + 1 : c;
}

/// Beam angle as a fraction of a turn (`beam-spin`, linear).
double beamAngle(double t, double duration) => _cycle(t, duration);

/// The ±[range] hue drift (`beam-hue-shift`: -r → +r → -r, ease-in-out).
double beamHueDrift(double t, double range, double period) =>
    beamKeyframes([(0, -range), (50, range), (100, -range)], _cycle(t, period), Curves.easeInOut);

/// Line keyframe values at one moment.
@immutable
class LineFrame {
  const LineFrame({
    required this.x,
    required this.w,
    required this.h,
    required this.spike,
    required this.spike2,
    required this.edge,
  });

  /// Beam centre as a fraction of the width.
  final double x;

  /// Width / height scale of the travelling blobs.
  final double w;
  final double h;
  final double spike;
  final double spike2;

  /// Opacity envelope that hides the jump back to the start.
  final double edge;

  factory LineFrame.at(double t, double duration) {
    // The web writes the derived durations with toFixed(1).
    double period(double k) => (duration * k * 10).round() / 10;
    final travel = _cycle(t, duration);
    return LineFrame(
      x: beamKeyframes(beamTravelX, travel, Curves.linear),
      w: beamKeyframes(beamTravelW, travel, Curves.linear),
      edge: beamKeyframes(beamEdgeFade, travel, Curves.linear),
      h: beamKeyframes(beamBreathe, _cycle(t, period(1.3)), Curves.easeInOut),
      spike: beamKeyframes(beamSpike, _cycle(t, period(1.33)), Curves.easeInOut),
      spike2: beamKeyframes(beamSpike2, _cycle(t, period(1.7)), Curves.easeInOut),
    );
  }
}

/// Breathing parameters (styles.ts `pulseParams`).
@immutable
class PulseParams {
  const PulseParams._(this.sp, this.dr, this.op, this.gh, this.bs, this.ss, this.ghs, this.huePeriod);

  factory PulseParams.of({required bool inner, required bool dark, required double duration}) {
    final k = duration / 2.3;
    if (inner) {
      return PulseParams._(
        0.28,
        dark ? 33 : 40,
        dark ? 0.48 : 0.45,
        dark ? 0.34 : 0.22,
        (dark ? 1.9 : 2.6) * k,
        (dark ? 2.6 : 4.6) * k,
        (dark ? 2.4 : 5.5) * k,
        16,
      );
    }
    return PulseParams._(
      dark ? 0.28 : 0.36,
      dark ? 14 : 19,
      dark ? 0.46 : 0,
      dark ? 0.16 : 0.58,
      (dark ? 2.3 : 3.7) * k,
      (dark ? 6.4 : 4.6) * k,
      (dark ? 2.4 : 3.8) * k,
      14,
    );
  }

  /// Size swing, drift px, quadrant opacity swing, global height swing.
  final double sp, dr, op, gh;

  /// Period bases in seconds.
  final double bs, ss, ghs;

  /// Seconds per full hue revolution.
  final double huePeriod;

  /// Alpha of the frozen bloom: the time-average of the [1 - op, 1] breathing.
  double get frozenBloomAlpha => 1 - op * 0.5;

  /// The 17 oscillators `(a, b, period, delay)` of `pulseOscillatorDefs`, in
  /// [PulseFrame] slot order.
  List<(double, double, double, double)> get oscillators => [
    (1 - sp, 1 + sp * 1.1, ss * 0.9, 0),
    (1 + sp * 0.9, 1 - sp * 0.85, ss * 1.26, 0),
    (-dr, dr * 0.9, bs * 1.6, 0),
    (dr * 0.55, -dr * 0.7, bs * 1.6, 0),
    (1 + sp, 1 - sp * 0.85, ss * 1.1, 0),
    (1 - sp * 0.8, 1 + sp * 1.05, ss * 0.81, 0),
    (dr * 0.8, -dr * 0.9, bs * 1.88, 0),
    (-dr, dr * 0.65, bs * 1.88, 0),
    (1 - sp * 0.6, 1 + sp * 1.15, ss * 0.98, 0),
    (1 + sp * 0.75, 1 - sp, ss * 1.4, 0),
    (-dr * 0.6, dr, bs * 1.45, 0),
    (-dr * 0.85, dr * 0.45, bs * 1.45, 0),
    (1 - gh, 1 + gh, ghs, 0),
    (1 - op, 1, bs, 0),
    (1 - op, 1, bs * 1.32, bs * 0.28),
    (1 - op, 1, bs * 0.84, bs * 0.55),
    (1 - op, 1, bs * 1.58, bs * 0.83),
  ];
}

/// Sampled pulse oscillators: per region r (1..3) slots `4(r-1) + {0: width,
/// 1: height, 2: dx, 3: dy}`, slot 12 the global height, 13 + quad the
/// quadrant opacity (tl, tr, bl, br).
class PulseFrame {
  PulseFrame(this.params) : _osc = params.oscillators;

  final PulseParams params;
  final List<(double, double, double, double)> _osc;
  final Float64List values = Float64List(17);

  /// `pulseDriver.ts`: cosine ping-pong between a and b, delayed.
  static double oscillate(double a, double b, double period, double delay, double t) =>
      a + (b - a) * (1 - math.cos(2 * math.pi * (t - delay) / period)) / 2;

  void sample(double t) {
    for (var i = 0; i < _osc.length; i++) {
      final (a, b, period, delay) = _osc[i];
      values[i] = oscillate(a, b, period, delay, t);
    }
  }

  /// Continuous full-circle hue rotation in degrees.
  double hue(double t) => _cycle(t, params.huePeriod) * 360;
}

/// pulse-outside glow geometry is authored for a 350×140 element and scaled
/// per axis to the real one, clamped to [0.35, 4], rounded to 3 decimals.
(double, double) beamGlowScale(double width, double height) {
  double s(double v) => (v.clamp(0.35, 4.0) * 1000).round() / 1000;
  return (s(width / 350), s(height / 140));
}

/// The CSS filter chain `hue-rotate(h) brightness(b) saturate(s)` as one
/// [ColorFilter.matrix] (W3C feColorMatrix maths, not an HSL rotation).
List<double> beamFilterMatrix(double hueDegrees, double brightness, double saturation) {
  final rad = hueDegrees * math.pi / 180;
  final c = math.cos(rad);
  final s = math.sin(rad);
  final hue = [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, //
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
  ];
  final v = saturation;
  final sat = [
    0.213 + 0.787 * v, 0.715 - 0.715 * v, 0.072 - 0.072 * v, //
    0.213 - 0.213 * v, 0.715 + 0.285 * v, 0.072 - 0.072 * v,
    0.213 - 0.213 * v, 0.715 - 0.715 * v, 0.072 + 0.928 * v,
  ];
  final m = List<double>.filled(20, 0);
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      var sum = 0.0;
      for (var k = 0; k < 3; k++) {
        sum += sat[row * 3 + k] * hue[k * 3 + col];
      }
      m[row * 5 + col] = sum * brightness;
    }
  }
  m[18] = 1;
  return m;
}

/// The fade between off and on: [from] → [to] from [start] over [duration]
/// seconds on the beam clock, CSS `ease`.
@immutable
class BeamFade {
  const BeamFade(this.from, this.to, this.start, this.duration);

  static const off = BeamFade(0, 0, 0, 0);

  final double from;
  final double to;
  final double start;
  final double duration;

  double at(double t) {
    if (duration <= 0) return to;
    final p = ((t - start) / duration).clamp(0.0, 1.0);
    return from + (to - from) * Curves.ease.transform(p);
  }

  bool doneAt(double t) => t - start >= duration;
}
