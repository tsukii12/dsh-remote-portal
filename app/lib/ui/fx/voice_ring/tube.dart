// Portions derived from Libraries.dev Voice ring (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The tube painter (tube.ts): a line drawn as a lit, solid tube. The line is
// cut into short runs drawn far → near, so where it passes in front of
// itself the near side covers the far one, a clear gap cut round it. Each run
// is one gradient from its first point's light to its last's, with a thin
// highlight laid along it toward the light. Each run starts a segment back
// into the run before, with butt caps, so the runs meet with no seam.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'frame.dart';
import 'voice.dart';

// segments per run: short enough that a crossing sorts cleanly
const int _run = 6;

/// The brightness the look gives a glow's colour: its emotion's own, or for
/// a colour between emotions a blend, weighted by how near it is to each.
double _emotionBrightness(FrameTube look, GlowFollower glow) {
  var sum = 0.0;
  var weight = 0.0;
  for (final (e, b) in [
    (VoiceRingEmotion.positive, look.positiveBrightness),
    (VoiceRingEmotion.negative, look.negativeBrightness),
    (VoiceRingEmotion.calm, look.calmBrightness),
  ]) {
    final c = emotionColors[e]!;
    final d = (glow.r - c.r) * (glow.r - c.r) + (glow.g - c.g) * (glow.g - c.g) + (glow.b - c.b) * (glow.b - c.b);
    final w = math.exp(-d / 6000);
    sum += w * b;
    weight += w;
  }
  return weight > 1e-6 ? sum / weight : 1;
}

/// The colour for a light value [s]: grey with the tint on it; an emotion
/// takes the tube over by [share], lit like the grey was — deep in the
/// shadows, vivid in the light, toward white only at the very brightest.
Color tubeColor(double s, bool dark, FrameTube look, {Rgb? tint, GlowFollower? glow, double share = 1}) {
  // on dark, lit parts read pale; on paper, as darker ink
  final g = dark ? 255 * (0.16 + 0.84 * s) : 255 * (0.1 + 0.6 * (1 - s));
  var r = g;
  var gr = g;
  var b = g;
  if (tint != null) {
    // a colour keeps the grey's light: toward black on dark, white on paper
    double shadeOf(double c) => dark ? c * g / 255 : c + (255 - c) * (g / 255) * 0.7;
    r += (shadeOf(tint.r) - r) * 0.85;
    gr += (shadeOf(tint.g) - gr) * 0.85;
    b += (shadeOf(tint.b) - b) * 0.85;
  }
  if (glow != null) {
    final bright = look.colorBrightness * _emotionBrightness(look, glow);
    double vivid(double c) => dark
        ? math.min(255, c * (0.3 + 0.9 * s) * bright + 90 * s * s * s * s)
        : math.min(255, c * (0.45 + 0.55 * (1 - s)) * bright);
    final k = glow.amount * share;
    r += (vivid(glow.r) - r) * k;
    gr += (vivid(glow.g) - gr) * k;
    b += (vivid(glow.b) - b) * k;
    // saturation: toward the grey below 1, past the colour above it
    final sat = look.saturation;
    if (sat != 1) {
      final m = (r + gr + b) / 3;
      r = m + (r - m) * sat;
      gr = m + (gr - m) * sat;
      b = m + (b - m) * sat;
    }
  }
  int c(double v) => v.round().clamp(0, 255);
  return Color.fromARGB(255, c(r), c(gr), c(b));
}

class _Run {
  RingStroke stroke = RingStroke(0);
  int from = 0;
  int to = 0;
  double z = 0;
}

/// Paints a tube frame. One per ring widget: it keeps its runs, paths and paints.
class TubePainter {
  final List<_Run> _runs = [];
  final Path _path = Path();
  final Paint _cut = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.round
    ..blendMode = BlendMode.dstOut
    ..color = const Color(0xFF000000);
  final Paint _body = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.round;
  final Paint _shine = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.round;

  void paint(Canvas canvas, OrbFrame frame, {required bool dark, Rgb? tint, GlowFollower? glow}) {
    final look = frame.tube!;
    double light(RingStroke s, int i) => clamp01(0.5 + (s.a[i] - 0.5) * look.contrast);

    var used = 0;
    for (final s in frame.strokes) {
      final n = s.length;
      for (var i0 = 0; i0 < n; i0 += _run) {
        final i1 = math.min(n, i0 + _run);
        var z = 0.0;
        for (var i = i0; i <= i1; i++) {
          z += s.z![i % n];
        }
        if (used == _runs.length) _runs.add(_Run());
        // a segment back into the run before, so the two overlap
        _runs[used++]
          ..stroke = s
          ..from = i0 - 1
          ..to = i1
          ..z = z / (i1 - i0 + 1);
      }
    }
    final runs = _runs
      ..removeRange(used, _runs.length)
      ..sort((a, b) => a.z.compareTo(b.z));

    // With an emotion, its colour fades round the ring into the neutral grey:
    // full on one side, grey on the other as far as `gradient` says.
    final emo = glow != null && glow.amount > 0.005 ? glow : null;
    var cx = 0.0;
    var cy = 0.0;
    if (emo != null) {
      var count = 0;
      for (final s in frame.strokes) {
        for (var i = 0; i < s.pts.length; i += 2) {
          cx += s.pts[i];
          cy += s.pts[i + 1];
          count++;
        }
      }
      cx /= count;
      cy /= count;
    }
    final phase = (look.gradientAngle + look.gradientSpin * (glow?.t ?? 0)) * math.pi / 180;
    final fade = clamp01(look.gradient);
    double shareAt(RingStroke s, int i) {
      if (emo == null) return 1;
      final side = (math.sin(math.atan2(s.pts[2 * i + 1] - cy, s.pts[2 * i] - cx) + phase) + 1) / 2;
      return 1 - fade * (1 - smoothstep(0, 1, side));
    }

    for (final run in runs) {
      final s = run.stroke;
      final n = s.length;
      int at(int i) => ((i % n) + n) % n;
      _path.reset();
      for (var i = run.from; i <= run.to; i++) {
        final k = at(i);
        if (i == run.from) {
          _path.moveTo(s.pts[2 * k], s.pts[2 * k + 1]);
        } else {
          _path.lineTo(s.pts[2 * k], s.pts[2 * k + 1]);
        }
      }
      final a = at(run.from);
      final b = at(run.to);
      final w = s.w * (1 - look.depth + look.depth * run.z);

      // the gap: whatever it passes in front of is cut back round it — cut
      // rather than shaded, so overlapping runs never darken twice
      canvas.drawPath(_path, _cut..strokeWidth = w * 1.35);

      // the body, its light running from one end of the run to the other
      final x0 = s.pts[2 * a];
      final y0 = s.pts[2 * a + 1];
      final x1 = s.pts[2 * b];
      final y1 = s.pts[2 * b + 1];
      final ca = tubeColor(light(s, a), dark, look, tint: tint, glow: emo, share: shareAt(s, a));
      if ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) > 0.25) {
        final cb = tubeColor(light(s, b), dark, look, tint: tint, glow: emo, share: shareAt(s, b));
        _body.shader = ui.Gradient.linear(Offset(x0, y0), Offset(x1, y1), [ca, cb]);
      } else {
        _body
          ..shader = null
          ..color = ca;
      }
      canvas.drawPath(_path, _body..strokeWidth = w);

      // the highlight, set toward the light (up and to the left), strongest
      // where the run is brightest
      var lit = 0.0;
      for (var i = run.from; i <= run.to; i++) {
        lit += light(s, at(i));
      }
      lit /= run.to - run.from + 1;
      final alpha = clamp01(look.shine * (dark ? 0.6 : 0.45) * lit * lit);
      if (alpha > 0.01) {
        canvas
          ..save()
          ..translate(-0.17 * w, -0.19 * w)
          ..drawPath(
            _path,
            _shine
              ..strokeWidth = w * 0.32
              ..color = Color.fromRGBO(255, 255, 255, alpha),
          )
          ..restore();
      }
    }
    _body.shader = null;
  }
}
