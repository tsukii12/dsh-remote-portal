// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/beam/beam_data.dart';
import 'package:dsh_app/ui/fx/beam/beam_engine.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('keyframes', () {
    test('sample linearly between stops', () {
      expect(beamKeyframes(beamTravelX, 0, Curves.linear), 0.06);
      expect(beamKeyframes(beamTravelX, 0.05, Curves.linear), closeTo(0.105, 1e-9));
      expect(beamKeyframes(beamTravelX, 0.5, Curves.linear), 0.5);
      expect(beamKeyframes(beamTravelX, 1, Curves.linear), 0.94);
    });

    test('ease each segment with the timing function', () {
      // Halfway through the 25%→55% segment of breathe.
      final mid = beamKeyframes(beamBreathe, 0.4, Curves.easeInOut);
      expect(mid, closeTo((1.25 + 0.85) / 2, 1e-9));
      final early = beamKeyframes(beamBreathe, 0.3, Curves.easeInOut);
      expect(early, greaterThan(1.25 - (1.25 - 0.85) / 6)); // eased: slower off the stop
    });
  });

  group('line', () {
    test('travels the bottom edge and fades at the ends', () {
      final start = LineFrame.at(0, 3.1);
      expect(start.x, 0.06);
      expect(start.w, 0.5);
      expect(start.edge, 0);
      final mid = LineFrame.at(1.55, 3.1);
      expect(mid.x, closeTo(0.5, 1e-9));
      expect(mid.w, closeTo(1.5, 1e-9));
      expect(mid.edge, 1);
      expect(LineFrame.at(3.1 * 0.225, 3.1).edge, closeTo(0.5, 1e-9));
    });

    test('derived periods are rounded to 0.1 s like the web', () {
      // 3.1 × 1.3 = 4.03 → 4.0 s: a quarter of it lands on the 25% stop.
      expect(LineFrame.at(1.0, 3.1).h, closeTo(1.25, 1e-9));
      expect(LineFrame.at(4.0, 3.1).h, closeTo(0.8, 1e-9));
      // 3.1 × 1.7 = 5.27 → 5.3 s.
      expect(LineFrame.at(5.3 / 2, 3.1).spike2, closeTo(1.4, 1e-9));
    });
  });

  group('rotate', () {
    test('angle is a linear fraction of a turn', () {
      expect(beamAngle(0, 1.96), 0);
      expect(beamAngle(2.45, 1.96), closeTo(0.25, 1e-9));
    });

    test('hue drifts -r → +r → -r over the period', () {
      expect(beamHueDrift(0, 30, 12), -30);
      expect(beamHueDrift(3, 30, 12), closeTo(0, 1e-9));
      expect(beamHueDrift(6, 30, 12), closeTo(30, 1e-9));
      expect(beamHueDrift(12, 30, 12), closeTo(-30, 1e-9));
    });
  });

  group('pulse', () {
    test('params follow pulseParams', () {
      final inner = PulseParams.of(inner: true, dark: true, duration: 2.3);
      expect(
        (inner.sp, inner.dr, inner.op, inner.gh, inner.bs, inner.ss, inner.ghs),
        (0.28, 33, 0.48, 0.34, 1.9, 2.6, 2.4),
      );
      expect(inner.huePeriod, 16);
      expect(inner.frozenBloomAlpha, closeTo(0.76, 1e-9));
      final outside = PulseParams.of(inner: false, dark: false, duration: 4.6);
      expect(outside.op, 0);
      expect(outside.frozenBloomAlpha, 1);
      expect(outside.bs, closeTo(3.7 * 2, 1e-9)); // periods scale with duration / 2.3
      expect(outside.huePeriod, 14); // the hue revolution does not
      expect(outside.oscillators, hasLength(17));
    });

    test('oscillators ping-pong a → b with the delay', () {
      expect(PulseFrame.oscillate(2, 4, 1, 0, 0), 2);
      expect(PulseFrame.oscillate(2, 4, 1, 0, 0.5), closeTo(4, 1e-9));
      expect(PulseFrame.oscillate(2, 4, 1, 0.25, 0.25), 2);
      final frame = PulseFrame(PulseParams.of(inner: true, dark: true, duration: 2.3))..sample(0);
      expect(frame.values[0], closeTo(1 - 0.28, 1e-9)); // bw1 starts at a
      expect(frame.values[13], closeTo(1 - 0.48, 1e-9)); // tl opacity
      expect(frame.hue(8), closeTo(180, 1e-9));
    });

    test('pulse-outside glow scales to the element, clamped', () {
      expect(beamGlowScale(348, 122), (0.994, 0.871));
      expect(beamGlowScale(10, 1000), (0.35, 4.0));
    });
  });

  group('filter matrix', () {
    test('identity when nothing changes', () {
      final m = beamFilterMatrix(0, 1, 1);
      const identity = [1.0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
      for (var i = 0; i < 20; i++) {
        expect(m[i], closeTo(identity[i], 1e-9));
      }
      final full = beamFilterMatrix(360, 1, 1);
      for (var i = 0; i < 20; i++) {
        expect(full[i], closeTo(identity[i], 1e-9));
      }
    });

    test('brightness scales and saturate(0) is the W3C luminance', () {
      expect(beamFilterMatrix(0, 2, 1)[0], closeTo(2, 1e-9));
      final grey = beamFilterMatrix(0, 1, 0);
      for (final row in [0, 5, 10]) {
        expect(
          [grey[row], grey[row + 1], grey[row + 2]],
          [closeTo(0.213, 1e-9), closeTo(0.715, 1e-9), closeTo(0.072, 1e-9)],
        );
      }
    });
  });

  test('fade eases from → to and reports done', () {
    const fade = BeamFade(0, 1, 2, 0.6);
    expect(fade.at(2), 0);
    expect(fade.at(2.3), closeTo(Curves.ease.transform(0.5), 1e-9));
    expect(fade.at(5), 1);
    expect(fade.doneAt(2.5), isFalse);
    expect(fade.doneAt(2.6), isTrue);
    expect(const BeamFade(0.4, 0, 1, 0).at(1), 0);
  });

  test('blur radii scale with glowSize and never collapse', () {
    expect(beamBlur(8, 1), 8);
    expect(beamBlur(8, 1.234), closeTo(9.87, 1e-9));
    expect(beamBlur(3, 0.01), 0.5);
  });

  group('palettes', () {
    test('the nine-colour recipe rebuilds the author\'s Forest tables', () {
      final forest = BorderBeamColorVariant.forest.palette;
      expect(forest.lineLight[0], const Color.fromRGBO(33, 115, 65, 1));
      expect(forest.spikeLight, (const Color.fromRGBO(33, 115, 65, 1), const Color.fromRGBO(22, 137, 86, 1)));
      expect(forest.smallInner[0], const Color.fromRGBO(60, 195, 140, 0.5));
      expect(forest.lineInner[8], const Color.fromRGBO(60, 195, 140, 0.52));
      expect(forest.bloomDark[1], (const Color.fromRGBO(70, 180, 70, 0.59), const Color.fromRGBO(20, 150, 130, 0.29)));
      expect(forest.bloomLight[0].$2, const Color.fromRGBO(22, 137, 86, 0.8));
      expect(forest.spike.$2, const Color.fromRGBO(30, 190, 120, 0.98));
    });

    test('every preset has full tables', () {
      for (final v in BorderBeamColorVariant.values) {
        final p = v.palette;
        expect([p.border, p.lineDark, p.lineLight, p.lineInner].map((l) => l.length), everyElement(9), reason: '$v');
        expect([p.small, p.smallInner].map((l) => l.length), everyElement(8), reason: '$v');
        expect([p.bloomDark, p.bloomLight].map((l) => l.length), everyElement(5), reason: '$v');
      }
    });

    test('the theme palette stays near the seed hue and calm', () {
      const seed = Color(0xFF4B67B4);
      final hue = HSLColor.fromColor(seed).hue;
      final p = BeamPalette.fromSeed(seed);
      for (final c in p.border) {
        final hsl = HSLColor.fromColor(c);
        final d = ((hsl.hue - hue + 540) % 360) - 180;
        expect(d.abs(), lessThanOrEqualTo(36.5));
        expect(hsl.saturation, lessThanOrEqualTo(0.67)); // 0.6 × 1.1 plus 8-bit rounding
      }
      // Grey seeds still get a little colour.
      final grey = BeamPalette.fromSeed(const Color(0xFF808080));
      expect(HSLColor.fromColor(grey.border[0]).saturation, greaterThan(0.35));
    });
  });

  test('presets match sizeThemePresets', () {
    final line = BeamThemePreset.of(BorderBeamSize.line, dark: true);
    expect((line.stroke, line.inner, line.bloom, line.saturation, line.brightness), (1.14, 0.7, 0.8, 1.2, 1.3));
    final outside = BeamThemePreset.of(BorderBeamSize.pulseOutside, dark: false);
    expect((outside.stroke, outside.brightness, outside.saturation), (1.96, 1.7, 0.6));
    expect(beamDefaultRadius(BorderBeamSize.sm), 32);
    expect(beamDefaultDuration(BorderBeamSize.line), 3.1);
    expect(beamDefaultDuration(BorderBeamSize.pulseInner), 2.3);
    expect(beamDefaultDuration(BorderBeamSize.md), 1.96);
  });
}
