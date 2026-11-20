import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../theme/theme.dart';

/// What an island takes from the App's look (§8): light / dark, the accent,
/// text colours, lines and surfaces as DSH Web's alias tokens, and the text
/// size. Pushed with `__dshGoIsland.setTheme` whenever it changes; the page
/// never reloads for it.
@immutable
class IslandTheme {
  const IslandTheme({required this.dark, required this.tokens, this.textScale = 1});

  /// The App's theme as DSH Web tokens. [textScale] is the App's (system)
  /// text scale; the WebView applies it as its text zoom.
  factory IslandTheme.fromTheme(ThemeData theme, {double textScale = 1}) {
    final scheme = theme.colorScheme;
    final colors = theme.extension<DshColors>();
    final dark = theme.brightness == Brightness.dark;
    final ink = scheme.onSurface;
    Color a(Color c, double alpha) => c.withValues(alpha: alpha);
    final lines = dark ? const [0.06, 0.12, 0.16, 0.20] : const [0.04, 0.10, 0.12, 0.16];
    final tertiary = colors?.textTertiary ?? scheme.onSurfaceVariant;
    return IslandTheme(
      dark: dark,
      textScale: textScale,
      tokens: {
        // The page is see-through: the App's own background shows behind.
        '--dsw-alias-bg-base': 'transparent',
        '--dsw-alias-bg-layer-1': cssColor(scheme.surfaceContainerLow),
        '--dsw-alias-bg-layer-2': cssColor(scheme.surfaceContainer),
        '--dsw-alias-bg-layer-3': cssColor(scheme.surfaceContainerHigh),
        '--dsw-alias-settings-card-fill': cssColor(scheme.surfaceContainer),
        '--dsw-alias-settings-card-stroke': cssColor(a(ink, lines[3])),
        '--dsw-alias-label-primary': cssColor(ink),
        '--dsw-alias-label-secondary': cssColor(scheme.onSurfaceVariant),
        '--dsw-alias-label-tertiary': cssColor(tertiary),
        '--dsw-alias-label-caption': cssColor(tertiary),
        '--dsw-alias-label-primary-inverted': cssColor(scheme.onPrimary),
        '--dsw-alias-menu-icon': cssColor(scheme.onSurfaceVariant),
        '--dsw-alias-border-l1': cssColor(a(ink, lines[0])),
        '--dsw-alias-border-l2': cssColor(a(ink, lines[1])),
        '--dsw-alias-border-l3': cssColor(a(ink, lines[2])),
        '--dsw-alias-border-l4': cssColor(a(ink, lines[3])),
        '--dsw-alias-brand-primary': cssColor(scheme.primary),
        '--dsw-alias-brand-primary-invert': cssColor(scheme.primary),
        '--dsw-alias-button-primary-fill': cssColor(scheme.primary),
        '--dsw-alias-button-primary-hover': cssColor(Color.lerp(scheme.primary, ink, 0.12)!),
        '--dsw-alias-link': cssColor(scheme.primary),
        '--dsw-alias-switch-thumb': cssColor(dark ? ink : Colors.white),
        '--dsw-alias-interactive-bg-hover': cssColor(a(ink, dark ? 0.08 : 0.06)),
        '--dsw-alias-interactive-bg-active': cssColor(a(ink, dark ? 0.14 : 0.10)),
        '--dsw-alias-state-success-primary': cssColor(colors?.success ?? scheme.tertiary),
        '--dsw-alias-state-warn-primary': cssColor(colors?.warning ?? scheme.tertiary),
        '--dsw-alias-state-error-primary': cssColor(colors?.danger ?? scheme.error),
      },
    );
  }

  final bool dark;
  final Map<String, String> tokens;
  final double textScale;

  /// The WebView's text zoom, percent (50–300, as Android takes it).
  int get textZoom => (textScale * 100).round().clamp(50, 300);

  /// `__dshGoIsland.setTheme`'s argument.
  Map<String, Object?> toJson() => {'dark': dark, 'tokens': tokens};

  @override
  bool operator ==(Object other) =>
      other is IslandTheme && other.dark == dark && other.textScale == textScale && mapEquals(other.tokens, tokens);

  @override
  int get hashCode =>
      Object.hash(dark, textScale, Object.hashAllUnordered(tokens.entries.map((e) => Object.hash(e.key, e.value))));
}

/// `#rrggbb` or `#rrggbbaa`.
String cssColor(Color c) {
  String h(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final rgb = '#${h(c.r)}${h(c.g)}${h(c.b)}';
  return c.a >= 1 ? rgb : '$rgb${h(c.a)}';
}
