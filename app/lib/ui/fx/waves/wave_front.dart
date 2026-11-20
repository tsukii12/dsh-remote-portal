// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'distortion_wave_style.dart';

/// The frame a wave of [type] opens from when none is given, in a view of
/// [size]: a wide button at the bottom, a tall strip at the left edge, or an
/// avatar in the middle.
Rect waveDefaultSource(DistortionWaveType type, Size size) => switch (type) {
  DistortionWaveType.vertical => Rect.fromLTWH(20, size.height - 92, size.width - 40, 58),
  DistortionWaveType.horizontal => Rect.fromLTWH(0, size.height * 0.343, 24, size.height * 0.3135),
  DistortionWaveType.center => Rect.fromCenter(center: size.center(Offset.zero), width: 64, height: 64),
};

/// Where the wave is at a moment of its life — a pure function of progress, so
/// the wave can be scrubbed, reversed and frozen for a screenshot.
///
/// Its life, in order: gravity pulls everything toward the source; the front
/// launches off the source's outline, crosses the view on the style's easing,
/// and settles past the far side as its swell, blur and colour die away; the
/// colour it left on the view's edges is wiped away by a second front,
/// `linger` seconds behind.
class WaveFront {
  WaveFront._({
    required this.origin,
    required this.tilt,
    required this.spine,
    required this.radius,
    required this.moved,
    required this.squash,
    required this.time,
    required this.energy,
    required this.swell,
    required this.size,
    required this.gravity,
    required this.glow,
    required this.clearRadius,
    required this.hairClearRadius,
    required this.rim,
    required this.fallen,
    required this.sparkle,
    required this.flying,
    required this.launched,
    required this.hasCleared,
    required this.ring,
    required this.sideways,
    required this.hold,
  });

  /// [focus]: where the source was touched, if the wave is to lean with it.
  factory WaveFront({
    required double progress,
    required Rect source,
    required Size size,
    required DistortionWaveStyle style,
    Offset? focus,
  }) {
    final duration = style.duration;
    final t = progress.clamp(0.0, 1.0) * duration;
    final sinceLaunch = t - style.anticipation;
    // Eased at both ends: a snap into the pull would read as a jolt.
    final gathered = smooth(0, math.max(style.anticipation, 0.001), t);
    final x = (sinceLaunch / style.travel).clamp(0.0, 1.0);
    final moved = style.easing(x);

    final ring = style.type == DistortionWaveType.center;
    final sideways = style.type == DistortionWaveType.horizontal;
    final fullSquash = ring ? 1.0 : _arcSquash;
    final startRadius = math.min(source.width, source.height) / 2;
    // The source's long side, along which the front starts as a pill.
    final length = sideways ? source.height : source.width;
    // A ring spreads from the source's centre, whatever the source's shape.
    final startSpine = ring ? 0.0 : math.max(0.0, length / 2 - startRadius);
    // The horizontal wave is the vertical one turned a quarter: its frame's up
    // is the screen's right.
    final turned = sideways ? math.pi / 2 : 0.0;
    final axisX = math.cos(turned);
    final axisY = math.sin(turned);
    final centre = source.center;

    // Touched off-centre, the wave opens from under the finger and leans its
    // way. It leans only as the pill opens into an arc, so it still leaves the
    // source's own outline.
    var lean = 0.0;
    if (!ring && focus != null) {
      final off = sideways ? focus.dy - centre.dy : focus.dx - centre.dx;
      lean = (off / math.max(length / 2, 1)).clamp(-1.0, 1.0);
    }
    final fullShift = lean * length / 2 * style.orientation;
    final fullLean = lean * style.orientation * _maxTilt;
    final fullTilt = turned + fullLean;
    final opening = smooth(0, 0.45, moved);

    // The radius at which the front has left the view's farthest corner, in
    // the wave's own frame once it has finished leaning.
    final cs = math.cos(fullTilt);
    final sn = math.sin(fullTilt);
    var reach = 0.0;
    for (final corner in [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      final dx = corner.dx - centre.dx - fullShift * axisX;
      final dy = corner.dy - centre.dy - fullShift * axisY;
      reach = math.max(reach, _hypot((cs * dx + sn * dy) * fullSquash, -sn * dx + cs * dy));
    }
    // …and has taken the outgoing side with it. The field divides by its
    // gradient, at most fullSquash.
    final crossed = reach + (style.swell + coverZone) * fullSquash;
    final settling = 1 - smooth(_settleStart, _settleEnd, x);

    // Before the launch a ring of colour falls in, onto where the front will
    // start: the style's gap out from the source's outline.
    final launchRadius = startRadius + math.max(style.launchGap, 0);
    final radius = sinceLaunch < 0
        ? launchRadius + style.inhale * (1 - gathered)
        : launchRadius + (crossed + _overshoot - launchRadius) * moved;
    // From what has gathered on the source, so nothing pops at the launch.
    final gatheredGlow = math.min(_gatheredGlowCap * math.max(style.gatherGlow, 0), 1.0);
    // Starts far enough back that the colour is whole all the way to the
    // source, and ends just as the softness of its edge has left the farthest
    // corner, so the whole of the easing plays out on screen.
    final clearStart = startRadius - style.rimSoftness;
    final clearEnd = reach + (style.rimSoftness + style.swell) * fullSquash;
    // Falling: slowly at first, then faster and faster, as under gravity.
    final falling = math.min(t / math.max(style.anticipation, 0.001), 1.0);

    return WaveFront._(
      origin: Offset(centre.dx + fullShift * opening * axisX, centre.dy + fullShift * opening * axisY),
      tilt: turned + fullLean * opening,
      // The pill opens into an arc only as the front travels, so its sides
      // never pull back in while the radius is still small.
      spine: startSpine * (1 - opening),
      radius: radius,
      moved: moved,
      squash: 1 + (fullSquash - 1) * smooth(0, 0.5, moved),
      time: t,
      energy: smooth(0, 0.05, x) * settling,
      swell: style.swell * smooth(0, 0.3, moved),
      size: size,
      gravity: style.pull * gathered * (1 - smooth(0, _release, sinceLaunch)),
      glow: sinceLaunch < 0
          ? gatheredGlow * gathered
          : (gatheredGlow + (1 - gatheredGlow) * smooth(0, 0.07, x)) * settling,
      clearRadius:
          clearStart +
          (clearEnd - clearStart) * style.rimEasing((sinceLaunch - style.linger) / math.max(style.rimFade, 0.01)),
      hairClearRadius:
          clearStart +
          (clearEnd - clearStart) *
              style.rimEasing((sinceLaunch - style.linger - style.hairlineLinger) / math.max(style.hairlineFade, 0.01)),
      rim: style.rimStrength * smooth(0, 0.1, x) * (1 - smooth(0.9, 1, t / duration)),
      fallen: falling * falling,
      sparkle: smooth(0, math.max(style.anticipation, 0.001) * 0.35, t),
      flying: math.max(sinceLaunch, 0),
      launched: sinceLaunch > 0,
      hasCleared: radius > crossed,
      ring: ring,
      sideways: sideways,
      hold: ring ? startRadius : 0,
    );
  }

  final Offset origin;

  /// How far the wave's frame is turned, radians: positive leans it right.
  final double tilt;

  /// Half-length of the straight part of the pill the front is an offset of.
  final double spine;

  /// Distance of the front from that spine.
  final double radius;

  /// How far the front is along its way, 0–1.
  final double moved;

  /// Scale of the x axis in the field: above 1 the front bows.
  final double squash;

  /// Seconds since the wave started.
  final double time;

  /// How strongly the swell and the blur act, 0–1. 0 at either end of their
  /// part in the wave, so nothing pops as the shaders switch off.
  final double energy;

  final double swell;
  final Size size;

  /// How far content is pulled toward the source.
  final double gravity;

  /// How strong the colour on the front is, 0–1.
  final double glow;

  /// Distance of the later front that wipes the colour off the view's edges.
  final double clearRadius;

  /// Distance of the front that wipes the hairline off them, later still.
  final double hairClearRadius;

  /// Opacity of the colour on the view's edges, 0–1.
  final double rim;

  /// How far the particles have fallen into the source, 0–1.
  final double fallen;

  /// How far the particles have faded in, 0–1.
  final double sparkle;

  /// Seconds since the front left the source, 0 before that.
  final double flying;

  /// True once the front has left the source.
  final bool launched;

  /// True once the front has crossed the whole view: nothing of the content it
  /// leaves behind can show any more, so that side need not be drawn.
  final bool hasCleared;

  /// True for a ring spreading from the source's centre, rather than an arc.
  final bool ring;

  /// True for an arc travelling left to right, rather than bottom to top.
  final bool sideways;

  /// Radius of the source the wave leaves alone: a ring's, 0 for an arc.
  final double hold;

  /// Half the zone over which the two screens crossfade (`coverZone` in the
  /// shaders).
  static const coverZone = 60.0;

  /// The most an arc's x axis is ever squashed; a ring's never is.
  static const _arcSquash = 1.4;

  /// Seconds gravity takes to let go after the launch.
  static const _release = 0.22;

  /// How strong the colour gathering around the source gets before the launch.
  static const _gatheredGlowCap = 0.5;

  /// How far past the point of having crossed the view the front settles: enough
  /// to see the easing's slowing down, and to stop drawing the outgoing side
  /// well before the front stops.
  static const _overshoot = 100.0;

  /// How far the wave turns, at full orientation, when touched at the end of
  /// the source: about 26°.
  static const _maxTilt = 0.45;

  /// The part of the travel over which the swell, the blur and the colour die
  /// away: the front has crossed the screen by its start.
  static const _settleStart = 0.2;
  static const _settleEnd = 0.55;

  static double smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _hypot(double x, double y) => math.sqrt(x * x + y * y);
}

/// The lumps that make the colour on the view's edges uneven: seven round the
/// perimeter, each with its own length and depth, drifting along the edge and
/// breathing. Worked out once a frame rather than for every pixel.
abstract final class WaveRim {
  static const count = 7;

  /// Centre along the perimeter (clockwise from the top centre), length and
  /// depth (a share of the rim's width) of each lump, into [out] (3 × [count]).
  /// [pulse], 0–1, makes them drift faster and breathe deeper.
  static void lumps(
    Float64List out, {
    required double time,
    required Size size,
    required double cornerRadius,
    double pulse = 0,
  }) {
    final ex = math.max(size.width / 2 - cornerRadius, 0.0);
    final ey = math.max(size.height / 2 - cornerRadius, 0.0);
    final perimeter = 4 * (ex + ey + 0.5 * math.pi * cornerRadius);
    const n = count;
    for (var i = 0; i < count; i++) {
      final fi = i.toDouble();
      // Fixed per lump, so the pattern is the same on every run.
      final a = _hash(fi, 12.9898, 1.3);
      final b = _hash(fi, 78.233, 4.1);
      final c = _hash(fi, 39.425, 2.7);
      final breath = (0.25 + 0.3 * pulse) * math.sin(time * (1.1 + 1.2 * a) * (1 + pulse) + fi * 2.4);
      out[i * 3] = perimeter * (fi + 0.35 * a) / n + time * (-22 + 44 * b) * (1 + 2 * pulse);
      out[i * 3 + 1] = perimeter / n * (0.2 + 0.25 * c);
      out[i * 3 + 2] = (0.2 + 2.6 * b) * (1 + breath);
    }
  }

  static double _hash(double i, double a, double b) {
    final x = math.sin(i * a + b) * 43758.5453;
    return x - x.floorToDouble();
  }
}

/// One tiny white dot. Where it is follows from the front alone, so it scrubs
/// and reverses with the rest.
///
/// During the anticipation it makes short hops toward the source: each starts
/// somewhere off it, flies a little way in, faster and faster, and fades out
/// well short of it. When the front leaves, the dot is thrown out with it: the
/// quickest ride the front, the slowest trail far behind. Then it floats on,
/// swaying and twinkling, until it fades out. No two are equally bright. Round a
/// ring it is the same, all the way round.
class WaveParticle {
  factory WaveParticle(int index, DistortionWaveStyle style) {
    // Low-discrepancy sequences: evenly scattered, the same on every run.
    final i = (index + 1).toDouble();
    double scatter(double step) => (i * step) % 1;
    final small = scatter(0.5497004779);
    return WaveParticle._(
      index: i,
      // Short of the source's ends, so a dot leaving it starts behind it.
      column: (scatter(0.7548776662) * 2 - 1) * 0.92,
      heading: scatter(0.7548776662) * 2 * math.pi,
      // More of them toward the front, the rest thinning out behind it.
      pace: 0.35 + 0.72 * math.sqrt(scatter(0.8191725134)),
      drift: 15 + 50 * scatter(0.6710436067),
      sway: 3 + 11 * scatter(0.4142135624),
      swayRate: 2.5 + 3.5 * scatter(0.7320508076),
      twinkleRate: 8 + 12 * scatter(0.2360679775),
      phase: scatter(0.6180339887) * 2 * math.pi,
      life: style.particleLife * (0.4 + 0.6 * scatter(0.6457513111)),
      size: style.particleSize * (0.55 + 0.45 * small * small),
      brightness: 0.3 + 0.7 * scatter(0.6055512755),
      hop: 0.16 + 0.14 * scatter(0.1231056256),
      hopOffset: scatter(0.4721359550),
      reach: style.particleReach,
      flight: style.particleFlight,
      gap: style.particleGap,
      anticipation: style.anticipation,
      gatherDots: style.gatherDots,
      spread: style.particleSpread.clamp(0.0, 1.0),
    );
  }

  WaveParticle._({
    required this.index,
    required this.column,
    required this.heading,
    required this.pace,
    required this.drift,
    required this.sway,
    required this.swayRate,
    required this.twinkleRate,
    required this.phase,
    required this.life,
    required this.size,
    required this.brightness,
    required this.hop,
    required this.hopOffset,
    required this._reach,
    required this._flight,
    required this._gap,
    required this._anticipation,
    required this._gatherDots,
    required this._spread,
  });

  final double index;

  /// Where across the source it leaves from, -1…1.
  final double column;

  /// Which way it leaves a ring, radians.
  final double heading;

  /// Its share of the front's way: 1 rides the front, less trails behind it.
  final double pace;

  /// How fast it keeps rising once the front has slowed down, per second.
  final double drift;

  /// How far it sways from side to side.
  final double sway;
  final double swayRate;
  final double twinkleRate;
  final double phase;

  /// Seconds after the launch by which it has faded out.
  final double life;

  /// Its diameter.
  final double size;

  /// How bright it is at its brightest, 0–1.
  final double brightness;

  /// Seconds each hop toward the source lasts.
  final double hop;
  final double hopOffset;

  final double _reach;
  final double _flight;
  final double _gap;
  final double _anticipation;
  final double _gatherDots;
  final double _spread;

  /// How much wider than the source the quickest end up: the front is an arc,
  /// opening.
  static const _fan = 0.22;

  /// How much lower they fly at the source's ends than in its middle, as the
  /// front does.
  static const _bow = 0.3;

  Offset point(WaveFront front, Rect source) {
    if (front.ring) return front.launched ? _ringOutflow(front, source) : _ringInflow(front, source);
    return front.launched ? _outflow(front, source) : _inflow(front, source);
  }

  double opacity(WaveFront front) {
    final twinkle = 0.5 + 0.5 * math.sin(front.time * twinkleRate + phase);
    final glint = brightness * (0.7 + 0.3 * twinkle);
    if (!front.launched) {
      // In and out within each hop, and all of them gone by the launch.
      final along = hopAt(front.time).along;
      final hopping = WaveFront.smooth(0, 0.25, along) * (1 - WaveFront.smooth(0.55, 1, along));
      final ending = 1 - WaveFront.smooth(_anticipation * 0.75, _anticipation, front.time);
      return front.sparkle * hopping * ending * glint * _gatherDots;
    }
    final burning = 1 - WaveFront.smooth(life * 0.55, life, front.flying);
    return burning * glint;
  }

  /// Which hop it is on at [time], and how far through it, 0–1.
  ({double count, double along}) hopAt(double time) {
    final hops = time / hop + hopOffset;
    final count = hops.floorToDouble();
    return (count: count, along: hops - count);
  }

  /// In the source's own frame: [along] its long side, [out] the way the wave
  /// will travel (up for the vertical wave, right for the horizontal one).
  static Offset _onSource(Rect source, bool sideways, double along, double out) => sideways
      ? Offset(source.center.dx + out, source.center.dy + along)
      : Offset(source.center.dx + along, source.center.dy - out);

  Offset _inflow(WaveFront front, Rect source) {
    final (:count, :along) = hopAt(front.time);
    final half = (front.sideways ? source.height : source.width) / 2;
    final face = (front.sideways ? source.width : source.height) / 2;
    // Born somewhere off the source's face, never nearer than the hop and the gap.
    final x = (_hash(index, count, 1) * 2 - 1) * (half + 24);
    final nearest = _gap + _flight;
    final away = nearest + math.max(_reach - nearest, 0) * _hash(index, count, 2);
    final start = _onSource(source, front.sideways, x, face + away);
    // Flying for the nearest point of the source's face, faster and faster.
    final corner = math.min(source.width, source.height) / 2;
    final target = _onSource(source, front.sideways, x.clamp(-half + corner, half - corner), face);
    final dx = target.dx - start.dx;
    final dy = target.dy - start.dy;
    final length = math.max(math.sqrt(dx * dx + dy * dy), 1);
    final travelled = _flight * along * along;
    return Offset(start.dx + dx / length * travelled, start.dy + dy / length * travelled);
  }

  Offset _outflow(WaveFront front, Rect source) {
    final start = math.min(source.width, source.height) / 2;
    final widening = 1 + _fan * front.moved * pace * _spread;
    final swaying = sway * math.sin(swayRate * front.flying + phase) * math.min(front.flying / 0.25, 1);
    final x = column * (front.sideways ? source.height : source.width) / 2 * widening + swaying;
    final height =
        (start + (front.radius - start) * pace * _spread) * (1 - _bow * column * column) +
        drift * front.flying * _spread;
    // Into the wave's frame, which leans with the touch.
    final cs = math.cos(front.tilt);
    final sn = math.sin(front.tilt);
    return Offset(front.origin.dx + cs * x + sn * height, front.origin.dy + sn * x - cs * height);
  }

  /// A hop toward a round source's centre from somewhere round it.
  Offset _ringInflow(WaveFront front, Rect source) {
    final (:count, :along) = hopAt(front.time);
    final angle = _hash(index, count, 1) * 2 * math.pi;
    final nearest = math.min(source.width, source.height) / 2 + _gap + _flight;
    final away = nearest + math.max(_reach - nearest, 0) * _hash(index, count, 2);
    final distance = away - _flight * along * along;
    return Offset(source.center.dx + math.cos(angle) * distance, source.center.dy + math.sin(angle) * distance);
  }

  /// Thrown straight out with the ring, swaying across its way.
  Offset _ringOutflow(WaveFront front, Rect source) {
    final edge = math.min(source.width, source.height) / 2;
    final distance = edge + ((front.radius - edge) * pace + drift * front.flying) * _spread;
    final swaying = sway * math.sin(swayRate * front.flying + phase) * math.min(front.flying / 0.25, 1);
    final dx = math.cos(heading);
    final dy = math.sin(heading);
    return Offset(front.origin.dx + dx * distance - dy * swaying, front.origin.dy + dy * distance + dx * swaying);
  }

  static double _hash(double i, double n, double salt) {
    final x = math.sin(i * 12.9898 + n * 78.233 + salt * 37.719) * 43758.5453;
    return x - x.floorToDouble();
  }
}
