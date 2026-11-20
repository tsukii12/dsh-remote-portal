import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_app/ui/fx/voice_glow/voice_driver.dart';
import 'package:dsh_app/ui/fx/voice_glow/voice_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceGlowConfig _config({
  VoiceBeamType type = VoiceBeamType.standard,
  bool dark = true,
  VoiceLevelScale levelScale = VoiceLevelScale.linear,
  bool reducedMotion = false,
  VoiceBeamColorVariant? colorVariant = VoiceBeamColorVariant.colorful,
}) => VoiceGlowConfig.resolve(
  type: type,
  dark: dark,
  scheme: const ColorScheme.dark(),
  colorVariant: colorVariant,
  levelScale: levelScale,
  reducedMotion: reducedMotion,
);

void main() {
  group('shaping', () {
    test('gates below the threshold and saturates softly to 1', () {
      expect(voiceShape(0.01, 0.015), 0);
      expect(voiceShape(1, 0.015), closeTo(1, 1e-9));
      expect(voiceShape(5, 0.015), 1);
      // The author's curve: (1 - e^-3t) / (1 - e^-3).
      final t = (0.5 - 0.015) / (1 - 0.015);
      expect(voiceShape(0.5, 0.015), closeTo((1 - math.exp(-3 * t)) / (1 - math.exp(-3)), 1e-12));
    });

    test('follows up on the attack and down on the release', () {
      final up = voiceFollow(0, 1, 0.1, 0.325, 0.86);
      final down = 1 - voiceFollow(1, 0, 0.1, 0.325, 0.86);
      expect(up, closeTo(1 - math.exp(-0.1 / 0.325), 1e-12));
      expect(down, closeTo(1 - math.exp(-0.1 / 0.86), 1e-12));
      expect(up, greaterThan(down));
    });

    test('wraps lobe offsets into the ring and fades them at its edge', () {
      const span = voiceLobeSpan;
      expect(voiceWrapX(0, span), 0);
      expect(voiceWrapX(span / 2, span), -span / 2);
      expect(voiceWrapX(-span / 2 - 1, span), closeTo(span / 2 - 1, 1e-9));
      expect(voiceEdgeEnvelope(0, span), 1);
      expect(voiceEdgeEnvelope(span / 2 + 4, span), 0);
    });
  });

  group('band line', () {
    test('the bell is 1 at the centre and 0 at both ends', () {
      expect(voiceBell(0, 1.75, 0.87, 0.12), closeTo(1, 1e-12));
      expect(voiceBell(1, 1.75, 0.87, 0.12), closeTo(0, 1e-12));
      expect(voiceBell(-1, 1.75, 0.87, 0.12), closeTo(0, 1e-12));
      // Positive skew widens the right side.
      expect(voiceBell(0.5, 1.75, 0.87, 0.12), greaterThan(voiceBell(-0.5, 1.75, 0.87, 0.12)));
    });

    test('the tail rises from its start to the full lift at the edge', () {
      expect(voiceTailLift(50, 200, 0.6, 0.67, 2.4), 0);
      expect(voiceTailLift(200, 200, 0.6, 0.67, 2.4), closeTo(0.6, 1e-12));
      expect(voiceTailLift(180, 200, 0.6, 0.67, 2.4), inExclusiveRange(0, 0.6));
    });

    test('corner lift follows the arc and caps at the radius', () {
      expect(voiceCornerLift(100, 300, 20), 0);
      expect(voiceCornerLift(0, 300, 20), 20);
      expect(voiceCornerLift(10, 300, 20), closeTo(20 - math.sqrt(400 - 100), 1e-9));
      expect(voicePaintedRadius(106, 150, 44), 22);
    });

    test('rests on the bottom with tails up at the corners, then loses them while gathered', () {
      final c = _config();
      final e = VoiceGlowEngine()..still(c, input: 0.8, active: true);
      final xs = Float64List(voiceBandSamples + 1), ys = Float64List(voiceBandSamples + 1);
      voiceBandPoints(c, e, 371, 104, xs, ys);
      final over = c.geometry.bandTailOverflow;
      expect(xs.first, -over);
      expect(xs.last, 371 + over);
      final mid = ys[voiceBandSamples ~/ 2];
      // The apex rises above the base (104 + 27); the ends lift again.
      expect(mid, lessThan(104 - c.geometry.bandOffset));
      expect(ys.first, lessThan(104 - c.geometry.bandOffset));

      e.still(c, input: 0, motion: const VoiceBeamMotion(gather: 1), active: true);
      voiceBandPoints(c, e, 371, 104, xs, ys);
      final half = voiceCeilingHalfWidth * c.geometry.rangeWidth * e.w * e.maskWidth;
      expect(xs.first, closeTo(371 / 2 - half, 1e-9));
    });
  });

  group('colour', () {
    test('the neutral chain is the identity and keeps white white', () {
      final id = voiceColorMatrix(0, 1, 1);
      for (var i = 0; i < 9; i++) {
        expect(id[i], closeTo(i % 4 == 0 ? 1 : 0, 1e-9));
      }
      final m = voiceColorMatrix(24, 1, 1.4);
      for (var row = 0; row < 3; row++) {
        expect(m[row * 3] + m[row * 3 + 1] + m[row * 3 + 2], closeTo(1, 1e-9));
      }
    });

    test('the theme palette stays near the primary hue and calm', () {
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));
      final primary = HSLColor.fromColor(scheme.primary).hue;
      for (final c in voiceThemeColors(scheme, dark: true)) {
        final hsl = HSLColor.fromColor(c);
        final d = ((hsl.hue - primary + 540) % 360) - 180;
        expect(d.abs(), lessThanOrEqualTo(42.5));
        expect(hsl.saturation, lessThanOrEqualTo(0.51));
      }
    });
  });

  group('level scales', () {
    test('linear passes the 0–1 level through', () {
      expect(VoiceLevelScale.linear.raw(0.4, 3.1), 0.4);
      expect(VoiceLevelScale.linear.raw(1.4, 3.1), 1);
    });

    test('dBFS scales turn back into RMS × the web mic gain', () {
      // 0.6 on −60…−10 dBFS is −30 dBFS.
      expect(VoiceLevelScale.callCapture.raw(0.6, 3.1), closeTo(math.pow(10, -1.5) * 5 * 3.1, 1e-9));
      // 0.5 on −50…−10 is −30 dBFS too.
      expect(VoiceLevelScale.playback.raw(0.5, 3.1), closeTo(VoiceLevelScale.callCapture.raw(0.6, 3.1), 1e-9));
      // Speech at −30 dBFS lights most of the glow; −55 dBFS of room hum barely any.
      expect(voiceShape(VoiceLevelScale.callCapture.raw(0.6, 3.1), 0.015), inExclusiveRange(0.7, 0.9));
      expect(voiceShape(VoiceLevelScale.callCapture.raw(0.1, 3.1), 0.015), lessThan(0.06));
    });

    test('a silent frame (meter at 0) closes the gate', () {
      for (final scale in [VoiceLevelScale.playback, VoiceLevelScale.callCapture]) {
        expect(scale.raw(0, 3.1), 0);
        expect(voiceShape(scale.raw(0, 3.1), 0.015), 0);
      }
    });
  });

  group('presets', () {
    test('the light theme retunes the chat input and every band strength', () {
      final dark = VoiceGeometry.resolve(VoiceBeamType.standard, dark: true);
      final light = VoiceGeometry.resolve(VoiceBeamType.standard, dark: false);
      expect((dark.reach, dark.spread, dark.coreLight, dark.bandStrength), (1.2, 1.05, 0.0, 1.55));
      expect((light.reach, light.spread, light.coreLight, light.bandStrength), (1.8, 0.8, 1.8, 1.7));
      expect(VoiceGeometry.resolve(VoiceBeamType.pill, dark: false).bandStrength, 2);
      final mobile = VoiceGeometry.resolve(VoiceBeamType.mobile, dark: false);
      expect((mobile.reach, mobile.spread, mobile.coreLight, mobile.bandStrength), (3.0, 0.45, 1.8, 1.7));
    });

    test('scale multiplies every length, once', () {
      final g = VoiceGeometry.resolve(VoiceBeamType.mobile, dark: true).resolved();
      expect(g.scale, 1.25);
      expect(g.flow, 60 * 1.25);
      expect(g.bandOffset, -50 * 1.25);
      expect(g.rangeWidth, 1.25 * 1.25);
      expect(g.reach, 3);
    });

    test('colour tuning comes from the type, then the theme', () {
      final chat = _config();
      expect((chat.brightness, chat.saturation, chat.strength), (1.15, 1.2, 1.0));
      final mobile = _config(type: VoiceBeamType.mobile, dark: false);
      expect((mobile.brightness, mobile.saturation, mobile.strength), (0.95, 1.6, 1.0));
      final light = _config(dark: false);
      expect(light.strength, 0.8);
      final mono = _config(colorVariant: VoiceBeamColorVariant.mono);
      expect(mono.staticColors, isTrue);
      expect(mono.bloomOpacity, closeTo(0.89 * 0.6, 1e-12));
    });
  });

  group('engine', () {
    test('a voice raises, widens and lights the glow; silence lets it settle', () {
      final c = _config();
      final e = VoiceGlowEngine();
      for (var i = 0; i < 120; i++) {
        e.step(c, dt: 1 / 60, input: 0.9, active: true);
      }
      expect(e.presence, 1);
      expect(e.level, greaterThan(0.9));
      expect(e.h, greaterThan(0.5 + 1.2 * 0.9));
      expect(e.w, greaterThan(0.85 + 1.05 * 0.9));
      expect(e.bendA, greaterThan(0.9));
      for (var i = 0; i < 300; i++) {
        e.step(c, dt: 1 / 60, input: 0, active: true);
      }
      expect(e.level, lessThan(0.01));
      // The idle breath keeps it present but low.
      expect(e.glow, inInclusiveRange(0.15, 0.15 + 0.85 * 0.18 + 1e-9));
    });

    test('is deterministic for the same inputs', () {
      final c = _config();
      final a = VoiceGlowEngine(), b = VoiceGlowEngine();
      for (var i = 0; i < 200; i++) {
        final input = 0.5 + 0.5 * math.sin(i / 7);
        final motion = VoiceBeamMotion(gather: i > 100 ? 1 : 0, offset: math.sin(i / 20));
        a.step(c, dt: 1 / 60, input: input, motion: motion, active: true);
        b.step(c, dt: 1 / 60, input: input, motion: motion, active: true);
      }
      expect(a.lobeX, b.lobeX);
      expect(a.lobeL, b.lobeL);
      expect((a.cx, a.h, a.w, a.hue), (b.cx, b.h, b.w, b.hue));
    });

    test('a gathered motion narrows the range, places the beam and holds it lit', () {
      final c = _config();
      final e = VoiceGlowEngine();
      const motion = VoiceBeamMotion(gather: 1, offset: 0.5, heldLevel: 0.55);
      for (var i = 0; i < 60; i++) {
        e.step(c, dt: 1 / 60, input: 0, motion: motion, active: true);
      }
      expect(e.morph, 1);
      expect(e.maskWidth, closeTo(0.55, 1e-12));
      expect(e.cx, closeTo(0.5 * voiceLobeSpan * c.geometry.lobeSpacing / 2, 1e-9));
      expect(e.glow, greaterThanOrEqualTo(0.15 + 0.85 * 0.55 - 1e-9));
    });

    test('fades in over 0.6 s and out over 0.5 s; paused holds all but the fade', () {
      final c = _config();
      final e = VoiceGlowEngine();
      for (var i = 0; i < 36; i++) {
        e.step(c, dt: 1 / 60, input: 0, active: true);
      }
      expect(e.presence, closeTo(1, 1e-9));
      final level = e.level, hue = e.hue;
      e.step(c, dt: 0.05, input: 1, active: true, frozen: true);
      expect((e.level, e.hue), (level, hue));
      for (var i = 0; i < 30; i++) {
        e.step(c, dt: 1 / 60, input: 0, active: false, frozen: true);
      }
      expect(e.visible, isFalse);
    });

    test('reduced motion: no breath, no flow, no drift, beam centred', () {
      final c = _config(reducedMotion: true);
      final e = VoiceGlowEngine();
      for (var i = 0; i < 200; i++) {
        e.step(c, dt: 1 / 60, input: 0.5, motion: const VoiceBeamMotion(gather: 1, offset: 0.8), active: true);
      }
      expect(e.hue, 0);
      expect(e.cx, 0);
      e.still(c, input: 0, active: true);
      expect(e.glow, closeTo(0.15 + 0.85 * 0.18 * 0.5, 1e-9));
    });
  });
}
