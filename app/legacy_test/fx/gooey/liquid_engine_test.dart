// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The expected numbers come from running the original TypeScript (spring.ts
// `simulate`, LiquidItem.tsx `mapMove` / `mapBend`, observer.ts `writeBlob`'s
// move branch) in node on the same inputs.

import 'package:dsh_app/ui/fx/gooey/liquid.dart';
import 'package:dsh_app/ui/fx/gooey/liquid_engine.dart';
import 'package:dsh_app/ui/fx/gooey/liquid_presets.dart';
import 'package:dsh_app/ui/fx/gooey/liquid_transition.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transition', () {
    test('springs compile to the same duration and curve as the original', () {
      const expected = {
        'snappy': (LiquidTransition.snappy, 400, 37, [0.28028, 0.765, 1.009, 1.0066, 1.00156]),
        'smooth': (LiquidTransition.smooth, 587, 54, [0.21227, 0.638725, 0.93275, 0.9907, 0.99755]),
        'bouncy': (LiquidTransition.bouncy, 746, 68, [0.56973, 1.173025, 0.9713, 1.004625, 1.00212]),
      };
      for (final MapEntry(key: name, value: (spring, ms, n, at)) in expected.entries) {
        final timing = spring.resolve();
        expect(timing.duration, Duration(milliseconds: ms), reason: name);
        expect((timing.curve as SampledCurve).values, hasLength(n), reason: name);
        final ts = [0.1, 0.25, 0.5, 0.75, 0.9];
        for (var i = 0; i < ts.length; i++) {
          expect(timing.curve.transform(ts[i]), closeTo(at[i], 1e-9), reason: '$name @${ts[i]}');
        }
      }
    });

    test('reduced motion snaps; timed transitions keep their curve', () {
      expect(LiquidTransition.bouncy.resolve(reduced: true).duration, Duration.zero);
      expect(LiquidMenu.open.resolve().duration, const Duration(milliseconds: 550));
      expect(LiquidMenu.close.resolve(reduced: true).duration, Duration.zero);
      // cubic-bezier(0.34, 1.56, 0.64, 1) overshoots.
      expect(LiquidMenu.open.curve.transform(0.5), greaterThan(1));
    });

    test('the close dip goes down by 30 % and back', () {
      expect(LiquidMenu.anticipationAt(0), 0);
      expect(LiquidMenu.anticipationAt(0.3), closeTo(LiquidMenu.anticipation, 1e-9));
      expect(LiquidMenu.anticipationAt(1), 0);
      expect(LiquidMenu.anticipationAt(0.15), inExclusiveRange(0, LiquidMenu.anticipation));
    });
  });

  group('tuning', () {
    void same(LiquidMoveOptions o, List<double> v) {
      final got = [o.stiffness!, o.damping!, o.stretch!, o.tail!, o.force!, o.bend!, o.bendX!];
      for (var i = 0; i < v.length; i++) {
        expect(got[i], closeTo(v[i], 1e-9), reason: 'field $i');
      }
    }

    test('MoveTuning maps like mapMove', () {
      same(const MoveTuning().resolve(), [380, 18, 0.18, 0.46, 0.5, 0, 0]);
      same(const MoveTuning(stretch: 0.6, trail: 0.35).resolve(), [380, 18, 0.3, 0.28, 0.5, 0, 0]);
      same(const MoveTuning(springiness: 0, wobble: 1).resolve(), [
        120.16655108639841,
        2.6992383609136756,
        0.18,
        0.46,
        0.5,
        0,
        0,
      ]);
      same(const MoveTuning(advanced: LiquidMoveOptions(damping: 24.5)).resolve(), [380, 24.5, 0.18, 0.46, 0.5, 0, 0]);
    });

    test('BendTuning maps like mapBend', () {
      same(const BendTuning().resolve(), [1201.6655108639843, 32.00902938070061, 0, 0, 0.5, 0.6, 0.35]);
    });

    test('goo threshold intercept tracks the slope', () {
      expect(Liquid.interceptFor(18), -7);
      expect(Liquid.interceptFor(4), -1.17);
      expect(Liquid.interceptFor(40), -16.17);
    });
  });

  group('move body', () {
    // A 60×30 pill (radius 15): still for a frame, then slid right 120 px and
    // down 40 px over 15 frames, then resting.
    List<LiquidBody> run(LiquidMoveOptions o, {int every = 1}) {
      final body = LiquidBody();
      final out = <LiquidBody>[];
      for (var i = 0; i < 60; i += every) {
        final p = ((i - 1) / 15).clamp(0.0, 1.0);
        body.step(Rect.fromLTWH(120 * p, 40 * p, 60, 30), 15, 60, every / 60, o);
        out.add(_copy(body));
      }
      return out;
    }

    test('trails, stretches and strings a tail like writeBlob', () {
      final rows = run(const MoveTuning().resolve());
      // cx, cy, tailX, tailY, tailR, stretch, angle, moving
      const expected = [
        (2, [30.844444, 15.281481, 30.039877, 15.013292, 0.506208, 0.032044, 0.32, 1]),
        (5, [42.06635, 19.022117, 31.426575, 15.475525, 4.8741, 0.18, 0.32, 1]),
        (10, [83.31612, 32.77204, 44.979551, 19.993184, 8.484222, 0.18, 0.32, 1]),
        (16, [136.300149, 50.433383, 82.534289, 32.51143, 10.097517, 0.18, 0.32, 1]),
        (20, [155.878998, 56.959666, 112.14115, 42.380383, 10.518104, 0.095337, 0.32, 1]),
        (30, [149.104592, 54.701531, 147.952951, 54.31765, 4.509824, 0.017276, -2.82, 1]),
        (45, [150.115155, 55.038385, 149.990127, 54.996709, 0.292712, 0.001319, -2.82, 1]),
        (59, [150.000264, 55.000088, 150.000906, 55.000302, 0.022798, 0, 0, 0]),
      ];
      for (final (i, v) in expected) {
        final b = rows[i];
        expect(b.cx, closeTo(v[0], 1e-5), reason: 'cx@$i');
        expect(b.cy, closeTo(v[1], 1e-5), reason: 'cy@$i');
        expect(b.tailX, closeTo(v[2], 1e-5), reason: 'tailX@$i');
        expect(b.tailY, closeTo(v[3], 1e-5), reason: 'tailY@$i');
        expect(b.tailR, closeTo(v[4], 1e-5), reason: 'tailR@$i');
        expect(b.stretch, closeTo(v[5], 1e-5), reason: 'stretch@$i');
        if (v[5] > 0) expect(b.stretchAngle, v[6], reason: 'angle@$i');
        expect(b.bending, isFalse);
        expect(b.paintR, closeTo(15, 1e-9));
      }
      // The mid-droplets of the tail.
      const mids = [
        (5, [37.144883, 17.826857, 34.128056, 16.237563]),
        (10, [65.817839, 27.76203, 54.144454, 24.445616]),
        (16, [112.588865, 40.918445, 96.443958, 35.587306]),
      ];
      for (final (i, v) in mids) {
        expect(rows[i].midA.dx, closeTo(v[0], 1e-5));
        expect(rows[i].midA.dy, closeTo(v[1], 1e-5));
        expect(rows[i].midB.dx, closeTo(v[2], 1e-5));
        expect(rows[i].midB.dy, closeTo(v[3], 1e-5));
      }
    });

    test('reports motion until settled', () {
      final body = LiquidBody();
      final o = const MoveTuning().resolve();
      final moving = <bool>[];
      for (var i = 0; i < 60; i++) {
        final p = ((i - 1) / 15).clamp(0.0, 1.0);
        moving.add(body.step(Rect.fromLTWH(120 * p, 40 * p, 60, 30), 15, 60, 1 / 60, o));
      }
      expect(moving.take(2), [false, false]);
      expect(moving[45], isTrue);
      expect(moving.last, isFalse);
    });

    test('substeps a long frame gap like springSteps', () {
      final rows = run(const MoveTuning().resolve(), every: 2);
      const expected = [
        (2, [39.666225, 18.222075, 4.952976]),
        (5, [87.829876, 34.276625, 9.144856]),
        (9, [151.700376, 55.566792, 10.561216]),
        (15, [148.939876, 54.646625, 3.47467]),
      ];
      for (final (i, v) in expected) {
        expect(rows[i].cx, closeTo(v[0], 1e-5));
        expect(rows[i].cy, closeTo(v[1], 1e-5));
        expect(rows[i].tailR, closeTo(v[2], 1e-5));
      }
    });

    test('bend bows the body like writeBlob', () {
      final rows = run(const BendTuning().resolve());
      const expected = [
        (3, [38.365515, 17.788505, 0.716846, 2.060992]),
        (8, [81.538354, 32.179451, 3.207672, 6.171458]),
        (14, [129.159548, 48.053183, 4.174471, 8.213499]),
        (18, [152.850809, 55.95027, 3.760741, 8.04377]),
        (25, [149.684842, 54.894947, 1.048876, 2.084944]),
        (40, [150.000953, 55.000318, 0.094608, 0.19153]),
      ];
      for (final (i, v) in expected) {
        final b = rows[i];
        expect(b.cx, closeTo(v[0], 1e-5), reason: 'cx@$i');
        expect(b.cy, closeTo(v[1], 1e-5), reason: 'cy@$i');
        expect(b.bendCur, closeTo(v[2], 1e-5), reason: 'bend@$i');
        expect(b.bendCurX, closeTo(v[3], 1e-5), reason: 'bendX@$i');
        expect(b.hasTail, isFalse);
        expect(b.stretch, 0);
      }
      expect(rows[8].bending, isTrue);
      expect(rows[40].bending, isFalse);
      // Bowing down: the bottom edge's middle sags below the rect.
      final bounds = _bowed().bendPath.getBounds();
      expect(bounds.bottom, greaterThan(15));
    });
  });

  test('springSteps substeps at 1/60 s', () {
    final (p1, v1) = springSteps(0, 0, 1, 380, 18, 1 / 30);
    var (p, v) = springSteps(0, 0, 1, 380, 18, 1 / 60);
    (p, v) = springSteps(p, v, 1, 380, 18, 1 / 60);
    expect(p1, closeTo(p, 1e-12));
    expect(v1, closeTo(v, 1e-12));
  });

  test('pill radius clamps to half the short side', () {
    expect(pillRadius(999, 120, 30), 15);
    expect(pillRadius(8, 120, 30), 8);
    expect(pillRadius(-2, 120, 30), 0);
  });
}

LiquidBody _copy(LiquidBody b) => _Snapshot(b);

LiquidBody _bowed() {
  final body = LiquidBody();
  final o = const BendTuning().resolve();
  for (var i = 0; i < 9; i++) {
    final p = ((i - 1) / 15).clamp(0.0, 1.0);
    body.step(Rect.fromLTWH(0, 80 * p, 60, 30), 15, 60, 1 / 60, o);
  }
  return body;
}

/// A frozen copy of the values a body paints with.
class _Snapshot extends LiquidBody {
  _Snapshot(LiquidBody b) {
    cx = b.cx;
    cy = b.cy;
    tailX = b.tailX;
    tailY = b.tailY;
    tailR = b.tailR;
    midA = b.midA;
    midB = b.midB;
    stretch = b.stretch;
    stretchAngle = b.stretchAngle;
    bendCur = b.bendCur;
    bendCurX = b.bendCurX;
    bending = b.bending;
    paintR = b.paintR;
  }
}
