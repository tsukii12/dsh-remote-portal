// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The lean (lean.ts): a finished frame bent in screen space toward the side
// a voice comes from — it drifts a little that way, the near side is pulled
// out further than the far side, the near flank bulges. Up against the
// screen's edge it presses on it, bounces, and (the ring) is refracted into
// it through a lens the painter draws.

import 'dart:math' as math;

import 'frame.dart';

/// How strongly the ring leans, each a share of its radius at full pan.
class LeanAmounts {
  const LeanAmounts({
    required this.move,
    required this.pull,
    required this.deform,
    required this.squash,
    required this.lens,
    required this.stretch,
    required this.split,
    required this.blur,
    required this.bounce,
  });

  final double move;
  final double pull;
  final double deform;
  final double squash;
  final double lens;
  final double stretch;
  final double split;
  final double blur;
  final double bounce;
}

/// The ring barely drifts but leans, its near side drawn out and bulging a
/// touch; light meets the edge through a soft lens rather than squashing.
const LeanAmounts ringLean = LeanAmounts(
  move: 0.21,
  pull: 0.36,
  deform: 0.28,
  squash: 0,
  lens: 0.49,
  stretch: 1.04,
  split: 1.01,
  blur: 1.24,
  bounce: 0.92,
);

/// Mono leans the same way but drifts further, and meets the edge with no lens.
const LeanAmounts monoLean = LeanAmounts(
  move: 0.55,
  pull: 0.36,
  deform: 0.28,
  squash: 0,
  lens: 0,
  stretch: 0,
  split: 0,
  blur: 1.24,
  bounce: 0.92,
);

/// Logical px the lean stops short of the screen's edge.
const double leanMargin = 32;

/// How far the lean can carry a mark sideways at full pan — the room the
/// canvas needs either side so a leaning ring is never cut off.
double leanReach(LeanAmounts k, double size) {
  final share = k.move.abs() + k.pull.abs() + 2 * k.deform.abs();
  return share == 0 ? 0 : (size * 0.36 * share).ceilToDouble() + 2;
}

/// The bounce as the ring meets the edge: a spring chasing how hard it
/// presses, loose enough to overshoot. Step it once a frame with the press
/// the last frame reported.
class EdgeBounce {
  double _x = 0;
  double _v = 0;
  bool _landed = false;

  /// How far the spring runs ahead of the press (+) or behind it (−); only a
  /// rebound counts as behind.
  double step(double press, double dt) {
    const w = 15.0;
    const z = 0.3;
    final n = math.max(1, (dt * 240).ceil());
    final h = dt / n;
    for (var i = 0; i < n; i++) {
      _v += (w * w * (press - _x) - 2 * z * w * _v) * h;
      _x += _v * h;
    }
    final ahead = _x - press;
    if (press <= 0) {
      _landed = false;
    } else if (ahead >= 0) {
      _landed = true;
    }
    return ahead < 0 && !_landed ? 0 : ahead;
  }
}

/// Bend [frame] in place toward [pan] (−1 left … 1 right). [roomLeft] and
/// [roomRight] are how far past the box a mark may land; a lean that would
/// carry any mark further is scaled down until the outermost one lands short
/// of that edge, and pressing on, the ring presses on it (`contact`).
void leanFrame(
  OrbFrame frame,
  double pan,
  double size,
  LeanAmounts k, {
  double roomLeft = double.infinity,
  double roomRight = double.infinity,
  double bounce = 0,
}) {
  if (pan.abs() < 0.002 || (k.move == 0 && k.pull == 0 && k.deform == 0)) return;
  final c = size / 2;
  // the rings fill roughly this much of their box
  final r = size * 0.36;
  final side = pan < 0 ? -1.0 : 1.0;
  final amount = pan.abs();
  double shift(double x, double y) {
    final nx = (x - c) / r;
    final ny = (y - c) / r;
    final near = clamp01((nx * side + 1) / 2);
    final flank = math.max(0.0, nx * side);
    return pan * r * (k.move + k.pull * near * near + k.deform * flank * flank * math.exp(-ny * ny * 1.5));
  }

  // the lens needs room: against an edge the ring stops short by a gap, and
  // pressing on, the lens draws it out across the gap
  final lens = k.lens.clamp(0.0, 2.0);
  final zone = r * 0.9;
  final bound = side > 0 ? roomRight : roomLeft;
  final finite = bound.isFinite;
  final gap = finite ? math.min(zone * 0.45, r * 0.3 * lens * math.max(0, k.stretch)) : 0.0;

  // the share of the lean that keeps every mark inside the room
  var scale = 1.0;
  var edge = double.infinity;
  const biggest = 1.0;
  if (finite) {
    edge = side > 0 ? size + bound : -bound;
    for (final s in frame.strokes) {
      final pts = s.pts;
      for (var i = 0; i < pts.length; i += 2) {
        final dx = shift(pts[i], pts[i + 1]) * side;
        if (dx > 1e-9) scale = math.min(scale, math.max(0, ((edge - pts[i]) * side - biggest - gap) / dx));
      }
    }
  }

  // at the edge and pushing on, it presses: harder as the lean it wanted
  // outruns the room; the bounce runs the press past that and back
  final pressure = scale < 1 ? math.min(1.0, (1 - scale) / 0.35) : 0.0;
  final hit = pressure > 0 ? bounce * k.bounce : 0.0;
  final pressed = math.min(1.4, pressure + math.max(0, hit));
  final recoil = r * 0.12 * math.max(0, -hit);
  final wall = edge - side * biggest;
  final rest = wall - side * gap;
  final band = r * 0.55 * pressed * k.squash;

  (double, double) bend(double x, double y) {
    final near = clamp01((((x - c) / r) * side + 1) / 2);
    final squeeze = 1 - 0.15 * k.deform * amount * scale * near;
    var bx = x + shift(x, y) * scale + side * (band * 0.5 - recoil);
    var by = c + (y - c) * squeeze;
    if (band > 0) {
      // the depth into the soft zone, eased so nothing reaches where it rests
      final into = (bx - (rest - side * band)) * side;
      if (into > 0) {
        final q = into / band;
        final flat = band * (q / math.sqrt(1 + q * q));
        bx = rest - side * band + side * flat;
        by = c + (by - c) * (1 + 0.18 * pressed * k.squash * (flat / band));
      }
    }
    return (bx, by);
  }

  for (final s in frame.strokes) {
    final pts = s.pts;
    for (var i = 0; i < pts.length; i += 2) {
      final (x, y) = bend(pts[i], pts[i + 1]);
      pts[i] = x;
      pts[i + 1] = y;
    }
  }
  if (pressure > 0) {
    final kk = lens * pressed;
    frame.contact = OrbContact(
      side: side,
      x: wall,
      press: pressure,
      lens: kk > 0.02
          ? OrbLens(
              zone: zone,
              // drawn across the gap as it presses, all the way at full press
              gap: gap * math.min(1, pressed),
              flare: 0.22 * kk * math.max(0, k.stretch),
              split: zone * 0.1 * kk * math.max(0, k.split),
              blur: zone * 0.075 * kk * math.max(0, k.blur),
              cy: c,
            )
          : null,
    );
  }
  final light = frame.light;
  if (light != null) {
    // the spectrum's centre and the highlight travel with the rings
    final (cx, cy) = bend(light.cx, light.cy);
    final (sx, sy) = bend(light.spec.x, light.spec.y);
    light
      ..cx = cx
      ..cy = cy;
    light.spec
      ..x = sx
      ..y = sy;
  }
}
