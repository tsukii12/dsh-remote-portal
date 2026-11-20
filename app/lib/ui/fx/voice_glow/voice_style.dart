// Portions derived from Libraries.dev Voice (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The look's constants, ported from `voice-glow`: the seven lobes
// (`styles.ts`), the eight palettes and the two theme presets, the band
// colours (`VoiceBeam.tsx`), and the geometry each host type tunes
// (`presets.ts`, as resolved by the author's SwiftUI port).

import 'package:flutter/material.dart';

/// 宿主类型：按包住的东西调光的几何（作者的 `type`）。
enum VoiceBeamType {
  /// 聊天输入框或卡片，约 350 宽（作者的 `default`，SwiftUI 版叫 `standard`）。
  standard,

  /// 约 150×44 的录音胶囊。
  pill,

  /// 手机整屏的底部：范围更宽、升得更高。
  mobile,
}

/// 作者的八套配色，和 border-beam 同一套。
enum VoiceBeamColorVariant { colorful, mono, ocean, sunset, forest, candy, ice, gold }

/// One soft ellipse fanning out from the bottom centre, in px for a ~350px
/// host. `band` is the voice band it follows: 0 lows, 1 mids, 2 highs.
@immutable
class VoiceLobe {
  const VoiceLobe(this.x, this.w, this.h, this.band);

  final double x;
  final double w;
  final double h;
  final int band;
}

/// Centre first, then the pairs outward: the centre follows the lows, its
/// neighbours the mids, the outer pair the highs, the far pair the mids again.
const voiceLobes = <VoiceLobe>[
  VoiceLobe(0, 74, 46, 0),
  VoiceLobe(-36, 54, 40, 1),
  VoiceLobe(36, 54, 40, 1),
  VoiceLobe(-72, 48, 32, 2),
  VoiceLobe(72, 48, 32, 2),
  VoiceLobe(-108, 42, 26, 1),
  VoiceLobe(108, 42, 26, 1),
];

/// Resting distance between neighbouring lobes, px.
const voiceLobeSpacing = 36.0;

/// Width of the ring the lobes travel around — one full turn of the flow.
const voiceLobeSpan = voiceLobeSpacing * 7;

/// The ceiling the glow is masked to, px at multiplier 1.
const voiceCeilingHalfWidth = 170.0;
const voiceCeilingHeight = 64.0;

const _palettes = <VoiceBeamColorVariant, (List<Color>, List<Color>)>{
  VoiceBeamColorVariant.colorful: (
    [
      Color.fromARGB(255, 255, 70, 120),
      Color.fromARGB(255, 60, 190, 255),
      Color.fromARGB(255, 175, 70, 255),
      Color.fromARGB(255, 60, 220, 130),
      Color.fromARGB(255, 255, 150, 40),
      Color.fromARGB(255, 90, 100, 255),
      Color.fromARGB(255, 40, 200, 190),
    ],
    [
      Color.fromARGB(255, 255, 201, 21),
      Color.fromARGB(255, 126, 196, 255),
      Color.fromARGB(255, 180, 40, 230),
      Color.fromARGB(255, 235, 100, 160),
      Color.fromARGB(255, 255, 176, 122),
      Color.fromARGB(255, 154, 160, 255),
      Color.fromARGB(255, 127, 217, 238),
    ],
  ),
  VoiceBeamColorVariant.mono: (
    [
      Color.fromARGB(255, 215, 215, 215),
      Color.fromARGB(255, 180, 180, 180),
      Color.fromARGB(255, 190, 190, 190),
      Color.fromARGB(255, 160, 160, 160),
      Color.fromARGB(255, 170, 170, 170),
      Color.fromARGB(255, 150, 150, 150),
      Color.fromARGB(255, 155, 155, 155),
    ],
    [
      Color.fromARGB(255, 60, 60, 60),
      Color.fromARGB(255, 90, 90, 90),
      Color.fromARGB(255, 85, 85, 85),
      Color.fromARGB(255, 110, 110, 110),
      Color.fromARGB(255, 105, 105, 105),
      Color.fromARGB(255, 125, 125, 125),
      Color.fromARGB(255, 120, 120, 120),
    ],
  ),
  VoiceBeamColorVariant.ocean: (
    [
      Color.fromARGB(255, 80, 140, 255),
      Color.fromARGB(255, 40, 200, 230),
      Color.fromARGB(255, 120, 90, 255),
      Color.fromARGB(255, 30, 170, 210),
      Color.fromARGB(255, 160, 80, 240),
      Color.fromARGB(255, 60, 110, 255),
      Color.fromARGB(255, 40, 190, 180),
    ],
    [
      Color.fromARGB(255, 40, 100, 240),
      Color.fromARGB(255, 20, 160, 200),
      Color.fromARGB(255, 90, 60, 230),
      Color.fromARGB(255, 20, 130, 180),
      Color.fromARGB(255, 130, 50, 220),
      Color.fromARGB(255, 40, 80, 230),
      Color.fromARGB(255, 20, 150, 150),
    ],
  ),
  VoiceBeamColorVariant.sunset: (
    [
      Color.fromARGB(255, 255, 110, 60),
      Color.fromARGB(255, 255, 180, 40),
      Color.fromARGB(255, 255, 60, 90),
      Color.fromARGB(255, 255, 210, 80),
      Color.fromARGB(255, 240, 70, 140),
      Color.fromARGB(255, 255, 140, 50),
      Color.fromARGB(255, 230, 50, 110),
    ],
    [
      Color.fromARGB(255, 235, 80, 30),
      Color.fromARGB(255, 230, 150, 10),
      Color.fromARGB(255, 230, 30, 70),
      Color.fromARGB(255, 225, 175, 30),
      Color.fromARGB(255, 215, 40, 110),
      Color.fromARGB(255, 235, 110, 20),
      Color.fromARGB(255, 205, 30, 90),
    ],
  ),
  VoiceBeamColorVariant.forest: (
    [
      Color.fromARGB(255, 70, 220, 120),
      Color.fromARGB(255, 40, 200, 180),
      Color.fromARGB(255, 140, 230, 80),
      Color.fromARGB(255, 30, 170, 140),
      Color.fromARGB(255, 190, 235, 70),
      Color.fromARGB(255, 50, 190, 110),
      Color.fromARGB(255, 30, 150, 120),
    ],
    [
      Color.fromARGB(255, 30, 170, 80),
      Color.fromARGB(255, 20, 150, 130),
      Color.fromARGB(255, 90, 180, 30),
      Color.fromARGB(255, 20, 130, 100),
      Color.fromARGB(255, 130, 180, 20),
      Color.fromARGB(255, 30, 150, 80),
      Color.fromARGB(255, 20, 120, 90),
    ],
  ),
  VoiceBeamColorVariant.candy: (
    [
      Color.fromARGB(255, 255, 90, 170),
      Color.fromARGB(255, 255, 120, 220),
      Color.fromARGB(255, 210, 80, 255),
      Color.fromARGB(255, 255, 150, 190),
      Color.fromARGB(255, 180, 110, 255),
      Color.fromARGB(255, 255, 70, 140),
      Color.fromARGB(255, 230, 100, 240),
    ],
    [
      Color.fromARGB(255, 235, 40, 140),
      Color.fromARGB(255, 230, 70, 190),
      Color.fromARGB(255, 180, 40, 230),
      Color.fromARGB(255, 235, 100, 160),
      Color.fromARGB(255, 150, 70, 230),
      Color.fromARGB(255, 230, 30, 110),
      Color.fromARGB(255, 200, 60, 210),
    ],
  ),
  VoiceBeamColorVariant.ice: (
    [
      Color.fromARGB(255, 150, 230, 255),
      Color.fromARGB(255, 90, 200, 255),
      Color.fromARGB(255, 190, 240, 255),
      Color.fromARGB(255, 120, 190, 255),
      Color.fromARGB(255, 160, 220, 250),
      Color.fromARGB(255, 80, 170, 255),
      Color.fromARGB(255, 200, 235, 255),
    ],
    [
      Color.fromARGB(255, 30, 160, 220),
      Color.fromARGB(255, 20, 130, 210),
      Color.fromARGB(255, 60, 180, 230),
      Color.fromARGB(255, 40, 120, 220),
      Color.fromARGB(255, 50, 160, 220),
      Color.fromARGB(255, 20, 110, 220),
      Color.fromARGB(255, 70, 170, 230),
    ],
  ),
  VoiceBeamColorVariant.gold: (
    [
      Color.fromARGB(255, 255, 200, 70),
      Color.fromARGB(255, 255, 170, 40),
      Color.fromARGB(255, 255, 220, 110),
      Color.fromARGB(255, 240, 150, 30),
      Color.fromARGB(255, 255, 235, 140),
      Color.fromARGB(255, 230, 160, 40),
      Color.fromARGB(255, 250, 210, 90),
    ],
    [
      Color.fromARGB(255, 200, 140, 10),
      Color.fromARGB(255, 190, 120, 0),
      Color.fromARGB(255, 210, 160, 30),
      Color.fromARGB(255, 180, 110, 0),
      Color.fromARGB(255, 205, 170, 40),
      Color.fromARGB(255, 175, 115, 5),
      Color.fromARGB(255, 195, 150, 20),
    ],
  ),
};

/// The seven lobe colours of an author palette, centre first.
List<Color> voicePalette(VoiceBeamColorVariant variant, {required bool dark}) {
  final (darkColors, lightColors) = _palettes[variant]!;
  return dark ? darkColors : lightColors;
}

/// 默认配色：跟着主题色走——主色和它两侧相邻的色相，饱和度压低，亮暗跟主题
/// （和通话页 `CallPalette.of` 同一个思路）。中心是主色，往外每对各偏一点，
/// 所以流动时屏幕上相邻的总是相邻的色相，不会出现彩虹。浅色背景上淡色会化进
/// 白里，所以浅色时饱和度高一点、颜色深一点（作者的浅色配色也是这样）。
List<Color> voiceThemeColors(ColorScheme scheme, {required bool dark}) {
  final base = HSLColor.fromColor(scheme.primary);
  final sat = dark ? (base.saturation * 0.62).clamp(0.28, 0.5) : (base.saturation * 0.8).clamp(0.4, 0.6);
  // Centre, then the pairs outward: ring positions 0, −1, +1, −2, +2, −3, +3.
  const shifts = [0.0, -14.0, 14.0, -28.0, 28.0, -42.0, 42.0];
  const lift = [0.0, 0.03, -0.02, 0.05, 0.0, 0.06, 0.03];
  final l = dark ? 0.66 : 0.54;
  return [
    for (var i = 0; i < shifts.length; i++)
      HSLColor.fromAHSL(1, (base.hue + shifts[i]) % 360, sat, (l + lift[i]).clamp(0.0, 1.0)).toColor(),
  ];
}

/// The band's colours: the core ridge and its chromatic fringes above,
/// between and below.
@immutable
class VoiceBandColors {
  const VoiceBandColors({required this.core, required this.above, required this.mid, required this.below});

  /// White core with red / green / blue fringes on dark.
  static const dark = VoiceBandColors(
    core: Color.fromARGB(255, 255, 255, 255),
    above: Color.fromARGB(255, 255, 70, 80),
    mid: Color.fromARGB(255, 90, 255, 150),
    below: Color.fromARGB(255, 80, 140, 255),
  );

  /// A lavender core with rose / sky / mint on light.
  static const light = VoiceBandColors(
    core: Color.fromARGB(255, 197, 139, 255),
    above: Color.fromARGB(255, 255, 122, 182),
    mid: Color.fromARGB(255, 126, 196, 255),
    below: Color.fromARGB(255, 45, 255, 171),
  );

  /// The theme-following band: the fringes are the theme hue's neighbours
  /// instead of red, green and blue.
  factory VoiceBandColors.theme(ColorScheme scheme, {required bool dark}) {
    final base = HSLColor.fromColor(scheme.primary);
    final sat = (base.saturation * 0.8).clamp(0.4, 0.62);
    Color tone(double shift, double l) => HSLColor.fromAHSL(1, (base.hue + shift) % 360, sat, l).toColor();
    return dark
        ? VoiceBandColors(
            core: const Color(0xFFFFFFFF),
            above: tone(-36, 0.7),
            mid: tone(12, 0.8),
            below: tone(36, 0.64),
          )
        : VoiceBandColors(core: tone(0, 0.76), above: tone(-36, 0.72), mid: tone(16, 0.74), below: tone(40, 0.6));
  }

  final Color core;
  final Color above;
  final Color mid;
  final Color below;
}

/// The per-theme layer weights and colour tuning (`themePresets`).
@immutable
class VoiceThemePreset {
  const VoiceThemePreset._({
    required this.strokeOpacity,
    required this.innerOpacity,
    required this.bloomOpacity,
    required this.innerShadow,
    required this.saturation,
    required this.brightness,
    required this.hueRange,
    required this.hueDuration,
    required this.hueBase,
    required this.strength,
  });

  static const dark = VoiceThemePreset._(
    strokeOpacity: 1.16,
    innerOpacity: 0.47,
    bloomOpacity: 0.89,
    innerShadow: Color.fromRGBO(255, 255, 255, 0.1),
    saturation: 1.2,
    brightness: 1.1,
    hueRange: 24,
    hueDuration: 12,
    hueBase: 0,
    strength: 1,
  );

  /// On white: the deep light palettes at far higher opacity, a touch less
  /// brightness, a wider and quicker hue drift nudged 5° warmer.
  static const light = VoiceThemePreset._(
    strokeOpacity: 1.2,
    innerOpacity: 0.85,
    bloomOpacity: 0.5,
    innerShadow: Color.fromRGBO(0, 0, 0, 0.08),
    saturation: 1.6,
    brightness: 0.95,
    hueRange: 40,
    hueDuration: 8.5,
    hueBase: 5,
    strength: 0.8,
  );

  final double strokeOpacity;
  final double innerOpacity;
  final double bloomOpacity;
  final Color innerShadow;
  final double saturation;
  final double brightness;
  final double hueRange;
  final double hueDuration;
  final double hueBase;
  final double strength;
}

/// The colour tuning a type carries on top of the theme preset
/// (`voiceTypeStyle`): null keeps the theme's own.
({double? brightness, double? saturation, double? strength}) voiceTypeStyle(VoiceBeamType type, {required bool dark}) =>
    switch ((type, dark)) {
      (VoiceBeamType.standard, true) => (brightness: 1.15, saturation: null, strength: null),
      (VoiceBeamType.pill, true) => (brightness: 1.35, saturation: 1.5, strength: null),
      (VoiceBeamType.mobile, true) => (brightness: 1.2, saturation: 1.5, strength: 1.0),
      (VoiceBeamType.mobile, false) => (brightness: null, saturation: null, strength: 1.0),
      (_, false) => (brightness: null, saturation: null, strength: null),
    };

/// The geometry and response knobs a type preset tunes (`VoiceGeometry` in
/// `presets.ts`). Lengths are px for the default host; [scaled] multiplies
/// them by `scale` the way the component does.
@immutable
class VoiceGeometry {
  const VoiceGeometry({
    this.scale = 1,
    this.glowSize = 1,
    this.strokeOpacity = 1,
    this.innerOpacity = 1,
    this.bloomOpacity = 1,
    this.idle = 0.18,
    this.reach = 1.2,
    this.spread = 1.05,
    this.flow = 48,
    this.bend = 60,
    this.bandStrength = 1.55,
    this.bandWidth = 2.15,
    this.bandPosition = 0.35,
    this.bandCurve = 1.75,
    this.bandSpread = 0.87,
    this.bandSkew = 0.12,
    this.bandOffset = -27,
    this.bandTail = 0.59,
    this.bandTailPosition = 0.67,
    this.bandTailCurve = 2.4,
    this.bandTailOverflow = 15,
    this.bandAberration = 0.89,
    this.glowWidth = 0.65,
    this.glowHeight = 1.25,
    this.lobeSpacing = 0.85,
    this.rangeWidth = 0.75,
    this.rangeHeight = 1,
    this.softness = 1.07,
    this.coreSize = 1,
    this.coreLight = 0,
    this.coreLightWidth = 1,
    this.coreLightHeight = 1,
    this.strokeScale = 1,
    this.innerScale = 1,
    this.innerHeight = 1,
    this.bloomScale = 1,
    this.bloomHeight = 1,
  });

  /// The full geometry for a type on a theme: the defaults, the light
  /// theme's own tweaks where the type leaves them alone, the type, then the
  /// type's light-theme band strength — the order `resolveVoiceDefaults`
  /// applies.
  factory VoiceGeometry.resolve(VoiceBeamType type, {required bool dark}) => switch (type) {
    VoiceBeamType.standard =>
      dark ? const VoiceGeometry() : const VoiceGeometry(reach: 1.8, spread: 0.8, coreLight: 1.8, bandStrength: 1.7),
    VoiceBeamType.pill => VoiceGeometry(
      scale: 0.45,
      glowSize: 0.95,
      strokeOpacity: 1.2,
      innerOpacity: 0.85,
      reach: 1.35,
      spread: 1.1,
      flow: 0,
      bend: 23,
      bandStrength: dark ? 1.55 : 2,
      bandWidth: 1.85,
      bandCurve: 1.95,
      bandSpread: 0.38,
      bandOffset: -16,
      bandTail: 0,
      glowWidth: 0.65,
      glowHeight: 0.95,
      lobeSpacing: 0.45,
      rangeWidth: 0.8,
      rangeHeight: 0.7,
      softness: 0.88,
      coreSize: 0.25,
      coreLight: dark ? 0 : 1.8,
      strokeScale: 1.25,
      innerScale: 0.95,
      bloomScale: 1.05,
      bloomHeight: 2.25,
    ),
    VoiceBeamType.mobile => VoiceGeometry(
      scale: 1.25,
      spread: 0.45,
      reach: 3,
      flow: 60,
      bend: 70,
      bandWidth: 2.4,
      bandCurve: 1.55,
      bandSpread: 0.9,
      bandOffset: -50,
      bandTail: 0.62,
      bandTailPosition: 0.42,
      bandTailCurve: 2.7,
      bandTailOverflow: 22,
      bandStrength: dark ? 1.8 : 1.7,
      glowWidth: 1.15,
      glowHeight: 2.1,
      lobeSpacing: 1.35,
      rangeWidth: 1.25,
      rangeHeight: 1.2,
      softness: 1.1,
      coreLight: dark ? 0 : 1.8,
    ),
  };

  final double scale;
  final double glowSize;
  final double strokeOpacity;
  final double innerOpacity;
  final double bloomOpacity;
  final double idle;
  final double reach;
  final double spread;
  final double flow;
  final double bend;
  final double bandStrength;
  final double bandWidth;
  final double bandPosition;
  final double bandCurve;
  final double bandSpread;
  final double bandSkew;
  final double bandOffset;
  final double bandTail;
  final double bandTailPosition;
  final double bandTailCurve;
  final double bandTailOverflow;
  final double bandAberration;
  final double glowWidth;
  final double glowHeight;
  final double lobeSpacing;
  final double rangeWidth;
  final double rangeHeight;
  final double softness;
  final double coreSize;
  final double coreLight;
  final double coreLightWidth;
  final double coreLightHeight;
  final double strokeScale;
  final double innerScale;
  final double innerHeight;
  final double bloomScale;
  final double bloomHeight;

  /// The knobs the widget exposes, over the preset; then every px length
  /// multiplied by the scale, as `VoiceBeam.tsx` does before it builds the
  /// stylesheet and the driver config.
  VoiceGeometry resolved({
    double? scale,
    double? glowSize,
    double? idle,
    double? reach,
    double? spread,
    double? flow,
    double? bend,
    double? bandStrength,
    double? bandWidth,
  }) {
    final sc = (scale ?? this.scale) < 0.05 ? 0.05 : (scale ?? this.scale);
    return VoiceGeometry(
      scale: sc,
      glowSize: (glowSize ?? this.glowSize) * sc,
      strokeOpacity: strokeOpacity,
      innerOpacity: innerOpacity,
      bloomOpacity: bloomOpacity,
      idle: (idle ?? this.idle).clamp(0.0, 1.0),
      reach: reach ?? this.reach,
      spread: spread ?? this.spread,
      flow: (flow ?? this.flow) * sc,
      bend: (bend ?? this.bend) * sc,
      bandStrength: bandStrength ?? this.bandStrength,
      bandWidth: (bandWidth ?? this.bandWidth) * sc,
      bandPosition: bandPosition,
      bandCurve: bandCurve,
      bandSpread: bandSpread,
      bandSkew: bandSkew,
      bandOffset: bandOffset * sc,
      bandTail: bandTail,
      bandTailPosition: bandTailPosition,
      bandTailCurve: bandTailCurve,
      bandTailOverflow: bandTailOverflow * sc,
      bandAberration: bandAberration,
      glowWidth: glowWidth * sc,
      glowHeight: glowHeight * sc,
      lobeSpacing: lobeSpacing * sc,
      rangeWidth: rangeWidth * sc,
      rangeHeight: rangeHeight * sc,
      softness: softness,
      coreSize: coreSize * sc,
      coreLight: coreLight,
      coreLightWidth: coreLightWidth,
      coreLightHeight: coreLightHeight,
      strokeScale: strokeScale,
      innerScale: innerScale,
      innerHeight: innerHeight,
      bloomScale: bloomScale,
      bloomHeight: bloomHeight,
    );
  }
}
