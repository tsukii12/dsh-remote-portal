// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// 光束类型，名字照搬原库的 `size`。
///
/// 旋转族（光沿边框走）：[md]（大，整圈）、[line]（只在底边来回）、[sm]（按钮大小）。
/// 呼吸族（不走，原地呼吸）：[pulseInner]（在边框里面亮）、[pulseOutside]（光晕往外散）。
enum BorderBeamSize {
  sm,
  md,
  line,
  pulseOutside,
  pulseInner;

  bool get isPulse => this == pulseInner || this == pulseOutside;
}

/// 原库的配色预设。不传配色时光束跟主题色走（[BeamPalette.fromSeed]）。
enum BorderBeamColorVariant {
  colorful,
  mono,
  ocean,
  sunset,
  forest,
  candy,
  ice,
  gold;

  BeamPalette get palette => switch (this) {
    colorful => _colorful,
    mono => _mono,
    ocean => _ocean,
    sunset => _sunset,
    forest => _forest,
    candy => _candy,
    ice => _ice,
    gold => _gold,
  };
}

/// 光束按深色还是浅色底来调（原库的 `theme`）。不传就跟 `Theme.of(context).brightness`。
enum BorderBeamTheme { dark, light }

/// Per type × theme opacities and filter defaults (styles.ts `sizeThemePresets`).
@immutable
class BeamThemePreset {
  const BeamThemePreset({
    required this.stroke,
    required this.inner,
    required this.bloom,
    required this.innerShadow,
    required this.saturation,
    this.brightness = 1.3,
  });

  final double stroke;
  final double inner;
  final double bloom;
  final Color innerShadow;
  final double saturation;
  final double brightness;

  static BeamThemePreset of(BorderBeamSize size, {required bool dark}) => switch (size) {
    BorderBeamSize.sm => dark ? _smDark : _smLight,
    BorderBeamSize.md => dark ? _mdDark : _mdLight,
    BorderBeamSize.line => dark ? _lineDark : _lineLight,
    BorderBeamSize.pulseOutside => dark ? _outsideDark : _outsideLight,
    BorderBeamSize.pulseInner => dark ? _innerDark : _innerLight,
  };

  static const _smDark = BeamThemePreset(
    stroke: 0.46,
    inner: 0.24,
    bloom: 0.38,
    innerShadow: Color.fromRGBO(255, 255, 255, 0.3),
    saturation: 1.2,
  );
  static const _smLight = BeamThemePreset(
    stroke: 0.12,
    inner: 0.3,
    bloom: 0.16,
    innerShadow: Color.fromRGBO(0, 0, 0, 0.14),
    saturation: 1.8,
  );
  static const _mdDark = BeamThemePreset(
    stroke: 0.26,
    inner: 0.42,
    bloom: 0.24,
    innerShadow: Color.fromRGBO(255, 255, 255, 0.27),
    saturation: 1.2,
  );
  static const _mdLight = BeamThemePreset(
    stroke: 0.12,
    inner: 0.26,
    bloom: 0.34,
    innerShadow: Color.fromRGBO(0, 0, 0, 0.14),
    saturation: 1.5,
  );
  static const _lineDark = BeamThemePreset(
    stroke: 1.14,
    inner: 0.7,
    bloom: 0.8,
    innerShadow: Color.fromRGBO(255, 255, 255, 0.1),
    saturation: 1.2,
  );
  static const _lineLight = BeamThemePreset(
    stroke: 0.16,
    inner: 0.32,
    bloom: 0.3,
    innerShadow: Color.fromRGBO(0, 0, 0, 0.14),
    saturation: 1.95,
  );
  static const _outsideDark = BeamThemePreset(
    stroke: 0.94,
    inner: 0.34,
    bloom: 0.3,
    innerShadow: Color(0x00000000),
    saturation: 1.2,
    brightness: 1.9,
  );
  static const _outsideLight = BeamThemePreset(
    stroke: 1.96,
    inner: 1.04,
    bloom: 0.42,
    innerShadow: Color(0x00000000),
    saturation: 0.6,
    brightness: 1.7,
  );
  static const _innerDark = BeamThemePreset(
    stroke: 1.54,
    inner: 0.44,
    bloom: 0.66,
    innerShadow: Color(0x00000000),
    saturation: 1.2,
    brightness: 0.75,
  );
  static const _innerLight = BeamThemePreset(
    stroke: 0.32,
    inner: 0.4,
    bloom: 0.8,
    innerShadow: Color(0x00000000),
    saturation: 0.75,
  );
}

/// Corner radius used when none is given (styles.ts `sizePresets`).
double beamDefaultRadius(BorderBeamSize size) => size == BorderBeamSize.sm ? 32 : 16;

/// Every type draws a 1px border ring (`sizePresets[*].borderWidth`).
const beamBorderWidth = 1.0;

// ── Gradient geometry, identical across colour variants ─────────────────────
//
// `radial-gradient(ellipse RXpx RYpx at X% Y%, colour, transparent)`: X/Y are
// fractions of the layer box, RX/RY the ellipse radii in logical px.

/// `colorPalettes[*].border` (md stroke + inner, pulse ring).
const beamBorderGeometry = <(double, double, double, double)>[
  (0.33, -0.074, 70, 40),
  (0.12, -0.05, 60, 35),
  (0.021, 0.683, 40, 70),
  (0.021, 0.683, 20, 35),
  (0.744, 1, 180, 32),
  (0.55, 1, 85, 26),
  (0.939, 0, 74, 32),
  (1, 0.271, 26, 42),
  (1, 0.271, 52, 48),
];

/// `smallColorPalettes[*].border` and `.inner` (sm).
const beamSmallGeometry = <(double, double, double, double)>[
  (0.02, 0.68, 9, 18),
  (0.02, 0.68, 4, 8),
  (0.72, -0.03, 59, 9),
  (0.74, 1, 42, 7),
  (1, 0.27, 10, 17),
  (1, 0.27, 10, 18),
  (1, 0.27, 5, 10),
  (1, 0.27, 11, 12),
];

// Line blobs ride the travelling beam: (rx, ry, dx, dy) — radii scale with the
// travel width/height, the centre sits at (beamX + dx, bottom + dy).

/// `lineColorPalettes[*].dark` (line stroke on dark).
const beamLineDarkGeometry = <(double, double, double, double)>[
  (36, 36, 0, 2),
  (30, 32, 39, 0),
  (33, 28, -36, 2),
  (29, 34, -54, 0),
  (27, 30, 51, -1),
  (36, 24, 21, 1),
  (30, 22, -21, 0),
  (25, 28, 66, 1),
  (23, 30, -66, -1),
];

/// `lineColorPalettes[*].light`.
const beamLineLightGeometry = <(double, double, double, double)>[
  (45, 36, 0, 2),
  (35, 32, 65, 0),
  (40, 28, -60, 2),
  (35, 34, -90, 0),
  (38, 30, 85, -1),
  (50, 24, 35, 1),
  (40, 22, -35, 0),
  (35, 28, 110, 1),
  (30, 30, -110, -1),
];

/// `lineInnerGradientData[*]` — the centre sits at `bottom - |dy|`.
const beamLineInnerGeometry = <(double, double, double, double)>[
  (33, 30, 0, 0),
  (24, 26, 39, -3),
  (27, 24, -36, 0),
  (23, 28, -54, -2),
  (24, 24, 51, -1),
  (30, 20, 21, 0),
  (25, 18, -21, -2),
  (21, 24, 66, 0),
  (18, 26, -66, -1),
];

// ── Conic stops (position 0..1, alpha), `from <beam angle>` ─────────────────

/// Stroke highlight on top of the colours: white on dark, black on light.
const beamWhiteStopsDark = [
  (0.0, 0.0), (0.54, 0.0), (0.57, 0.1), (0.60, 0.3), (0.63, 0.6), (0.66, 0.75), //
  (0.69, 0.6), (0.72, 0.3), (0.75, 0.1), (0.78, 0.0), (1.0, 0.0),
];
const beamWhiteStopsLight = [
  (0.0, 0.0), (0.54, 0.0), (0.57, 0.08), (0.60, 0.2), (0.63, 0.4), (0.66, 0.55), //
  (0.69, 0.4), (0.72, 0.2), (0.75, 0.08), (0.78, 0.0), (1.0, 0.0),
];

/// Bloom ring.
const beamBloomStopsDark = [
  (0.0, 0.0), (0.58, 0.0), (0.62, 0.03), (0.65, 0.08), (0.67, 0.2), (0.69, 0.45), (0.70, 0.85), //
  (0.705, 0.85), (0.715, 0.45), (0.73, 0.2), (0.75, 0.08), (0.78, 0.03), (0.82, 0.0),
];
const beamBloomStopsLight = [
  (0.0, 0.0), (0.58, 0.0), (0.62, 0.02), (0.65, 0.08), (0.67, 0.2), (0.69, 0.4), (0.70, 0.6), //
  (0.705, 0.6), (0.715, 0.4), (0.73, 0.2), (0.75, 0.08), (0.78, 0.02), (0.82, 0.0),
];

/// The travelling window that masks md (stroke + inner) and sm (stroke).
const beamWindowStops = [
  (0.0, 0.0), (0.30, 0.0), (0.36, 0.1), (0.44, 0.35), (0.52, 1.0), //
  (0.80, 1.0), (0.86, 0.35), (0.92, 0.1), (0.95, 0.0), (1.0, 0.0),
];

/// sm inner glow uses a wider window.
const beamSmallWindowStops = [
  (0.0, 0.0), (0.22, 0.0), (0.28, 0.12), (0.36, 0.4), (0.46, 1.0), //
  (0.82, 1.0), (0.88, 0.4), (0.94, 0.12), (0.97, 0.0), (1.0, 0.0),
];

/// Inner layers fade from solid at the edges to clear this far in.
const beamEdgeMaskPx = 28.0;

// ── Line keyframes (percent of the cycle → value) ───────────────────────────

const beamTravelX = [
  (0.0, 0.06), (10.0, 0.15), (20.0, 0.25), (30.0, 0.35), (40.0, 0.44), (50.0, 0.5), //
  (60.0, 0.56), (70.0, 0.65), (80.0, 0.75), (90.0, 0.85), (100.0, 0.94),
];
const beamTravelW = [
  (0.0, 0.5), (10.0, 0.8), (20.0, 1.1), (30.0, 1.3), (40.0, 1.45), (50.0, 1.5), //
  (60.0, 1.45), (70.0, 1.3), (80.0, 1.1), (90.0, 0.8), (100.0, 0.5),
];
const beamEdgeFade = [(0.0, 0.0), (12.5, 0.0), (32.5, 1.0), (67.5, 1.0), (87.5, 0.0), (100.0, 0.0)];
const beamBreathe = [(0.0, 0.8), (25.0, 1.25), (55.0, 0.85), (80.0, 1.3), (100.0, 0.8)];
const beamSpike = [(0.0, 0.8), (25.0, 1.3), (50.0, 0.9), (75.0, 1.4), (100.0, 0.8)];
const beamSpike2 = [(0.0, 1.2), (25.0, 0.7), (50.0, 1.4), (75.0, 0.8), (100.0, 1.2)];

// ── Pulse tables ─────────────────────────────────────────────────────────────
//
// Region 1–3 picks a size/drift oscillator set, quad 0–3 (tl, tr, bl, br) an
// opacity oscillator; region 0 means static (the corner accents).

/// `PULSE_RING_MAP`: region and quad of each of the nine border-palette blobs.
const beamPulseRingMap = <(int, int)>[(1, 0), (2, 0), (3, 2), (1, 2), (2, 3), (3, 3), (1, 1), (2, 1), (3, 1)];

/// `PULSE_INNER_SIZES`: pulse-inner glow blob radii (positions from the palette).
const beamPulseInnerSizes = <(double, double)>[
  (65, 35), (55, 30), (35, 65), (15, 30), (173, 28), (80, 22), (69, 28), (22, 38), (47, 44), //
];

/// Fixed blob tables: (palette index, region, quad, rx, ry, x, y); a null x/y
/// takes the palette position.
typedef BeamPulseBlob = (int, int, int, double, double, double?, double?);

/// `PULSE_INNER_BLOOM`.
const beamPulseInnerBloom = <BeamPulseBlob>[
  (0, 1, 0, 84, 48, null, null),
  (1, 2, 0, 72, 42, null, null),
  (2, 3, 2, 48, 84, null, null),
  (4, 2, 3, 216, 38, null, null),
  (5, 3, 3, 102, 31, null, null),
  (6, 1, 1, 89, 38, null, null),
  (8, 3, 1, 62, 58, null, null),
];

/// `PULSE_OUTER_CORE` (pulse-outside stroke and core glow).
const beamPulseOuterCore = <BeamPulseBlob>[
  (0, 1, 0, 80, 19, 0.27, 0),
  (6, 2, 1, 74, 11, 0.73, -0.01),
  (7, 3, 1, 15, 44, 1, 0.33),
  (8, 1, 3, 19, 38, 1.01, 0.72),
  (4, 2, 3, 84, 13, 0.67, 1),
  (1, 3, 2, 60, 21, 0.24, 1.01),
  (2, 1, 2, 17, 40, 0, 0.6),
  (3, 2, 0, 13, 32, -0.01, 0.28),
];

/// `PULSE_OUTER_BLOOM`.
const beamPulseOuterBloom = <BeamPulseBlob>[
  (0, 1, 0, 110, 30, 0.27, 0.03),
  (6, 2, 1, 100, 20, 0.73, 0.01),
  (7, 3, 1, 26, 62, 1, 0.33),
  (8, 1, 3, 30, 56, 1.01, 0.72),
  (4, 2, 3, 120, 22, 0.67, 0.99),
  (1, 3, 2, 88, 32, 0.24, 0.99),
  (2, 1, 2, 28, 58, 0, 0.6),
];

/// The colours of one palette. Geometry is shared ([beamBorderGeometry] and
/// friends); a palette only says which colour goes where.
@immutable
class BeamPalette {
  const BeamPalette({
    required this.border,
    required this.spike,
    required this.spikeLight,
    required this.small,
    required this.smallInner,
    required this.lineDark,
    required this.lineLight,
    required this.lineInner,
    required this.bloomDark,
    required this.bloomLight,
  });

  /// The author's recipe for a palette from nine colours — Forest, Candy, Ice
  /// and Gold are built exactly this way (light rows darkened to 72%).
  factory BeamPalette.fromColors(List<Color> c) {
    assert(c.length == 9);
    Color dim(Color x) =>
        Color.fromRGBO((x.r * 255 * 0.72).round(), (x.g * 255 * 0.72).round(), (x.b * 255 * 0.72).round(), 1);
    Color a(Color x, double alpha) => x.withValues(alpha: alpha);
    final d = [for (final x in c) dim(x)];
    return BeamPalette(
      border: c,
      spike: (c[0], a(c[1], 0.98)),
      spikeLight: (d[0], d[1]),
      small: c.sublist(0, 8),
      smallInner: [
        a(c[8], 0.5),
        a(c[0], 0.45),
        a(c[1], 0.35),
        a(c[2], 0.35),
        a(c[3], 0.3),
        a(c[4], 0.4),
        a(c[5], 0.3),
        a(c[6], 0.3),
      ],
      lineDark: c,
      lineLight: d,
      lineInner: [
        for (final (i, alpha) in const [0.48, 0.42, 0.48, 0.42, 0.50, 0.45, 0.40, 0.45, 0.52].indexed) a(c[i], alpha),
      ],
      bloomDark: [
        (c[0], c[1]),
        (a(c[2], 0.59), a(c[3], 0.29)),
        (c[4], c[5]),
        (a(c[6], 0.91), a(c[7], 0.45)),
        (c[8], c[0]),
      ],
      bloomLight: [
        (d[0], a(d[1], 0.8)),
        (a(d[2], 0.7), a(d[3], 0.46)),
        (d[4], a(d[5], 0.82)),
        (d[6], a(d[7], 0.7)),
        (d[8], a(d[0], 0.78)),
      ],
    );
  }

  /// 跟主题色走：主色左右相邻的九个色相，饱和度压低，不刺眼。
  factory BeamPalette.fromSeed(Color seed) {
    final base = HSLColor.fromColor(seed);
    // A grey theme still gets a whisper of colour; a loud one is calmed down.
    final sat = (base.saturation * 0.85).clamp(0.4, 0.6);
    Color tone(double shift, double s, double l) =>
        HSLColor.fromAHSL(1, (base.hue + shift) % 360, s.clamp(0.0, 1.0), l).toColor();
    return BeamPalette.fromColors([
      tone(0, sat, 0.62),
      tone(-24, sat * 0.9, 0.66),
      tone(18, sat, 0.6),
      tone(-10, sat * 1.1, 0.58),
      tone(32, sat * 0.85, 0.66),
      tone(-36, sat, 0.62),
      tone(8, sat * 0.9, 0.7),
      tone(-16, sat, 0.6),
      tone(26, sat, 0.64),
    ]);
  }

  /// Nine colours for [beamBorderGeometry].
  final List<Color> border;

  /// Line bloom spike colours (primary, secondary) on dark / light.
  final (Color, Color) spike;
  final (Color, Color) spikeLight;

  /// Eight colours each for [beamSmallGeometry].
  final List<Color> small;
  final List<Color> smallInner;

  /// Nine colours each for the line geometry tables.
  final List<Color> lineDark;
  final List<Color> lineLight;
  final List<Color> lineInner;

  /// Five line bloom spikes (centre colour, mid colour) on dark / light.
  final List<(Color, Color)> bloomDark;
  final List<(Color, Color)> bloomLight;
}

// ── Presets (styles.ts colour tables) ────────────────────────────────────────

const _colorful = BeamPalette(
  border: [
    Color.fromRGBO(255, 50, 100, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(50, 200, 80, 1),
    Color.fromRGBO(30, 185, 170, 1),
    Color.fromRGBO(100, 70, 255, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(255, 120, 40, 1),
    Color.fromRGBO(240, 50, 180, 1),
    Color.fromRGBO(180, 40, 240, 1),
  ],
  spike: (Color.fromRGBO(255, 60, 80, 1), Color.fromRGBO(40, 190, 180, 0.98)),
  spikeLight: (Color.fromRGBO(200, 30, 60, 1), Color.fromRGBO(20, 150, 140, 1)),
  small: [
    Color.fromRGBO(50, 200, 80, 1),
    Color.fromRGBO(30, 185, 170, 1),
    Color.fromRGBO(255, 120, 40, 1),
    Color.fromRGBO(100, 70, 255, 1),
    Color.fromRGBO(240, 50, 180, 1),
    Color.fromRGBO(180, 40, 240, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(255, 50, 100, 1),
  ],
  smallInner: [
    Color.fromRGBO(50, 200, 80, 0.5),
    Color.fromRGBO(30, 185, 170, 0.45),
    Color.fromRGBO(255, 120, 40, 0.35),
    Color.fromRGBO(100, 70, 255, 0.35),
    Color.fromRGBO(240, 50, 180, 0.3),
    Color.fromRGBO(180, 40, 240, 0.4),
    Color.fromRGBO(40, 140, 255, 0.3),
    Color.fromRGBO(255, 50, 100, 0.3),
  ],
  lineDark: [
    Color.fromRGBO(255, 50, 100, 1),
    Color.fromRGBO(40, 180, 220, 1),
    Color.fromRGBO(50, 200, 80, 1),
    Color.fromRGBO(180, 40, 240, 1),
    Color.fromRGBO(255, 160, 30, 1),
    Color.fromRGBO(100, 70, 255, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(240, 50, 180, 1),
    Color.fromRGBO(30, 185, 170, 1),
  ],
  lineLight: [
    Color.fromRGBO(255, 50, 100, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(50, 200, 80, 1),
    Color.fromRGBO(180, 40, 240, 1),
    Color.fromRGBO(30, 185, 170, 1),
    Color.fromRGBO(100, 70, 255, 1),
    Color.fromRGBO(40, 140, 255, 1),
    Color.fromRGBO(255, 120, 40, 1),
    Color.fromRGBO(240, 50, 180, 1),
  ],
  lineInner: [
    Color.fromRGBO(255, 50, 100, 0.48),
    Color.fromRGBO(40, 180, 220, 0.42),
    Color.fromRGBO(50, 200, 80, 0.48),
    Color.fromRGBO(180, 40, 240, 0.42),
    Color.fromRGBO(255, 160, 30, 0.5),
    Color.fromRGBO(100, 70, 255, 0.45),
    Color.fromRGBO(40, 140, 255, 0.4),
    Color.fromRGBO(240, 50, 180, 0.45),
    Color.fromRGBO(30, 185, 170, 0.52),
  ],
  bloomDark: [
    (Color.fromRGBO(100, 70, 255, 1), Color.fromRGBO(100, 70, 255, 1)),
    (Color.fromRGBO(255, 170, 40, 0.59), Color.fromRGBO(255, 170, 40, 0.29)),
    (Color.fromRGBO(50, 200, 100, 1), Color.fromRGBO(50, 200, 100, 1)),
    (Color.fromRGBO(200, 50, 240, 0.91), Color.fromRGBO(200, 50, 240, 0.45)),
    (Color.fromRGBO(40, 140, 255, 1), Color.fromRGBO(40, 140, 255, 1)),
  ],
  bloomLight: [
    (Color.fromRGBO(80, 50, 200, 1), Color.fromRGBO(80, 50, 200, 0.8)),
    (Color.fromRGBO(210, 130, 0, 0.7), Color.fromRGBO(210, 130, 0, 0.46)),
    (Color.fromRGBO(30, 160, 70, 1), Color.fromRGBO(30, 160, 70, 0.82)),
    (Color.fromRGBO(160, 30, 190, 1), Color.fromRGBO(160, 30, 190, 0.7)),
    (Color.fromRGBO(30, 100, 200, 1), Color.fromRGBO(30, 100, 200, 0.78)),
  ],
);

const _mono = BeamPalette(
  border: [
    Color.fromRGBO(180, 180, 180, 1),
    Color.fromRGBO(140, 140, 140, 1),
    Color.fromRGBO(160, 160, 160, 1),
    Color.fromRGBO(130, 130, 130, 1),
    Color.fromRGBO(170, 170, 170, 1),
    Color.fromRGBO(150, 150, 150, 1),
    Color.fromRGBO(190, 190, 190, 1),
    Color.fromRGBO(145, 145, 145, 1),
    Color.fromRGBO(165, 165, 165, 1),
  ],
  spike: (Color.fromRGBO(200, 200, 200, 1), Color.fromRGBO(170, 170, 170, 1)),
  spikeLight: (Color.fromRGBO(80, 80, 80, 1), Color.fromRGBO(120, 120, 120, 1)),
  small: [
    Color.fromRGBO(160, 160, 160, 1),
    Color.fromRGBO(140, 140, 140, 1),
    Color.fromRGBO(180, 180, 180, 1),
    Color.fromRGBO(150, 150, 150, 1),
    Color.fromRGBO(170, 170, 170, 1),
    Color.fromRGBO(155, 155, 155, 1),
    Color.fromRGBO(145, 145, 145, 1),
    Color.fromRGBO(165, 165, 165, 1),
  ],
  smallInner: [
    Color.fromRGBO(160, 160, 160, 0.25),
    Color.fromRGBO(140, 140, 140, 0.22),
    Color.fromRGBO(180, 180, 180, 0.17),
    Color.fromRGBO(150, 150, 150, 0.17),
    Color.fromRGBO(170, 170, 170, 0.15),
    Color.fromRGBO(155, 155, 155, 0.2),
    Color.fromRGBO(145, 145, 145, 0.15),
    Color.fromRGBO(165, 165, 165, 0.15),
  ],
  lineDark: [
    Color.fromRGBO(200, 200, 200, 1),
    Color.fromRGBO(170, 170, 170, 1),
    Color.fromRGBO(155, 155, 155, 1),
    Color.fromRGBO(185, 185, 185, 1),
    Color.fromRGBO(165, 165, 165, 1),
    Color.fromRGBO(180, 180, 180, 1),
    Color.fromRGBO(160, 160, 160, 1),
    Color.fromRGBO(175, 175, 175, 1),
    Color.fromRGBO(190, 190, 190, 1),
  ],
  lineLight: [
    Color.fromRGBO(100, 100, 100, 1),
    Color.fromRGBO(80, 80, 80, 1),
    Color.fromRGBO(90, 90, 90, 1),
    Color.fromRGBO(70, 70, 70, 1),
    Color.fromRGBO(85, 85, 85, 1),
    Color.fromRGBO(95, 95, 95, 1),
    Color.fromRGBO(75, 75, 75, 1),
    Color.fromRGBO(105, 105, 105, 1),
    Color.fromRGBO(65, 65, 65, 1),
  ],
  lineInner: [
    Color.fromRGBO(200, 200, 200, 0.48),
    Color.fromRGBO(170, 170, 170, 0.42),
    Color.fromRGBO(155, 155, 155, 0.48),
    Color.fromRGBO(185, 185, 185, 0.42),
    Color.fromRGBO(165, 165, 165, 0.5),
    Color.fromRGBO(180, 180, 180, 0.45),
    Color.fromRGBO(160, 160, 160, 0.4),
    Color.fromRGBO(175, 175, 175, 0.45),
    Color.fromRGBO(190, 190, 190, 0.52),
  ],
  bloomDark: [
    (Color.fromRGBO(200, 200, 200, 1), Color.fromRGBO(200, 200, 200, 1)),
    (Color.fromRGBO(180, 180, 180, 0.59), Color.fromRGBO(180, 180, 180, 0.29)),
    (Color.fromRGBO(190, 190, 190, 1), Color.fromRGBO(190, 190, 190, 1)),
    (Color.fromRGBO(170, 170, 170, 0.91), Color.fromRGBO(170, 170, 170, 0.45)),
    (Color.fromRGBO(185, 185, 185, 1), Color.fromRGBO(185, 185, 185, 1)),
  ],
  bloomLight: [
    (Color.fromRGBO(80, 80, 80, 1), Color.fromRGBO(80, 80, 80, 0.8)),
    (Color.fromRGBO(100, 100, 100, 0.7), Color.fromRGBO(100, 100, 100, 0.46)),
    (Color.fromRGBO(70, 70, 70, 1), Color.fromRGBO(70, 70, 70, 0.82)),
    (Color.fromRGBO(90, 90, 90, 1), Color.fromRGBO(90, 90, 90, 0.7)),
    (Color.fromRGBO(85, 85, 85, 1), Color.fromRGBO(85, 85, 85, 0.78)),
  ],
);

const _ocean = BeamPalette(
  border: [
    Color.fromRGBO(100, 80, 220, 1),
    Color.fromRGBO(60, 120, 255, 1),
    Color.fromRGBO(80, 100, 200, 1),
    Color.fromRGBO(50, 140, 220, 1),
    Color.fromRGBO(120, 80, 255, 1),
    Color.fromRGBO(70, 130, 255, 1),
    Color.fromRGBO(140, 100, 240, 1),
    Color.fromRGBO(90, 110, 230, 1),
    Color.fromRGBO(130, 70, 255, 1),
  ],
  spike: (Color.fromRGBO(100, 120, 255, 1), Color.fromRGBO(130, 100, 220, 0.98)),
  spikeLight: (Color.fromRGBO(60, 60, 180, 1), Color.fromRGBO(80, 100, 200, 1)),
  small: [
    Color.fromRGBO(60, 140, 200, 1),
    Color.fromRGBO(50, 120, 180, 1),
    Color.fromRGBO(100, 80, 220, 1),
    Color.fromRGBO(80, 100, 255, 1),
    Color.fromRGBO(120, 70, 240, 1),
    Color.fromRGBO(90, 80, 220, 1),
    Color.fromRGBO(70, 110, 255, 1),
    Color.fromRGBO(110, 90, 230, 1),
  ],
  smallInner: [
    Color.fromRGBO(60, 140, 200, 0.5),
    Color.fromRGBO(50, 120, 180, 0.45),
    Color.fromRGBO(100, 80, 220, 0.35),
    Color.fromRGBO(80, 100, 255, 0.35),
    Color.fromRGBO(120, 70, 240, 0.3),
    Color.fromRGBO(90, 80, 220, 0.4),
    Color.fromRGBO(70, 110, 255, 0.3),
    Color.fromRGBO(110, 90, 230, 0.3),
  ],
  lineDark: [
    Color.fromRGBO(100, 80, 220, 1),
    Color.fromRGBO(60, 120, 255, 1),
    Color.fromRGBO(80, 100, 200, 1),
    Color.fromRGBO(130, 70, 255, 1),
    Color.fromRGBO(70, 130, 255, 1),
    Color.fromRGBO(120, 80, 255, 1),
    Color.fromRGBO(90, 110, 230, 1),
    Color.fromRGBO(110, 90, 240, 1),
    Color.fromRGBO(140, 100, 255, 1),
  ],
  lineLight: [
    Color.fromRGBO(80, 60, 200, 1),
    Color.fromRGBO(50, 100, 220, 1),
    Color.fromRGBO(70, 90, 190, 1),
    Color.fromRGBO(110, 60, 220, 1),
    Color.fromRGBO(60, 110, 230, 1),
    Color.fromRGBO(100, 70, 240, 1),
    Color.fromRGBO(80, 100, 210, 1),
    Color.fromRGBO(90, 80, 225, 1),
    Color.fromRGBO(120, 90, 245, 1),
  ],
  lineInner: [
    Color.fromRGBO(100, 80, 220, 0.48),
    Color.fromRGBO(60, 120, 255, 0.42),
    Color.fromRGBO(80, 100, 200, 0.48),
    Color.fromRGBO(130, 70, 255, 0.42),
    Color.fromRGBO(70, 130, 255, 0.5),
    Color.fromRGBO(120, 80, 255, 0.45),
    Color.fromRGBO(90, 110, 230, 0.4),
    Color.fromRGBO(110, 90, 240, 0.45),
    Color.fromRGBO(140, 100, 255, 0.52),
  ],
  bloomDark: [
    (Color.fromRGBO(100, 80, 255, 1), Color.fromRGBO(100, 80, 255, 1)),
    (Color.fromRGBO(80, 130, 220, 0.59), Color.fromRGBO(80, 130, 220, 0.29)),
    (Color.fromRGBO(60, 100, 255, 1), Color.fromRGBO(60, 100, 255, 1)),
    (Color.fromRGBO(90, 120, 200, 0.91), Color.fromRGBO(90, 120, 200, 0.45)),
    (Color.fromRGBO(120, 90, 255, 1), Color.fromRGBO(120, 90, 255, 1)),
  ],
  bloomLight: [
    (Color.fromRGBO(50, 40, 180, 1), Color.fromRGBO(50, 40, 180, 0.8)),
    (Color.fromRGBO(40, 80, 200, 0.7), Color.fromRGBO(40, 80, 200, 0.46)),
    (Color.fromRGBO(30, 50, 190, 1), Color.fromRGBO(30, 50, 190, 0.82)),
    (Color.fromRGBO(60, 90, 180, 1), Color.fromRGBO(60, 90, 180, 0.7)),
    (Color.fromRGBO(70, 60, 200, 1), Color.fromRGBO(70, 60, 200, 0.78)),
  ],
);

const _sunset = BeamPalette(
  border: [
    Color.fromRGBO(255, 80, 50, 1),
    Color.fromRGBO(255, 160, 40, 1),
    Color.fromRGBO(255, 120, 60, 1),
    Color.fromRGBO(255, 200, 50, 1),
    Color.fromRGBO(255, 100, 80, 1),
    Color.fromRGBO(255, 180, 60, 1),
    Color.fromRGBO(255, 60, 60, 1),
    Color.fromRGBO(255, 140, 50, 1),
    Color.fromRGBO(255, 90, 70, 1),
  ],
  spike: (Color.fromRGBO(255, 140, 80, 1), Color.fromRGBO(255, 100, 60, 0.98)),
  spikeLight: (Color.fromRGBO(200, 80, 40, 1), Color.fromRGBO(220, 120, 30, 1)),
  small: [
    Color.fromRGBO(255, 180, 50, 1),
    Color.fromRGBO(255, 150, 40, 1),
    Color.fromRGBO(255, 80, 60, 1),
    Color.fromRGBO(255, 100, 80, 1),
    Color.fromRGBO(255, 60, 80, 1),
    Color.fromRGBO(255, 120, 60, 1),
    Color.fromRGBO(255, 200, 50, 1),
    Color.fromRGBO(255, 90, 70, 1),
  ],
  smallInner: [
    Color.fromRGBO(255, 180, 50, 0.5),
    Color.fromRGBO(255, 150, 40, 0.45),
    Color.fromRGBO(255, 80, 60, 0.35),
    Color.fromRGBO(255, 100, 80, 0.35),
    Color.fromRGBO(255, 60, 80, 0.3),
    Color.fromRGBO(255, 120, 60, 0.4),
    Color.fromRGBO(255, 200, 50, 0.3),
    Color.fromRGBO(255, 90, 70, 0.3),
  ],
  lineDark: [
    Color.fromRGBO(255, 100, 60, 1),
    Color.fromRGBO(255, 180, 50, 1),
    Color.fromRGBO(255, 140, 70, 1),
    Color.fromRGBO(255, 80, 80, 1),
    Color.fromRGBO(255, 200, 60, 1),
    Color.fromRGBO(255, 120, 50, 1),
    Color.fromRGBO(255, 160, 80, 1),
    Color.fromRGBO(255, 90, 60, 1),
    Color.fromRGBO(255, 70, 70, 1),
  ],
  lineLight: [
    Color.fromRGBO(220, 80, 40, 1),
    Color.fromRGBO(230, 150, 30, 1),
    Color.fromRGBO(210, 110, 50, 1),
    Color.fromRGBO(200, 60, 60, 1),
    Color.fromRGBO(220, 170, 40, 1),
    Color.fromRGBO(210, 100, 30, 1),
    Color.fromRGBO(230, 130, 60, 1),
    Color.fromRGBO(190, 70, 50, 1),
    Color.fromRGBO(180, 50, 50, 1),
  ],
  lineInner: [
    Color.fromRGBO(255, 100, 60, 0.48),
    Color.fromRGBO(255, 180, 50, 0.42),
    Color.fromRGBO(255, 140, 70, 0.48),
    Color.fromRGBO(255, 80, 80, 0.42),
    Color.fromRGBO(255, 200, 60, 0.5),
    Color.fromRGBO(255, 120, 50, 0.45),
    Color.fromRGBO(255, 160, 80, 0.4),
    Color.fromRGBO(255, 90, 60, 0.45),
    Color.fromRGBO(255, 70, 70, 0.52),
  ],
  bloomDark: [
    (Color.fromRGBO(255, 100, 80, 1), Color.fromRGBO(255, 100, 80, 1)),
    (Color.fromRGBO(255, 150, 80, 0.59), Color.fromRGBO(255, 150, 80, 0.29)),
    (Color.fromRGBO(255, 80, 60, 1), Color.fromRGBO(255, 80, 60, 1)),
    (Color.fromRGBO(255, 120, 50, 0.91), Color.fromRGBO(255, 120, 50, 0.45)),
    (Color.fromRGBO(255, 140, 70, 1), Color.fromRGBO(255, 140, 70, 1)),
  ],
  bloomLight: [
    (Color.fromRGBO(200, 60, 30, 1), Color.fromRGBO(200, 60, 30, 0.8)),
    (Color.fromRGBO(220, 100, 20, 0.7), Color.fromRGBO(220, 100, 20, 0.46)),
    (Color.fromRGBO(180, 40, 20, 1), Color.fromRGBO(180, 40, 20, 0.82)),
    (Color.fromRGBO(210, 80, 10, 1), Color.fromRGBO(210, 80, 10, 0.7)),
    (Color.fromRGBO(190, 70, 30, 1), Color.fromRGBO(190, 70, 30, 0.78)),
  ],
);

final _forest = BeamPalette.fromColors(const [
  Color.fromRGBO(46, 160, 90, 1),
  Color.fromRGBO(30, 190, 120, 1),
  Color.fromRGBO(70, 180, 70, 1),
  Color.fromRGBO(20, 150, 130, 1),
  Color.fromRGBO(90, 200, 80, 1),
  Color.fromRGBO(40, 170, 110, 1),
  Color.fromRGBO(120, 210, 70, 1),
  Color.fromRGBO(35, 145, 100, 1),
  Color.fromRGBO(60, 195, 140, 1),
]);

final _candy = BeamPalette.fromColors(const [
  Color.fromRGBO(240, 70, 170, 1),
  Color.fromRGBO(255, 90, 140, 1),
  Color.fromRGBO(215, 60, 200, 1),
  Color.fromRGBO(255, 110, 180, 1),
  Color.fromRGBO(200, 80, 240, 1),
  Color.fromRGBO(250, 60, 150, 1),
  Color.fromRGBO(230, 120, 220, 1),
  Color.fromRGBO(245, 85, 165, 1),
  Color.fromRGBO(210, 70, 230, 1),
]);

final _ice = BeamPalette.fromColors(const [
  Color.fromRGBO(90, 200, 240, 1),
  Color.fromRGBO(60, 175, 230, 1),
  Color.fromRGBO(130, 220, 250, 1),
  Color.fromRGBO(70, 190, 215, 1),
  Color.fromRGBO(110, 210, 255, 1),
  Color.fromRGBO(50, 165, 220, 1),
  Color.fromRGBO(150, 230, 250, 1),
  Color.fromRGBO(85, 195, 235, 1),
  Color.fromRGBO(65, 180, 245, 1),
]);

final _gold = BeamPalette.fromColors(const [
  Color.fromRGBO(240, 190, 60, 1),
  Color.fromRGBO(255, 210, 90, 1),
  Color.fromRGBO(225, 165, 40, 1),
  Color.fromRGBO(250, 200, 70, 1),
  Color.fromRGBO(255, 225, 120, 1),
  Color.fromRGBO(230, 175, 50, 1),
  Color.fromRGBO(245, 205, 85, 1),
  Color.fromRGBO(215, 155, 35, 1),
  Color.fromRGBO(255, 215, 100, 1),
]);
