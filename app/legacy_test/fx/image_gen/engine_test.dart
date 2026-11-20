// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/image_gen/field.dart';
import 'package:dsh_app/ui/fx/image_gen/presets.dart';
import 'package:dsh_app/ui/fx/image_gen/reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A frame of [mode] on a 320×320 card whose raw field is [sample] (64² RGBA).
FxFrame _frame(FxPresetMode mode, {Uint8List? sample, double time = 50}) => FxFrame(
  mode: mode,
  look: FxLook.preset(mode),
  size: const Size(320, 320),
  pixelScale: 1,
  time: time,
  sample: (_) => sample,
);

/// A raw field painted in one colour.
Uint8List _flat(Color c) {
  final out = Uint8List(fxMaskSize * fxMaskSize * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = (c.r * 255).round();
    out[i + 1] = (c.g * 255).round();
    out[i + 2] = (c.b * 255).round();
    out[i + 3] = 255;
  }
  return out;
}

Future<RevealImage> _image(WidgetTester tester) async =>
    RevealImage((await tester.runAsync(() => createTestImage(width: 40, height: 30)))!);

int _sum(Uint8List a) => a.fold(0, (s, v) => s + v);

void main() {
  group('grid and sizing', () {
    test('gridCounts keeps cells square: 6 + cellSize·74 across 320 px', () {
      expect(fxGrid(0.22, const Size(320, 320)), (22, 22));
      expect(fxGrid(0.22, const Size(280, 210)), (19, 14));
      expect(fxGrid(0.22, const Size(640, 160)), (44, 11));
      expect(fxGrid(0.22, const Size(10, 10)), (2, 2));
    });

    test('pixelScale divides the base cell count', () {
      expect(effectiveCellSize(0.22, 1), 0.22);
      expect(6 + effectiveCellSize(0.22, 2) * 74, closeTo(22.28 / 2, 1e-9));
      expect(6 + effectiveCellSize(0.22, 0.5) * 74, closeTo(44.56, 1e-9));
    });

    test('easeOutCubic', () {
      expect(easeOutCubic(0), 0);
      expect(easeOutCubic(0.5), 0.875);
      expect(easeOutCubic(1), 1);
      expect(easeOutCubic(2), 1);
    });

    test('cover rect crops the overflowing axis and trims 0.6 %', () {
      final wide = fxCoverRect(400, 200, const Size(100, 100));
      expect(wide.width, closeTo(200 - 2 * 200 * 0.006, 1e-9));
      expect(wide.center.dx, closeTo(200, 1e-9));
      final tall = fxCoverRect(200, 400, const Size(200, 100));
      // Cropped to 2:1, then the same inset off every edge.
      expect(tall.width, closeTo(200 - 2 * 100 * 0.006, 1e-9));
      expect(tall.height, closeTo(100 - 2 * 100 * 0.006, 1e-9));
      expect(tall.center.dy, closeTo(200, 1e-9));
    });

    test('area downsample averages the covered pixels', () {
      final src = Uint8List(fxMaskSize * fxMaskSize);
      for (var r = 0; r < fxMaskSize; r++) {
        for (var c = 0; c < fxMaskSize ~/ 2; c++) {
          src[r * fxMaskSize + c] = 255;
        }
      }
      final dst = Uint8List(4 * 3);
      fxAreaDownsample(src, fxMaskSize, dst, 4, 3);
      expect(dst, [255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0]);
      final odd = Uint8List(3);
      fxAreaDownsample(src, fxMaskSize, odd, 3, 1);
      expect(odd, [255, 128, 0]);
    });
  });

  group('palette', () {
    test('preset palette: card-coloured slots follow a cardBg override', () {
      final mode = ImageGenerationPreset.pixelsOrganic.mode(Brightness.dark);
      const card = Color(0xFF1A1E26);
      final look = FxLook.preset(mode, cardBg: card, colors: [null, const Color(0xFFFF0000)]);
      expect(look.cardBg, card);
      expect(look.colors[0], card);
      expect(look.colors[1], const Color(0xFFFF0000));
      expect(look.colors[2], mode.colors[2]);
      expect(look.colors[3], card);
      expect(FxLook.preset(mode).colors, mode.colors);
    });

    test('themed palette keeps the luminance order and the card, low saturation', () {
      for (final preset in ImageGenerationPreset.values) {
        for (final b in Brightness.values) {
          final mode = preset.mode(b);
          final card = b == Brightness.dark ? const Color(0xFF1A1E26) : const Color(0xFFE7EBF3);
          final look = FxLook.themed(mode, const Color(0xFF4B67B4), card);
          for (var i = 0; i < 7; i++) {
            if (mode.colors[i] == mode.cardBg) {
              expect(look.colors[i], card);
            } else {
              expect(HSLColor.fromColor(look.colors[i]).saturation, lessThanOrEqualTo(0.31));
            }
            for (var j = 0; j < 7; j++) {
              final a = fxLuma(mode.colors[i]), c = fxLuma(mode.colors[j]);
              if (a < c - 0.02) expect(fxLuma(look.colors[i]), lessThan(fxLuma(look.colors[j]) + 0.02));
            }
          }
        }
      }
    });

    test('regenerate tint maps image colours onto slots by luminance rank', () {
      // 24² pixels: a ramp of greys, plus transparent corners that are skipped.
      final rgba = Uint8List(fxTintGrid * fxTintGrid * 4);
      for (var i = 0; i < fxTintGrid * fxTintGrid; i++) {
        final v = i * 255 ~/ (fxTintGrid * fxTintGrid - 1);
        rgba.setAll(i * 4, [v, v ~/ 2, 255 - v, i < 4 ? 0 : 255]);
      }
      final mode = ImageGenerationPreset.pixelsMechanic.mode(Brightness.dark);
      final tint = sampleTint(rgba, mode.colors)!;
      // The darkest slot (#060606, index 5) takes the 5th percentile, the
      // brightest (#949494, index 0) the 95th.
      final order = [5, 4, 1, 6, 2, 3, 0];
      for (var k = 1; k < order.length; k++) {
        expect(fxLuma(tint.colors[order[k]]), greaterThanOrEqualTo(fxLuma(tint.colors[order[k - 1]])));
      }
      expect(tint.cardBg.a, 1);
      expect(sampleTint(Uint8List(16), mode.colors), isNull);
    });
  });

  group('field (CPU port of the shader)', () {
    test('snoise and the effects match the numpy port of the GLSL', () {
      // Reference values from the numpy port used for the preview frames.
      expect(FxField.snoise(0, 0), closeTo(0, 1e-12));
      expect(FxField.snoise(0.5, 0.25), closeTo(-0.21835526512829567, 1e-12));
      expect(FxField.snoise(3.7, -1.2), closeTo(0.6899446445892339, 1e-12));
      expect(FxField.snoise(-12.3, 40.1), closeTo(-0.25914870117190597, 1e-12));
      expect(FxField.snoise(100.25, 7.5), closeTo(-0.8794467447272581, 1e-12));
      for (final (preset, b, t, grey) in [
        (ImageGenerationPreset.pixelsMechanic, Brightness.dark, 28.0, 0.39645083),
        (ImageGenerationPreset.pixelsOrganic, Brightness.light, 12.0, 0.92628273),
        (ImageGenerationPreset.sweepGradient, Brightness.dark, 106.0, 0.28627658),
      ]) {
        final mode = preset.mode(b);
        final out = Float64List(3);
        FxField(mode, FxLook.preset(mode)).effectColor(0.3, 0.7, 1.2, t, 19, 14, out);
        expect(out, everyElement(closeTo(grey, 1e-7)));
      }
      var lo = 1.0, hi = -1.0;
      final r = math.Random(1);
      for (var i = 0; i < 20000; i++) {
        final v = FxField.snoise(r.nextDouble() * 200 - 100, r.nextDouble() * 200 - 100);
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
      expect(lo, greaterThan(-1.01));
      expect(hi, lessThan(1.01));
      expect(hi - lo, greaterThan(1.5));
    });

    test('effect colours stay inside the palette, deterministic per time', () {
      for (final preset in ImageGenerationPreset.values) {
        final mode = preset.mode(Brightness.dark);
        final f = FxField(mode, FxLook.preset(mode));
        final a = Float64List(3), b = Float64List(3);
        f.effectColor(0.3, 0.7, 1.2, 40, 19, 14, a);
        f.effectColor(0.3, 0.7, 1.2, 40, 19, 14, b);
        expect(a, b);
        final lums = mode.colors.take(5).map(fxLuma);
        final l = 0.299 * a[0] + 0.587 * a[1] + 0.114 * a[2];
        expect(l, inInclusiveRange(lums.reduce(math.min) - 1e-4, lums.reduce(math.max) + 1e-4));
      }
    });

    test('raw sample is row 0 at the top, opaque', () {
      final mode = ImageGenerationPreset.sweepGradient.mode(Brightness.dark);
      final s = FxField(mode, FxLook.preset(mode)).rawSample(fxMaskSize, const Size(320, 320), 12, 22, 22);
      expect(s.length, fxMaskSize * fxMaskSize * 4);
      for (var i = 3; i < s.length; i += 4) {
        expect(s[i], 255);
      }
    });
  });

  group('reveal state machine', () {
    testWidgets('reveal: 3 s mask, cell dissolve, then hold', (tester) async {
      final mode = ImageGenerationPreset.pixelsOrganic.mode(Brightness.dark);
      var now = 0.0;
      var completed = 0;
      final reveal = FxReveal(now: () => now, random: math.Random(1));
      // The field everywhere equals the mask's target slot: the mask opens fully.
      final sample = _flat(FxLook.preset(mode).colors[mode.reveal.mask.slot]);
      final img = await _image(tester);
      reveal.startReveal(img, () => completed++);
      expect(reveal.phase, RevealPhase.reveal);

      reveal.frame(_frame(mode, sample: sample), now);
      final first = reveal.overlay! as FxOverlayPixels;
      expect((first.gx, first.gy), (22, 22));
      // Threshold starts at 1: proximity 1 is exactly on it, so nothing shows yet.
      expect(_sum(first.mask), 0);
      expect(first.drop.every((a) => a == 255), isTrue);
      expect(reveal.shaderOpacity, 1);

      now = 1000;
      reveal.frame(_frame(mode, sample: sample), now);
      final mid = reveal.overlay! as FxOverlayPixels;
      expect(mid.mask.every((a) => a == 255), isTrue);
      // Some cells have dissolved to the smooth image, some are still chunky.
      expect(mid.drop.any((a) => a == 0), isTrue);
      expect(mid.drop.any((a) => a == 255), isTrue);
      expect(reveal.shaderOpacity, closeTo(1 - easeOutCubic(1 / 3), 1e-9));

      now = 2700;
      reveal.frame(_frame(mode, sample: sample), now);
      expect((reveal.overlay! as FxOverlayPixels).drop.every((a) => a == 0), isTrue);
      expect(completed, 0);

      now = 3000;
      reveal.frame(_frame(mode, sample: sample), now);
      expect(reveal.phase, RevealPhase.hold);
      expect(reveal.overlay, isA<FxOverlayImage>());
      expect(reveal.shaderOpacity, 0);
      expect(completed, 1);
      reveal.dispose();
    });

    testWidgets('a field far from the target slot keeps the image hidden longer', (tester) async {
      final mode = ImageGenerationPreset.pixelsOrganic.mode(Brightness.dark);
      var now = 0.0;
      final reveal = FxReveal(now: () => now, random: math.Random(1));
      reveal.startReveal(await _image(tester), () {});
      now = 600;
      reveal.frame(_frame(mode, sample: _flat(const Color(0xFFFFFFFF))), now);
      expect(_sum((reveal.overlay! as FxOverlayPixels).mask), 0);
      reveal.dispose();
    });

    testWidgets('gradient sweep: a band from the top left', (tester) async {
      final mode = ImageGenerationPreset.sweepGradient.mode(Brightness.dark);
      var now = 0.0;
      final reveal = FxReveal(now: () => now, random: math.Random(1));
      reveal.startReveal(await _image(tester), () {});
      now = 500;
      reveal.frame(_frame(mode), now);
      final o = reveal.overlay! as FxOverlayPixels;
      expect(o.mask.first, greaterThan(o.mask.last));
      expect(o.mask.last, 0);
      reveal.dispose();
    });

    testWidgets('hide fades the overlay back over 300 ms', (tester) async {
      final mode = ImageGenerationPreset.pixelsMechanic.mode(Brightness.light);
      var now = 0.0;
      final reveal = FxReveal(now: () => now, random: math.Random(1));
      reveal.startReveal(await _image(tester), () {});
      now = 3000;
      reveal.frame(_frame(mode), now);
      expect(reveal.phase, RevealPhase.hold);
      reveal.startHide();
      now = 3150;
      reveal.frame(_frame(mode), now);
      expect(reveal.overlayOpacity, closeTo(0.5, 1e-9));
      expect(reveal.shaderOpacity, closeTo(0.5, 1e-9));
      now = 3300;
      reveal.frame(_frame(mode), now);
      expect(reveal.phase, RevealPhase.idle);
      expect(reveal.overlay, isNull);
      expect(reveal.image, isNull);
      expect((reveal.overlayOpacity, reveal.shaderOpacity), (1.0, 1.0));
    });

    testWidgets('boil: pixelate-in, churn, then the handoff settles on the next image', (tester) async {
      final mode = ImageGenerationPreset.pixelsMechanic.mode(Brightness.dark);
      var now = 0.0;
      var completed = 0;
      final reveal = FxReveal(now: () => now, random: math.Random(3));
      final a = await _image(tester), b = await _image(tester);
      reveal.startReveal(a, () => completed++);
      now = 3000;
      reveal.frame(_frame(mode), now);
      expect(completed, 1);

      // No-op unless an image is revealed or held.
      final idle = FxReveal(now: () => now, random: math.Random(1))..startBoil();
      expect(idle.phase, RevealPhase.idle);

      reveal.startBoil();
      expect(reveal.phase, RevealPhase.boil);
      final sample = FxField(mode, FxLook.preset(mode)).rawSample(fxMaskSize, const Size(320, 320), 50, 22, 22);
      reveal.frame(_frame(mode, sample: sample), now);
      var o = reveal.overlay! as FxOverlayBoil;
      // Frame 0: the photo under, no chunky cells yet, the mosaic hidden.
      expect((o.from, o.to, o.base), (a, null, a));
      expect(o.baseAlpha, 1);
      expect(_sum(o.drop), lessThan(o.drop.length * 255 ~/ 4));
      expect(reveal.shaderOpacity, 0);

      now = 3000 + 600;
      reveal.frame(_frame(mode, sample: sample, time: 50.6), now);
      o = reveal.overlay! as FxOverlayBoil;
      expect(o.baseAlpha, lessThan(1));
      expect(reveal.shaderOpacity, greaterThan(0));

      // The churn settles near half the cells dropped (BOIL_LEVEL).
      now = 3000 + 2500;
      reveal.frame(_frame(mode, sample: sample, time: 52.5), now);
      o = reveal.overlay! as FxOverlayBoil;
      expect(o.base, isNull);
      expect(reveal.shaderOpacity, 1);
      final kept = o.drop.where((v) => v > 127).length / o.drop.length;
      expect(kept, inInclusiveRange(0.3, 0.7));

      reveal.startReveal(b, () => completed++);
      expect(reveal.phase, RevealPhase.boil);
      now += 400;
      reveal.frame(_frame(mode, sample: sample, time: 53), now);
      o = reveal.overlay! as FxOverlayBoil;
      expect((o.from, o.to), (a, b));
      expect(o.blendT, closeTo(0.5, 1e-9));

      for (var t = 500; t <= 2100; t += 100) {
        reveal.frame(_frame(mode, sample: sample, time: 53), now + t);
      }
      expect(reveal.phase, RevealPhase.hold);
      expect(reveal.image, b);
      expect(reveal.shaderOpacity, 0);
      expect(completed, 2);
      reveal.dispose();
    });

    testWidgets('a reveal mid-boil hands over instead of restarting', (tester) async {
      final mode = ImageGenerationPreset.pixelsOrganic.mode(Brightness.light);
      var now = 0.0;
      final reveal = FxReveal(now: () => now, random: math.Random(1));
      final a = await _image(tester), b = await _image(tester), c = await _image(tester);
      reveal.startReveal(a, () {});
      reveal.startBoil();
      reveal.startReveal(b, () {});
      reveal.startReveal(c, () {});
      expect(reveal.phase, RevealPhase.boil);
      expect(reveal.image, a);
      // Still drawable until the next frame replaces the overlay.
      expect(b.image.debugDisposed, isFalse);
      now = 100;
      reveal.frame(_frame(mode), now);
      expect(b.image.debugDisposed, isTrue);
      expect((reveal.overlay! as FxOverlayBoil).to, c);
      reveal.clear();
      expect(reveal.phase, RevealPhase.idle);
      expect(a.image.debugDisposed, isTrue);
      expect(c.image.debugDisposed, isTrue);
    });
  });

  testWidgets('a picture dropped mid-handoff lives while the hide still draws it', (tester) async {
    final mode = ImageGenerationPreset.pixelsOrganic.mode(Brightness.light);
    var now = 0.0;
    final reveal = FxReveal(now: () => now, random: math.Random(1));
    final a = await _image(tester), b = await _image(tester);
    reveal.startReveal(a, () {});
    reveal.startBoil();
    reveal.startReveal(b, () {});
    now = 400;
    reveal.frame(_frame(mode), now);
    expect((reveal.overlay! as FxOverlayBoil).to, b);
    reveal.dropPending();
    reveal.startHide(300);
    now = 500;
    reveal.frame(_frame(mode), now);
    expect(b.image.debugDisposed, isFalse);
    now = 800;
    reveal.frame(_frame(mode), now);
    expect(reveal.phase, RevealPhase.idle);
    expect(b.image.debugDisposed, isTrue);
    expect(a.image.debugDisposed, isTrue);
  });

  testWidgets('cover cells and the tint read-back come from the cover-fit image', (tester) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(const Rect.fromLTWH(0, 0, 20, 10), Paint()..color = const Color(0xFFFF0000))
      ..drawRect(const Rect.fromLTWH(20, 0, 20, 10), Paint()..color = const Color(0xFF0000FF));
    final picture = recorder.endRecording();
    final img = RevealImage(picture.toImageSync(40, 10));
    picture.dispose();
    final cells = img.cells(4, 2, const Size(200, 100));
    expect((cells.width, cells.height), (4, 2));
    expect(identical(img.cells(4, 2, const Size(200, 100)), cells), isTrue);
    await tester.runAsync(() async {
      img.prepareTint(const Size(100, 100));
      for (var i = 0; i < 50 && img.tintPixels == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final px = img.tintPixels!;
    expect(px.length, fxTintGrid * fxTintGrid * 4);
    // Left half red, right half blue.
    expect(px[0], greaterThan(200));
    expect(px[(fxTintGrid - 1) * 4 + 2], greaterThan(200));
    img.dispose();
  });
}
