// Every palette (the six presets, custom picks across the hue circle, odd
// picks) keeps the contrast rules of docs/design/polish-guide.md §1.1, in
// light and dark. Mist stays byte-identical to the original Mist Glass tokens.

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything a palette can be: presets, a custom pick every 15°, and picks
/// that stress the guard (near white, near black, grey, loud primaries).
final _palettes = <AppAccent>[
  ...AppAccent.presets,
  for (var h = 0; h < 360; h += 15) AppAccent.derive(AppAccent.hueColor(h.toDouble())),
  for (final c in const [
    Color(0xFFFFFFFF),
    Color(0xFFF4E04D),
    Color(0xFF00FF00),
    Color(0xFFFF0000),
    Color(0xFF0000FF),
    Color(0xFF000000),
    Color(0xFF808080),
    Color(0xFF8BE9FD),
    Color(0xFF3A2A00),
  ])
    AppAccent.derive(c, id: AppAccent.wallpaperId),
];

void main() {
  test('mist is the original Mist Glass, untouched', () {
    final light = buildLightTheme();
    final dark = buildDarkTheme();
    expect(light.colorScheme.primary, const Color(0xFF4B67B4));
    expect(light.colorScheme.surface, DshPalette.mist);
    expect(light.colorScheme.onSurface, DshPalette.ink);
    expect(dark.colorScheme.surface, DshPalette.night);
    expect(identical(light.extension<DshColors>(), DshColors.light), isTrue);
    expect(identical(dark.extension<DshColors>(), DshColors.dark), isTrue);
    final s = light.extension<DshSurfaces>()!;
    expect(s.backdropTop, DshPalette.mistTop);
    expect(s.glowSecondary, const Color(0xFFD5CBEB).withValues(alpha: 0.38));
    expect(s.accent, AppAccent.mist);
    expect(identical(NeutralTones.forAccent(AppAccent.mist), NeutralTones.defaults), isTrue);
    expect(dshHighlightTheme(Brightness.light)['root']!.color, const Color(0xFF1E232E));
  });

  test('the derivation reproduces mist from its seed (one recipe for every hue)', () {
    final d = AppAccent.derive(AppAccent.mist.seed);
    const m = AppAccent.mist;
    void near(Color a, Color b, String name) {
      for (final (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)]) {
        expect((x - y).abs() * 255, lessThan(3.5), reason: '$name: $a vs $b');
      }
    }

    near(d.seed, m.seed, 'seed');
    near(d.container, m.container, 'container');
    near(d.onContainer, m.onContainer, 'onContainer');
    near(d.bubble, m.bubble, 'bubble');
    near(d.seedDark, m.seedDark, 'seedDark');
    near(d.containerDark, m.containerDark, 'containerDark');
    near(d.bubbleDark, m.bubbleDark, 'bubbleDark');
  });

  test('presets: unique ids and names, mist first', () {
    expect(AppAccent.presets.first, AppAccent.mist);
    expect(AppAccent.presets.map((p) => p.id).toSet(), hasLength(6));
    expect(AppAccent.presets.map((p) => p.label), ['雾蓝', '黛青', '暮紫', '松石', '琥珀', '石墨']);
    expect(AppAccent.preset('nope'), AppAccent.mist);
    expect(AppAccent.preset('amber'), AppAccent.amber);
  });

  for (final accent in _palettes) {
    final name = '${accent.id} ${accent.seed}';
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      test('$name · ${brightness.name}: accent, text and glass contrast', () {
        final theme = dark ? buildDarkTheme(accent: accent) : buildLightTheme(accent: accent);
        final scheme = theme.colorScheme;
        final s = theme.extension<DshSurfaces>()!;
        final c = theme.extension<DshColors>()!;
        final card = Color.alphaBlend(s.card.fill, s.backdropTop);
        final grounds = [s.backdropTop, s.backdropBottom, card, scheme.surface, scheme.surfaceContainerHighest];

        // The guard: accent ≥ 3:1 on every ground, text on it ≥ 4.5:1.
        for (final g in grounds) {
          expect(contrastRatio(scheme.primary, g), greaterThanOrEqualTo(3), reason: 'primary on $g');
        }
        expect(contrastRatio(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(scheme.onPrimaryContainer, scheme.primaryContainer), greaterThanOrEqualTo(7));
        // Text tiers keep their steps on the page whatever the tint.
        for (final g in [s.backdropTop, s.backdropBottom, card]) {
          expect(contrastRatio(scheme.onSurface, g), greaterThanOrEqualTo(10), reason: 'onSurface on $g');
          expect(contrastRatio(scheme.onSurfaceVariant, g), greaterThanOrEqualTo(6), reason: 'variant on $g');
          expect(contrastRatio(c.textTertiary, g), greaterThanOrEqualTo(4.5), reason: 'tertiary on $g');
        }
        expect(contrastRatio(s.onUserBubble, s.userBubble), greaterThanOrEqualTo(7));
        expect(contrastRatio(c.codeWellFg, c.codeWellBg), greaterThanOrEqualTo(10));
        expect(contrastRatio(c.lineNumberFg, c.codeWellBg), greaterThanOrEqualTo(3));
        // The page stays quiet: neutrals are near-grey, not coloured.
        for (final g in [s.backdropTop, s.backdropBottom, scheme.surface]) {
          expect(Oklch.fromColor(g).c, lessThan(0.025), reason: 'quiet page $g');
        }
        expect(Oklch.fromColor(scheme.primary).c, lessThanOrEqualTo(AppAccent.maxChroma + 0.005));
      });

      test('$name · ${brightness.name}: switch knob reads on both tracks', () {
        final theme = dark ? buildDarkTheme(accent: accent) : buildLightTheme(accent: accent);
        final sw = theme.switchTheme;
        const on = {WidgetState.selected};
        final knob = sw.thumbColor!.resolve(on)!;
        final track = sw.trackColor!.resolve(on)!;
        expect(contrastRatio(knob, track), greaterThanOrEqualTo(1.6), reason: 'knob on the accent track');
        expect(contrastRatio(sw.thumbIcon!.resolve(on)!.color!, knob), greaterThan(3), reason: 'check on knob');
      });
    }
  }

  test('neutrals keep their lightness when re-tinted', () {
    for (final accent in AppAccent.presets) {
      final n = NeutralTones.forAccent(accent);
      const m = NeutralTones.defaults;
      for (final (a, b) in [
        (n.mistTop, m.mistTop),
        (n.ink, m.ink),
        (n.inkFaint, m.inkFaint),
        (n.night, m.night),
        (n.paper, m.paper),
        (n.codeWell, m.codeWell),
      ]) {
        expect(Oklch.fromColor(a).l, closeTo(Oklch.fromColor(b).l, 0.006), reason: '${accent.id}: $a vs $b');
      }
    }
  });

  test('guard only moves lightness, and only as far as needed', () {
    // Already fine: returned as is.
    const ok = Oklch(0.5, 0.1, 250);
    final kept = AppAccent.guard(
      ok,
      brightness: Brightness.light,
      surface: DshPalette.mistHighest,
      onAccent: const Color(0xFFFFFFFF),
    );
    expect(kept, ok.toColor());
    // Too light for white text: darkened to just past 4.5:1, hue kept.
    const pale = Oklch(0.8, 0.1, 90);
    final fixed = AppAccent.guard(
      pale,
      brightness: Brightness.light,
      surface: DshPalette.mistHighest,
      onAccent: const Color(0xFFFFFFFF),
    );
    final ratio = contrastRatio(const Color(0xFFFFFFFF), fixed);
    expect(ratio, greaterThanOrEqualTo(4.5));
    expect(ratio, lessThan(4.8));
    expect(Oklch.fromColor(fixed).h, closeTo(90, 4));
  });
}
