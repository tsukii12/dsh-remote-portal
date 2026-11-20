// 壁纸上的字怎么保证读得清：一条亮度界限，两头各管一半。
//
//   壁纸那头（wallpaper_render.dart）：每一小格背景都烘到界限之内 —— 浅色不暗于、深色不亮于
//   「二级文字恰好 4.6:1」的亮度（深色按卡片、胶囊那层薄白算，卡片里的字也够）。不够的格子叠一层页面色（浅色是晨雾、深色是石板），只叠到
//   刚好够，再扩散、抹匀成渐变；顶上（状态栏 + 顶栏）和底下（输入区 + 导航条）的界限更靠近
//   页面本色，所以那两条在需要时会自己长出一层渐变遮罩。
//
//   文字那头（guardTheme）：比二级文字还淡的颜色（三级文字、主色、状态色）在壁纸上挪一点
//   明度，挪到对这条界限也有 4.6:1。主文字和二级文字本来就够。
//
// 4.6 而不是 4.5：留一点给 8 位取整和合成。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme/accent.dart';
import '../ui/theme/oklch.dart';
import '../ui/theme/palette.dart';
import '../ui/theme/semantic_colors.dart';
import '../ui/theme/surfaces.dart';

/// The contrast every text colour keeps on the wallpaper (WCAG AA is 4.5).
const double wallpaperContrast = 4.6;

/// WCAG contrast of two relative luminances.
double contrastOf(double a, double b) => (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);

/// One palette's page in one mode, as the wallpaper sees it.
@immutable
class WallpaperLook {
  const WallpaperLook({
    required this.brightness,
    required this.veilTop,
    required this.veilBottom,
    required this.bound,
    required this.edgeBound,
    this.lift = 0,
  });

  /// The look for [accent]'s page in [brightness] (what the app's own theme is built from).
  factory WallpaperLook.forAccent(AppAccent accent, Brightness brightness) =>
      _cache[(accent, brightness)] ??= _make(accent, brightness);

  /// The look for the page [context] is on. Follows a theme change at its midpoint, not every
  /// frame of the cross-fade.
  factory WallpaperLook.of(BuildContext context) {
    final theme = Theme.of(context);
    return WallpaperLook.forAccent(DshSurfaces.of(context).accent, theme.brightness);
  }

  static final _cache = <(AppAccent, Brightness), WallpaperLook>{};

  /// How far toward black the dark page's veil is taken.
  static const deepen = 0.55;

  static WallpaperLook _make(AppAccent accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surfaces = dark ? DshSurfaces.dark(accent) : DshSurfaces.light(accent);
    final scheme = dark ? DshPalette.darkScheme(accent) : DshPalette.lightScheme(accent);
    final secondary = scheme.onSurfaceVariant.computeLuminance();
    final bound = dark ? (secondary + 0.05) / wallpaperContrast - 0.05 : wallpaperContrast * (secondary + 0.05) - 0.05;
    // Dark cards and pills are a little white over the page, and text sits on them too.
    final lift = dark
        ? [
            for (final g in [surfaces.card, surfaces.pill]) ...[g.fill.a, g.fallbackFill.a],
          ].reduce(math.max)
        : 0.0;
    double lum(Color c) => liftOf(c, lift).computeLuminance();
    final top = lum(surfaces.backdropTop);
    final bottom = lum(surfaces.backdropBottom);
    // The page's own luminance at its least favourable end.
    final page = dark ? math.max(top, bottom) : math.min(top, bottom);
    // Light: the page's mist. Dark: the page's slate taken most of the way to black, so a
    // bright picture darkens like a photo dimmed (its colours kept) rather than going grey.
    Color veil(Color c) => dark ? Color.lerp(c, const Color(0xFF000000), deepen)! : c;
    return WallpaperLook(
      brightness: brightness,
      veilTop: veil(surfaces.backdropTop),
      veilBottom: veil(surfaces.backdropBottom),
      bound: bound,
      edgeBound: (bound + page) / 2,
      lift: lift,
    );
  }

  /// [c] under [lift] of white.
  static Color liftOf(Color c, double lift) =>
      lift <= 0 ? c : Color.alphaBlend(const Color(0xFFFFFFFF).withValues(alpha: lift), c);

  final Brightness brightness;

  /// The page's own gradient, laid over the picture where it needs calming.
  final Color veilTop;
  final Color veilBottom;

  /// Relative luminance what text sits on stays within: light, no darker than this; dark, no
  /// lighter (the page under [lift]). The secondary text colour reads at [wallpaperContrast] on it.
  final double bound;

  /// The same under the bars at the top and bottom: halfway from [bound] to the page itself.
  final double edgeBound;

  /// Dark: the most white a surface that carries text (a card, a pill) lays over the page. Text
  /// keeps its contrast on those too. Light: 0 (white surfaces only help dark text).
  final double lift;

  bool get dark => brightness == Brightness.dark;

  /// Whether a background of luminance [l] is within [limit].
  bool fits(double l, double limit) => dark ? l <= limit : l >= limit;

  /// The worst contrast a text colour of luminance [text] has on any background within [bound].
  double worstContrast(Color text) => contrastOf(text.computeLuminance(), bound);

  /// [color] moved in lightness (hue and chroma kept) just far enough to read at
  /// [wallpaperContrast] on any background within [bound]; unchanged when it already does.
  Color guard(Color color) {
    if (worstContrast(color) >= wallpaperContrast) return color;
    final o = Oklch.fromColor(color);
    // Light: darker; dark: lighter. The far end (black / white) always reads.
    var lo = o.l;
    var hi = dark ? 1.0 : 0.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (worstContrast(o.copyWith(l: mid).toColor(alpha: color.a)) >= wallpaperContrast) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return o.copyWith(l: hi).toColor(alpha: color.a);
  }

  /// [theme] for a page on the wallpaper: the colours text takes that are fainter than the
  /// secondary one, [guard]ed.
  ThemeData guardTheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    final colors = theme.extension<DshColors>();
    return theme.copyWith(
      colorScheme: scheme.copyWith(
        primary: guard(scheme.primary),
        secondary: guard(scheme.secondary),
        tertiary: guard(scheme.tertiary),
        error: guard(scheme.error),
        onSurfaceVariant: guard(scheme.onSurfaceVariant),
        onSurface: guard(scheme.onSurface),
      ),
      extensions: [
        for (final e in theme.extensions.values)
          if (e is! DshColors) e,
        if (colors != null)
          colors.copyWith(
            textTertiary: guard(colors.textTertiary),
            success: guard(colors.success),
            warning: guard(colors.warning),
            danger: guard(colors.danger),
            info: guard(colors.info),
          ),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperLook &&
      other.brightness == brightness &&
      other.veilTop == veilTop &&
      other.veilBottom == veilBottom &&
      other.bound == bound &&
      other.edgeBound == edgeBound &&
      other.lift == lift;

  @override
  int get hashCode => Object.hash(brightness, veilTop, veilBottom, bound, edgeBound, lift);
}
