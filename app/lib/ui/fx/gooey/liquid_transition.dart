// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// Timing for a morph item's `x` / `y` / `scale` changes (spring.ts).
///
/// A spring is simulated once and compiled to a sampled curve plus a duration,
/// the way the original compiles it to CSS `linear()`; a [LiquidTimed] is a plain
/// duration and curve.
@immutable
sealed class LiquidTransition {
  const LiquidTransition();

  /// The author's three presets.
  static const snappy = LiquidSpring(stiffness: 480, damping: 34);
  static const smooth = LiquidSpring(stiffness: 190, damping: 26);
  static const bouncy = LiquidSpring(stiffness: 320, damping: 17);

  /// Duration and curve to play; [reduced] (system "remove animations") snaps.
  LiquidTiming resolve({bool reduced = false});
}

/// A spring, `{ stiffness, damping, mass }`. Unset fields fall back to 300 / 24 / 1.
class LiquidSpring extends LiquidTransition {
  const LiquidSpring({this.stiffness = 300, this.damping = 24, this.mass = 1});

  final double stiffness;
  final double damping;
  final double mass;

  static final _cache = <(double, double, double), LiquidTiming>{};

  @override
  LiquidTiming resolve({bool reduced = false}) {
    if (reduced) return LiquidTiming.instant;
    return _cache.putIfAbsent((stiffness, damping, mass), () {
      final sim = simulateSpring(stiffness, damping, mass);
      return LiquidTiming(Duration(milliseconds: (sim.duration * 1000).round()), SampledCurve(sim.values));
    });
  }

  @override
  bool operator ==(Object other) =>
      other is LiquidSpring && other.stiffness == stiffness && other.damping == damping && other.mass == mass;

  @override
  int get hashCode => Object.hash(stiffness, damping, mass);
}

/// `{ duration, ease }`. The default curve is the original's
/// `cubic-bezier(0.22, 1, 0.36, 1)`.
class LiquidTimed extends LiquidTransition {
  const LiquidTimed(this.duration, [this.curve = const Cubic(0.22, 1, 0.36, 1)]);

  final Duration duration;
  final Curve curve;

  @override
  LiquidTiming resolve({bool reduced = false}) => reduced ? LiquidTiming.instant : LiquidTiming(duration, curve);

  @override
  bool operator ==(Object other) => other is LiquidTimed && other.duration == duration && other.curve == curve;

  @override
  int get hashCode => Object.hash(duration, curve);
}

/// A resolved transition.
@immutable
class LiquidTiming {
  const LiquidTiming(this.duration, this.curve);

  static const instant = LiquidTiming(Duration.zero, Curves.linear);

  final Duration duration;
  final Curve curve;
}

/// The spring's settle time (s) and its curve sampled at evenly spaced stops.
typedef SpringSamples = ({double duration, List<double> values, bool overshoots});

/// spring.ts `simulate`: semi-implicit Euler at 240 Hz from 0 to 1, settled once
/// within 0.001 of 1 at under 0.02/s for 64 ms; 24–120 stops, 90 per second.
SpringSamples simulateSpring(double stiffness, double damping, double mass) {
  const dt = 1 / 240;
  var x = 0.0;
  var v = 0.0;
  var t = 0.0;
  var settledAt = -1.0;
  var max = 0.0;
  final xs = <double>[0];
  while (t < 10) {
    final a = (-stiffness * (x - 1) - damping * v) / mass;
    v += a * dt;
    x += v * dt;
    t += dt;
    xs.add(x);
    if (x > max) max = x;
    if ((x - 1).abs() < 0.001 && v.abs() < 0.02) {
      if (settledAt < 0) settledAt = t;
      if (t - settledAt >= 0.064) break;
    } else {
      settledAt = -1;
    }
  }
  final duration = settledAt > 0 ? settledAt : t;
  final n = math.min(120.0, math.max(24.0, duration * 90)).round();
  final lastIdx = math.min(xs.length - 1.0, duration / dt);
  final values = <double>[
    for (var i = 0; i <= n; i++) (xs[math.min(xs.length - 1, ((i / n) * lastIdx).round())] * 1e4).round() / 1e4,
  ];
  values[values.length - 1] = 1;
  return (duration: duration, values: values, overshoots: max > 1.001);
}

/// CSS `linear(v0, v1, …)` with evenly spaced stops: what the compiled spring plays.
class SampledCurve extends Curve {
  const SampledCurve(this.values);

  final List<double> values;

  @override
  double transformInternal(double t) {
    final f = t * (values.length - 1);
    final i = f.floor();
    if (i >= values.length - 1) return values.last;
    return values[i] + (values[i + 1] - values[i]) * (f - i);
  }
}
