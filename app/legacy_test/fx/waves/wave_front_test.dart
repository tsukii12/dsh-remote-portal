// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The original's WaveFrontTests, ported: the timeline, the rim's lumps and the
// dots are plain maths, the same in both.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_app/ui/fx/waves/distortion_wave_style.dart';
import 'package:dsh_app/ui/fx/waves/wave_front.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const screen = Size(402, 874);
const button = Rect.fromLTWH(20, 782, 362, 58);
const style = DistortionWaveStyle.vertical;

WaveFront front(double p, {DistortionWaveStyle s = style, Offset? focus}) =>
    WaveFront(progress: p, source: button, size: screen, style: s, focus: focus);

WaveFront at(double seconds, {DistortionWaveStyle s = style, Offset? focus}) =>
    front(seconds / s.duration, s: s, focus: focus);

double hypot(double x, double y) => math.sqrt(x * x + y * y);

/// The farthest point of the screen in the field's own metric.
double farthest(WaveFront f) => hypot(button.center.dx * f.squash, button.center.dy);

List<WaveParticle> particlesOf(DistortionWaveStyle s) => [for (var i = 0; i < s.particleCount; i++) WaveParticle(i, s)];

double distanceToButton(Offset p) {
  final dx = math.max(math.max(button.left - p.dx, 0.0), p.dx - button.right);
  final dy = math.max(math.max(button.top - p.dy, 0.0), p.dy - button.bottom);
  return hypot(dx, dy);
}

void main() {
  test('launches clear of the source outline', () {
    final f = at(style.anticipation);
    expect(f.radius, closeTo(29 + style.launchGap, 0.01));
    expect(f.spine, closeTo(181 - 29, 0.01));
    expect(f.squash, closeTo(1, 0.001));
    expect(f.energy, closeTo(0, 0.001));
  });

  test('gravity pulls only around the launch', () {
    expect(front(0).gravity, closeTo(0, 0.001));
    expect(at(style.anticipation).gravity, closeTo(style.pull, 0.01));
    expect(at(style.anticipation + 0.25).gravity, closeTo(0, 0.001));
  });

  test('ring of colour falls in before the launch', () {
    var last = double.infinity;
    for (var i = 0; i <= 40; i++) {
      final f = at(style.anticipation * i / 40);
      expect(f.radius, lessThanOrEqualTo(last));
      last = f.radius;
    }
    expect(front(0).radius, closeTo(29 + style.launchGap + style.inhale, 0.01));
  });

  test('front only ever moves outward after the launch', () {
    var lastTop = -double.infinity;
    var lastSide = -double.infinity;
    for (var i = 0; i <= 400; i++) {
      final f = at(style.anticipation + (style.duration - style.anticipation) * i / 400);
      final side = (f.spine + f.radius) / f.squash;
      expect(f.radius, greaterThanOrEqualTo(lastTop));
      expect(side, greaterThanOrEqualTo(lastSide - 0.001));
      lastTop = f.radius;
      lastSide = side;
    }
  });

  test('rim lumps average out, thin and thick', () {
    const r = 62.0;
    const ex = 201 - r;
    const ey = 437 - r;
    const perimeter = 4 * (ex + ey + 0.5 * math.pi * r);
    final lumps = Float64List(WaveRim.count * 3);
    final all = <double>[];
    for (var t = 0.0; t <= 2.0; t += 0.25) {
      WaveRim.lumps(lumps, time: t, size: screen, cornerRadius: r);
      for (var k = 0; k < 500; k++) {
        final s = perimeter * k / 500;
        var thickness = 0.08;
        for (var i = 0; i < lumps.length; i += 3) {
          var ds = s - lumps[i];
          ds -= perimeter * (ds / perimeter).roundToDouble();
          thickness += lumps[i + 2] * math.exp(-math.pow(ds / lumps[i + 1], 2));
        }
        all.add(thickness / 1.0498);
      }
    }
    final mean = all.reduce((a, b) => a + b) / all.length;
    expect(mean, closeTo(1, 0.03));
    expect(all.reduce(math.min), lessThan(0.2));
    expect(all.reduce(math.max), greaterThan(2.5));
  });

  test('leans with the touch', () {
    final finger = Offset(button.right - 30, button.center.dy);
    final launch = at(style.anticipation, focus: finger);
    expect(launch.origin.dx, closeTo(button.center.dx, 0.001));
    expect(launch.tilt, closeTo(0, 0.0001));
    final open = at(style.anticipation + 0.3 * style.travel, focus: finger);
    expect(open.origin.dx, greaterThan(button.center.dx + 40));
    expect(open.tilt, greaterThan(0.1));

    // The front is further up the screen on the touched side.
    double frontHeight(double x, WaveFront f) {
      var y = f.origin.dy;
      while (y > 0) {
        final dx = x - f.origin.dx;
        final dy = y - f.origin.dy;
        final qx = math.cos(f.tilt) * dx + math.sin(f.tilt) * dy;
        final qy = -math.sin(f.tilt) * dx + math.cos(f.tilt) * dy;
        if (hypot(math.max((qx * f.squash).abs() - f.spine, 0), qy) >= f.radius) break;
        y -= 1;
      }
      return f.origin.dy - y;
    }

    final crossing = at(style.anticipation + 0.08 * style.travel, focus: finger);
    expect(frontHeight(40, crossing), lessThan(700));
    expect(frontHeight(360, crossing), greaterThan(frontHeight(40, crossing) + 30));

    final even = style.copyWith(orientation: 0);
    final level = at(style.anticipation + 0.3 * style.travel, s: even, focus: finger);
    expect(level.origin.dx, closeTo(button.center.dx, 0.001));
    expect(level.tilt, closeTo(0, 0.0001));
  });

  test('edges wipe on ease-in-out', () {
    final wiped = style.copyWith(linger: 0.3);
    double clear(double seconds) => at(seconds, s: wiped).clearRadius;
    final begin = wiped.anticipation + wiped.linger;
    final start = clear(begin);
    final end = clear(begin + wiped.rimFade);
    double share(double part) => (clear(begin + part * wiped.rimFade) - start) / (end - start);
    expect(share(0.5), closeTo(0.5, 0.001));
    expect(share(0.1), lessThan(0.05));
    expect(share(0.9), greaterThan(0.95));
    expect(begin + wiped.rimFade, lessThanOrEqualTo(wiped.duration + 0.001));
    expect(style.anticipation + style.linger + style.rimFade, lessThanOrEqualTo(style.duration + 0.001));
  });

  test('easing matches CSS', () {
    const easing = DistortionWaveEasing(0.22, 1, 0.36, 1);
    expect(easing(0), 0);
    expect(easing(1), 1);
    // The curve's parameter at 1/2 gives x = 0.3425, y = 0.875 by hand.
    expect(easing(0.3425), closeTo(0.875, 0.0001));
    expect(easing.transform(0.3425), closeTo(0.875, 0.0001));
  });

  test('front moves on the easing', () {
    final long = style.copyWith(linger: 2, rimFade: 2);
    double radius(double seconds) => at(seconds, s: long).radius;
    final start = radius(long.anticipation);
    final end = radius(long.anticipation + long.travel);
    final mid = radius(long.anticipation + 0.3425 * long.travel);
    expect((mid - start) / (end - start), closeTo(0.875, 0.0001));
  });

  test('swell, blur and colour die as the front settles', () {
    final f = at(style.anticipation + 0.55 * style.travel);
    expect(f.hasCleared, isTrue);
    expect(f.energy, closeTo(0, 0.001));
    expect(f.glow, closeTo(0, 0.001));
  });

  test('particles hop toward the button', () {
    for (final particle in particlesOf(style)) {
      ({double count, double distance})? hopStart;
      for (var i = 0; i < 200; i++) {
        final f = at(style.anticipation * i / 200);
        final distance = distanceToButton(particle.point(f, button));
        expect(distance, greaterThanOrEqualTo(style.particleGap - 0.5));
        expect(distance, lessThanOrEqualTo(style.particleReach + 30));
        final count = particle.hopAt(f.time).count;
        final start = hopStart;
        if (start != null && start.count == count) {
          expect(distance, lessThanOrEqualTo(start.distance + 0.001));
          expect(start.distance - distance, lessThanOrEqualTo(style.particleFlight + 0.5));
        } else {
          hopStart = (count: count, distance: distance);
        }
      }
    }
  });

  test('no two particles equally bright', () {
    final particles = particlesOf(style);
    final levels = {for (final p in particles) (p.brightness * 20).round()};
    expect(levels.length, greaterThan(10));
    expect(particles.map((p) => p.brightness).reduce(math.min), greaterThanOrEqualTo(0.3));
  });

  test('particles ride out with the front', () {
    final particles = particlesOf(style);
    for (final particle in particles) {
      var lastY = double.infinity;
      for (var i = 1; i <= 200; i++) {
        final y = particle.point(at(style.anticipation + style.travel * i / 200), button).dy;
        expect(y, lessThanOrEqualTo(lastY + 0.001));
        lastY = y;
      }
    }
    final quick = particles.where((p) => p.pace > 0.95).toList()
      ..sort((a, b) => a.column.abs().compareTo(b.column.abs()));
    for (final seconds in [0.05, 0.1, 0.2]) {
      final f = at(style.anticipation + seconds);
      final height = f.origin.dy - quick.first.point(f, button).dy;
      expect(height, closeTo(f.radius, style.lead));
    }
  });

  test('particles spread out behind the front', () {
    final f = at(style.anticipation + 0.5);
    final heights = [for (final p in particlesOf(style)) p.point(f, button).dy];
    expect(heights.reduce(math.max) - heights.reduce(math.min), greaterThan(400));
  });

  test('particles burn out one by one', () {
    final particles = particlesOf(style);
    expect(particles.every((p) => p.opacity(front(0)) == 0), isTrue);
    final launch = at(style.anticipation + 0.05);
    expect(particles.every((p) => p.opacity(launch) > 0), isTrue);
    final midway = [for (final p in particles) p.opacity(at(style.anticipation + 0.5 * style.particleLife))];
    expect(midway.any((o) => o == 0), isTrue);
    expect(midway.any((o) => o > 0), isTrue);
    final burnt = at(style.anticipation + style.particleLife);
    expect(style.anticipation + style.particleLife, lessThanOrEqualTo(style.duration + 0.001));
    expect(particles.every((p) => p.opacity(burnt) == 0), isTrue);
  });

  test('colour stays on the edges after the front has left', () {
    final held = style.copyWith(linger: 0.9, rimFade: 2.05);
    final f = at(held.anticipation + 0.6 * held.travel, s: held);
    expect(f.glow, closeTo(0, 0.001));
    expect(f.energy, closeTo(0, 0.001));
    expect(f.rim, closeTo(held.rimStrength, 0.001));
    expect(f.clearRadius, lessThan(farthest(f)));
  });

  test('everything has left the screen by the end', () {
    final f = front(1);
    expect(f.hasCleared, isTrue);
    expect(f.clearRadius - style.rimSoftness - style.swell, greaterThan(farthest(f)));
    expect(f.hairClearRadius - style.rimSoftness - style.swell + 0.001, greaterThanOrEqualTo(farthest(f)));
    expect(f.energy, closeTo(0, 0.001));
    expect(f.glow, closeTo(0, 0.001));
    expect(f.rim, closeTo(0, 0.001));
    expect(f.gravity, closeTo(0, 0.001));
  });

  test('hairline outlasts the colour', () {
    final s = style.copyWith(rimFade: 2.51, hairlineLinger: 0.25, hairlineFade: 3.0);
    for (var i = 0; i <= 200; i++) {
      final f = at(s.duration * i / 200, s: s);
      expect(f.hairClearRadius, lessThanOrEqualTo(f.clearRadius + 0.001));
    }
    final f = at(s.anticipation + s.linger + s.rimFade, s: s);
    expect(f.clearRadius - f.hairClearRadius, greaterThan(100));
    expect(f.hairClearRadius - s.rimSoftness, lessThan(farthest(f)));
    expect(s.duration, greaterThanOrEqualTo(s.anticipation + s.linger + s.hairlineLinger + s.hairlineFade));
  });

  test('clears only once the front has crossed the screen', () {
    expect(at(style.anticipation + 0.2).hasCleared, isFalse);
    expect(at(style.anticipation + style.travel).hasCleared, isTrue);
    for (var i = 0; i <= 400; i++) {
      final f = front(i / 400);
      if (f.hasCleared) expect(f.radius, greaterThan(farthest(f) + WaveFront.coverZone));
    }
  });

  group('ring', () {
    const sheet = Size(386, 509);
    const avatar = Rect.fromLTWH(161, 54, 64, 64);
    const center = DistortionWaveStyle.center;
    WaveFront ring(double seconds, {Offset? focus, DistortionWaveStyle s = center}) =>
        WaveFront(progress: seconds / s.duration, source: avatar, size: sheet, style: s, focus: focus);

    test('spreads evenly from the centre', () {
      for (var t = 0.0; t <= center.duration; t += 0.1) {
        final f = ring(t, focus: Offset(avatar.right, avatar.center.dy));
        expect(f.spine, closeTo(0, 0.001));
        expect(f.squash, closeTo(1, 0.001));
        expect(f.tilt, closeTo(0, 0.001));
        expect(f.origin.dx, closeTo(avatar.center.dx, 0.001));
        expect(f.origin.dy, closeTo(avatar.center.dy, 0.001));
        expect(f.ring, isTrue);
        // The token itself is held out of the wave.
        expect(f.hold, closeTo(32, 0.001));
      }
      expect(ring(center.anticipation).radius, closeTo(32, 0.01));
    });

    test('crosses the whole sheet', () {
      final end = ring(center.duration);
      final corner = hypot(sheet.width - avatar.center.dx, sheet.height - avatar.center.dy);
      expect(end.radius, greaterThan(corner + WaveFront.coverZone));
      expect(end.clearRadius - center.rimSoftness - center.swell + 0.001, greaterThanOrEqualTo(corner));
      expect(ring(center.anticipation + center.travel).hasCleared, isTrue);
    });

    test('gathers nothing before the launch', () {
      final particles = particlesOf(center);
      for (var t = 0.0; t <= center.anticipation; t += 0.01) {
        final f = ring(t);
        expect(f.glow, closeTo(0, 0.0001));
        for (final p in particles) {
          expect(p.opacity(f), closeTo(0, 0.0001));
        }
      }
      expect(ring(center.anticipation + 0.01).glow, closeTo(0, 0.05));
      expect(ring(center.anticipation + 0.3).glow, greaterThan(0.5));
      expect(ring(center.anticipation).gravity, greaterThan(0));
    });

    test('dots come in and go out all round', () {
      final s = center.copyWith(gatherDots: 1);
      final centre = avatar.center;
      final sides = <int>{};
      for (var i = 0; i < s.particleCount; i++) {
        final dot = WaveParticle(i, s);
        final a = ring(0.1, s: s);
        final b = ring(0.1 + dot.hop * 0.2, s: s);
        if (dot.hopAt(a.time).count == dot.hopAt(b.time).count) {
          expect((dot.point(b, avatar) - centre).distance, lessThan((dot.point(a, avatar) - centre).distance + 0.001));
        }
        final out = dot.point(ring(s.anticipation + 0.4, s: s), avatar) - centre;
        expect(out.distance, greaterThan(32));
        sides.add(((math.atan2(out.dy, out.dx) + math.pi) / (math.pi / 2)).floor() % 4);
      }
      expect(sides.length, 4);
    });
  });

  group('horizontal', () {
    const edge = Rect.fromLTWH(0, 300, 24, 274);
    const sideways = DistortionWaveStyle.horizontal;
    WaveFront side(double seconds, {Offset? focus}) =>
        WaveFront(progress: seconds / sideways.duration, source: edge, size: screen, style: sideways, focus: focus);

    /// How far inside the front a point is: above 0 the front has passed it.
    double passed(Offset p, WaveFront f) {
      final dx = p.dx - f.origin.dx;
      final dy = p.dy - f.origin.dy;
      final qx = math.cos(f.tilt) * dx + math.sin(f.tilt) * dy;
      final qy = -math.sin(f.tilt) * dx + math.cos(f.tilt) * dy;
      return f.radius - hypot(math.max((qx * f.squash).abs() - f.spine, 0), qy);
    }

    test('travels left to right', () {
      final launch = side(sideways.anticipation);
      expect(launch.tilt, closeTo(math.pi / 2, 0.0001));
      expect(launch.spine + launch.radius, closeTo(137, 0.01));
      expect(launch.radius, closeTo(12, 0.01));
      final f = side(sideways.anticipation + 0.1 * sideways.travel);
      final right = Offset(edge.right + 250, edge.center.dy);
      final up = Offset(edge.center.dx, edge.top - 250);
      expect(passed(right, f), greaterThan(0));
      expect(passed(right, f), greaterThan(passed(up, f) + 60));
      expect(side(sideways.anticipation + sideways.travel).hasCleared, isTrue);
    });

    test('leans with the touch', () {
      final finger = Offset(edge.center.dx, edge.bottom - 20);
      final open = side(sideways.anticipation + 0.3 * sideways.travel, focus: finger);
      expect(open.origin.dy, greaterThan(edge.center.dy + 40));
      expect(open.origin.dx, closeTo(edge.center.dx, 0.001));
      expect(open.tilt, greaterThan(math.pi / 2 + 0.1));
    });

    test('dots come from the right', () {
      final before = side(sideways.anticipation * 0.6);
      final after = side(sideways.anticipation + 0.5);
      for (var i = 0; i < sideways.particleCount; i++) {
        final dot = WaveParticle(i, sideways);
        expect(dot.point(before, edge).dx, greaterThan(edge.right));
        expect(dot.point(after, edge).dx, greaterThan(edge.center.dx));
      }
    });
  });

  group('style', () {
    test('duration covers the slowest part', () {
      // 0.5 + max(1.368, 2.68, 3.12, 2.19)
      expect(style.duration, closeTo(3.62, 1e-9));
      expect(DistortionWaveStyle.center.duration, closeTo(0.25 + 3.93, 1e-9));
    });

    test('the theme palette is soft and near the primary hue', () {
      for (final brightness in Brightness.values) {
        final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4B67B4), brightness: brightness);
        final palette = DistortionWavePalette.fromScheme(scheme);
        final hue = HSLColor.fromColor(scheme.primary).hue;
        for (final color in [...palette.colors, palette.ahead, palette.behind]) {
          final hsl = HSLColor.fromColor(color);
          expect(hsl.saturation, lessThanOrEqualTo(0.56));
          final off = ((hsl.hue - hue + 540) % 360) - 180;
          expect(off.abs(), lessThanOrEqualTo(34));
        }
      }
      expect(style.palette, isNull);
      expect(style.copyWith(palette: DistortionWavePalette.colorful).palette, DistortionWavePalette.colorful);
    });

    test('oklab of white and black', () {
      final white = waveOklab(const Color(0xFFFFFFFF));
      expect(white[0], closeTo(1, 1e-3));
      expect(white[1].abs() + white[2].abs(), lessThan(1e-3));
      expect(waveOklab(const Color(0xFF000000))[0], closeTo(0, 1e-6));
    });
  });
}
