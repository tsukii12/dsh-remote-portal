import 'dart:math' as math;

import 'package:dsh_app/ui/fx/voice_ring/aura.dart';
import 'package:dsh_app/ui/fx/voice_ring/frame.dart';
import 'package:dsh_app/ui/fx/voice_ring/lean.dart';
import 'package:dsh_app/ui/fx/voice_ring/light.dart';
import 'package:dsh_app/ui/fx/voice_ring/voice.dart';
import 'package:dsh_app/ui/fx/voice_ring/voice_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VoiceInput _run(
  VoiceFollower f,
  double seconds, {
  double? level,
  bool processing = false,
  double direction = 0,
  bool still = false,
}) {
  late VoiceInput v;
  for (var t = 0.0; t < seconds; t += 1 / 60) {
    if (level == null) {
      f.readSilence();
    } else {
      f.readLevel(level, 0.85);
    }
    v = f.step(
      1 / 60,
      threshold: 0.04,
      attack: 0.06,
      release: 0.32,
      idle: 0.1,
      driveGain: 1.8,
      calm: 0.4,
      rate: 1.6,
      processing: processing,
      direction: direction,
      still: still,
    );
  }
  return v;
}

VoiceInput _loud() {
  final v = VoiceInput()
    ..level = 1
    ..soft = 1
    ..drive = 3.7;
  v.bands.fillRange(0, 3, 1);
  v.softBands.fillRange(0, 3, 1);
  return v;
}

void main() {
  group('follower', () {
    test('gate and soft saturation', () {
      expect(shapeLevel(0.03, 0.04), 0);
      expect(shapeLevel(1, 0.04), closeTo(1, 1e-9));
      expect(shapeLevel(0.3, 0.04), lessThan(shapeLevel(0.6, 0.04)));
    });

    test('meter levels go back to the author\'s RMS × 5', () {
      // mic: 0.8 shown is −20 dBFS, an RMS of 0.1
      expect(VoiceRingLevel.mic(0.8), closeTo(0.5, 1e-9));
      expect(VoiceRingLevel.playback(0.75), closeTo(0.5, 1e-9));
      // a closed meter falls under the noise gate
      expect(shapeLevel(VoiceRingLevel.mic(0) * 0.85, 0.04), 0);
      expect(shapeLevel(VoiceRingLevel.playback(0) * 0.85, 0.04), 0);
    });

    test('silence keeps only the idle breathing; a voice lifts every envelope', () {
      final quiet = _run(VoiceFollower(), 3);
      expect(quiet.level, lessThanOrEqualTo(0.1 + 1e-9));
      final f = VoiceFollower();
      final loud = _run(f, 2, level: 0.9);
      expect(loud.level, greaterThan(0.9));
      expect(loud.soft, greaterThan(0.85));
      expect(loud.spectrum.reduce(math.max), greaterThan(0.3));
      // the voice clock outruns the ambient clock while someone speaks
      expect(loud.drive, greaterThan(f.t));
    });

    test('processing eases in, and its spin comes home to a whole turn', () {
      final f = VoiceFollower();
      expect(_run(f, 3, processing: true).processing, greaterThan(0.95));
      final after = _run(f, 20);
      expect(after.processing, lessThan(0.01));
      final turns = after.spin / (2 * math.pi);
      expect(turns, greaterThan(1));
      expect((turns - turns.round()).abs(), lessThan(1e-3));
    });

    test('the lean follows the side only while a voice is heard', () {
      final f = VoiceFollower();
      expect(_run(f, 4, level: 0.9, direction: 1).pan, closeTo(1, 0.05));
      expect(_run(f, 8, direction: 1).pan.abs(), lessThan(0.05));
    });

    test('reduced motion holds the clocks but still hears the voice', () {
      final f = VoiceFollower();
      final v = _run(f, 1, level: 0.9, still: true);
      expect(f.t, 0);
      expect(v.drive, 0);
      expect(v.level, greaterThan(0.9));
    });

    test('an emotion eases in, crossfades, and fades out', () {
      final g = GlowFollower();
      final calm = emotionColors[VoiceRingEmotion.calm]!;
      for (var i = 0; i < 300; i++) {
        g.step(1 / 60, calm, 0, still: false);
      }
      expect(g.amount, greaterThan(0.99));
      expect(g.b, closeTo(calm.b, 1e-6));
      g.step(1 / 60, emotionColors[VoiceRingEmotion.negative], 0, still: false);
      expect(g.r, greaterThan(calm.r));
      expect(g.r, lessThan(255));
      g.step(1 / 60, null, 0, still: true);
      expect(g.amount, 0);
    });
  });

  group('frames', () {
    test('the ring bends but neither grows nor slides', () {
      final b = AuraFrameBuilder(segs: 140);
      final frame = b.build(200, 1.3, _loud());
      expect(frame.strokes, hasLength(6));
      var sx = 0.0;
      var sy = 0.0;
      var sr = 0.0;
      var n = 0;
      for (final s in frame.strokes) {
        for (var i = 0; i < s.length; i++) {
          final x = s.pts[2 * i] - 100;
          final y = s.pts[2 * i + 1] - 100;
          sx += x;
          sy += y;
          sr += math.sqrt(x * x + y * y);
          n++;
        }
      }
      final r = 100 * 0.56 * 1.17;
      expect(sx / n, closeTo(0, 1.5));
      expect(sy / n, closeTo(0, 1.5));
      // the rings lie a little off the view axis, so they read slightly smaller
      expect(sr / n, closeTo(r, r * 0.12));
      final light = frame.light!;
      expect(light.intensity, closeTo((0.62 + 0.55) * 0.78, 1e-9));
      expect(light.stops, same(auraSpectrum));
    });

    test('mono lights its tubes and knows their depth', () {
      final b = MonoFrameBuilder(segs: 180);
      final frame = b.build(200, 2, _loud());
      expect(frame.strokes, hasLength(2));
      for (final s in frame.strokes) {
        expect(s.a.every((a) => a >= 0 && a <= 1), isTrue);
        expect(s.z!.every((z) => z >= -1 && z <= 1), isTrue);
      }
      expect(frame.tube, same(monoTube));
    });
  });

  group('lean', () {
    OrbFrame frame() => AuraFrameBuilder(segs: 140).build(200, 1, VoiceInput());

    double maxX(OrbFrame f) =>
        f.strokes.expand((s) => [for (var i = 0; i < s.length; i++) s.pts[2 * i]]).reduce(math.max);

    test('no pan, no lean', () {
      final f = frame();
      final before = maxX(f);
      leanFrame(f, 0, 200, ringLean);
      expect(maxX(f), before);
    });

    test('leans toward the voice and presses on the edge through a lens', () {
      final free = frame();
      final before = maxX(free);
      leanFrame(free, 1, 200, ringLean);
      expect(maxX(free), greaterThan(before + 10));
      expect(free.contact, isNull);

      final tight = frame();
      leanFrame(tight, 1, 200, ringLean, roomRight: 4);
      expect(maxX(tight), lessThanOrEqualTo(204));
      expect(tight.contact!.press, greaterThan(0));
      expect(tight.contact!.lens, isNotNull);

      final mono = MonoFrameBuilder(segs: 180).build(200, 1, VoiceInput());
      leanFrame(mono, 1, 200, monoLean, roomRight: 4);
      expect(mono.contact!.lens, isNull);
    });

    test('the reach covers the lean', () {
      expect(leanReach(ringLean, 300), (300 * 0.36 * 1.13).ceilToDouble() + 2);
    });

    test('the bounce overshoots and settles', () {
      final b = EdgeBounce();
      var peak = 0.0;
      var last = 0.0;
      for (var i = 0; i < 180; i++) {
        last = b.step(1, 1 / 60);
        peak = math.max(peak, last);
      }
      expect(peak, greaterThan(0.1));
      expect(last.abs(), lessThan(0.01));
    });
  });

  group('colour', () {
    test('the smoothed spectrum closes on itself and keeps its stops', () {
      final s = smoothSpectrum(auraSpectrum);
      expect(s, hasLength(37));
      expect(s.first.$2, closeTo(s.last.$2, 1));
      expect(s.first.$2, closeTo(255, 1));
      expect(s.first.$3, closeTo(150, 1));
    });

    test('on paper the light reads as deeper ink', () {
      final dark = lightPalette(auraSpectrum, dark: true);
      final light = lightPalette(auraSpectrum, dark: false);
      expect(dark[3].$2, auraSpectrum[3].$2);
      expect(light[3].$2, closeTo(auraSpectrum[3].$2 * 0.82, 1e-9));
    });

    test('green swings toward yellow, not teal', () {
      final (mid, swing) = emotionHue(toHsl(92, 224, 150).$1);
      expect(mid * 360, lessThan(146));
      expect(swing, lessThan(spectrumSwing));
    });

    test('the theme palette keeps to the theme colour\'s neighbours, calmer than the original', () {
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4D6BFE));
      final p = scheme.primary;
      final hue = toHsl(p.r * 255, p.g * 255, p.b * 255).$1 * 360;
      final palette = VoiceRingPalette.of(scheme);
      double chroma(SpectrumStop s) {
        final (_, a, b) = toLab(s.$2, s.$3, s.$4);
        return math.sqrt(a * a + b * b);
      }

      for (var i = 0; i < auraSpectrum.length; i++) {
        final s = palette.spectrum[i];
        final h = toHsl(s.$2, s.$3, s.$4).$1 * 360;
        final off = ((h - hue + 540) % 360 - 180).abs();
        expect(off, lessThan(48), reason: 'stop $i at $h°, theme $hue°');
        expect(chroma(s), lessThan(chroma(auraSpectrum[i])));
      }
      // a grey theme keeps only a whisper of colour
      final grey = VoiceRingPalette.of(
        ColorScheme.fromSeed(seedColor: Colors.grey, dynamicSchemeVariant: DynamicSchemeVariant.monochrome),
      );
      expect(grey.spectrum.map(chroma).reduce(math.max), lessThan(0.06));
    });
  });
}
