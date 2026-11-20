// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/orbs/orb_core.dart';
import 'package:dsh_app/ui/fx/orbs/orb_modes.dart';
import 'package:dsh_app/ui/fx/orbs/orb_presets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'orb_golden.dart';

void main() {
  test('every state x size resolves to the author\'s preset', () {
    expect(goldenResolved, hasLength(OrbState.values.length * OrbSize.values.length));
    for (final state in OrbState.values) {
      for (final size in OrbSize.values) {
        final key = '${state.name}-${size.px.toInt()}';
        final (speed, opts) = goldenResolved[key]!;
        final p = resolvePreset(state, size);
        expect(p.speed, speed, reason: key);
        expect(p.opts.keys.toSet(), opts.keys.toSet(), reason: key);
        for (final MapEntry(:key, :value) in opts.entries) {
          expect(p.opts[key], closeTo(value, 1e-9), reason: '${state.name}-${size.px} $key');
        }
      }
    }
  });

  // The web engine's own output (spec/orbs-golden.json) at four frozen
  // instants per case: counts, order-free field sums, and the farthest and
  // nearest dot. A mistyped constant or a sign error lands far outside 1e-4
  // per dot.
  test('geometry matches the web engine at the golden instants', () {
    final frame = OrbFrame();
    for (final c in goldenCases) {
      final state = OrbState.values.byName(c.state);
      final size = OrbSize.values.firstWhere((s) => s.px == c.size);
      final p = resolvePreset(state, size);
      modeFrames[p.mode]!(frame, size.px, c.t, p.opts);
      final key = '${c.state}-${c.size}@${c.t}';
      expect(frame.dotCount, c.dots, reason: '$key dots');
      expect(frame.lineCount, c.lines, reason: '$key lines');

      if (state == OrbState.solving && size == OrbSize.px20) {
        // sin(pi/4) is 0.7071067811865475 in V8, glibc and bionic but one ulp
        // higher in the Windows CRT, and this lattice sits exactly on the band
        // boundaries: a dot or three may turn with a neighbouring band. The
        // original engine fed the CRT's value gives this port's frame exactly.
        expect(_unmatched(frame, goldenSolving20['${c.t}']!), lessThanOrEqualTo(3), reason: key);
        continue;
      }

      final sums = List<double>.filled(8, 0);
      for (var k = 0; k < frame.dotCount; k++) {
        final x = frame.x(k), y = frame.y(k), r = frame.r(k), w = frame.white(k);
        sums[0] += x;
        sums[1] += y;
        sums[2] += frame.z(k);
        sums[3] += r;
        sums[4] += w;
        sums[5] += frame.a(k);
        sums[6] += x * r;
        sums[7] += y * w;
        if (k > 0) expect(frame.z(k), greaterThanOrEqualTo(frame.z(k - 1)), reason: '$key z order');
      }
      final tol = 1e-4 * (c.dots + 1);
      for (var i = 0; i < 8; i++) {
        expect(sums[i], closeTo(c.dotSums[i], tol), reason: '$key dot sum $i');
      }

      final lineSums = List<double>.filled(7, 0);
      for (var k = 0; k < frame.lineCount; k++) {
        lineSums[0] += frame.lineX1(k);
        lineSums[1] += frame.lineY1(k);
        lineSums[2] += frame.lineX2(k);
        lineSums[3] += frame.lineY2(k);
        lineSums[4] += frame.lineWhite(k);
        lineSums[5] += frame.lineA(k);
        lineSums[6] += frame.lineW(k);
      }
      for (var i = 0; i < 7; i++) {
        expect(lineSums[i], closeTo(c.lineSums[i], 1e-4 * (c.lines + 1)), reason: '$key line sum $i');
      }

      List<double> dotAt(int k) => [frame.x(k), frame.y(k), frame.z(k), frame.r(k), frame.white(k), frame.a(k)];
      final first = dotAt(0);
      final last = dotAt(frame.dotCount - 1);
      for (var i = 0; i < 6; i++) {
        expect(first[i], closeTo(c.first[i], 1e-4), reason: '$key first[$i]');
        expect(last[i], closeTo(c.last[i], 1e-4), reason: '$key last[$i]');
      }
    }
  });

  test('a reused frame gives the same geometry as a fresh one', () {
    final reused = OrbFrame();
    final p = resolvePreset(OrbState.connecting, OrbSize.px64);
    // dirty it with a larger mode first
    final big = resolvePreset(OrbState.composing, OrbSize.px64);
    modeFrames[big.mode]!(reused, 64, 2.2, big.opts);
    modeFrames[p.mode]!(reused, 64, 1.3, p.opts);
    final fresh = OrbFrame();
    modeFrames[p.mode]!(fresh, 64, 1.3, p.opts);
    expect(reused.dotCount, fresh.dotCount);
    expect(reused.lineCount, fresh.lineCount);
    for (var k = 0; k < fresh.dotCount; k++) {
      expect(reused.x(k), fresh.x(k));
      expect(reused.r(k), fresh.r(k));
    }
  });

  test('solving scrambles, then clicks back to solved and rests', () {
    final p = resolvePreset(OrbState.solving, OrbSize.px64);
    final unmoved = {...p.opts, 'moveCount': 0.0};
    final frame = OrbFrame();
    final still = OrbFrame();

    // Dots of the band being turned ink 0.14 darker than their depth says.
    int turningDots() {
      var n = 0;
      for (var k = 0; k < frame.dotCount; k++) {
        if (frame.white(k) < 0.62 - 0.54 * (frame.z(k) + 1) / 2 - 0.1) n++;
      }
      return n;
    }

    // cycle = 2 x 14 x 0.42 + 1.2 = 12.96 s; the last 1.2 s are the rest
    modeFrames[p.mode]!(frame, 64, 3.0, p.opts);
    expect(turningDots(), greaterThan(0));

    modeFrames[p.mode]!(frame, 64, 12.5, p.opts);
    modeFrames[p.mode]!(still, 64, 12.5, unmoved);
    expect(turningDots(), 0);
    expect(frame.dotCount, still.dotCount);
    for (var k = 0; k < frame.dotCount; k++) {
      expect(frame.x(k), closeTo(still.x(k), 1e-9));
      expect(frame.y(k), closeTo(still.y(k), 1e-9));
    }
  });
}

/// Golden dots (stride 6) with no dot of [frame] within 1e-4 in every field.
int _unmatched(OrbFrame frame, List<double> golden) {
  final used = List<bool>.filled(frame.dotCount, false);
  var missing = 0;
  for (var i = 0; i < golden.length; i += 6) {
    final k = List.generate(frame.dotCount, (k) => k).indexWhere((k) {
      if (used[k]) return false;
      final d = [frame.x(k), frame.y(k), frame.z(k), frame.r(k), frame.white(k), frame.a(k)];
      for (var j = 0; j < 6; j++) {
        if ((d[j] - golden[i + j]).abs() > 1e-4) return false;
      }
      return true;
    });
    if (k < 0) {
      missing++;
    } else {
      used[k] = true;
    }
  }
  return missing;
}
