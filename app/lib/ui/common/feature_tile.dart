// The big graphics of the nine headline features (全部功能, their empty states,
// the phone page's overview) in three styles the user picks from.
//
// - Flat duotone (the default) and minimal geometric are vectors: SVG masters in
//   assets/tiles/<style>/, turned into paths by tool/make_feature_tiles.py
//   (feature_tile_shapes.g.dart). Every colour is a tone of the theme's accent.
// - Glass gradient is the painted set in assets/tiles/glassy/ (288px WebP: 96dp at
//   3x), turned from the default accent's hue to the current one.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/tile_style_state.dart';
import '../theme/theme.dart';
import 'feature_tile_shapes.g.dart';

export '../../state/tile_style_state.dart' show TileStyle;
export 'feature_tile_shapes.g.dart' show FeatureKind;

/// One feature's graphic, [size] square, in the user's [TileStyle].
///
/// ```dart
/// FeatureTile(FeatureKind.automation, size: FeatureTile.empty)
/// ```
///
/// - Colours follow the accent and switch with light / dark; [tint] takes one of
///   the 8 identity hues (`DshColors.identity`) instead.
/// - [style] pins a style (the picker's previews); null follows the setting.
/// - Decorative unless [semanticLabel] is given: a title always sits next to it.
class FeatureTile extends ConsumerWidget {
  const FeatureTile(this.kind, {super.key, this.size = 48, this.style, this.tint, this.semanticLabel});

  final FeatureKind kind;
  final double size;
  final TileStyle? style;
  final int? tint;
  final String? semanticLabel;

  /// In a 全部功能 card (the circle badge it replaces is 36 too).
  static const card = 36.0;

  /// Over an empty state, in place of `EmptyView`'s 64 badge.
  static const empty = 64.0;

  /// Over a compact empty state (a sheet), in place of the 48 badge.
  static const compact = 48.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TileStyle style = this.style ?? ref.watch(tileStyleProvider);
    final palette = TilePalette.of(context, tint: tint);
    final Widget art = switch (style) {
      TileStyle.glassy => _GlassTile(kind: kind, size: size, palette: palette),
      TileStyle.duotone => _VectorTile(art: DuotoneTiles.of(kind), size: size, palette: palette),
      TileStyle.geometric => _VectorTile(art: GeometricTiles.of(kind), size: size, palette: palette),
    };
    final label = semanticLabel;
    return label == null ? ExcludeSemantics(child: art) : Semantics(label: label, image: true, child: art);
  }
}

/// The four tones of a tile, from the theme.
///
/// Hierarchy is contrast with the card the tile sits on: [ink] stands out most,
/// [wash] least but still reads (≥ [washContrast]; a 1.2 : 1 tint vanishes on
/// white). So in light the body is the deep accent and the back
/// shapes are light; in dark the body is the light accent and the back shapes are
/// deep, like the app's own filled buttons. A tone that falls short (a quiet
/// accent such as 石墨) is pushed toward [ink] until it reads.
@immutable
class TilePalette {
  const TilePalette({required this.wash, required this.mid, required this.ink, required this.on});

  final Color wash;
  final Color mid;
  final Color ink;

  /// Details on [ink].
  final Color on;

  /// Least contrast of [wash] and [mid] with the card.
  static const washContrast = 1.5;
  static const midContrast = 2.0;

  /// The accent: `primary`, `inversePrimary` (the accent's other-brightness
  /// tone) and `primaryContainer`.
  factory TilePalette.accent(ColorScheme scheme) {
    final p = scheme.primary;
    final other = scheme.inversePrimary;
    final container = scheme.primaryContainer;
    if (scheme.brightness == Brightness.dark) {
      return _readable(
        card(scheme),
        ink: p,
        mid: Color.lerp(p, other, 0.55)!,
        wash: Color.lerp(other, container, 0.4)!,
        on: scheme.onPrimary,
      );
    }
    return _readable(card(scheme), ink: p, mid: other, wash: Color.lerp(other, container, 0.5)!, on: container);
  }

  /// One identity hue: its container and on-container (`DshColors.identity` /
  /// `onIdentity`), mixed the same way.
  factory TilePalette.identity(DshColors colors, int slot, ColorScheme scheme) {
    final i = slot % colors.identity.length;
    final container = colors.identity[i];
    final strong = colors.onIdentity[i];
    if (scheme.brightness == Brightness.dark) {
      return _readable(
        card(scheme),
        ink: Color.lerp(strong, container, 0.1)!,
        mid: Color.lerp(strong, container, 0.45)!,
        wash: Color.lerp(container, strong, 0.22)!,
        on: container,
      );
    }
    return _readable(
      card(scheme),
      ink: Color.lerp(strong, container, 0.3)!,
      mid: Color.lerp(strong, container, 0.58)!,
      wash: Color.lerp(container, strong, 0.2)!,
      on: container,
    );
  }

  /// The card a tile is checked against: the lightest surface in light, the
  /// lightest dark one in dark (the hardest case either way).
  static Color card(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark ? scheme.surfaceContainerHighest : scheme.surfaceContainerLowest;

  static TilePalette _readable(
    Color card, {
    required Color ink,
    required Color mid,
    required Color wash,
    required Color on,
  }) => TilePalette(
    ink: ink,
    mid: _atLeast(mid, ink, card, midContrast),
    wash: _atLeast(wash, ink, card, washContrast),
    on: on,
  );

  static Color _atLeast(Color color, Color toward, Color card, double ratio) {
    for (var t = 0.0; t < 1; t += 0.04) {
      final c = Color.lerp(color, toward, t)!;
      if (contrast(c, card) >= ratio) return c;
    }
    return toward;
  }

  /// WCAG contrast ratio of [a] and [b].
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// The accent's palette, or identity hue [tint]'s.
  static TilePalette of(BuildContext context, {int? tint}) {
    final theme = Theme.of(context);
    return tint == null
        ? TilePalette.accent(theme.colorScheme)
        : TilePalette.identity(DshColors.of(context), tint, theme.colorScheme);
  }

  Color operator [](TileTone tone) => switch (tone) {
    TileTone.wash => wash,
    TileTone.mid => mid,
    TileTone.ink => ink,
    TileTone.on => on,
  };

  @override
  bool operator ==(Object other) =>
      other is TilePalette && other.wash == wash && other.mid == mid && other.ink == ink && other.on == on;

  @override
  int get hashCode => Object.hash(wash, mid, ink, on);
}

class _VectorTile extends StatelessWidget {
  const _VectorTile({required this.art, required this.size, required this.palette});

  final TileArt art;
  final double size;
  final TilePalette palette;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: TilePainter(art, palette));
}

/// Draws a [TileArt] scaled to the canvas, its tones from [palette].
class TilePainter extends CustomPainter {
  const TilePainter(this.art, this.palette);

  final TileArt art;
  final TilePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    const grid = Rect.fromLTWH(0, 0, TileArt.grid, TileArt.grid);
    canvas.save();
    canvas.scale(size.width / TileArt.grid, size.height / TileArt.grid);
    for (final layer in art.layers) {
      final cut = layer.cuts.isNotEmpty;
      // A layer of its own so a cut erases this layer's shapes and nothing under them.
      if (cut) canvas.saveLayer(grid.inflate(8), Paint());
      for (final shape in layer.shapes) {
        _draw(canvas, shape, Paint()..color = palette[shape.tone!]);
      }
      for (final shape in layer.cuts) {
        _draw(canvas, shape, Paint()..blendMode = BlendMode.clear);
      }
      if (cut) canvas.restore();
    }
    canvas.restore();
  }

  static void _draw(Canvas canvas, TileShape shape, Paint paint) {
    if (shape.fill) canvas.drawPath(shape.path, paint..style = PaintingStyle.fill);
    if (shape.stroke > 0) {
      canvas.drawPath(
        shape.path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = shape.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(TilePainter old) => old.art != art || old.palette != palette;
}

class _GlassTile extends StatelessWidget {
  const _GlassTile({required this.kind, required this.size, required this.palette});

  final FeatureKind kind;
  final double size;
  final TilePalette palette;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;
    Widget image = Image.asset(
      GlassTint.asset(kind),
      width: size,
      height: size,
      // Decode at the drawn size: one 288px master serves every size.
      cacheWidth: math.min(GlassTint.assetPixels, (size * dpr).ceil()),
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
      gaplessPlayback: true,
    );
    final filter = GlassTint.filter(palette.ink, dark ? Brightness.dark : Brightness.light);
    if (filter != null) image = ColorFiltered(colorFilter: filter, child: image);
    return SizedBox.square(dimension: size, child: image);
  }
}

/// Turns the glass set, painted in the default accent (雾蓝), to another accent.
///
/// A hue rotation (the SVG / CSS `hueRotate` matrix), solved so the default
/// accent lands exactly on the target's hue, and a saturation cut for quiet
/// accents (石墨) so the glass doesn't stay vivid blue among grey controls.
abstract final class GlassTint {
  /// Width and height of the masters: 96dp at 3x.
  static const assetPixels = 288;

  static String asset(FeatureKind kind) => 'assets/tiles/glassy/${kind.name}.webp';

  /// The colour the set was painted to, per brightness: the default accent's
  /// `primary` (what [TilePalette.ink] is for it).
  static Color reference(Brightness brightness) => AppAccent.mist.seedFor(brightness);

  static final _cache = <(int, Brightness), ColorFilter?>{};

  /// The filter that turns the set from [reference] to [target], or null when
  /// there is nothing to turn (the default accent).
  static ColorFilter? filter(Color target, Brightness brightness) =>
      _cache.putIfAbsent((target.toARGB32(), brightness), () {
        final (degrees, saturation) = solve(target, brightness);
        if (degrees.abs() < 1 && saturation > 0.98) return null;
        return ColorFilter.matrix(matrix(degrees, saturation));
      });

  /// (rotation in degrees, saturation factor) taking [reference] to [target]'s hue.
  static (double, double) solve(Color target, Brightness brightness) {
    final ref = HSLColor.fromColor(reference(brightness));
    final to = HSLColor.fromColor(target);
    // Chroma (OKLCH), not HSL saturation: the accents share one chroma rule, and
    // HSL calls every light tint "saturated".
    final saturation = (chroma(target) / chroma(reference(brightness))).clamp(0.3, 1.0).toDouble();
    if (to.saturation < 0.02) return (0.0, saturation);
    double miss(double deg) {
      final hue = HSLColor.fromColor(apply(matrix(deg, saturation), reference(brightness))).hue;
      final d = (hue - to.hue).abs() % 360;
      return math.min(d, 360 - d);
    }

    // The matrix keeps luminance, not HSL hue, so search around the plain difference.
    final start = to.hue - ref.hue;
    var best = start;
    var bestMiss = miss(start);
    for (var step = 8.0; step >= 0.05; step /= 2) {
      for (final candidate in [best - step, best + step]) {
        final m = miss(candidate);
        if (m < bestMiss) {
          best = candidate;
          bestMiss = m;
        }
      }
    }
    for (var deg = -180.0; deg < 180 && bestMiss > 2; deg += 10) {
      final m = miss(deg);
      if (m < bestMiss) {
        best = deg;
        bestMiss = m;
      }
    }
    final wrapped = ((best + 180) % 360) - 180;
    return (wrapped, saturation);
  }

  /// OKLCH chroma of [color].
  static double chroma(Color color) {
    double lin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = lin(color.r);
    final g = lin(color.g);
    final b = lin(color.b);
    double cbrt(double v) => math.pow(v, 1 / 3).toDouble();
    final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    return math.sqrt(a * a + bb * bb);
  }

  /// Saturation × hue rotation, as a 4×5 colour matrix.
  static List<double> matrix(double degrees, double saturation) {
    final a = degrees * math.pi / 180;
    final c = math.cos(a);
    final s = math.sin(a);
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
    final k = saturation;
    final sat = [
      0.213 + 0.787 * k,
      0.715 - 0.715 * k,
      0.072 - 0.072 * k,
      0.213 - 0.213 * k,
      0.715 + 0.285 * k,
      0.072 - 0.072 * k,
      0.213 - 0.213 * k,
      0.715 - 0.715 * k,
      0.072 + 0.928 * k,
    ];
    final m = List<double>.filled(9, 0);
    for (var r = 0; r < 3; r++) {
      for (var col = 0; col < 3; col++) {
        for (var i = 0; i < 3; i++) {
          m[r * 3 + col] += hue[r * 3 + i] * sat[i * 3 + col];
        }
      }
    }
    return [m[0], m[1], m[2], 0, 0, m[3], m[4], m[5], 0, 0, m[6], m[7], m[8], 0, 0, 0, 0, 0, 1, 0];
  }

  /// [color] through a 4×5 [matrix] (no offsets), clamped.
  static Color apply(List<double> matrix, Color color) {
    double ch(int row) =>
        (matrix[row * 5] * color.r + matrix[row * 5 + 1] * color.g + matrix[row * 5 + 2] * color.b).clamp(0, 1);
    return Color.from(alpha: color.a, red: ch(0), green: ch(1), blue: ch(2));
  }
}
