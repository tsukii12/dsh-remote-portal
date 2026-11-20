// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

/// One `box-shadow` layer drawn on the merged liquid silhouette (shadow.ts
/// `ShadowLayer`), so it follows every merge and split. [inset] layers paint
/// inside the liquid edge: inner rings, top highlights.
@immutable
class LiquidShadow {
  const LiquidShadow({
    required this.color,
    this.offset = Offset.zero,
    this.blur = 0,
    this.spread = 0,
    this.inset = false,
  });

  final Color color;
  final Offset offset;

  /// CSS blur radius (σ = blur / 2).
  final double blur;
  final double spread;
  final bool inset;

  @override
  bool operator ==(Object other) =>
      other is LiquidShadow &&
      other.color == color &&
      other.offset == offset &&
      other.blur == blur &&
      other.spread == spread &&
      other.inset == inset;

  @override
  int get hashCode => Object.hash(color, offset, blur, spread, inset);
}

/// The author's shadow stacks (sites/gooey `theme.ts` and the tabs demo), sRGB
/// values. Light keeps the Figma soft elevation; dark keeps black shadows plus
/// two faint light inset hairlines, never a white outline.
abstract final class LiquidShadows {
  static List<LiquidShadow> figmaSoft(Brightness brightness) =>
      brightness == Brightness.dark ? _figmaSoftDark : _figmaSoftLight;

  static List<LiquidShadow> floating(Brightness brightness) =>
      brightness == Brightness.dark ? _floatingDark : _floatingLight;

  /// The tab indicator pill's own elevation.
  static List<LiquidShadow> tabPill(Brightness brightness) =>
      brightness == Brightness.dark ? _tabPillDark : _tabPillLight;

  static const _figmaSoftLight = [
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.06), spread: 1),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.05), offset: Offset(0, 2), blur: 6),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.06), offset: Offset(0, 4), blur: 42),
  ];
  static const _figmaSoftDark = [
    LiquidShadow(color: Color.fromRGBO(255, 255, 255, 0.04), spread: 1, inset: true),
    LiquidShadow(color: Color.fromRGBO(255, 255, 255, 0.03), offset: Offset(0, 1), inset: true),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.06), spread: 1),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.05), offset: Offset(0, 2), blur: 6),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.24), offset: Offset(0, 4), blur: 42),
  ];
  static const _floatingLight = [
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.08), offset: Offset(0, 2), blur: 6),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.18), offset: Offset(0, 12), blur: 32),
  ];
  static const _floatingDark = [
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.4), offset: Offset(0, 2), blur: 6),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.55), offset: Offset(0, 12), blur: 32),
  ];
  static const _tabPillLight = [
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.11), offset: Offset(0, 1), blur: 3),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.07), offset: Offset(0, 1), blur: 1),
  ];
  static const _tabPillDark = [
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.5), offset: Offset(0, 1), blur: 3),
    LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.35), offset: Offset(0, 1), blur: 1),
  ];
}

/// Liquid colours and the ink drawn on them.
///
/// [LiquidPalette.of] follows the app theme: the primary's hue, quietened. A
/// [surface] for pieces that merge and bow (a raised puck a shade off the page)
/// and a stronger [indicator] for the drop that travels under a selected tab.
/// [lab] is the author's own neutral set.
@immutable
class LiquidPalette {
  const LiquidPalette({
    required this.surface,
    required this.onSurface,
    required this.indicator,
    required this.onIndicator,
  });

  factory LiquidPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    return LiquidPalette.fromScheme(theme.colorScheme, theme.brightness);
  }

  factory LiquidPalette.fromScheme(ColorScheme scheme, Brightness brightness) {
    final base = HSLColor.fromColor(scheme.primary);
    final sat = base.saturation;
    Color tone(double s, double l) => HSLColor.fromAHSL(1, base.hue, s.clamp(0.0, 1.0), l).toColor();
    return brightness == Brightness.dark
        ? LiquidPalette(
            surface: tone((sat * 0.25).clamp(0.06, 0.16), 0.17),
            onSurface: tone((sat * 0.3).clamp(0.08, 0.22), 0.91),
            indicator: tone((sat * 0.45).clamp(0.16, 0.34), 0.8),
            onIndicator: tone((sat * 0.4).clamp(0.12, 0.3), 0.13),
          )
        : LiquidPalette(
            surface: tone((sat * 0.3).clamp(0.08, 0.22), 0.975),
            onSurface: tone((sat * 0.45).clamp(0.14, 0.32), 0.22),
            indicator: tone((sat * 0.5).clamp(0.18, 0.4), 0.36),
            onIndicator: tone((sat * 0.2).clamp(0.05, 0.12), 0.98),
          );
  }

  /// The author's demo colours: white liquid on light, #202020 on dark; the tab
  /// indicator inverted (near-black on light, white on dark).
  factory LiquidPalette.lab(Brightness brightness) => brightness == Brightness.dark
      ? const LiquidPalette(
          surface: Color(0xFF202020),
          onSurface: Color(0xFFFBFBFB),
          indicator: Color(0xFFFFFFFF),
          onIndicator: Color(0xFF0D0D0D),
        )
      : const LiquidPalette(
          surface: Color(0xFFFFFFFF),
          onSurface: Color(0xFF17181C),
          indicator: Color(0xFF0F0F0F),
          onIndicator: Color(0xFFFFFFFF),
        );

  final Color surface;
  final Color onSurface;
  final Color indicator;
  final Color onIndicator;

  @override
  bool operator ==(Object other) =>
      other is LiquidPalette &&
      other.surface == surface &&
      other.onSurface == onSurface &&
      other.indicator == indicator &&
      other.onIndicator == onIndicator;

  @override
  int get hashCode => Object.hash(surface, onSurface, indicator, onIndicator);
}
