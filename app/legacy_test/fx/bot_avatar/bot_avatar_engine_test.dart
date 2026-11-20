// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_color.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_engine.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_form.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_fur.dart';
import 'package:dsh_app/ui/fx/bot_avatar/bot_avatar_outline.dart';
import 'package:flutter_test/flutter_test.dart';

/* advance a sim by `seconds` in 60 fps steps */
void run(BotAvatarSim sim, double seconds, [void Function()? each]) {
  for (var i = 0; i < (seconds * 60).round(); i++) {
    sim.update(1 / 60);
    each?.call();
  }
}

void main() {
  group('rig', () {
    test('mulberry32 matches the author\'s JS sequence', () {
      final r = mulberry32((0.5 * 1e6).floor() + 1);
      for (final want in [0.500372989336, 0.157671587542, 0.696338303853, 0.1986010822]) {
        expect(r(), closeTo(want, 1e-12));
      }
    });

    test('the same seed moves the same way', () {
      final a = BotAvatarSim(0.42), b = BotAvatarSim(0.42);
      run(a, 5);
      run(b, 5);
      expect(a.pose.yaw, b.pose.yaw);
      expect(a.pose.lookX, b.pose.lookX);
    });

    test('rest poses carry the author\'s targets', () {
      final sleep = BotAvatarPose.rest(BotAvatarState.sleeping);
      expect(sleep.pitch, closeTo(-16 * math.pi / 180, 1e-9));
      expect(sleep.roll, closeTo(6 * math.pi / 180, 1e-9));
      expect(sleep.y, 3);
      expect(sleep.w, [0, 0, 1]);
      expect(BotAvatarPose.rest(BotAvatarState.working).pitch, closeTo(5 * math.pi / 180, 1e-9));
      expect(BotAvatarPose.rest(BotAvatarState.idle).w, [1, 0, 0]);
    });

    test('a switch eases the weights on a sine over the state\'s time', () {
      final sim = BotAvatarSim(0.3);
      sim.setState(BotAvatarState.working);
      run(sim, 0.35);
      /* 0.7 s to working: halfway at 0.35 s */
      expect(sim.pose.w[1], closeTo(0.5, 0.03));
      run(sim, 0.4);
      expect(sim.pose.w[1], 1);
      expect(sim.pose.w[0] + sim.pose.w[1] + sim.pose.w[2], closeTo(1, 1e-9));
      sim.setState(BotAvatarState.sleeping);
      run(sim, 1.0);
      expect(sim.pose.w[2], lessThan(1));
      run(sim, 0.45);
      expect(sim.pose.w[2], 1);
    });

    test('working hops, and every third hop spins round', () {
      final sim = BotAvatarSim(0.6, BotAvatarState.working);
      var minY = 0.0, maxYaw = 0.0;
      run(sim, 3 * 0.68 + 0.05, () {
        minY = math.min(minY, sim.pose.y);
        maxYaw = math.max(maxYaw, sim.pose.yaw);
      });
      expect(minY, lessThan(-15));
      expect(maxYaw, greaterThan(math.pi * 1.5));
    });

    test('a poke jumps and turns right round, then lands', () {
      final sim = BotAvatarSim(0.1);
      run(sim, 0.5);
      final yaw0 = sim.pose.yaw;
      sim.poke();
      expect(sim.jumping, isTrue);
      var top = 0.0;
      run(sim, 1.6, () => top = math.min(top, sim.pose.y));
      expect(top, lessThan(-20));
      expect(sim.jumping, isFalse);
      /* a whole turn: back where it was, give or take the idle wander */
      expect(((sim.pose.yaw - yaw0) % (2 * math.pi)).abs(), anyOf(lessThan(0.6), greaterThan(2 * math.pi - 0.6)));
    });

    test('sleeping blinks never, idle blinks within a few seconds', () {
      final idle = BotAvatarSim(0.2);
      var blinked = false;
      run(idle, 5, () => blinked |= idle.pose.blinkL > 0.5);
      expect(blinked, isTrue);
      final sleep = BotAvatarSim(0.2, BotAvatarState.sleeping);
      blinked = false;
      run(sleep, 6, () => blinked |= sleep.pose.blinkL > 0.01);
      expect(blinked, isFalse);
    });
  });

  group('look', () {
    test('ids map stably to a type, a seed and a tone', () {
      expect(BotAvatar.typeFor('agent-1'), BotAvatarType.values[3]);
      expect(BotAvatar.toneFor('agent-1'), 0);
      expect(BotAvatar.toneFor('agent-6'), 4);
      expect(BotAvatar.seedFor('agent-1'), 0.584);
      expect(BotAvatar.typeFor('agent-1'), BotAvatar.typeFor('agent-1'));
      expect(BotAvatar.toneFor('x'), inInclusiveRange(0, 4));
    });

    test('shade and ink follow the author\'s colour maths', () {
      final s = shade(const Color(0xFF41C4FF), -0.2, 0.05);
      expect([s.h, s.s, s.l], [198.6, 100, 42.7]);
      expect(autoInk(const Color(0xFF111111)), lightInk);
      expect(autoInk(const Color(0xFF41C4FF)), darkInk);
      /* past saturation 1.5 the colour deepens toward its most vivid shade */
      final star = BotAvatarType.star.preset;
      final rich = bodyColor(star.color, brightness: star.brightness!, saturation: star.saturation!);
      expect(rich, isNot(star.color));
    });

    test('every stock outline parses into closed polygons in the body box', () {
      for (final t in BotAvatarType.values) {
        final polys = BotAvatarOutline.parse(botAvatarShapes[t]!).polygons();
        expect(polys, isNotEmpty, reason: t.name);
        for (final p in polys) {
          for (var i = 0; i < p.length; i++) {
            expect(p[i], inInclusiveRange(-0.5, 100.5), reason: t.name);
          }
        }
      }
      expect(BotAvatarOutline.parts(botAvatarParts[BotAvatarType.mech]!), hasLength(4));
      /* the circle's area, by the shoelace formula */
      final c = BotAvatarOutline.parse(botAvatarShapes[BotAvatarType.circle]!).polygons().single;
      var area = 0.0;
      for (var i = 0; i < c.length ~/ 2; i++) {
        final j = (i + 1) % (c.length ~/ 2);
        area += c[2 * i] * c[2 * j + 1] - c[2 * j] * c[2 * i + 1];
      }
      expect(area.abs() / 2, closeTo(math.pi * 42 * 42, 15));
    });
  });

  group('material', () {
    final circle = BotAvatarOutline.parse(botAvatarShapes[BotAvatarType.circle]!).polygons();

    test('the raster covers the outline with antialiased edges', () {
      final cov = rasterizeOutline(circle, 64);
      expect(cov[32 * 64 + 32], 255);
      expect(cov[0], 0);
      expect(cov.where((v) => v > 0 && v < 255), isNotEmpty);
    });

    test('the form is a pillow: thickest in the middle, a signed distance', () {
      final form = buildForm(rasterizeOutline(circle, 64), 64, 9.75);
      final u = span / 64;
      int at(double x, double y) => ((y + pad) / u).floor() * 64 + ((x + pad) / u).floor();
      /* 22 units in from the edge (the medial axis itself is rounded by the blur) */
      expect(form.sd[at(50, 30)], closeTo(22, 1.5));
      expect(form.sd[at(50, 6)], lessThan(0));
      expect(form.h[at(50, 50)], form.top);
      expect(form.h[at(50, 50)], greaterThan(form.h[at(80, 50)]));
      expect(form.ao[at(50, 50)], greaterThan(0));
      final rel = reliefFor(form, 14, 1);
      expect(rel.scale.first, 1);
      for (var k = 1; k < 14; k++) {
        expect(rel.scale[k], lessThanOrEqualTo(rel.scale[k - 1]));
      }
    });

    test('the pile bakes its planes and hairs', () {
      final form = buildForm(rasterizeOutline(circle, 64), 64, 9.75);
      final bake = bakeFur(
        FurJob(
          n: form.n,
          sd: form.sd,
          h: form.h,
          r: 192,
          lx: math.sin(295 * math.pi / 180),
          ly: -math.cos(295 * math.pi / 180),
          style: const FurStyle(),
          lights: FurLights.stock(math.sin(295 * math.pi / 180), -math.cos(295 * math.pi / 180)),
        ),
      );
      expect(bake.rb, ((192 * filmSpan) / span + 0.5).floor());
      expect(bake.mask[96 * 192 + 96], 255);
      expect(bake.mask[0], 0);
      expect(bake.haze.any((v) => v > 0), isTrue);
      expect(bake.dark.any((v) => v > 0) && bake.light.any((v) => v > 0), isTrue);
      expect(bake.strokes.map((s) => s.layer).toSet(), containsAll([FurLayer.dark, FurLayer.light, FurLayer.mask]));
      expect(bake.strokes.every((s) => s.cmds.isNotEmpty), isTrue);
    });
  });
}
