// Portions derived from Libraries.dev Voice (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The voice driver, ported from `voiceDriver.ts` (and its SwiftUI twin
// `VoiceGlowEngine.swift`): it shapes the raw level (noise gate, soft
// saturation), follows it with an attack / release envelope, slides the
// lobes sideways with the flow, gathers them into one beam where a
// [VoiceBeamMotion] asks for it, folds in the idle breathing and the hue drift.
// Pure maths — the painter reads the result each frame.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'voice_style.dart';

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double _smoothstep(double t) => t * t * (3 - 2 * t);

/// Noise gate, then soft saturation, so a shout rounds off instead of clipping.
double voiceShape(double raw, double threshold) {
  if (raw <= threshold) return 0;
  final t = (raw - threshold) / math.max(0.001, 1 - threshold);
  return _clamp01((1 - math.exp(-3 * t)) / (1 - math.exp(-3)));
}

/// One-pole follower: [attack] seconds to rise, [release] seconds to settle.
double voiceFollow(double prev, double target, double dt, double attack, double release) {
  final tau = target > prev ? attack : release;
  return prev + (target - prev) * (1 - math.exp(-dt / math.max(0.001, tau)));
}

/// A lobe offset wrapped into [-span/2, span/2).
double voiceWrapX(double x, double span) => (x + span / 2) % span - span / 2;

/// How much of a lobe shows at offset [x]: full at the centre, gone at the
/// wrap edge, so a lobe never pops from one side to the other.
double voiceEdgeEnvelope(double x, double span) {
  final t = x / (span / 2 + 4);
  return math.max(0, 1 - t * t);
}

/// Cosine ease, 0 at phase 0 and 1, 1 at phase 0.5.
double voicePingPong(double phase) => (1 - math.cos(2 * math.pi * phase)) / 2;

/// The corner radius a box actually paints (clamped to half its sides).
double voicePaintedRadius(double radius, double cw, double ch) =>
    math.max(0, math.min(radius, math.min(cw / 2, ch / 2)));

/// How far above the bottom edge the outline sits at [x]: 0 along the
/// straight run, rising along the corner's circle in the last [radius] px.
/// [influence] is how far the thing at [x] reaches sideways.
double voiceCornerLift(double x, double cw, double radius, [double influence = 0]) {
  if (radius <= 0) return 0;
  final d = math.min(x, cw - x) - influence;
  if (d >= radius) return 0;
  if (d <= 0) return radius;
  final dx = radius - d;
  return radius - math.sqrt(math.max(0, radius * radius - dx * dx));
}

/// The band's bell, 1 at the centre and exactly 0 at the ends:
/// exp(-(|t| / σ)^p) with the tail value subtracted out; `skew` widens one
/// side and narrows the other.
double voiceBell(double t, double p, double sigma, double skew) {
  final side = t < 0 ? 1 - skew : 1 + skew;
  final s = math.max(0.05, sigma * side);
  final v = math.exp(-math.pow(t.abs() / s, p));
  final tail = math.exp(-math.pow(1 / s, p));
  return math.max(0, (v - tail) / (1 - tail));
}

/// The band's ends rising again toward the corners: from [position] of the
/// way out to the full [lift] exactly at the edge, with [curve] as exponent.
double voiceTailLift(double dist, double edge, double lift, double position, double curve) {
  if (lift <= 0 || edge <= 0) return 0;
  final start = edge * position.clamp(0.0, 0.98);
  if (dist <= start) return 0;
  final u = math.min(1.0, (dist - start) / math.max(1, edge - start));
  return lift * math.pow(u, math.max(0.5, curve));
}

/// `hue-rotate(θ) brightness(b) saturate(s)` as one 3×3 matrix, from the W3C
/// Filter Effects spec — the CSS filter every glow layer carries.
List<double> voiceColorMatrix(double hueDegrees, double brightness, double saturation) {
  final rad = hueDegrees * math.pi / 180;
  final c = math.cos(rad), s = math.sin(rad);
  final hue = [
    0.213 + c * 0.787 - s * 0.213,
    0.715 - c * 0.715 - s * 0.715,
    0.072 - c * 0.072 + s * 0.928,
    0.213 - c * 0.213 + s * 0.143,
    0.715 + c * 0.285 + s * 0.140,
    0.072 - c * 0.072 - s * 0.283,
    0.213 - c * 0.213 - s * 0.787,
    0.715 - c * 0.715 + s * 0.715,
    0.072 + c * 0.928 + s * 0.072,
  ];
  final o = saturation;
  final sat = [
    0.213 + 0.787 * o,
    0.715 - 0.715 * o,
    0.072 - 0.072 * o,
    0.213 - 0.213 * o,
    0.715 + 0.285 * o,
    0.072 - 0.072 * o,
    0.213 - 0.213 * o,
    0.715 - 0.715 * o,
    0.072 + 0.928 * o,
  ];
  return [
    for (var row = 0; row < 3; row++)
      for (var col = 0; col < 3; col++)
        sat[row * 3] * hue[col] * brightness +
            sat[row * 3 + 1] * hue[3 + col] * brightness +
            sat[row * 3 + 2] * hue[6 + col] * brightness,
  ];
}

/// The same chain as a [ColorFilter] matrix.
List<double> voiceColorFilterMatrix(double hueDegrees, double brightness, double saturation) {
  final m = voiceColorMatrix(hueDegrees, brightness, saturation);
  return [m[0], m[1], m[2], 0, 0, m[3], m[4], m[5], 0, 0, m[6], m[7], m[8], 0, 0, 0, 0, 0, 1, 0];
}

/// What the 0–1 number from outside measures, so the driver can turn it into
/// the raw level the author's driver expects.
///
/// The web driver has two inputs: a 0–1 `level` it uses as is, and a
/// microphone it measures itself as RMS amplitude × 5 × `sensitivity`. This
/// app's audio arrives as dBFS already squeezed onto 0–1, so a dBFS scale
/// turns it back into RMS amplitude and takes the microphone path — the glow
/// then reacts to our microphone the way the web one does to its own.
@immutable
class VoiceLevelScale {
  const VoiceLevelScale._(this.floorDb, this.ceilDb);

  /// A dBFS range spread linearly over 0–1: `((db - floor) / (ceil - floor)).clamp(0, 1)`.
  const VoiceLevelScale.dbfs(double floorDb, double ceilDb) : this._(floorDb, ceilDb);

  /// Already a 0–1 loudness: used as is, like the author's `level` prop
  /// (`sensitivity` does not apply). The system recogniser's level
  /// (`(rmsdB + 2) / 12`) is one.
  static const linear = VoiceLevelScale._(null, null);

  /// 通话采音：每 40 ms 一次 `((db + 60) / 50).clamp(0, 1)`。
  static const callCapture = VoiceLevelScale.dbfs(-60, -10);

  /// 朗读播放（和云端听写的录音）：每 40 ms 一次 `((db + 50) / 40).clamp(0, 1)`。
  static const playback = VoiceLevelScale.dbfs(-50, -10);

  final double? floorDb;
  final double? ceilDb;

  /// The raw level the shaping curve takes.
  double raw(double value, double sensitivity) {
    final floor = floorDb, ceil = ceilDb;
    if (floor == null || ceil == null) return _clamp01(value);
    // 0 is the meter's floor — silence — not the floor's quiet hum: let the gate close.
    if (value <= 0) return 0;
    final db = floor + _clamp01(value) * (ceil - floor);
    return math.pow(10, db / 20) * _baseGain * sensitivity;
  }

  /// Gain the web driver applies to a microphone's RMS before `sensitivity`:
  /// a laptop mic at speaking distance (RMS 0.03–0.2) lands in 0.15–1.
  static const _baseGain = 5.0;
}

/// 光的大尺度姿态（作者的 `motion` 属性）：七团光收成一束的程度、这束光
/// 在哪、移动时多宽、收拢时保持多亮、贴多少圆角。默认 [rest] 就是随声的光。
@immutable
class VoiceBeamMotion {
  const VoiceBeamMotion({
    required this.gather,
    this.offset = 0,
    this.stretch = 0,
    this.heldLevel = 0,
    this.cornerFollow = 0,
  });

  static const rest = VoiceBeamMotion(gather: 0);

  /// 0 the voice glow at rest … 1 the lobes gathered into one beam.
  final double gather;

  /// Where the beam sits, in half-widths of the lobe ring (0 = centre).
  final double offset;

  /// Extra width while it moves, 0–1.
  final double stretch;

  /// The level the glow is held at while gathered, 0–1.
  final double heldLevel;

  /// How much the beam rides the host's corner arcs, 0–1.
  final double cornerFollow;
}

/// Everything the driver and the painter need, resolved from the type, the
/// theme and the widget's options (what `VoiceBeam.tsx` hands the stylesheet
/// and the driver).
@immutable
class VoiceGlowConfig {
  const VoiceGlowConfig._({
    required this.type,
    required this.dark,
    required this.geometry,
    required this.levelScale,
    required this.sensitivity,
    required this.threshold,
    required this.attack,
    required this.release,
    required this.breatheDuration,
    required this.bands,
    required this.strength,
    required this.brightness,
    required this.saturation,
    required this.hueRange,
    required this.hueDuration,
    required this.hueBase,
    required this.staticColors,
    required this.strokeOpacity,
    required this.innerOpacity,
    required this.bloomOpacity,
    required this.innerShadow,
    required this.colors,
    required this.bandColors,
    required this.radius,
    required this.reducedMotion,
  });

  /// [colorVariant] null follows [scheme] ([voiceThemeColors], the band's
  /// fringes from the same hues); [colors] fills the lobe slots it names,
  /// centre first.
  factory VoiceGlowConfig.resolve({
    VoiceBeamType type = VoiceBeamType.standard,
    required bool dark,
    required ColorScheme scheme,
    VoiceBeamColorVariant? colorVariant,
    List<Color>? colors,
    VoiceBandColors? bandColors,
    double radius = 16,
    VoiceLevelScale levelScale = VoiceLevelScale.linear,
    double sensitivity = 3.1,
    double threshold = 0.015,
    double attack = 0.325,
    double release = 0.86,
    double breatheDuration = 5.2,
    bool bands = true,
    double? scale,
    double? glowSize,
    double? idle,
    double? reach,
    double? spread,
    double? flow,
    double? bend,
    double? bandStrength,
    double? bandWidth,
    double? strength,
    double? brightness,
    double? saturation,
    bool staticColors = false,
    double? hueRange,
    double? hueDuration,
    bool reducedMotion = false,
  }) {
    final theme = dark ? VoiceThemePreset.dark : VoiceThemePreset.light;
    final typeStyle = voiceTypeStyle(type, dark: dark);
    final g = VoiceGeometry.resolve(type, dark: dark).resolved(
      scale: scale,
      glowSize: glowSize,
      idle: idle,
      reach: reach,
      spread: spread,
      flow: flow,
      bend: bend,
      bandStrength: bandStrength,
      bandWidth: bandWidth,
    );
    final mono = colorVariant == VoiceBeamColorVariant.mono;
    // Uniform grey at full opacity reads as a harsh bar; soften it.
    final monoMul = mono ? 0.6 : 1.0;
    final base = colorVariant == null ? voiceThemeColors(scheme, dark: dark) : voicePalette(colorVariant, dark: dark);
    return VoiceGlowConfig._(
      type: type,
      dark: dark,
      geometry: g,
      levelScale: levelScale,
      sensitivity: math.max(0, sensitivity),
      threshold: threshold.clamp(0.0, 0.95),
      attack: math.max(0, attack),
      release: math.max(0, release),
      breatheDuration: math.max(0.2, breatheDuration),
      bands: bands,
      strength: (strength ?? typeStyle.strength ?? theme.strength).clamp(0.0, 1.0),
      brightness: brightness ?? typeStyle.brightness ?? theme.brightness,
      saturation: saturation ?? typeStyle.saturation ?? theme.saturation,
      // The theme palette already spans ±42° around the theme hue; the
      // author's ±24° / ±40° drift on top would carry it off the theme.
      hueRange: math.max(0, hueRange ?? (colorVariant == null ? _themeHueRange : theme.hueRange)),
      hueDuration: math.max(0.5, hueDuration ?? theme.hueDuration),
      hueBase: theme.hueBase,
      staticColors: mono || staticColors,
      strokeOpacity: theme.strokeOpacity * g.strokeOpacity * monoMul,
      innerOpacity: theme.innerOpacity * g.innerOpacity * monoMul,
      bloomOpacity: theme.bloomOpacity * g.bloomOpacity * monoMul,
      innerShadow: theme.innerShadow,
      colors: [for (var i = 0; i < base.length; i++) (colors != null && i < colors.length) ? colors[i] : base[i]],
      bandColors:
          bandColors ??
          (colorVariant == null
              ? VoiceBandColors.theme(scheme, dark: dark)
              : (dark ? VoiceBandColors.dark : VoiceBandColors.light)),
      radius: radius,
      reducedMotion: reducedMotion,
    );
  }

  static const _themeHueRange = 12.0;

  final VoiceBeamType type;
  final bool dark;

  /// The type's geometry with the widget's knobs, every length already scaled.
  final VoiceGeometry geometry;
  final VoiceLevelScale levelScale;
  final double sensitivity;
  final double threshold;
  final double attack;
  final double release;
  final double breatheDuration;
  final bool bands;
  final double strength;
  final double brightness;
  final double saturation;
  final double hueRange;
  final double hueDuration;
  final double hueBase;
  final bool staticColors;

  /// Layer opacities: the theme's, times the type's multipliers (and mono's softening).
  final double strokeOpacity;
  final double innerOpacity;
  final double bloomOpacity;
  final Color innerShadow;

  /// The seven lobe colours, centre first.
  final List<Color> colors;
  final VoiceBandColors bandColors;
  final double radius;
  final bool reducedMotion;

  double get scale => geometry.scale;
}

/// The driver: the envelope state carried across frames, and the frame it
/// computes (what the web driver writes as CSS custom properties).
class VoiceGlowEngine {
  // ── State ──
  /// The smoothed level, 0–1.
  double level = 0;
  final _bands = Float64List(3);
  double _phase = 0;
  double _t = 0;

  /// The fade in / out, 0–1, linear (drawn through [shownPresence]).
  double presence = 0;
  VoiceBeamMotion _motion = VoiceBeamMotion.rest;

  // ── Frame ──
  /// Layer opacity factor (`--vb-glow`).
  double glow = 0.4;

  /// Height and spread multipliers (`--vb-h`, `--vb-w`).
  double h = 0.8;
  double w = 1;

  /// The beam's sideways travel, px (`--vb-cx`).
  double cx = 0;

  /// The range narrowed into a beam while gathered (`--vb-mw`).
  double maskWidth = 1;

  /// The ceiling's extra height at the centre, px, and the band's strength (`--vb-bh`, `--vb-bendA`).
  double lift = 0;
  double bendA = 0;

  /// How far the lobes are gathered into one beam, and how much it rides the corners.
  double morph = 0;
  double cornerFollow = 0;

  /// Hue drift, degrees (`--vb-hue`).
  double hue = 0;

  /// Per lobe: offset along the flow (`--vb-xN`) and amplitude (`--vb-lN`).
  final lobeX = Float64List(voiceLobes.length);
  final lobeL = Float64List(voiceLobes.length);

  /// The fade as drawn: the SwiftUI port's smoothstep over the web's 0.6 s in, 0.5 s out.
  double get shownPresence => _smoothstep(presence);

  bool get visible => presence > 0.002;

  /// Advances one frame of [dt] seconds. [input] is the 0–1 number from
  /// outside, read through the config's [VoiceLevelScale]; [motion] is the
  /// glow's large-scale pose this frame. [frozen] holds everything but the
  /// fade (`paused`).
  void step(
    VoiceGlowConfig c, {
    required double dt,
    required double input,
    VoiceBeamMotion motion = VoiceBeamMotion.rest,
    required bool active,
    bool frozen = false,
  }) {
    final fade = dt / (active ? 0.6 : 0.5);
    presence = active ? math.min(1, presence + fade) : math.max(0, presence - fade);
    if (frozen) return;
    _t += dt;
    final raw = c.levelScale.raw(input, c.sensitivity);
    final target = voiceShape(raw, c.threshold);
    level = voiceFollow(level, target, dt, c.attack, c.release);
    // No spectrum to read, so the bands get slow out-of-phase wobbles scaled
    // by the level: the lobes ripple rather than pump in lockstep.
    for (var b = 0; b < 3; b++) {
      final rawBand = switch (b) {
        0 => raw,
        1 => raw * (0.72 + 0.28 * math.sin(_t * 9.1)),
        _ => raw * (0.6 + 0.4 * math.sin(_t * 13.7 + 2)),
      };
      _bands[b] = voiceFollow(_bands[b], voiceShape(rawBand, c.threshold * 0.6), dt, c.attack, c.release * 1.15);
    }
    _motion = motion;
    _compose(c, dt);
  }

  /// A still frame for reduced motion: the envelope jumps to where it leads,
  /// nothing drifts. The level still shows — the glow is a meter.
  void still(
    VoiceGlowConfig c, {
    required double input,
    VoiceBeamMotion motion = VoiceBeamMotion.rest,
    required bool active,
  }) {
    presence = active ? 1 : 0;
    final raw = c.levelScale.raw(input, c.sensitivity);
    level = voiceShape(raw, c.threshold);
    _bands[0] = voiceShape(raw, c.threshold * 0.6);
    _bands[1] = voiceShape(raw * 0.72, c.threshold * 0.6);
    _bands[2] = voiceShape(raw * (0.6 + 0.4 * math.sin(2)), c.threshold * 0.6);
    _motion = motion;
    _compose(c, 0);
  }

  void _compose(VoiceGlowConfig c, double dt) {
    final g = c.geometry;
    final span = voiceLobeSpan * math.max(0.1, g.lobeSpacing);
    final m = _motion;
    morph = _clamp01(m.gather);
    cornerFollow = _clamp01(m.cornerFollow);
    cx = c.reducedMotion ? 0 : m.offset * span / 2;
    // The cluster: lobes pulled to 40% of their resting spread, the visible
    // range narrowed to match, a little wider while it moves.
    final gather = 1 - morph * 0.6;
    maskWidth = 1 - morph * 0.45;
    final passWidth = 1 + morph * 0.3 * _clamp01(m.stretch);

    // Idle breathing folded under the voice.
    final breathe = c.reducedMotion ? 0.5 : 0.5 + 0.5 * math.sin(2 * math.pi * _t / c.breatheDuration);
    final voiced = level + (1 - level) * g.idle * breathe;
    // The held level waits for the first quarter of the morph — the time the
    // tail hooks take to collapse — so they never light up with it.
    final held = _smoothstep(_clamp01((morph - 0.25) / 0.75));
    final eff = math.max(voiced, _clamp01(m.heldLevel) * held);

    glow = 0.15 + 0.85 * eff;
    h = 0.5 + math.max(0, g.reach) * eff;
    w = (0.85 + math.max(0, g.spread) * eff) * passWidth;

    // Flow: the spectrum slides sideways as the voice comes in.
    if (g.flow != 0 && !c.reducedMotion) _phase = (_phase + g.flow * eff * dt) % span;

    // Bend: the ceiling humps up at the centre with the level.
    final bend = math.max(0.0, g.bend);
    lift = bend * eff;
    bendA = bend > 0 ? math.min(1, lift / bend) : 0;

    for (var i = 0; i < voiceLobes.length; i++) {
      final lobe = voiceLobes[i];
      final x = voiceWrapX(lobe.x * g.lobeSpacing + _phase, span);
      final bandLift = c.bands ? 0.6 + 0.7 * _bands[lobe.band] : 1.0;
      lobeX[i] = x * gather;
      lobeL[i] = bandLift * voiceEdgeEnvelope(x, span);
    }

    hue = c.staticColors || c.reducedMotion || c.hueRange == 0
        ? 0
        : -c.hueRange + 2 * c.hueRange * voicePingPong(_t / c.hueDuration);
  }
}

/// Samples along the band line (57 points).
const voiceBandSamples = 56;

/// The band line in host px, left to right, written into [xs] / [ys]
/// (`bandPoints`): an organic bell on the glow's ceiling whose ends rise
/// toward the corners, riding the corner arcs while gathered.
void voiceBandPoints(VoiceGlowConfig c, VoiceGlowEngine e, double cw, double ch, Float64List xs, Float64List ys) {
  final g = c.geometry;
  final centre = cw / 2 + e.cx * e.w;
  final half = voiceCeilingHalfWidth * g.rangeWidth * e.w * e.maskWidth;
  // Sit on the ceiling but never leave the host; below scale 1 the cap
  // shrinks with it so a scaled-down beam keeps its proportions.
  final apexCap = ch * 0.82 * math.min(1, c.scale);
  final apex = math.min(apexCap, (voiceCeilingHeight * g.rangeHeight * e.h + e.lift) * g.bandPosition);
  final base = ch - g.bandOffset;
  // The tail hook is the resting look; the travelling beam has none — gone
  // by a quarter of the morph, before the held level lights the beam.
  final tailT = math.min(1.0, e.morph * 4);
  final tail = g.bandTail.clamp(0.0, 1.5) * (1 - _smoothstep(tailT));
  final withTail = tail > 0.001;
  final over = withTail ? g.bandTailOverflow : 0.0;
  final x0 = withTail ? -over : centre - half;
  final x1 = withTail ? cw + over : centre + half;
  final radius = voicePaintedRadius(c.radius, cw, ch);
  for (var i = 0; i <= voiceBandSamples; i++) {
    final x = x0 + (x1 - x0) * i / voiceBandSamples;
    final t = ((x - centre) / math.max(1, half)).clamp(-1.0, 1.0);
    final edge = (x < centre ? centre : cw - centre) + over;
    final y =
        voiceBell(t, math.max(0.3, g.bandCurve), math.max(0.05, g.bandSpread), g.bandSkew.clamp(-0.9, 0.9)) +
        voiceTailLift((x - centre).abs(), edge, tail, g.bandTailPosition, g.bandTailCurve);
    final arc = e.morph > 0 ? voiceCornerLift(x, cw, radius) * e.morph : 0.0;
    xs[i] = x;
    ys[i] = base - apex * y - arc;
  }
}
