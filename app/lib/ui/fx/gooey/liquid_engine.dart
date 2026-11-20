// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// How a [LiquidItem]'s surface behaves (LiquidItem.tsx `LiquidEffect`).
enum LiquidEffect {
  /// Pieces merge and split like goo; `x` / `y` / `scale` animate the piece and
  /// its liquid together.
  morph,

  /// The surface trails a moving piece as liquid rubber: it lags on a spring,
  /// stretches with speed and strings a droplet tail.
  move,

  /// The surface stays glued to a dragged piece and its body bows with velocity.
  bend,
}

/// Raw move-engine springs (observer.ts `MoveOptions`); unset fields keep
/// [defaults] or the value they are merged over.
@immutable
class LiquidMoveOptions {
  const LiquidMoveOptions({this.stiffness, this.damping, this.stretch, this.tail, this.force, this.bend, this.bendX});

  /// `MOVE_DEFAULTS`. Both bows are opt-in: as defaults they turned round
  /// thumbs egg-shaped mid-drag.
  static const defaults = LiquidMoveOptions(
    stiffness: 380,
    damping: 18,
    stretch: 0.18,
    tail: 0.46,
    force: 0.5,
    bend: 0,
    bendX: 0,
  );

  /// Spring pulling the surface after the piece.
  final double? stiffness;
  final double? damping;

  /// Max axial stretch at speed; 0 is rigid.
  final double? stretch;

  /// Trailing droplet size as a fraction of the trailing side; 0 disables it.
  final double? tail;

  /// How far the tail reaches past the trailing edge, 0..1.
  final double? force;

  /// Vertical bow of the top and bottom edges, 0..1.
  final double? bend;

  /// Horizontal cap deformation, 0..1.
  final double? bendX;

  /// [top]'s set fields over this.
  LiquidMoveOptions merge(LiquidMoveOptions? top) => top == null
      ? this
      : LiquidMoveOptions(
          stiffness: top.stiffness ?? stiffness,
          damping: top.damping ?? damping,
          stretch: top.stretch ?? stretch,
          tail: top.tail ?? tail,
          force: top.force ?? force,
          bend: top.bend ?? bend,
          bendX: top.bendX ?? bendX,
        );

  @override
  bool operator ==(Object other) =>
      other is LiquidMoveOptions &&
      other.stiffness == stiffness &&
      other.damping == damping &&
      other.stretch == stretch &&
      other.tail == tail &&
      other.force == force &&
      other.bend == bend &&
      other.bendX == bendX;

  @override
  int get hashCode => Object.hash(stiffness, damping, stretch, tail, force, bend, bendX);
}

/// Damping ratio from a 0..1 bounciness knob: 0.5 lands on the tuned defaults,
/// 0 is critically damped, 1 very springy.
double _zeta(double bounce) => math.max(0.12, 1 - 1.1 * bounce.clamp(0.0, 1.0));

/// Tuning for [LiquidEffect.move]; every knob is 0..1 and the defaults are the
/// library's tuned look (`MoveTuning`).
@immutable
class MoveTuning {
  const MoveTuning({this.springiness = 0.5, this.wobble = 0.5, this.stretch = 0.36, this.trail = 0.575, this.advanced});

  /// How tightly the liquid chases the piece: 0 heavy syrup, 1 near-instant.
  final double springiness;

  /// Overshoot and wobble on arrival.
  final double wobble;

  /// Velocity stretch of the drop; 0 is rigid.
  final double stretch;

  /// Trailing droplet size; 0 disables the tail.
  final double trail;

  /// Raw springs merged over the mapped values.
  final LiquidMoveOptions? advanced;

  /// `mapMove`: an exponential stiffness curve centred on the default
  /// (0 → ~120, 0.5 → 380, 1 → ~1200), damping rescaled with √stiffness and the
  /// wobble's damping ratio, so the default knobs reproduce [LiquidMoveOptions.defaults].
  LiquidMoveOptions resolve() {
    const base = LiquidMoveOptions.defaults;
    final p = springiness.clamp(0.0, 1.0);
    final stiffness = base.stiffness! * math.pow(10, p - 0.5);
    final damping = base.damping! * math.sqrt(stiffness / base.stiffness!) * (_zeta(wobble) / _zeta(0.5));
    return base.merge(
      LiquidMoveOptions(
        stiffness: stiffness,
        damping: damping,
        stretch: 0.5 * stretch.clamp(0.0, 1.0),
        tail: 0.8 * trail.clamp(0.0, 1.0),
      ).merge(advanced),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MoveTuning &&
      other.springiness == springiness &&
      other.wobble == wobble &&
      other.stretch == stretch &&
      other.trail == trail &&
      other.advanced == advanced;

  @override
  int get hashCode => Object.hash(springiness, wobble, stretch, trail, advanced);
}

/// Tuning for [LiquidEffect.bend] (`BendTuning`): the surface tracks the piece
/// 1:1 and all the liquid character comes from the bows.
@immutable
class BendTuning {
  const BendTuning({this.vertical = 0.6, this.horizontal = 0.35, this.advanced});

  /// Vertical drag arcs the top and bottom edges: the middle leads, the ends lag.
  final double vertical;

  /// Horizontal drag reshapes the round caps: the leading one blunts, the
  /// trailing one stretches out.
  final double horizontal;

  /// Raw springs merged last.
  final LiquidMoveOptions? advanced;

  /// `mapBend`: springiness 1, no stretch, no tail, plus the two bows.
  LiquidMoveOptions resolve() => const MoveTuning(springiness: 1, stretch: 0, trail: 0)
      .resolve()
      .merge(LiquidMoveOptions(bend: vertical.clamp(0.0, 1.0), bendX: horizontal.clamp(0.0, 1.0)))
      .merge(advanced);

  @override
  bool operator ==(Object other) =>
      other is BendTuning && other.vertical == vertical && other.horizontal == horizontal && other.advanced == advanced;

  @override
  int get hashCode => Object.hash(vertical, horizontal, advanced);
}

/// Semi-implicit Euler spring advanced over a wall-clock [dt], substepped at
/// ≤ 1/60 s so it stays stable however long the frame gap was (`springSteps`).
(double, double) springSteps(double cur, double vel, double target, double k, double c, double dt) {
  var n = math.max(1, (dt * 60).ceil());
  final h = dt / n;
  var p = cur;
  var v = vel;
  while (n-- > 0) {
    final a = k * (target - p) - c * v;
    v = v + a * h;
    p = p + v * h;
  }
  return (p, v);
}

/// A CSS radius as a rounded-rect corner: clamped to min(w, h) / 2 so the
/// `999px` pill idiom stays a pill (`pillRadius`).
double pillRadius(double r, double w, double h) => math.max(0, math.min(r, math.min(w, h) / 2));

/// The liquid body of a move / bend piece: a simulated surface chasing the
/// piece's painted rect (observer.ts `writeBlob`, its move branch).
///
/// Centre-based: the mass's centre springs after the piece, size and corner
/// follow it exactly; speed stretches the body along its velocity, a laggier
/// satellite plus two tapering mid-droplets string a tail behind it, and the
/// bows curve its edges.
class LiquidBody {
  bool _seeded = false;
  double cx = 0;
  double cy = 0;
  double w = 0;
  double h = 0;
  double r = 0;
  double vcx = 0;
  double vcy = 0;

  double tailX = 0;
  double tailY = 0;
  double tailVx = 0;
  double tailVy = 0;
  double tailR = 0;
  double tailPhase = 0;
  Offset midA = Offset.zero;
  Offset midB = Offset.zero;

  double bendCur = 0;
  double bendCurX = 0;

  /// Velocity stretch this frame: axis angle (rad) and amount (0 = none).
  double stretchAngle = 0;
  double stretch = 0;

  /// The bowed silhouette, centred on the body; only while [bending].
  final Path bendPath = Path();
  bool bending = false;

  /// Corner radius the body paints with.
  double paintR = 0;

  bool get hasTail => tailR >= 0.3;

  /// One frame towards [f] (the piece's rect in the group). [radius] is the
  /// piece's corner radius at its layout width [baseW]. Returns whether the
  /// body is still moving.
  bool step(Rect f, double radius, double baseW, double dt, LiquidMoveOptions o) {
    final tcx = f.center.dx;
    final tcy = f.center.dy;
    final tr = radius * (baseW > 0 ? f.width / baseW : 1);
    if (!_seeded) {
      _seeded = true;
      cx = tcx;
      cy = tcy;
    }
    final (nx, nvx) = springSteps(cx, vcx, tcx, o.stiffness!, o.damping!, dt);
    final (ny, nvy) = springSteps(cy, vcy, tcy, o.stiffness!, o.damping!, dt);
    cx = nx;
    vcx = nvx;
    cy = ny;
    vcy = nvy;
    w = f.width;
    h = f.height;
    r = tr;

    final speed = math.sqrt(vcx * vcx + vcy * vcy);
    // Mild stretch along the velocity axis; the drop shape itself comes from
    // the trailing satellite, not from squashing the body into an ellipse.
    if (speed > 2) {
      stretch = math.min(o.stretch!, speed * 0.0006);
      stretchAngle = (math.atan2(vcy, vcx) * 100).round() / 100;
    } else {
      stretch = 0;
    }

    // Trailing droplet: chases the body's centre on a laggier spring. The lag
    // is clamped so the satellite always overlaps the body's blur field — a
    // small circle on its own sits below the goo threshold and vanishes.
    if (tailR == 0 && tailX.abs() < 0.001 && tailY.abs() < 0.001) {
      tailX = cx;
      tailY = cy;
    }
    final (tx, tvx) = springSteps(tailX, tailVx, cx, 170, 22, dt);
    final (ty, tvy) = springSteps(tailY, tailVy, cy, 170, 22, dt);
    tailX = tx;
    tailVx = tvx;
    tailY = ty;
    tailVy = tvy;
    // Size from the side it trails (a horizontal drag trails the height), lag
    // cap past the body's own half-extent along the motion.
    final ux = speed > 0.001 ? vcx / speed : 1.0;
    final uy = speed > 0.001 ? vcy / speed : 0.0;
    final perp = math.max(4.0, ux.abs() * h + uy.abs() * w);
    final halfAlong = (ux.abs() * w + uy.abs() * h) / 2;
    final base = perp / 2;
    final lagX = tailX - cx;
    final lagY = tailY - cy;
    final lag = math.sqrt(lagX * lagX + lagY * lagY);
    final maxLag = halfAlong + base * (0.2 + o.force! * 1.6);
    if (lag > maxLag) {
      tailX = cx + (lagX / lag) * maxLag;
      tailY = cy + (lagY / lag) * maxLag;
    }
    // Full size (`tail` × the trailing side's half-extent) once genuinely
    // moving; the short onset ramp only stops it popping on micro-jitter.
    final onset = ((speed - 20) / 120).clamp(0.0, 1.0);
    final targetR = base * o.tail! * onset;
    tailR += (targetR - tailR) * math.min(1, dt * 10);
    if (hasTail) {
      // Wobble phase rides distance travelled; the mid-droplets sit at 45% and
      // 75% of the way out, tapering, nudged off-axis in opposite directions.
      tailPhase += speed * dt * 0.045;
      final wob = tailR * 0.16;
      final px = -uy;
      final py = ux;
      final w1 = math.sin(tailPhase) * wob;
      final w2 = math.sin(tailPhase + 2.4) * -wob;
      // The clamp above may have moved the satellite: the original strings the
      // mid-droplets from the pre-clamp lag.
      midA = Offset(cx + lagX * 0.45 + px * w1, cy + lagY * 0.45 + py * w1);
      midB = Offset(cx + lagX * 0.75 + px * w2, cy + lagY * 0.75 + py * w2);
    }

    paintR = pillRadius(math.max(0, r), w, h);

    // Body bow, two axes: vertical velocity arcs the top and bottom edges,
    // horizontal velocity reshapes the caps.
    final cap = math.min(w, h) * 0.5;
    final bTy = (vcy * 0.05).clamp(-cap, cap) * o.bend!;
    final capX = math.min(w, h) * 0.9;
    final bTx = (vcx * 0.09).clamp(-capX, capX) * o.bendX!;
    bendCur += (bTy - bendCur) * math.min(1, dt * 9);
    bendCurX += (bTx - bendCurX) * math.min(1, dt * 9);
    bending = (bendCur.abs() > 0.5 || bendCurX.abs() > 0.5) && w > 1 && h > 1;
    if (bending) _bow();

    final settled = (cx - tcx).abs() < 0.05 && (cy - tcy).abs() < 0.05 && speed < 1 && !hasTail;
    return !settled;
  }

  /// The bowed silhouette: quadratic sag on the top and bottom edges, the
  /// caps as quarter-circle cubics with the leading one blunted and the
  /// trailing one stretched about twice as far.
  void _bow() {
    final bw = w;
    final bh = h;
    final rr = math.min(paintR, math.min(bw / 2, bh / 2));
    final sag = bendCur * 2;
    final k = bendCurX;
    final rxR = (k > 0 ? rr - 0.8 * k : rr + 1.6 * -k).clamp(rr * 0.2, rr * 3);
    final rxL = (k > 0 ? rr + 1.6 * k : rr - 0.8 * -k).clamp(rr * 0.2, rr * 3);
    const kk = 0.5523;
    final ox = -bw / 2;
    final oy = -bh / 2;
    bendPath
      ..reset()
      ..moveTo(ox + rxL, oy)
      ..quadraticBezierTo(ox + bw / 2, oy + sag, ox + bw - rxR, oy)
      ..cubicTo(ox + bw - rxR + kk * rxR, oy, ox + bw, oy + rr - kk * rr, ox + bw, oy + rr)
      ..lineTo(ox + bw, oy + bh - rr)
      ..cubicTo(ox + bw, oy + bh - rr + kk * rr, ox + bw - rxR + kk * rxR, oy + bh, ox + bw - rxR, oy + bh)
      ..quadraticBezierTo(ox + bw / 2, oy + bh + sag, ox + rxL, oy + bh)
      ..cubicTo(ox + rxL - kk * rxL, oy + bh, ox, oy + bh - rr + kk * rr, ox, oy + bh - rr)
      ..lineTo(ox, oy + rr)
      ..cubicTo(ox, oy + rr - kk * rr, ox + rxL - kk * rxL, oy, ox + rxL, oy)
      ..close();
  }

  /// Paints the tail droplets and the body.
  void paint(Canvas canvas, Paint fill) {
    if (hasTail) {
      canvas
        ..drawCircle(Offset(tailX, tailY), tailR, fill)
        ..drawCircle(midA, tailR * 0.62, fill)
        ..drawCircle(midB, tailR * 0.4, fill);
    }
    canvas
      ..save()
      ..translate(cx, cy);
    if (stretch > 0) {
      canvas
        ..rotate(stretchAngle)
        ..scale(1 + stretch, 1 / (1 + stretch * 0.65))
        ..rotate(-stretchAngle);
    }
    if (bending) {
      canvas.drawPath(bendPath, fill);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w, height: h), Radius.circular(paintR)),
        fill,
      );
    }
    canvas.restore();
  }
}

/// One piece registered with a group: its render box, how its liquid behaves,
/// and what it painted last.
class LiquidBlob {
  LiquidBlob({required this.box, required this.effect, required this.radius, required this.move});

  final RenderBox box;
  LiquidEffect effect;
  BorderRadius radius;

  /// Resolved springs for move / bend; null for morph.
  LiquidMoveOptions? move;

  LiquidBody? body;
  RRect _plain = RRect.zero;

  bool get dynamic => move != null;

  /// Measures the piece in [group]'s coordinates and, for move / bend, steps
  /// its body by [dt] (0 = same frame again: measure only). Returns whether
  /// the body is still moving.
  bool update(RenderBox group, double dt, {required bool reduced}) {
    final size = box.size;
    final f = MatrixUtils.transformRect(box.getTransformTo(group), Offset.zero & size);
    final move = this.move;
    if (move != null && !reduced) {
      if (dt == 0 && body != null) return false;
      return (body ??= LiquidBody()).step(f, radius.topLeft.x, size.width, dt == 0 ? 1 / 60 : dt, move);
    }
    body = null;
    _plain = _rrect(f, size.width);
    return false;
  }

  /// The rendered corner scales with the transform (CSS radii don't, the
  /// rendered corner does); uniform radii clamp like a pill, mixed ones get
  /// CSS overlap clamping.
  RRect _rrect(Rect f, double baseW) {
    final s = baseW > 0 ? f.width / baseW : 1.0;
    var tl = math.max(0.0, radius.topLeft.x * s);
    var tr = math.max(0.0, radius.topRight.x * s);
    var br = math.max(0.0, radius.bottomRight.x * s);
    var bl = math.max(0.0, radius.bottomLeft.x * s);
    if (tl == tr && tr == br && br == bl) {
      return RRect.fromRectAndRadius(f, Radius.circular(pillRadius(tl, f.width, f.height)));
    }
    final k = [
      1.0,
      f.width / math.max(1e-6, tl + tr),
      f.width / math.max(1e-6, bl + br),
      f.height / math.max(1e-6, tl + bl),
      f.height / math.max(1e-6, tr + br),
    ].reduce(math.min);
    tl *= k;
    tr *= k;
    br *= k;
    bl *= k;
    return RRect.fromRectAndCorners(
      f,
      topLeft: Radius.circular(tl),
      topRight: Radius.circular(tr),
      bottomRight: Radius.circular(br),
      bottomLeft: Radius.circular(bl),
    );
  }

  void paint(Canvas canvas, Paint fill) {
    final body = this.body;
    if (body != null) {
      body.paint(canvas, fill);
    } else {
      canvas.drawRRect(_plain, fill);
    }
  }
}

/// A group's registry and clock (observer.ts `ObserveEngine`): pieces register
/// here, the group's paint measures and steps them, and [onActive] keeps frames
/// coming while a body moves. It sleeps after 30 still frames.
class LiquidEngine {
  LiquidEngine({required this.onActive});

  /// A body started moving while frames were idle.
  final VoidCallback onActive;

  final blobs = <LiquidBlob>[];

  /// The group's render box, set while attached.
  RenderBox? group;

  /// System "remove animations": bodies glue to their pieces.
  bool reduced = false;

  /// Frames in a row in which no body moved.
  int clean = 0;

  Duration? _last;

  bool get asleep => _last == null;

  void add(LiquidBlob blob) {
    blobs.add(blob);
    group?.markNeedsPaint();
  }

  void remove(LiquidBlob blob) {
    blobs.remove(blob);
    group?.markNeedsPaint();
  }

  /// Frames stopped: the next step starts from a fresh 1/60 s.
  void sleep() {
    _last = null;
  }

  /// Measures every piece and steps the bodies to frame [stamp]. A wall-clock
  /// dt, capped only against long gaps; the springs substep.
  void step(RenderBox group, Duration stamp) {
    final last = _last;
    final double dt;
    if (last == null) {
      dt = 1 / 60;
    } else if (stamp == last) {
      dt = 0;
    } else {
      dt = ((stamp - last).inMicroseconds / 1e6).clamp(1 / 240, 0.25);
    }
    var moving = false;
    for (final blob in blobs) {
      if (blob.box.hasSize && blob.update(group, dt, reduced: reduced)) moving = true;
    }
    if (dt == 0) return;
    if (moving) {
      clean = 0;
      if (last == null) onActive();
    } else {
      clean++;
    }
    if (last != null || moving) _last = stamp;
  }

  /// Paints every piece's silhouette with [fill].
  void paint(Canvas canvas, Paint fill) {
    for (final blob in blobs) {
      if (blob.box.hasSize) blob.paint(canvas, fill);
    }
  }
}
