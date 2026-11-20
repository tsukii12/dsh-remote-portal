// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 生图占位的三个预设（原库的 `preset`）：决定马赛克跑哪种效果。
enum ImageGenerationPreset {
  /// Chromium Flow 做成像素马赛克：柔和、云一样的块。原库默认。
  pixelsOrganic,

  /// Nebula 做成像素马赛克：更硬、贴着网格的块。
  pixelsMechanic,

  /// Gradient Sweep：一条斜带从左上扫到右下，格子跟着闪。
  sweepGradient;

  /// The preset's dark or light tuning block.
  FxPresetMode mode(Brightness brightness) => switch ((this, brightness)) {
    (pixelsOrganic, Brightness.dark) => _organicDark,
    (pixelsOrganic, Brightness.light) => _organicLight,
    (pixelsMechanic, Brightness.dark) => _mechanicDark,
    (pixelsMechanic, Brightness.light) => _mechanicLight,
    (sweepGradient, Brightness.dark) => _sweepDark,
    (sweepGradient, Brightness.light) => _sweepLight,
  };

  /// The regenerate churn always runs on one of these (`PIXEL_CHURN_PRESETS`).
  bool get isPixelChurn => this != sweepGradient;
}

/// `pixelConfig`: the pixel-mosaic cell settings (dotMode 1).
@immutable
class FxMosaicConfig {
  const FxMosaicConfig({
    required this.cellSize,
    required this.gap,
    required this.dotOpacity,
    required this.hlScale,
    required this.fillOpacity,
    required this.edgeFade,
    required this.fadeStr,
  });

  /// 0..1, `6 + cellSize * 74` cells across a 320 px card.
  final double cellSize;
  final double gap;
  final double dotOpacity;
  final double hlScale;
  final double fillOpacity;

  /// Edge fade band, CSS px.
  final double edgeFade;
  final double fadeStr;
}

/// `revealConfig.maskShape` as the bundled presets use it: `shaderColorN` (the
/// image shows where the live field comes close to palette slot N) or
/// `gradientSweep` (a diagonal band).
@immutable
class FxRevealMask {
  const FxRevealMask.shaderColor(this.slot);
  const FxRevealMask.gradientSweep() : slot = -1;

  /// 0-based palette slot; -1 for the sweep.
  final int slot;

  bool get isSweep => slot < 0;
}

/// `revealConfig`. Every bundled preset eases both the mask and the cell
/// dissolve with `easeOutCubic` and has no reveal blur, so those keys are not
/// carried.
@immutable
class FxRevealConfig {
  const FxRevealConfig({required this.duration, required this.mask, required this.softness, required this.pixDuration});

  /// Mask animation, seconds.
  final double duration;
  final FxRevealMask mask;
  final double softness;

  /// Per-cell chunky-to-smooth dissolve, seconds.
  final double pixDuration;
}

/// One theme block of a preset (the JSON shape of `presets/*.ts`, pixel mode).
@immutable
class FxPresetMode {
  const FxPresetMode({
    required this.effectIndex,
    required this.colors,
    required this.cardBg,
    required this.pixel,
    required this.direction,
    required this.speed,
    required this.intensity,
    required this.scale,
    required this.softness,
    required this.distortion,
    this.flicker = 0,
    required this.complexity,
    required this.shape,
    required this.blur,
    required this.highlight,
    required this.vignette,
    required this.vigOpacity,
    required this.shaderOpacity,
    this.sweepEase = 0,
    required this.reveal,
  });

  final int effectIndex;

  /// Seven palette slots; the shader reads the first five.
  final List<Color> colors;
  final Color cardBg;
  final FxMosaicConfig pixel;

  /// Drift angle, degrees.
  final double direction;
  final double speed;
  final double intensity;
  final double scale;
  final double softness;
  final double distortion;
  final double flicker;
  final double complexity;
  final double shape;
  final double blur;
  final double highlight;
  final double vignette;
  final double vigOpacity;
  final double shaderOpacity;
  final double sweepEase;
  final FxRevealConfig reveal;
}

const _pixelDark = FxMosaicConfig(
  cellSize: 0.22,
  gap: 0.14,
  dotOpacity: 0.68,
  hlScale: 0.8,
  fillOpacity: 0.44,
  edgeFade: 24,
  fadeStr: 1,
);
const _pixelLight = FxMosaicConfig(
  cellSize: 0.22,
  gap: 0.14,
  dotOpacity: 0.68,
  hlScale: 0.8,
  fillOpacity: 0.18,
  edgeFade: 20,
  fadeStr: 1,
);

// pixels-organic: preset-pixels-style-3.json, Chromium Flow.
const _organicDark = FxPresetMode(
  effectIndex: 22,
  colors: [
    Color(0xFF0F0F0F),
    Color(0xFF4A4949),
    Color(0xFFB9B9B9),
    Color(0xFF0F0F0F),
    Color(0xFFD8D8D8),
    Color(0xFF0F0F0F),
    Color(0xFF2F2F2F),
  ],
  cardBg: Color(0xFF0F0F0F),
  pixel: _pixelDark,
  direction: 0,
  speed: 0.3,
  intensity: 1,
  scale: 1,
  softness: 0.76,
  distortion: 0.3,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.2,
  vignette: 0.26,
  vigOpacity: 1,
  shaderOpacity: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.shaderColor(3), softness: 0.5, pixDuration: 2.65),
);
const _organicLight = FxPresetMode(
  effectIndex: 22,
  colors: [
    Color(0xFFE3E3E3),
    Color(0xFFFFFFFF),
    Color(0xFFF5F5F5),
    Color(0xFFF5F5F5),
    Color(0xFF080808),
    Color(0xFFF5F5F5),
    Color(0xFFF5F5F5),
  ],
  cardBg: Color(0xFFF5F5F5),
  pixel: _pixelLight,
  direction: 25,
  speed: 0.3,
  intensity: 0.85,
  scale: 1,
  softness: 0.76,
  distortion: 0.3,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.7,
  vignette: 0,
  vigOpacity: 0,
  shaderOpacity: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.shaderColor(3), softness: 0.5, pixDuration: 2.55),
);

// pixels-mechanic: preset-pixels-style-4.json, Nebula.
const _mechanicDark = FxPresetMode(
  effectIndex: 11,
  colors: [
    Color(0xFF949494),
    Color(0xFF2D2D2D),
    Color(0xFF333333),
    Color(0xFF3A3A3A),
    Color(0xFF0B0B0B),
    Color(0xFF060606),
    Color(0xFF2F2F2F),
  ],
  cardBg: Color(0xFF0F0F0F),
  pixel: _pixelDark,
  direction: 0,
  speed: 0.7,
  intensity: 1,
  scale: 1.4,
  softness: 0.76,
  distortion: 0.3,
  flicker: 0.5,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.32,
  vignette: 0.26,
  vigOpacity: 1,
  shaderOpacity: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.shaderColor(3), softness: 0.5, pixDuration: 2.65),
);
const _mechanicLight = FxPresetMode(
  effectIndex: 11,
  colors: [
    Color(0xFFE0E0E0),
    Color(0xFFFDFDFD),
    Color(0xFFF2F2F2),
    Color(0xFF0A0A0A),
    Color(0xFFDCDCDC),
    Color(0xFFF5F5F5),
    Color(0xFFF5F5F5),
  ],
  cardBg: Color(0xFFF5F5F5),
  pixel: _pixelLight,
  direction: 25,
  speed: 0.55,
  intensity: 0.85,
  scale: 0.9,
  softness: 0.76,
  distortion: 0.3,
  flicker: 0.5,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.92,
  vignette: 0,
  vigOpacity: 0,
  shaderOpacity: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.shaderColor(2), softness: 0.5, pixDuration: 2.6),
);

// sweep-gradient: Gradient Sweep defaults.
const _sweepDark = FxPresetMode(
  effectIndex: 25,
  colors: [
    Color(0xFF0F0F0F),
    Color(0xFF0F0F0F),
    Color(0xFF282828),
    Color(0xFF3A3A3A),
    Color(0xFF525252),
    Color(0xFF0F0F0F),
    Color(0xFF0F0F0F),
  ],
  cardBg: Color(0xFF0F0F0F),
  pixel: _pixelDark,
  direction: 0,
  speed: 2.65,
  intensity: 1,
  scale: 1,
  softness: 0.76,
  distortion: 0.3,
  flicker: 0.5,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.32,
  vignette: 0.26,
  vigOpacity: 1,
  shaderOpacity: 1,
  sweepEase: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.gradientSweep(), softness: 0.5, pixDuration: 2.65),
);
const _sweepLight = FxPresetMode(
  effectIndex: 25,
  colors: [
    Color(0xFFF5F5F5),
    Color(0xFFF5F5F5),
    Color(0xFFEDEDED),
    Color(0xFFEAEAEA),
    Color(0xFFD2D2D2),
    Color(0xFFF5F5F5),
    Color(0xFFF5F5F5),
  ],
  cardBg: Color(0xFFF5F5F5),
  pixel: _pixelLight,
  direction: 0,
  speed: 2.65,
  intensity: 0.85,
  scale: 1,
  softness: 0.76,
  distortion: 0.3,
  flicker: 0.5,
  complexity: 0.2,
  shape: 0.52,
  blur: 1,
  highlight: 0.92,
  vignette: 0,
  vigOpacity: 0,
  shaderOpacity: 1,
  sweepEase: 1,
  reveal: FxRevealConfig(duration: 3, mask: FxRevealMask.gradientSweep(), softness: 0.5, pixDuration: 2.6),
);

/// `EASING_FNS.easeOutCubic`, the only easing the bundled presets use.
double easeOutCubic(double t) {
  final u = 1 - t.clamp(0.0, 1.0);
  return 1 - u * u * u;
}

/// The preset `cellSize` for a `pixelScale` (renderer.ts `effectiveCellSize`):
/// scaling the cell size divides the base cell count.
double effectiveCellSize(double cellSize, double pixelScale) {
  if (!(pixelScale > 0) || pixelScale == 1) return cellSize;
  final baseCount = (6 + cellSize * 74) / pixelScale;
  return (baseCount - 6) / 74;
}

/// Cells along x / y on a card of [size] CSS px (`gridCounts` in the shader,
/// the anisotropic grid of the reveal): cells stay square, a 320 px edge gets
/// `6 + cellSize * 74` of them.
(int, int) fxGrid(double cellSize, Size size) {
  final base = 6 + cellSize * 74;
  return (math.max(2, (base * size.width / 320).floor()), math.max(2, (base * size.height / 320).floor()));
}

/// Rec. 601 luma, as the shader and the palette sampler weigh colours.
double fxLuma(Color c) => 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;

/// The colours the effect runs with: seven palette slots and the card surface
/// the shader fades cells against.
@immutable
class FxLook {
  const FxLook(this.colors, this.cardBg);

  /// The preset's own palette (renderer.ts `effectivePaletteColor`): with a
  /// [cardBg] override, slots authored as the preset's card colour follow it;
  /// a non-null [colors] slot replaces the preset colour verbatim.
  factory FxLook.preset(FxPresetMode mode, {Color? cardBg, List<Color?>? colors}) {
    final bg = cardBg ?? mode.cardBg;
    return FxLook([
      for (var i = 0; i < 7; i++)
        _slot(colors, i) ?? (cardBg != null && _same8(mode.colors[i], mode.cardBg) ? cardBg : mode.colors[i]),
    ], bg);
  }

  /// 跟主题走的配色：保留预设的明暗结构（哪几格暗、哪几格亮、和卡片底色差多少），
  /// 染上主色的色相和左右邻居，饱和度压低。和预设卡片底色相同的格子直接用 [cardBg]。
  factory FxLook.themed(FxPresetMode mode, Color primary, Color cardBg, {List<Color?>? colors}) {
    final base = HSLColor.fromColor(primary);
    final sat = (base.saturation * 0.45).clamp(0.1, 0.3);
    final lp = fxLuma(mode.cardBg);
    final lt = fxLuma(cardBg);
    // Neighbouring hues by brightness: darker slots lean one way, lighter the other.
    final order = [for (var i = 0; i < 7; i++) i]
      ..sort((a, b) {
        final c = fxLuma(mode.colors[a]).compareTo(fxLuma(mode.colors[b]));
        return c != 0 ? c : a.compareTo(b);
      });
    final rank = List<int>.filled(7, 0);
    for (var r = 0; r < 7; r++) {
      rank[order[r]] = r;
    }
    Color tone(int i) {
      final v = fxLuma(mode.colors[i]);
      // Keep each slot's distance from the card: towards white above it,
      // towards black below it.
      final l = v >= lp ? lt + (v - lp) * (1 - lt) / math.max(1e-6, 1 - lp) : lt - (lp - v) * lt / math.max(1e-6, lp);
      final shift = (rank[i] / 6 - 0.5) * 36;
      return HSLColor.fromAHSL(1, (base.hue + shift) % 360, sat, l.clamp(0.0, 1.0)).toColor();
    }

    return FxLook([
      for (var i = 0; i < 7; i++) _slot(colors, i) ?? (_same8(mode.colors[i], mode.cardBg) ? cardBg : tone(i)),
    ], cardBg);
  }

  final List<Color> colors;
  final Color cardBg;

  static Color? _slot(List<Color?>? colors, int i) => colors != null && i < colors.length ? colors[i] : null;

  static bool _same8(Color a, Color b) => a.toARGB32() & 0xFFFFFF == b.toARGB32() & 0xFFFFFF;

  @override
  bool operator ==(Object other) => other is FxLook && other.cardBg == cardBg && _sameColors(other.colors, colors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    for (var i = 0; i < 7; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(cardBg, Object.hashAll(colors));
}

/// Edge of the square the regenerate tint is sampled at (palette.ts `GRID`).
const fxTintGrid = 24;

/// palette.ts `samplePaletteFromCanvas`: the image's colours mapped onto the
/// preset's seven slots by luminance rank (5th..95th percentile), and the
/// image's average colour as the card. [rgba] is the [fxTintGrid]² cover-fit
/// image. Null when every pixel is transparent.
FxLook? sampleTint(Uint8List rgba, List<Color> presetColors) {
  final idx = <int>[];
  final lum = <double>[];
  var ar = 0.0, ag = 0.0, ab = 0.0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 8) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    idx.add(i);
    lum.add(0.299 * r + 0.587 * g + 0.114 * b);
    ar += r;
    ag += g;
    ab += b;
  }
  if (idx.isEmpty) return null;
  // Array.prototype.sort is stable: ties keep pixel order.
  final px = [for (var k = 0; k < idx.length; k++) k]
    ..sort((a, b) {
      final c = lum[a].compareTo(lum[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  final n = idx.length;
  final ranked = [for (var s = 0; s < presetColors.length; s++) s]
    ..sort((a, b) {
      final c = fxLuma(presetColors[a]).compareTo(fxLuma(presetColors[b]));
      return c != 0 ? c : a.compareTo(b);
    });
  final colors = List<Color>.filled(presetColors.length, const Color(0xFF000000));
  for (var rank = 0; rank < ranked.length; rank++) {
    final q = 0.05 + (0.9 * rank) / math.max(1, ranked.length - 1);
    final i = idx[px[math.min(n - 1, (q * (n - 1)).round())]];
    colors[ranked[rank]] = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
  }
  return FxLook(colors, Color.fromARGB(255, (ar / n).round(), (ag / n).round(), (ab / n).round()));
}
