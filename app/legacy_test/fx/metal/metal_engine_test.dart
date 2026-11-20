// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui';

import 'package:dsh_app/ui/fx/metal/metal_bend.dart';
import 'package:dsh_app/ui/fx/metal/metal_geometry.dart';
import 'package:dsh_app/ui/fx/metal/metal_glow.dart';
import 'package:dsh_app/ui/fx/metal/metal_material.dart';
import 'package:flutter/material.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('material', () {
    test('presets carry the author numbers', () {
      final chromatic = MetalMaterial.preset(MetalPreset.chromatic, Brightness.dark);
      expect(chromatic.colorTint, const Color(0x2E88CCFF));
      expect((chromatic.shiftRed, chromatic.repetition, chromatic.softness), (0.75, 2.0, 0.09));
      final gold = MetalMaterial.preset(MetalPreset.gold, Brightness.dark);
      expect((gold.speed, gold.shaderOpacity), (0.85, 0.92));
      expect(MetalMaterial.preset(MetalPreset.silver, Brightness.light).colorTint, const Color(0x40FFFFFF));
    });

    test('the theme default is a pale tint of the theme hue', () {
      final m = MetalMaterial.themed(const Color(0xFF2E7D32), Brightness.dark);
      final hsl = HSLColor.fromColor(m.colorTint);
      expect(hsl.hue, closeTo(HSLColor.fromColor(const Color(0xFF2E7D32)).hue, 1));
      expect(hsl.saturation, lessThanOrEqualTo(0.141));
      expect(m.colorTint.a, closeTo(0.55, 0.01));
      expect(m.shaderOpacity, 0.88);
      expect(MetalMaterial.themed(const Color(0xFF2E7D32), Brightness.light).shaderOpacity, 1);
      expect(MetalMaterial.resolve(null, const Color(0xFF2E7D32), Brightness.dark), m);
    });

    // Values from the numpy port of shaders/fx/metal_liquid.frag: the CPU
    // sampler the halo hunts with must see the same material as the GPU.
    test('the CPU sampler matches the shader', () {
      const cases = {
        (MetalPreset.chromatic, Brightness.dark): [
          (0.5, 0.5, 0.0, 0.974955, 0.748984, 0.293982),
          (0.31, 0.42, 2.0, 0.953108, 0.970397, 0.998319),
          (0.7, 0.25, 3.3, 0.136876, 0.143226, 0.209104),
          (0.2, 0.8, 5.5, 0.215911, 0.284178, 0.420039),
          (0.55, 0.62, 9.1, 0.902532, 0.921034, 0.959392),
          (0.05, 0.5, 1.0, 0.408508, 0.543611, 0.625261),
        ],
        (MetalPreset.gold, Brightness.dark): [
          (0.5, 0.5, 0.0, 0.975131, 0.794382, 0.099669),
          (0.31, 0.42, 2.0, 0.839751, 0.823712, 0.697116),
          (0.7, 0.25, 3.3, 0.165266, 0.033659, 0.037290),
          (0.2, 0.8, 5.5, 0.978299, 0.960931, 0.038660),
          (0.55, 0.62, 9.1, 0.368458, 0.249705, 0.090194),
          (0.05, 0.5, 1.0, 0.375492, 0.284886, 0.086317),
        ],
        (MetalPreset.silver, Brightness.light): [
          (0.5, 0.5, 0.0, 0.975131, 0.828652, 0.498345),
          (0.31, 0.42, 2.0, 0.918675, 0.928107, 0.955711),
          (0.7, 0.25, 3.3, 0.372005, 0.377119, 0.404288),
          (0.2, 0.8, 5.5, 0.126492, 0.137670, 0.233946),
          (0.55, 0.62, 9.1, 0.894360, 0.898395, 0.930110),
          (0.05, 0.5, 1.0, 0.441616, 0.471324, 0.500930),
        ],
      };
      for (final MapEntry(key: (preset, brightness), value: samples) in cases.entries) {
        final m = MetalMaterial.preset(preset, brightness);
        for (final (u, v, t, r, g, b) in samples) {
          final (sr, sg, sb) = m.sample(u, v, t);
          expect([sr, sg, sb], [closeTo(r, 1e-4), closeTo(g, 1e-4), closeTo(b, 1e-4)], reason: '$preset ($u, $v) @ $t');
        }
      }
    });

    test('the sheet crop follows the 140×40 canonical pill', () {
      List<double> uv(MetalSheetMapping m, Offset p) => [m.uv(p).$1, m.uv(p).$2];
      final pill = MetalSheetMapping(const Size(140, 40), 1.6);
      expect(uv(pill, Offset.zero), [closeTo(0.1875, 1e-9), closeTo(0.1875, 1e-9)]);
      expect(uv(pill, const Offset(140, 40)), [closeTo(0.8125, 1e-9), closeTo(0.8125, 1e-9)]);
      final big = MetalSheetMapping(const Size(600, 200), 1.6);
      expect(uv(big, Offset.zero), [0.0, 0.0]);
      expect(uv(big, const Offset(600, 200)), [closeTo(1, 1e-9), closeTo(1, 1e-9)]);
    });
  });

  group('geometry', () {
    test('arcAtPoint inverts sampleAtArc on the outline', () {
      for (final kind in MetalShapeKind.values) {
        final perim = MetalGeometry.shapePerim(140, 40, 20, kind);
        for (var i = 0; i < 24; i++) {
          final s = perim * i / 24;
          final p = MetalGeometry.sampleAtArc(s, 140, 40, 20, 0, 0, kind);
          expect(MetalGeometry.arcAtPoint(p, 140, 40, 20, kind), closeTo(s, 1e-6), reason: '$kind $s');
        }
      }
    });

    test('nearestOutlinePoint and boundaryPoint', () {
      final (p, d) = MetalGeometry.nearestOutlinePoint(const Offset(70, -10), 140, 40, 20, MetalShapeKind.pill);
      expect([p.dx, p.dy, d], [closeTo(70, 1e-9), closeTo(0, 1e-9), closeTo(10, 1e-9)]);
      final (q, e) = MetalGeometry.nearestOutlinePoint(const Offset(70, 30), 140, 40, 20, MetalShapeKind.pill);
      expect((q.dy, e), (40.0, -10.0));
      final b = MetalGeometry.boundaryPoint(const Size(40, 40), 20, const Offset(1, 1));
      expect((b - const Offset(20, 20)).distance, closeTo(20, 1e-9));
    });
  });

  group('glow', () {
    // A grey material lit at one spot of the ring.
    MetalSampler spot(Offset Function() at) => (p) {
      final l = math.exp(-(p - at()).distanceSquared / 200) * 0.9;
      return (l, l, l);
    };

    test('appears on the brightest point, holds, then relocates through a fade', () {
      final glow = MetalGlowState()..configure(const Size(140, 40), 20, MetalShapeKind.pill);
      var bright = const Offset(70, 1.5);
      final sampler = spot(() => bright);
      var now = 0.0;
      MetalGlowFrame frame() => glow.tick(now, sampler, strength: 1, dark: true)!;

      final first = frame();
      expect(first.envelope, 0);
      for (; now < 400; now += 16) {
        frame();
      }
      final shown = frame();
      expect(shown.envelope, 1);
      expect((shown.position - bright).distance, lessThan(12));
      // It appears at the opacity of the spot it hunted from and creeps toward
      // the lit spot's (the web's `fadeRate`), so not at full strength yet.
      expect(shown.haloOpacity, inInclusiveRange(0.68, 0.8));

      // A brighter rival elsewhere: ignored during the dwell, then fade out in
      // place and in at the rival.
      bright = const Offset(70, 38.5);
      final before = shown.position;
      for (; now < 1000; now += 16) {
        expect((frame().position - before).distance, lessThan(12));
      }
      var faded = false;
      for (; now < 3000; now += 16) {
        final f = frame();
        if (f.envelope < 0.05) faded = true;
        if (faded && f.envelope == 1) break;
      }
      expect(faded, isTrue);
      expect((frame().position - bright).distance, lessThan(12));
    });

    test('faces a passing light, then goes back to the hunt', () {
      final glow = MetalGlowState()..configure(const Size(140, 40), 20, MetalShapeKind.pill);
      final sampler = spot(() => const Offset(70, 38.5));
      var now = 0.0;
      for (; now < 600; now += 16) {
        glow.tick(now, sampler, strength: 1, dark: true);
      }
      final light = (point: const Offset(30, 0), weight: 1.0);
      MetalGlowFrame? f;
      for (; now < 2000; now += 16) {
        f = glow.tick(now, sampler, strength: 1, dark: true, light: light);
      }
      expect(f!.envelope, 1);
      expect((f.position - const Offset(30, 1.5)).distance, lessThan(2));
      for (; now < 4000; now += 16) {
        f = glow.tick(now, sampler, strength: 1, dark: true);
      }
      expect((f!.position - const Offset(70, 38.5)).distance, lessThan(12));
    });

    test('a still frame sits fully in on the brightest point', () {
      final glow = MetalGlowState()..configure(const Size(40, 40), 20, MetalShapeKind.circle);
      final f = glow.still(spot(() => const Offset(38.5, 20)), strength: 1, dark: false)!;
      expect(f.envelope, 1);
      expect((f.position - const Offset(38.5, 20)).distance, lessThan(8));
    });
  });

  test('the sweep passes over the top edge once a period', () {
    final tracker = MetalSweepTracker();
    const sweep = MetalSweep();
    MetalLight? light;
    for (var now = 0.0; now < 5400; now += 16) {
      light = tracker.step(now, sweep, const Size(140, 40), 20, MetalShapeKind.pill);
      expect(light, isNull);
    }
    for (var now = 5400.0; now <= 7200; now += 16) {
      light = tracker.step(now, sweep, const Size(140, 40), 20, MetalShapeKind.pill);
    }
    expect(light!.weight, greaterThan(0.8));
    expect(light.point.dy, 0);
    expect(light.point.dx, closeTo(70, 3));
    for (var now = 7200.0; now < 9200; now += 16) {
      light = tracker.step(now, sweep, const Size(140, 40), 20, MetalShapeKind.pill);
    }
    expect(light, isNull);
  });

  test('a press dents the ring toward the centre and it springs back', () {
    final bend = MetalBendModel();
    const size = Size(40, 40);
    var now = 1.0;
    MetalBendField? field;
    for (var i = 0; i < 20; i++, now += 1 / 60) {
      field = bend.step(now, const Offset(20, 6), pressed: true, size: size, radius: 20);
    }
    expect(field!.deform(const Offset(20, 0)).dy, greaterThan(1));
    expect(field.deform(const Offset(20, 40)).dy, closeTo(40, 0.5));
    var i = 0;
    for (; i < 240 && bend.busy; i++, now += 1 / 60) {
      bend.step(now, null, pressed: false, size: size, radius: 20);
    }
    expect(bend.busy, isFalse);
    expect(bend.field, isNull);
  });
}
