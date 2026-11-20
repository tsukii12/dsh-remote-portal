// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The nine geometry builders, translated line for line from thinking-orbs
// `src/engine/{lattice,orbits,web,braid,ribbon,morph}.ts`. Each is pure maths
// over (size, t, opts) and writes one finished frame; theme and ink are the
// painter's business. Constants, easing and timings are the author's.

import 'dart:math' as math;
import 'dart:typed_data';

import 'orb_core.dart';
import 'orb_presets.dart';

typedef ModeFrame = void Function(OrbFrame out, double size, double t, ModeOpts o);

/// Mode key to geometry builder (`MODE_FRAMES`). Ring shares ribbon's
/// geometry; its `faceOn` profile flag switches it.
const Map<OrbMode, ModeFrame> modeFrames = {
  OrbMode.orbits: frameOrbits,
  OrbMode.globe: frameGlobe,
  OrbMode.rubik: frameRubik,
  OrbMode.wave: frameWave,
  OrbMode.web: frameWeb,
  OrbMode.braid: frameBraid,
  OrbMode.ribbon: frameRibbon,
  OrbMode.ring: frameRibbon,
  OrbMode.morph: frameMorph,
};

const _tau = 2 * math.pi;

// --- the shared solver heartbeat (rubik) -----------------------------------
// Rapid eased moves scramble, then replay in reverse (palindrome) so
// everything clicks back to solved, rests, repeats.

typedef _Move = ({int axis, double lo, double hi, double ang});

final _movesByCount = <int, List<_Move>>{};

/// The scramble is a pure function of the move count, so it is built once.
List<_Move> _makeMoves(int count) => _movesByCount.putIfAbsent(
  count,
  () => List.generate(count, (i) {
    final h = i.toDouble();
    final axis = math.min(2, (hashD(h, 2.3) * 3).floor());
    final lo = -1.0 + 0.5 * math.min(3, (hashD(h, 5.9) * 4).floor());
    final dir = hashD(h, 7.7) < 0.5 ? 1 : -1;
    return (axis: axis, lo: lo, hi: lo + 0.5, ang: (dir * math.pi) / 2);
  }),
);

/// Writes each move's turn amount to `amount[0..count)` and returns the move
/// being turned right now (-1 while resting).
int _solveCycle(double time, int count, double slotDur, double rest, Float64List amount) {
  final cyc = 2 * count * slotDur + rest;
  final tc = time % cyc;
  amount.fillRange(0, count, 0);
  var active = -1;
  if (tc < 2 * count * slotDur) {
    final slot = (tc / slotDur).floor();
    final p = (tc - slot * slotDur) / slotDur;
    final cl = math.min(1.0, p / 0.7);
    final ep = 1 - math.pow(1 - cl, 3); // machine ease-out
    if (slot < count) {
      amount.fillRange(0, slot, 1);
      amount[slot] = ep.toDouble();
      active = slot;
    } else {
      final u = 2 * count - 1 - slot;
      // tc / slotDur can round up to exactly 2 * count; JavaScript then writes
      // amount[-1], which nothing reads, so the frame is simply solved.
      if (u >= 0) {
        amount.fillRange(0, u, 1);
        amount[u] = 1 - ep.toDouble();
        active = u;
      }
    }
  }
  return active;
}

// --- Globe: lat/long field, a scan meridian sweeps: searching ---------------

void frameGlobe(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  const spin = 0.5;
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.82;
  final tilt = 0.4 + 0.06 * math.sin(t * 0.35);
  final pt = out.proj..set(t * spin, tilt, cx, cy, radius);
  // scan sweeps relative to the spin; scanMul scales that relative rate
  final scan = t * (spin + (1.7 - spin) * (o['scanMul'] ?? 1));
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);
  final dimBase = o['dimBase'] ?? 1;
  final rBase = o['rBase'] ?? 0.6;
  final rDepth = o['rDepth'] ?? 1.7;
  final rBoost = o['rBoost'] ?? 1;
  final inkFar = o['inkFar'] ?? 0.62;
  final inkSpan = o['inkSpan'] ?? 0.54;

  final latRings = o['latRings'] ?? 17;
  final lonDensity = o['lonDensity'] ?? 44;
  for (var li = 0; li <= latRings; li++) {
    final lat = -math.pi / 2 + (li / latRings) * math.pi;
    final cosLat = math.cos(lat);
    final sinLat = math.sin(lat);
    final lonCount = math.max(1, (cosLat.abs() * lonDensity).round());
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * _tau;
      pt(cosLat * math.cos(lon), sinLat, cosLat * math.sin(lon));
      final z = pt.pz;
      final depth = (z + 1) / 2;
      // the scan: a moving meridian read as a size ripple, not a shine
      final d = angleDelta(lon + t * spin, scan);
      final boost = math.exp(-(d * d) / 0.18) * math.max(0.0, z);
      out.dot(
        pt.px,
        pt.py,
        z,
        (rBase + rDepth * depth + rBoost * boost) * rs,
        inkFar - inkSpan * depth,
        // dimBase < 1 fades un-scanned dots so the meridian reads clearly
        dimBase + (1 - dimBase) * math.min(1.0, boost),
      );
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Rubik: bands twist in quarter turns, scramble then solve: solving ------

void frameRubik(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.82;
  final pt = out.proj..set(t * 0.55, 0.35 + 0.1 * math.sin(t * 0.9), cx, cy, radius);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);
  final moveCount = (o['moveCount'] ?? 14).toInt();
  final moves = _makeMoves(moveCount);
  final amount = out.scratchOf(moveCount);
  final active = _solveCycle(t, moveCount, 0.42, 1.2, amount);
  final rBase = o['rBase'] ?? 0.6;
  final rDepth = o['rDepth'] ?? 1.7;
  final rActive = o['rActive'] ?? 0.3;
  final inkFar = o['inkFar'] ?? 0.62;
  final inkSpan = o['inkSpan'] ?? 0.54;

  final latRings = o['latRings'] ?? 15;
  final lonDensity = o['lonDensity'] ?? 40;
  for (var li = 0; li <= latRings; li++) {
    final lat = -math.pi / 2 + (li / latRings) * math.pi;
    final cosLat = math.cos(lat);
    final sinLat = math.sin(lat);
    final lonCount = math.max(1, (cosLat.abs() * lonDensity).round());
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * _tau;
      var x = cosLat * math.cos(lon);
      var y = sinLat;
      var z = cosLat * math.sin(lon);
      // applyMoves
      var inActive = false;
      for (var i = 0; i < moves.length; i++) {
        if (amount[i] <= 0) continue;
        final mv = moves[i];
        final coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z);
        if (coord < mv.lo || coord >= mv.hi) continue;
        if (i == active) inActive = true;
        final a = mv.ang * amount[i];
        final ca = math.cos(a);
        final sa = math.sin(a);
        if (mv.axis == 0) {
          final y2 = y * ca - z * sa;
          z = y * sa + z * ca;
          y = y2;
        } else if (mv.axis == 1) {
          final x2 = x * ca + z * sa;
          z = -x * sa + z * ca;
          x = x2;
        } else {
          final x2 = x * ca - y * sa;
          y = x * sa + y * ca;
          x = x2;
        }
      }
      pt(x, y, z);
      final zr = pt.pz;
      final depth = (zr + 1) / 2;
      // the band being turned inks a touch darker: the "hand"
      out.dot(
        pt.px,
        pt.py,
        zr,
        (rBase + rDepth * depth + (inActive ? rActive : 0)) * rs,
        inkFar - inkSpan * depth - (inActive ? 0.14 : 0),
      );
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Wave: a waveform rolls through the rings: listening --------------------

void frameWave(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  // 0.76 base x 1.15: the undulation pulls the sphere inward, so wave read
  // ~15% smaller than the other lattice modes; scaled up to match them
  final radius = (size / 2) * 0.874;
  final pt = out.proj..set(t * 0.18, 0.38, cx, cy, 1);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);
  final rBase = o['rBase'] ?? 0.6;
  final rDepth = o['rDepth'] ?? 1.7;

  final rings = o['rings'] ?? 15;
  final lonDensity = o['lonDensity'] ?? 40;
  for (var ri = 0; ri <= rings; ri++) {
    final lat = -math.pi / 2 + (ri / rings) * math.pi;
    final cosLat = math.cos(lat);
    final sinLat = math.sin(lat);
    // two waves, different tempi: organic, never quite repeating
    final w = 0.62 * math.sin(t * 2.1 - ri * 0.52) + 0.38 * math.sin(t * 1.27 + ri * 0.83);
    final rr = radius * (0.88 + 0.105 * w);
    final lonCount = math.max(1, (cosLat.abs() * lonDensity).round());
    final crest = math.max(0.0, w);
    for (var lj = 0; lj < lonCount; lj++) {
      final lon = (lj / lonCount) * _tau;
      pt(cosLat * math.cos(lon) * rr, sinLat * rr, cosLat * math.sin(lon) * rr);
      final z = pt.pz;
      final depth = (z / radius + 1) / 2;
      out.dot(pt.px, pt.py, z, (rBase + rDepth * depth) * (1 + 0.4 * crest) * rs, 0.66 - 0.56 * depth - 0.1 * crest);
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Orbits: particles on tilted orbits: working ----------------------------
// No nucleus (the tuned preset runs coreless): just ghost paths and the
// particles doing the work.

void frameOrbits(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.82;
  final pt = out.proj..set(t * 0.12, 0.3, cx, cy, 1);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);

  final orbitN = o['orbitN'] ?? 12;
  final ghostN = o['ghostN'] ?? 40;
  final particles = o['particles'] ?? 3;
  final ghostR = o['ghostR'] ?? 0.9;
  final ghostA = o['ghostA'] ?? 0.5;
  final partR = o['partR'] ?? 1.2;
  final partRDepth = o['partRDepth'] ?? 1.6;

  // orbits: each a tilted circle, a ghost path + running particles
  for (var orb = 0; orb < orbitN; orb++) {
    final h1 = hashD(orb.toDouble(), 1.7);
    final h2 = hashD(orb.toDouble(), 5.2);
    final h3 = hashD(orb.toDouble(), 8.9);
    final ro = radius * (0.45 + 0.52 * h1);
    final th = h1 * _tau;
    final phi = math.acos(2 * h2 - 1);
    // orbit plane basis (u, v perpendicular to the normal n)
    final nx = math.sin(phi) * math.cos(th);
    final ny = math.cos(phi);
    final nz = math.sin(phi) * math.sin(th);
    var ux = -ny;
    var uy = nx;
    const uz = 0.0;
    final ul = math.max(1e-6, math.sqrt(ux * ux + uy * uy));
    ux /= ul;
    uy /= ul;
    final vx = ny * uz - nz * uy;
    final vy = nz * ux - nx * uz;
    final vz = nx * uy - ny * ux;
    final speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1);

    // ghost path
    for (var k = 0; k < ghostN; k++) {
      final a = (k / ghostN) * _tau;
      final ca = math.cos(a);
      final sa = math.sin(a);
      pt((ux * ca + vx * sa) * ro, (uy * ca + vy * sa) * ro, (uz * ca + vz * sa) * ro);
      final depth = (pt.pz / ro + 1) / 2;
      out.dot(pt.px, pt.py, pt.pz, ghostR * rs, 0.72, ghostA * (0.4 + 0.6 * depth));
    }
    // the particles doing the work
    for (var m = 0; m < particles; m++) {
      final a = t * speed + (m / particles) * _tau + h2 * 6;
      final ca = math.cos(a);
      final sa = math.sin(a);
      pt((ux * ca + vx * sa) * ro, (uy * ca + vy * sa) * ro, (uz * ca + vz * sa) * ro);
      final depth = (pt.pz / ro + 1) / 2;
      out.dot(pt.px, pt.py, pt.pz, (partR + partRDepth * depth) * rs, 0.3 - 0.22 * depth);
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Web: a constellation wires itself: connecting --------------------------
// Nodes drift on the sphere under slow value noise; any pair closer than `thr`
// grows an edge, and bright packets run along randomly re-picked node pairs.

void frameWeb(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.8 * (o['spread'] ?? 1);
  // the projector carries the radius as its scale, so node vectors stay
  // unit-length and distances below are in unit-sphere space
  final pt = out.proj..set(t * 0.12, 0.32, cx, cy, radius);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);

  final nodeN = (o['nodeN'] ?? 30).toInt();
  final thr = o['thr'] ?? 0.72;
  final nodeR = o['nodeR'] ?? 1.4;
  final nodeRDepth = o['nodeRDepth'] ?? 1.8;
  final lineW = math.max(0.6, (o['lineW'] ?? 0.8) * rs);

  // nodes (unit x, y, z) then their projection (px, py, pz), 6 per node:
  // fib lattice + slow noise wander, renormalised to the surface
  final nodes = out.scratchOf(nodeN * 6);
  final d = out.v3;
  for (var i = 0; i < nodeN; i++) {
    fibDir(i, nodeN, d);
    final x = d[0] + 0.3 * (vnoise(i * 0.31 + 9, t * 0.24) - 0.5) * 2;
    final y = d[1] + 0.3 * (vnoise(i * 0.53 + 27, t * 0.21) - 0.5) * 2;
    final z = d[2] + 0.3 * (vnoise(i * 0.77 + 55, t * 0.27) - 0.5) * 2;
    final l = math.sqrt(x * x + y * y + z * z);
    final o6 = i * 6;
    nodes[o6] = x / l;
    nodes[o6 + 1] = y / l;
    nodes[o6 + 2] = z / l;
    pt(nodes[o6], nodes[o6 + 1], nodes[o6 + 2]);
    nodes[o6 + 3] = pt.px;
    nodes[o6 + 4] = pt.py;
    nodes[o6 + 5] = pt.pz;
  }

  // edges between close neighbours, alpha by proximity + depth
  for (var i = 0; i < nodeN; i++) {
    final a6 = i * 6;
    for (var j = i + 1; j < nodeN; j++) {
      final b6 = j * 6;
      final dx = nodes[a6] - nodes[b6];
      final dy = nodes[a6 + 1] - nodes[b6 + 1];
      final dz = nodes[a6 + 2] - nodes[b6 + 2];
      final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist >= thr) continue;
      final depth = ((nodes[a6 + 5] + nodes[b6 + 5]) / 2 + 1) / 2;
      out.line(
        nodes[a6 + 3],
        nodes[a6 + 4],
        nodes[b6 + 3],
        nodes[b6 + 4],
        0.42,
        (1 - dist / thr) * (0.3 + 0.55 * depth),
        lineW,
      );
    }
  }

  for (var i = 0; i < nodeN; i++) {
    final o6 = i * 6;
    final z = nodes[o6 + 5];
    final depth = (z + 1) / 2;
    final pulse = 1 + 0.25 * math.sin(t * 1.4 + i * 2.7);
    out.dot(nodes[o6 + 3], nodes[o6 + 4], z, (nodeR + nodeRDepth * depth) * pulse * rs, 0.55 - 0.45 * depth);
  }

  // signals: bright packets running between paired nodes
  final signals = o['signals'] ?? 5;
  for (var s = 0; s < signals; s++) {
    final seg = (t * 0.55 + s * 7.31).floorToDouble();
    final a = (hashD(seg, s * 3.1 + 1.7) * nodeN).floor();
    final b = (hashD(seg, s * 5.7 + 4.2) * nodeN).floor();
    if (a == b) continue;
    final f = frac(t * 0.55 + s * 7.31);
    final x = lerp(nodes[a * 6], nodes[b * 6], f);
    final y = lerp(nodes[a * 6 + 1], nodes[b * 6 + 1], f);
    final z = lerp(nodes[a * 6 + 2], nodes[b * 6 + 2], f);
    final l = math.max(1e-6, math.sqrt(x * x + y * y + z * z));
    pt(x / l, y / l, z / l);
    final depth = (pt.pz + 1) / 2;
    out.dot(pt.px, pt.py, pt.pz, (nodeR * 1.5 + nodeRDepth * depth) * rs, 0.05, 0.5 + 0.5 * depth);
  }

  out.finalize(o['rMin'] ?? 0.3);
}

/// The faint ghost sphere behind braid and ribbon.
void _ghostSphere(OrbFrame out, Projector pt, int ghostN, double radius, double rs) {
  final d = out.v3;
  for (var i = 0; i < ghostN; i++) {
    fibDir(i, ghostN, d);
    pt(d[0] * radius, d[1] * radius, d[2] * radius);
    final depth = (pt.pz / radius + 1) / 2;
    out.dot(pt.px, pt.py, pt.pz, 0.8 * rs, 0.78, 0.1 + 0.22 * depth);
  }
}

// --- Braid: three strands plait around the sphere: weaving ------------------
// Each strand runs pole to pole on a helix, and a radial breathing term makes
// them trade places, reading as the over/under of a plait.

void frameBraid(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.76;
  final pt = out.proj..set(t * 0.4, 0.3, cx, cy, 1);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);
  final rBase = o['rBase'] ?? 1.2;
  final rDepth = o['rDepth'] ?? 1.8;

  _ghostSphere(out, pt, (o['ghostN'] ?? 150).toInt(), radius, rs);

  final strandN = o['strandN'] ?? 52;
  final turns = o['turns'] ?? 3;
  for (var s = 0; s < 3; s++) {
    final phase = (s / 3) * _tau;
    for (var i = 0; i < strandN; i++) {
      // u walks pole to pole; the frac() drift slides the whole strand along
      final u = (frac(i / strandN + t * 0.045) * 2 - 1) * 0.96;
      final surf = math.sqrt(math.max(0.0, 1 - u * u));
      final endFade = math.min(1.0, (1 - u.abs()) / 0.1);
      final a = u * math.pi * turns + phase;
      // radial breathing: strands trade places, the over/under of a plait
      final weave = 1 + 0.075 * math.sin(u * math.pi * turns * 2 + phase * 2 + t * 0.8);
      final rr = surf * radius * weave;
      pt(math.cos(a) * rr, u * radius * weave, math.sin(a) * rr);
      final depth = (pt.pz / radius + 1) / 2;
      out.dot(pt.px, pt.py, pt.pz, (rBase + rDepth * depth) * rs, 0.55 - 0.45 * depth, endFade * (0.45 + 0.55 * depth));
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Ribbon: an undulating sash of parallel strands rides a great circle ----
// "composing". The tuned preset freezes the 3D tumble (spin 0), leaving the
// traveling undulation on a fixed band.
//
// The same builder also drives "breathing" (ring) via the `faceOn` flag: a
// face-on circle whose radius, not its out-of-plane offset, undulates, so it
// reads as a ring slowly morphing rather than a sash in orbit.

void frameRibbon(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final cx = size / 2;
  final cy = size / 2;
  final radius = (size / 2) * 0.78;
  // spin scales the 3D tumble; spin=0 freezes the band's orientation,
  // leaving only the traveling undulation
  final spin = o['spin'] ?? 1;
  const camTilt = 0.3;
  final pt = out.proj..set(t * 0.1 * spin, camTilt, cx, cy, 1);
  final rs = radiusScale(size, o['rsPow'] ?? 0.6);
  final faceOn = (o['faceOn'] ?? 0) != 0;

  _ghostSphere(out, pt, (o['ghostN'] ?? 150).toInt(), radius, rs);

  // The band plane, precessing (frozen when spin=0). The projection squashes
  // the band's great circle vertically by cos(ta + camTilt); face-on sets
  // ta = -camTilt so that term is 1 and the band reads as a true circle
  // rather than ribbon's tilted ellipse.
  final ya = t * 0.24 * spin;
  final ta = faceOn ? -camTilt : 0.55 + 0.3 * math.sin(t * 0.18) * spin;
  final ux = math.cos(ya);
  const uy = 0.0;
  final uz = math.sin(ya);
  final vx = -uz * math.sin(ta);
  final vy = math.cos(ta);
  final vz = ux * math.sin(ta);
  // plane normal n = u x v
  final nx = uy * vz - uz * vy;
  final ny = uz * vx - ux * vz;
  final nz = ux * vy - uy * vx;

  // Radial lobes swell past R, so pull the base radius in by (most of) the
  // wobble amplitude. The silhouette then stays inside the frame however far
  // the deformation is pushed, while lobes keep getting deeper relative to the
  // mean radius.
  final wobMul = o['wobMul'] ?? 1;
  final wobAmp = 0.23 * wobMul;
  final baseR = faceOn ? radius / (1 + 0.85 * wobAmp) : radius;
  final rBase = o['rBase'] ?? 1.1;
  final rDepth = o['rDepth'] ?? 1.7;

  final baseLanes = o['lanes'] ?? 5;
  final segs = o['segs'] ?? 88;
  final lanes = math.max(1, (baseLanes * (o['bandMul'] ?? 1)).round());
  for (var w = 0; w < lanes; w++) {
    final laneOff = (w - (lanes - 1) / 2) * 0.075;
    final edge = (w - (lanes - 1) / 2).abs() / math.max(1, (lanes - 1) / 2);
    for (var k = 0; k < segs; k++) {
      final a = (k / segs) * _tau;
      // the undulation: two traveling waves along the band; wobMul scales
      // the deformation, 0 is a clean band
      final wob = (0.16 * math.sin(a * 3 - t * 1.7 + w * 0.22) + 0.07 * math.sin(a * 5 + t * 1.1)) * wobMul;
      // A normal-direction wobble is cancelled by the re-normalisation below:
      // the point lands back on the sphere, so the silhouette is pinned at R
      // and the deformation can only ever pull dots inward. Face-on instead
      // modulates the in-plane RADIUS, so lobes genuinely swell outward and
      // pinch inward. Ribbon keeps the original out-of-plane sash wobble.
      final radial = faceOn ? 1 + wob : 1.0;
      final off = faceOn ? laneOff : laneOff + wob;
      final ca = math.cos(a);
      final sa = math.sin(a);
      final x = ux * ca + vx * sa + nx * off;
      final y = uy * ca + vy * sa + ny * off;
      final z = uz * ca + vz * sa + nz * off;
      final l = math.sqrt(x * x + y * y + z * z);
      final rr = baseR * radial;
      pt((x / l) * rr, (y / l) * rr, (z / l) * rr);
      final depth = (pt.pz / radius + 1) / 2;
      out.dot(
        pt.px,
        pt.py,
        pt.pz,
        (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
        0.52 - 0.44 * depth + 0.18 * edge,
        0.4 + 0.6 * depth,
      );
    }
  }
  out.finalize(o['rMin'] ?? 0.3);
}

// --- Morph: a dotted outline cycling circle, triangle, square: shaping ------
// Each shape is a continuous closed path parameterised by arc length
// (top-centre start, clockwise). Every frame the engine blends the two
// neighbouring paths, then lays the dots EVENLY along the blended outline, so
// spacing stays uniform at every instant of the morph.
//
// The author tuned this state in inkform through a blur + threshold "goo"
// filter but ships plain circles (filters are not portable); the dot geometry
// is identical either way, so the radius is not "corrected" for it here either.

/// A closed polyline walked by arc length (`polyPath`).
final class _PolyPath {
  _PolyPath(this.verts) {
    for (var i = 0; i < verts.length; i++) {
      final a = verts[i];
      final b = verts[(i + 1) % verts.length];
      final dx = b.$1 - a.$1;
      final dy = b.$2 - a.$2;
      final l = math.sqrt(dx * dx + dy * dy);
      lengths.add(l);
      total += l;
    }
  }

  final List<(double, double)> verts;
  final List<double> lengths = [];
  double total = 0;

  /// Point at arc fraction [f], written to `out[0..1]`.
  void at(double f, Float64List out) {
    final v = verts.length;
    var target = f * total;
    var i = 0;
    while (target > lengths[i] && i < v - 1) {
      target -= lengths[i];
      i++;
    }
    final a = verts[i];
    final b = verts[(i + 1) % v];
    final ff = lengths[i] != 0 ? math.min(1.0, target / lengths[i]) : 0.0;
    out[0] = a.$1 + (b.$1 - a.$1) * ff;
    out[1] = a.$2 + (b.$2 - a.$2) * ff;
  }
}

void _circle(double f, Float64List out) {
  final a = -math.pi / 2 + f * _tau;
  out[0] = math.cos(a) * 0.24;
  out[1] = math.sin(a) * 0.24;
}

final _triangle = _PolyPath(const [(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)]);
// 5-vertex walk so the path STARTS at top-centre like the other shapes
final _square = _PolyPath(const [(0.0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)]);
final List<void Function(double, Float64List)> _cycle = [_circle, _triangle.at, _square.at];

double _smoothE(double x) => x * x * (3 - 2 * x);

// low floor keeps sparse outlines possible while never degenerating
int _morphN(double d) => math.max(6, (34 * d).round());

const _hold = 1.4;
const _morph = 0.9;
const _seg = _hold + _morph;
const _samples = 160;

final _pa = Float64List(2);
final _pb = Float64List(2);

void frameMorph(OrbFrame out, double size, double t, ModeOpts o) {
  out.begin();
  final k = _cycle.length;
  final tc = t % (_seg * k);
  // `shape` 0 / 1 / 2 holds one outline instead of cycling; anything else
  // keeps the tuned circle, triangle, square loop
  final shape = o['shape'];
  final held = shape != null && shape >= 0 && shape < k ? shape.floor() : -1;
  final ki = held >= 0 ? held : (tc / _seg).floor();
  final local = held >= 0 ? t % _seg : tc - ki * _seg;
  final m = held >= 0 ? 0.0 : (local > _hold ? _smoothE((local - _hold) / _morph) : 0.0);
  final sprd = o['spread'] ?? 1;

  // blend the two shape PATHS at m, then measure the blended outline
  final pathA = _cycle[ki];
  final pathB = held >= 0 ? pathA : _cycle[(ki + 1) % k];
  // pts (x, y) then segment lengths, in one scratch buffer
  final buf = out.scratchOf(_samples * 3);
  for (var i = 0; i < _samples; i++) {
    final f = i / _samples;
    pathA(f, _pa);
    pathB(f, _pb);
    buf[i * 2] = (_pa[0] + (_pb[0] - _pa[0]) * m) * sprd;
    buf[i * 2 + 1] = (_pa[1] + (_pb[1] - _pa[1]) * m) * sprd;
  }
  const lens = _samples * 2;
  var total = 0.0;
  for (var i = 0; i < _samples; i++) {
    final j = (i + 1) % _samples;
    final dx = buf[j * 2] - buf[i * 2];
    final dy = buf[j * 2 + 1] - buf[i * 2 + 1];
    final l = math.sqrt(dx * dx + dy * dy);
    buf[lens + i] = l;
    total += l;
  }

  // dot radius depends ONLY on rDot (the size knob); the count sets the gaps.
  // Formed shapes breathe a little (uniform pulse).
  final n = _morphN(o['iconD'] ?? 1);
  final re = (o['rDot'] ?? 0.021) * 1.35 * sprd;
  final pulse = 1 + 0.02 * math.sin(local * 3.1);

  final c2 = size / 2;
  var seg = 0;
  var acc = 0.0;
  for (var k2 = 0; k2 < n; k2++) {
    final target = (k2 / n) * total;
    while (acc + buf[lens + seg] < target && seg < _samples - 1) {
      acc += buf[lens + seg];
      seg++;
    }
    final nx = (seg + 1) % _samples;
    final segL = buf[lens + seg];
    final f = segL != 0 ? math.min(1.0, (target - acc) / segL) : 0.0;
    final x = (buf[seg * 2] + (buf[nx * 2] - buf[seg * 2]) * f) * pulse;
    final y = (buf[seg * 2 + 1] + (buf[nx * 2 + 1] - buf[seg * 2 + 1]) * f) * pulse;
    out.dot(c2 + x * size, c2 + y * size, 0, math.max(0.35, re * size), 0.1);
  }
  out.finalize(o['rMin'] ?? 0.3);
}
