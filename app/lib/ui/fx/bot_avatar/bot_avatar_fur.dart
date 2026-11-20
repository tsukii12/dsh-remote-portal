// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The pile for a form, made once per outline, texture size and light: the
   author's furJob, ported pass for pass. A plush's fine strands lie in one
   flow — combed from a parting behind the top of the head and falling —
   gathered into locks, the locks into tufts; the locks are mounds on the
   curved body, lit by the same key and fill as the body; over them strands,
   single hairs and guard hairs; past the silhouette tufts of hairs and a
   haze. Kept as alpha films (the pile's dark and light parts, the fibres'
   own light) over a square wider than the body, and the halo (mask, haze,
   core) over the body's square. The hairs are kept as stroke lists: the
   isolate has no canvas, so the UI side strokes them over the films. */

import 'dart:math' as math;
import 'dart:typed_data';

import 'bot_avatar_form.dart';
import 'bot_avatar_material.dart';

/// The pile's style.
class FurStyle {
  const FurStyle({
    this.length = 1,
    this.density = 1.6,
    this.fuzz = 0.9,
    this.clumps = 0.4,
    this.curl = 0.7,
    this.gravity = 0.9,
  });

  /// 0.3–2.5, length of the pile
  final double length;

  /// 0.3–2, how many fibres
  final double density;

  /// 0–1, the haze of hairs at the silhouette
  final double fuzz;

  /// 0–1, how much the fibres gather into tufts
  final double clumps;

  /// 0–1, straight to wavy
  final double curl;

  /// 0–1, how much it hangs
  final double gravity;

  String get id => [length, density, fuzz, clumps, curl, gravity].map((v) => v.toStringAsFixed(2)).join(',');

  @override
  bool operator ==(Object other) => other is FurStyle && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The lights the pile's own fibres are baked for.
class FurLights {
  const FurLights(this.bx, this.by, this.front);

  /// the back light's direction on screen (unit, y down)
  final double bx;
  final double by;

  /// how far round to the front the key sits (radians)
  final double front;

  String get id => '${_jsRound(math.atan2(by, bx) / (math.pi / 36))}|${_jsRound(front / (math.pi / 90))}';

  factory FurLights.stock(double lx, double ly) {
    final (bx, by) = backFromKey(lx, ly);
    return FurLights(bx, by, keyEl);
  }
}

/// The pile's resolution for a cap drawn `capPx` device pixels across.
int furTier(double capPx) => capPx <= 200 ? 192 : (capPx <= 360 ? 320 : 512);

/// How far past the body's square the pile's film reaches, and its span.
const filmM = 20.0;
const filmSpan = span + 2 * filmM;

/// How high the pile's tops stand over its hollows, per unit of its length.
const pileH = 0.5;

/// The shade the film's dark part is encoded for.
const gapRef = 0.36;

/* the locks */
const _lockCover = 3.2;
const _lockDense = 1 / 2.56;
final _lockTaper = 1 / ((2 / 3) * math.sqrt(1 / 3));
const _lockPart = 0.6;
/* the light in the pile */
const _pileAmb = 0.07;
const _pileFill = 0.14;
const _pileWrap = 0.3;
const _pileShadow = 0.6;
const _pileAo = 0.35;
const _pileRoot = 0.3;
const _pileKk = 0.3;
const _pileGain = 1.26;
const _pileLift = 1.6;
const _pileBias = 0.045;
const _pileStand = 0.5;
final _pileCos = math.cos(_pileStand), _pileSin = math.sin(_pileStand);
const _pileCrease = 0.22;
const _pileLit = 1.1;
const _tipTop = 1.625;
/* the fine strands */
const _strandTaper = 0.5;
const _strandRise = 0.9;
const _strandShort = 0.7;
const _strandCastH = 0.15;
const _strandCast = 1.3;
/* the halo */
const _haloA = 0.8;
const _haloStreak = 0.3;
const _haloHair = 0.8;
const _haloLift = 0.7;

/// How far in from the outline the halo's band reaches, in design units.
const haloCore = 1.2;
const _furMid = 128;

/// Which film a stroke goes on.
enum FurLayer { dark, light, glint, back, mask }

/// Hairs stroked over a film: path commands (0 move x y, 1 line x y, 2 quad
/// cx cy x y) in the body square's pixels, a width, an alpha, and whether
/// they cut the film (destination-out) rather than add to it.
class FurStroke {
  const FurStroke(this.layer, this.cmds, this.width, this.alpha, {this.erase = false});
  final FurLayer layer;
  final Float32List cmds;
  final double width;
  final double alpha;
  final bool erase;
}

/// What the bake hands the UI side: alpha planes and hairs.
class FurBake {
  FurBake({
    required this.r,
    required this.rb,
    required this.dark,
    required this.light,
    required this.glint,
    required this.back,
    required this.backSoft,
    required this.mask,
    required this.haze,
    required this.core,
    required this.soft,
    required this.strokes,
  });

  /// the halo's side (the body square) and the films' side (the wider square)
  final int r;
  final int rb;
  final Uint8List dark;
  final Uint8List light;
  final Uint8List glint;
  final Uint8List back;
  final Uint8List backSoft;
  final Uint8List mask;
  final Uint8List haze;
  final Uint8List core;

  /// the outline with a plain soft edge, no fringe: fabric's inner slices
  final Uint8List soft;
  final List<FurStroke> strokes;
}

/// What the bake needs from the form (all sendable to an isolate).
class FurJob {
  const FurJob({
    required this.n,
    required this.sd,
    required this.h,
    required this.r,
    required this.lx,
    required this.ly,
    required this.style,
    required this.lights,
  });

  final int n;
  final Float32List sd;
  final Float32List h;
  final int r;
  final double lx;
  final double ly;
  final FurStyle style;
  final FurLights lights;
}

int _jsRound(double v) => (v + 0.5).floor();
int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

/* a stable white noise, so every avatar of a type wears the same pile */
double _hash2(int x, int y) {
  var h = (x * 374761393 + y * 668265263) & 0xFFFFFFFF;
  h = _imul(h ^ (h >> 13), 1274126177);
  return ((h ^ (h >> 16)) & 0xFFFFFFFF) / 4294967296;
}

double _hash3(int x, int y, int z) {
  var h = (x * 374761393 + y * 668265263 + z * 1274126177) & 0xFFFFFFFF;
  h = _imul(h ^ (h >> 13), 1274126177);
  return ((h ^ (h >> 16)) & 0xFFFFFFFF) / 4294967296;
}

/* a small deterministic generator, so a type's pile is the same every bake */
double Function() _rng(int seed) {
  var a = seed & 0xFFFFFFFF;
  return () {
    a = (a + 0x6d2b79f5) & 0xFFFFFFFF;
    var t = _imul(a ^ (a >> 15), 1 | a);
    t = ((t + _imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296;
  };
}

/* smooth value noise over the design box */
double Function(double, double) _valueNoise(double scale, int seed) {
  return (x, y) {
    final fx = x / scale, fy = y / scale;
    final x0 = fx.floor(), y0 = fy.floor();
    final tx = fx - x0, ty = fy - y0;
    final sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
    double h(int i, int j) => _hash2(i + seed * 131, j - seed * 71);
    final a = h(x0, y0), b = h(x0 + 1, y0), c = h(x0, y0 + 1), d = h(x0 + 1, y0 + 1);
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy;
  };
}

/* the same in three dimensions: a solid texture read on the body's surface */
double Function(double, double, double) _valueNoise3(double scale, int seed) {
  return (x, y, z) {
    final fx = x / scale, fy = y / scale, fz = z / scale;
    final x0 = fx.floor(), y0 = fy.floor(), z0 = fz.floor();
    final tx = fx - x0, ty = fy - y0, tz = fz - z0;
    final sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty), sz = tz * tz * (3 - 2 * tz);
    double h(int i, int j, int k) => _hash3(i + seed * 131, j - seed * 71, k + seed * 17);
    double lerp(double a, double b, double t) => a + (b - a) * t;
    final c00 = lerp(h(x0, y0, z0), h(x0 + 1, y0, z0), sx), c10 = lerp(h(x0, y0 + 1, z0), h(x0 + 1, y0 + 1, z0), sx);
    final c01 = lerp(h(x0, y0, z0 + 1), h(x0 + 1, y0, z0 + 1), sx);
    final c11 = lerp(h(x0, y0 + 1, z0 + 1), h(x0 + 1, y0 + 1, z0 + 1), sx);
    return lerp(lerp(c00, c10, sy), lerp(c01, c11, sy), sz);
  };
}

int _a8(double v) => (255 * v).round().clamp(0, 255);

/// Bakes the pile (the author's furJob, steps run back to back).
FurBake bakeFur(FurJob job) {
  final n = job.n, r = job.r, style = job.style, lights = job.lights;
  final px = r / span;
  double sdAt(double x, double y) => bilerp(job.sd, n, ((x + pad) / span) * n - 0.5, ((y + pad) / span) * n - 0.5);
  double hAt(double x, double y) => bilerp(job.h, n, ((x + pad) / span) * n - 0.5, ((y + pad) / span) * n - 0.5);
  /* the pile's grey is made over a wider square than the body's */
  const o = pad + filmM;
  final rb = _jsRound((r * filmSpan) / span);
  final rand = _rng(n * 7919 + 17);
  final lean = _valueNoise(3.4, 21), tone = _valueNoise(22, 9);
  final swirl = _valueNoise(13, 57);
  final kLen = style.length, kDen = style.density, fuzz = style.fuzz, clumps = style.clumps, curl = style.curl;
  final gravity = style.gravity;
  var ll = math.sqrt(job.lx * job.lx + job.ly * job.ly);
  if (ll == 0) ll = 1;
  final lX = job.lx / ll, lY = job.ly / ll;
  final uf = (lX, lY, 0.0);
  const vf = (0.0, 0.0, 1.0), df = (0.0, 1.0, 0.0);
  final k3 = fabricKey(uf, vf, lights.front), b3 = fabricBack((lights.bx, lights.by, 0), vf);
  final h3 = norm3((k3.$1, k3.$2, k3.$3 + 1));
  final f3 = norm3((
    -0.55 * uf.$1 + 0.85 * vf.$1 + 0.15 * df.$1,
    -0.55 * uf.$2 + 0.85 * vf.$2 + 0.15 * df.$2,
    -0.55 * uf.$3 + 0.85 * vf.$3 + 0.15 * df.$3,
  ));

  /* the parting: over the top of the head, behind it */
  var crownY = 12.0;
  for (var y = -pad; y < 60; y += 0.5) {
    if (sdAt(50, y) > 0.5) {
      crownY = y + 1;
      break;
    }
  }
  crownY -= 18;
  const crownX = 50.0;
  (double, double) outward(double x, double y) {
    const e = 0.8;
    final ox = sdAt(x - e, y) - sdAt(x + e, y), oy = sdAt(x, y - e) - sdAt(x, y + e);
    var ol = math.sqrt(ox * ox + oy * oy);
    if (ol == 0) ol = 1;
    return (ox / ol, oy / ol);
  }

  /* the flow: away from the parting, and falling; near the edge out over the
     outline where the edge faces sideways or down; each tuft its own way */
  (double, double) flow(double x, double y) {
    var rx = x - crownX, ry = y - crownY;
    var rl = math.sqrt(rx * rx + ry * ry);
    if (rl == 0) rl = 1;
    rx /= rl;
    ry /= rl;
    final fall = gravity * (1 - 0.6 * math.exp(-rl / 8));
    var dx = rx * (1 - 0.8 * fall), dy = ry * (1 - 0.8 * fall) + fall;
    final d0 = sdAt(x, y);
    if (d0 < 5) {
      final (ox, oy) = outward(x, y);
      final up = math.max(0.0, -oy);
      final ex = ox * (1 - gravity * up), ey = oy * (1 - gravity * up) + 1.2 * gravity;
      final w = (1 - d0 / 5).clamp(0.0, 1.0) * 0.75;
      dx = dx * (1 - w) + ex * w * 1.6;
      dy = dy * (1 - w) + ey * w * 1.6;
    }
    final a = (lean(x, y) - 0.5) * (0.5 + 1.6 * curl) + (swirl(x, y) - 0.5) * (0.6 + curl);
    final ca = math.cos(a), sa = math.sin(a);
    final qx = dx * ca - dy * sa, qy = dx * sa + dy * ca;
    var m = math.sqrt(qx * qx + qy * qy);
    if (m == 0) m = 1;
    return (qx / m, qy / m);
  }

  (double, double, double) slopeAt(double x, double y) {
    const e = 0.6;
    final gx = (hAt(x + e, y) - hAt(x - e, y)) / (2 * e), gy = (hAt(x, y + e) - hAt(x, y - e)) / (2 * e);
    final m = math.sqrt(gx * gx + gy * gy);
    return (m > 1e-6 ? -gx / m : 0, m > 1e-6 ? -gy / m : 0, m / math.sqrt(1 + m * m));
  }

  /* 1. the flow on a coarse grid, read bilinearly by everything after */
  const g = 112;
  const gu = filmSpan / g;
  final flowX = Float32List(g * g), flowY = Float32List(g * g), tiltG = Float32List(g * g);
  final nXg = Float32List(g * g), nYg = Float32List(g * g), nZg = Float32List(g * g);
  final onG = Float32List(g * g);
  final pfX = Float32List(g * g), pfY = Float32List(g * g), foreG = Float32List(g * g);
  final hG = Float32List(g * g), creaseG = Float32List(g * g);
  final toneG = Float32List(g * g);
  for (var j = 0, i = 0; j < g; j++) {
    for (var x = 0; x < g; x++, i++) {
      final xX = (x + 0.5) * gu - o, yY = (j + 0.5) * gu - o;
      var (fx, fy) = flow(xX, yY);
      final (dx, dy, tiltS) = slopeAt(xX, yY);
      /* a hanging pile lies down its slope only as far as gravity lets it */
      final w = tiltS * (0.25 + 0.5 * (1 - gravity)) * (1 - gravity * math.max(0.0, -dy));
      fx = fx * (1 - w) + dx * w;
      fy = fy * (1 - w) + (dy + 0.35 * gravity) * w;
      var fl = math.sqrt(fx * fx + fy * fy);
      if (fl == 0) fl = 1;
      fx /= fl;
      fy /= fl;
      flowX[i] = fx;
      flowY[i] = fy;
      tiltG[i] = tiltS;
      var nx = dx * tiltS, ny = dy * tiltS, nz = math.sqrt(math.max(0, 1 - tiltS * tiltS));
      final d0 = sdAt(xX, yY);
      if (d0 < 2) {
        final (ox, oy) = outward(xX, yY);
        final w2 = d0 >= 0 ? 0.7 * (1 - d0 / 2) : math.min(1.0, 0.7 - 0.2 * d0);
        nx += w2 * (ox - nx);
        ny += w2 * (oy - ny);
        nz -= w2 * nz;
        var nl = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl == 0) nl = 1;
        nx /= nl;
        ny /= nl;
        nz /= nl;
      }
      nXg[i] = nx;
      nYg[i] = ny;
      nZg[i] = nz;
      onG[i] = smoothstep(-3.5, -1.5, d0);
      toneG[i] = tone(xX, yY);
      hG[i] = d0 > 0 ? hAt(xX, yY) : 0;
      /* the flow as a direction on the surface, seen foreshortened, raised out
         of it at the pile's angle */
      final s = math.sqrt(nx * nx + ny * ny), gx = s > 1e-4 ? nx / s : 0.0, gy = s > 1e-4 ? ny / s : 0.0;
      final a = fx * gx + fy * gy, k = (1 - math.max(0.0, nz)) * a;
      var qx = _pileCos * (fx - k * gx) + _pileSin * s * gx, qy = _pileCos * (fy - k * gy) + _pileSin * s * gy;
      final att = smoothstep(-0.5, 1.5, d0);
      qx = fx + (qx - fx) * att;
      qy = fy + (qy - fy) * att;
      var ql = math.sqrt(qx * qx + qy * qy);
      if (ql == 0) ql = 1;
      pfX[i] = qx / ql;
      pfY[i] = qy / ql;
      foreG[i] = 1 + (math.min(1.0, ql) - 1) * att;
    }
  }
  {
    /* the crease: the body's height under a wide average of it, and the
       underside, by how far the surface faces the floor */
    final tmp = Float32List(g * g), avg = Float32List.fromList(hG);
    for (var pass = 0; pass < 3; pass++) {
      for (var y = 0, i = 0; y < g; y++) {
        for (var x = 0; x < g; x++, i++) {
          var acc = 0.0;
          for (var t = -2; t <= 2; t++) {
            acc += avg[y * g + (x + t).clamp(0, g - 1)];
          }
          tmp[i] = acc / 5;
        }
      }
      for (var y = 0, i = 0; y < g; y++) {
        for (var x = 0; x < g; x++, i++) {
          var acc = 0.0;
          for (var t = -2; t <= 2; t++) {
            acc += tmp[(y + t).clamp(0, g - 1) * g + x];
          }
          avg[i] = acc / 5;
        }
      }
    }
    for (var j = 0, i = 0; j < g; j++) {
      for (var x = 0; x < g; x++, i++) {
        final inside = smoothstep(0.2, 2, sdAt((x + 0.5) * gu - o, (j + 0.5) * gu - o));
        final valley = smoothstep(0.3, 3.5, avg[i] - hG[i]) * inside;
        final under = smoothstep(0.15, 0.85, nYg[i]) * (1 - nZg[i]);
        creaseG[i] = math.min(1.0, valley + 0.45 * under) * onG[i];
      }
    }
  }
  double gridAt(Float32List f, double xX, double yY) => bilerp(f, g, (xX + o) / gu - 0.5, (yY + o) / gu - 0.5);
  (double, double) dirAt(double xX, double yY) {
    final ux = gridAt(pfX, xX, yY), uy = gridAt(pfY, xX, yY);
    final ul = math.sqrt(ux * ux + uy * uy);
    return ul > 1e-4 ? (ux / ul, uy / ul) : (0, 1);
  }

  (double, double) freeDirAt(double xX, double yY) {
    final ux = gridAt(flowX, xX, yY), uy = gridAt(flowY, xX, yY);
    final ul = math.sqrt(ux * ux + uy * uy);
    return ul > 1e-4 ? (ux / ul, uy / ul) : (0, 1);
  }

  /* 2. the locks: tapering bundles lying along the flow, each its own mound
     on the body's curved surface; one height field with the index of the
     lock seen at each point */
  final rl = rb >> 1, pl = rl / filmSpan;
  final lock = Float32List(rl * rl), lockLit = Float32List(rl * rl);
  double lockAt(Float32List f, double xX, double yY) => bilerp(f, rl, (xX + o) * pl - 0.5, (yY + o) * pl - 0.5);
  final bump = _valueNoise(0.7 + 0.35 * kLen, 61), swell = _valueNoise(2.2 + 0.6 * kLen, 67);
  final tuftK = (0.2 + 0.5 * fuzz) * math.min(1.8, kLen);
  double tuftAt(double xX, double yY) {
    final v =
        0.3 * lockAt(lock, xX, yY).clamp(-1.6, 1.6) / 1.6 +
        0.25 * (bump(xX, yY) - 0.5) * 2.4 +
        0.45 * (swell(xX, yY) - 0.5) * 2.4;
    return tuftK * v.clamp(-1.0, 1.0);
  }

  final lockW = 0.8 + 0.45 * kLen;
  final lockWd = lockW * (0.65 + 0.4 * clumps), lockLd = 1.5 + 1.6 * kLen;
  final hMax = 0.32 * lockWd * (0.15 + 0.85 * clumps);
  final pileHt = Float32List(rb * rb)..fillRange(0, rb * rb, -0.25 * hMax);
  final own = Int32List(rb * rb)..fillRange(0, rb * rb, -1);
  const lp = 16;
  final cell = math.sqrt((0.6 * lockWd * lockLd) / _lockCover / _lockDense);
  final gn = (filmSpan / cell).ceil();
  final locks = Float32List(gn * gn * lp);
  var nLocks = 0;
  final stand0 = 0.45 - 0.2 * gravity;
  final tuftN = _valueNoise3(1.6 * lockLd, 79), sizeN = _valueNoise(9, 73);
  final tuftH = 1.5 * hMax * (0.25 + clumps);
  for (var gy = 0; gy < gn; gy++) {
    for (var gx = 0; gx < gn; gx++) {
      final xX = (gx + rand()) * cell - o, yY = (gy + rand()) * cell - o;
      final r1 = rand(), r2 = rand(), r3 = rand(), r4 = rand(), r5 = rand(), r6 = rand(), r7 = rand();
      var nx = gridAt(nXg, xX, yY), ny = gridAt(nYg, xX, yY), nz = gridAt(nZg, xX, yY);
      var nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl == 0) nl = 1;
      nx /= nl;
      ny /= nl;
      nz /= nl;
      final (fx, fy) = freeDirAt(xX, yY);
      final ja = (r1 - 0.5) * (0.2 + 0.45 * curl), cj = math.cos(ja), sj = math.sin(ja);
      final ux = fx * cj - fy * sj, uy = fx * sj + fy * cj;
      final a = ux * nx + uy * ny;
      var tx = ux - a * nx, ty = uy - a * ny, tz = -a * nz;
      var tl = math.sqrt(tx * tx + ty * ty + tz * tz);
      if (tl < 0.05) {
        tx = nz * nx;
        ty = nz * ny;
        tz = nz * nz - 1;
        tl = math.sqrt(tx * tx + ty * ty + tz * tz);
        if (tl == 0) tl = 1;
      }
      tx /= tl;
      ty /= tl;
      tz /= tl;
      var bx = ny * tz - nz * ty, by = nz * tx - nx * tz, bz = nx * ty - ny * tx;
      final st = stand0 + 0.2 * r2, cs = math.cos(st), sn = math.sin(st);
      final grow = 0.8 + 0.45 * sizeN(xX, yY);
      final wd = lockWd * grow * (0.8 + 0.4 * r3), ld = lockLd * grow * (0.75 + 0.5 * r4);
      var ax = (tx * cs + nx * sn) * ld * px, ay = (ty * cs + ny * sn) * ld * px;
      var la = math.sqrt(ax * ax + ay * ay);
      if (la < 1.5) {
        ax = ux;
        ay = uy;
        la = 1.5;
      } else {
        ax /= la;
        ay /= la;
      }
      var across = -bx * ay + by * ax;
      if (across < 0) {
        bx = -bx;
        by = -by;
        bz = -bz;
        across = -across;
      }
      final wa = math.max(0.6, 0.5 * wd * px * math.max(0.15, across));
      final seen = (la / (ld * px)) * (wa / (0.5 * wd * px));
      final tn = tuftN(xX, yY, hAt(xX, yY));
      if (r5 >
          (_lockDense / math.max(_lockDense, seen)) * (1 - _lockPart * clumps * (1 - smoothstep(0.25, 0.65, tn)))) {
        continue;
      }
      final b = nLocks++ * lp;
      locks[b] = (xX + o) * px;
      locks[b + 1] = (yY + o) * px;
      locks[b + 2] = ax;
      locks[b + 3] = ay;
      locks[b + 4] = la;
      locks[b + 5] = wa;
      locks[b + 6] = 0.1 * hMax * r6 + tuftH * tn;
      locks[b + 7] = (r7 - 0.5) * 1.2 * curl;
      locks[b + 8] = tx;
      locks[b + 9] = ty;
      locks[b + 10] = tz;
      locks[b + 11] = bx;
      locks[b + 12] = by;
      locks[b + 13] = bz;
      locks[b + 14] = ld;
      locks[b + 15] = wd;
    }
  }
  /* each lock into the height field: rising over its first quarter, sinking
     to half at the tip, rounded across, drawn to a point */
  double lockAlong(double s) => (s < 0.25 ? 4 * s : 1) * (1 - 0.5 * s);
  for (var k = 0; k < nLocks; k++) {
    final b = k * lp;
    final ox = locks[b], oy = locks[b + 1], ax = locks[b + 2], ay = locks[b + 3], la = locks[b + 4];
    final wa = locks[b + 5], z0 = locks[b + 6], bend = locks[b + 7];
    final ext = wa * (1 + bend.abs()) + 1, ex = ox + ax * la, ey = oy + ay * la;
    final xa = math.max(0, (math.min(ox, ex) - ext).floor()), xb = math.min(rb - 1, (math.max(ox, ex) + ext).ceil());
    final ya = math.max(0, (math.min(oy, ey) - ext).floor()), yb = math.min(rb - 1, (math.max(oy, ey) + ext).ceil());
    final iLa = 1 / la, iWa = 1 / wa;
    for (var y = ya; y <= yb; y++) {
      final dy = y + 0.5 - oy;
      for (var x = xa, i = y * rb + xa; x <= xb; x++, i++) {
        final dx = x + 0.5 - ox;
        final s = (dx * ax + dy * ay) * iLa;
        if (s <= 0 || s >= 1) continue;
        final w = _lockTaper * math.sqrt(s) * (1 - s);
        final v = (dy * ax - dx * ay) * iWa - bend * s * s;
        if (v >= w || v <= -w) continue;
        final q = v / w;
        final h = z0 + hMax * lockAlong(s) * (1 - q * q);
        if (h > pileHt[i]) {
          pileHt[i] = h;
          own[i] = k;
        }
      }
    }
  }
  /* the pile's height averaged over about a lock's width: the hollows */
  final pileB = Float32List(rb * rb);
  final rB = math.max(1, _jsRound(0.3 * lockWd * px));
  final line = Float32List(rb);
  void box(Float32List src, Float32List dst, int rr, int k, int stride) {
    final step = stride == 1 ? rb : 1, inv = 1 / (2 * rr + 1);
    double at(int t) => line[t < 0 ? 0 : (t >= rb ? rb - 1 : t)];
    final off = k * step;
    for (var t = 0; t < rb; t++) {
      line[t] = src[off + t * stride];
    }
    var acc = 0.0;
    for (var t = -rr; t <= rr; t++) {
      acc += at(t);
    }
    for (var t = 0; t < rb; t++) {
      dst[off + t * stride] = acc * inv;
      acc += at(t + rr + 1) - at(t - rr);
    }
  }

  for (var y = 0; y < rb; y++) {
    box(pileHt, pileB, rB, y, 1);
  }
  for (var y = 0; y < rb; y++) {
    box(pileB, pileB, rB, y, 1);
  }
  for (var x = 0; x < rb; x++) {
    box(pileB, pileB, rB, x, rb);
  }
  for (var x = 0; x < rb; x++) {
    box(pileB, pileB, rB, x, rb);
  }
  /* and the pile itself softened by a pixel */
  for (var y = 0; y < rb; y++) {
    box(pileHt, pileHt, 1, y, 1);
  }
  for (var x = 0; x < rb; x++) {
    box(pileHt, pileHt, 1, x, rb);
  }

  /* 3. the fleece: every pixel's fibres, lit */
  final darkA = Uint8List(rb * rb), lightA = Uint8List(rb * rb);
  final glintA = Uint8List(rb * rb), backA = Uint8List(rb * rb), softA = Uint8List(rb * rb);
  final white = Float32List(rb * rb);
  final fib = Float64List(11);
  void fibreLight(double xX, double yY, double ux, double uy, double stand) {
    final fx = ((xX + o) / gu - 0.5).clamp(0.0, g - 1.0), fy = ((yY + o) / gu - 0.5).clamp(0.0, g - 1.0);
    final x0 = math.min(g - 2, fx.toInt()), y0 = math.min(g - 2, fy.toInt());
    final u = fx - x0, v = fy - y0, j = y0 * g + x0;
    final w00 = (1 - u) * (1 - v), w10 = u * (1 - v), w01 = (1 - u) * v, w11 = u * v;
    double read(Float32List f) => f[j] * w00 + f[j + 1] * w10 + f[j + g] * w01 + f[j + g + 1] * w11;
    var nx = read(nXg), ny = read(nYg), nz = read(nZg);
    var nn = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nn == 0) nn = 1;
    nx /= nn;
    ny /= nn;
    nz /= nn;
    final nK = nx * k3.$1 + ny * k3.$2 + nz * k3.$3;
    fib[4] = nx;
    fib[5] = ny;
    fib[6] = nz;
    fib[7] = nK;
    fib[8] = read(creaseG);
    final on = read(onG);
    fib[9] = on;
    fib[10] = read(toneG);
    if (on <= 0) {
      fib[0] = fib[1] = fib[3] = 0;
      fib[2] = 0.7;
      return;
    }
    final key = smoothstep(-0.2, 0.5, nK);
    final along = ux * nx + uy * ny;
    var tx = ux - along * nx, ty = uy - along * ny, tz = -along * nz;
    final tl = math.sqrt(tx * tx + ty * ty + tz * tz);
    if (tl > 1e-3) {
      tx /= tl;
      ty /= tl;
      tz /= tl;
    } else {
      tx = 0;
      ty = 0;
      tz = 1;
    }
    final cs = math.cos(stand), sn = math.sin(stand);
    tx = tx * cs + nx * sn;
    ty = ty * cs + ny * sn;
    tz = tz * cs + nz * sn;
    /* Kajiya–Kay, two reflections as Marschner's */
    final tH = tx * h3.$1 + ty * h3.$2 + tz * h3.$3, nH = nx * h3.$1 + ny * h3.$2 + nz * h3.$3;
    final a1 = tH - 0.12 * nH, a2 = tH + 0.2 * nH;
    final b1 = math.max(0.0, 1 - a1 * a1), b2 = b1 * b1, b4 = b2 * b2, b8 = b4 * b4, b16 = b8 * b8;
    final c1 = math.max(0.0, 1 - a2 * a2), c2 = c1 * c1;
    fib[0] = key * (0.85 * b16 * b16 * b4 + 0.15 * c2 * c2);
    fib[0] *= (0.4 + 0.6 * (1 - smoothstep(0.35, 0.85, nK))) * on;
    final side = math.sqrt(math.max(0, 1 - tz * tz));
    final nb = nx * b3.$1 + ny * b3.$2 + nz * b3.$3;
    fib[1] =
        smoothstep(-0.3, 0.6, nb) * math.pow(1 - nz, 1.6) * (0.4 + 0.6 * side) * (1 - 0.6 * math.max(0.0, ny)) * on;
    fib[3] = smoothstep(-0.5, 0.75, nb) * math.pow(1 - nz, 0.85) * (1 - 0.6 * math.max(0.0, ny)) * on;
    fib[2] = key * on + 0.7 * (1 - on);
  }

  for (var y = 0, i = 0; y < rb; y++) {
    for (var x = 0; x < rb; x++, i++) {
      final h = _hash2(x + 911, y + 37);
      white[i] = h * h * h;
    }
  }
  const wMean = 0.25;
  final wSd = math.sqrt(1 / 7 - 1 / 16);
  final strandHalf = math.max(1, _jsRound((0.35 + 0.4 * kLen) * px));
  final strandW = <Float64List>[];
  final strandMean = Float64List(2 * strandHalf + 1), strandSd = Float64List(2 * strandHalf + 1);
  for (var l = 0; l <= 2 * strandHalf; l++) {
    final w = Float64List(l + 1);
    var m1 = 0.0, v2 = 0.0;
    for (var t = 0; t <= l; t++) {
      final tau = l > 0 ? t / l : 0.0, p = tau <= _strandShort ? 1.0 : (1 - tau) / (1 - _strandShort);
      w[t] = 1 - _strandTaper * tau;
      m1 += w[t] * p * wMean;
      v2 += w[t] * w[t] * (p / 7 - wMean * wMean * p * p);
    }
    strandW.add(w);
    strandMean[l] = m1;
    strandSd[l] = math.sqrt(math.max(1e-6, v2));
  }
  final strandK = 0.12 * (r >= 512 ? 1 : (r >= 320 ? 0.75 : 0.4)) * math.min(1.4, 0.55 + 0.35 * kDen);
  final reachSh = math.max(1.0, 1.5 * lockWd * px), nsh = _jsRound(reachSh).clamp(1, 5);
  final shX = Int32List(nsh), shY = Int32List(nsh), shD = Float64List(nsh);
  for (var t = 0; t < nsh; t++) {
    final d = ((t + 1) / nsh) * reachSh;
    shX[t] = _jsRound(lX * d);
    shY[t] = _jsRound(lY * d);
    shD[t] = math.sqrt(shX[t] * shX[t] + shY[t] * shY[t].toDouble()) / px;
  }
  final difLut = powLut(1.35), gamLut = powLut(1 / 2.2);
  double keyOn(double nk) {
    final q = (nk + _pileWrap) / (1 + _pileWrap);
    return q <= 0 ? 0 : (q >= 1 ? 1 : difLut[(q * powN).toInt()]);
  }

  final depthK = r >= 512 ? 1.0 : (r >= 320 ? 0.8 : 0.55);
  final seenL = Float64List(4);
  void lockSeen(int x, int y, double xX, double yY, int k) {
    if (k < 0) {
      final (ux, uy) = dirAt(xX, yY);
      seenL[0] = ux;
      seenL[1] = uy;
      seenL[2] = 0.5;
      seenL[3] = 0;
      return;
    }
    final b = k * lp;
    final ax = locks[b + 2], ay = locks[b + 3], la = locks[b + 4], wa = locks[b + 5], bend = locks[b + 7];
    final dx = x + 0.5 - locks[b], dy = y + 0.5 - locks[b + 1];
    final s = ((dx * ax + dy * ay) / la).clamp(0.005, 0.995);
    final ss = math.sqrt(s), w = _lockTaper * ss * (1 - s), dw = _lockTaper * ((0.5 * (1 - s)) / ss - ss);
    final q = (((dy * ax - dx * ay) / wa - bend * s * s) / w).clamp(-1.0, 1.0);
    final sl = (q * dw + 2 * bend * s).clamp(-1.2, 1.2);
    final ux = la * ax - sl * wa * ay, uy = la * ay + sl * wa * ax;
    var ul = math.sqrt(ux * ux + uy * uy);
    if (ul == 0) ul = 1;
    seenL[0] = ux / ul;
    seenL[1] = uy / ul;
    seenL[2] = s;
    seenL[3] = lockAlong(s) * (1 - q * q);
  }

  /* the fine strands first, into a buffer of their own */
  final strandBuf = Float32List(rb * rb);
  for (var y = 0; y < rb; y++) {
    final yY = (y + 0.5) / px - o;
    for (var x = 0, i = y * rb; x < rb; x++, i++) {
      final xX = (x + 0.5) / px - o;
      lockSeen(x, y, xX, yY, own[i]);
      final ux = seenL[0], uy = seenL[1];
      final gx = ((xX + o) / gu - 0.5).clamp(0.0, g - 1.0), gy = ((yY + o) / gu - 0.5).clamp(0.0, g - 1.0);
      final gx0 = math.min(g - 2, gx.toInt()), gy0 = math.min(g - 2, gy.toInt());
      final gtx = gx - gx0, gty = gy - gy0, gj = gy0 * g + gx0;
      final tilt =
          (tiltG[gj] * (1 - gtx) + tiltG[gj + 1] * gtx) * (1 - gty) +
          (tiltG[gj + g] * (1 - gtx) + tiltG[gj + g + 1] * gtx) * gty;
      final fore =
          (foreG[gj] * (1 - gtx) + foreG[gj + 1] * gtx) * (1 - gty) +
          (foreG[gj + g] * (1 - gtx) + foreG[gj + g + 1] * gtx) * gty;
      final l = 2 * _jsRound((strandHalf * (0.5 + 0.5 * tilt) * fore) / _pileCos).clamp(1, strandHalf);
      final sw = strandW[l];
      var acc = 0.0, accR = 0.0;
      for (var t = 0; t <= l; t++) {
        final sx = _jsRound(x - ux * t), sy = _jsRound(y - uy * t);
        if (sx < 0 || sy < 0 || sx >= rb || sy >= rb) {
          acc += strandMean[l] / (l + 1);
          continue;
        }
        final m = white[sy * rb + sx], f = m * 53.7, ls = l * (_strandShort + (1 - _strandShort) * (f - f.floor()));
        if (t <= ls) {
          acc += m * sw[t];
          accR += (m * sw[t] * t) / (ls == 0 ? 1 : ls);
        }
      }
      final strand = (acc - strandMean[l]) / strandSd[l];
      final along = acc > 1e-4 ? accR / acc : 0.5;
      strandBuf[i] = strand + _strandRise * strand.clamp(0.0, 2.5) * (along - 0.45);
    }
  }
  for (var y = 0; y < rb; y++) {
    final yY = (y + 0.5) / px - o;
    for (var x = 0; x < rb; x++) {
      final xX = (x + 0.5) / px - o;
      final i = y * rb + x, k = own[i], b = k * lp;
      lockSeen(x, y, xX, yY, k);
      final ux = seenL[0], uy = seenL[1], s = seenL[2], hgt = seenL[3];
      fibreLight(xX, yY, ux, uy, 0.25 + 0.2 * hgt);
      final nx = fib[4], ny = fib[5], nz = fib[6], nKb = fib[7];
      /* the pile's own surface: the body's, tilted by the slope of the pile */
      final xl0 = x > 0 ? i - 1 : i,
          xr0 = x < rb - 1 ? i + 1 : i,
          yu0 = y > 0 ? i - rb : i,
          yd0 = y < rb - 1 ? i + rb : i;
      final dxi = xr0 - xl0, dyi = yd0 - yu0;
      final gx = ((pileHt[xr0] - pileHt[xl0]) * px) / (dxi == 0 ? 1 : dxi);
      final gy = ((pileHt[yd0] - pileHt[yu0]) * px * rb) / (dyi == 0 ? 1 : dyi);
      final l1 = math.sqrt(nx * nx + ny * ny);
      var t1x = 1.0, t1y = 0.0, t2x = 0.0, t2y = 1.0, t2z = 0.0;
      if (l1 > 1e-3) {
        t1x = -ny / l1;
        t1y = nx / l1;
        t2x = (-nz * nx) / l1;
        t2y = (-nz * ny) / l1;
        t2z = l1;
      }
      final g1 = (gx * t1x + gy * t1y).clamp(-1.5, 1.5), g2 = (gx * t2x + gy * t2y).clamp(-1.5, 1.5);
      var mx = nx - g1 * t1x - g2 * t2x, my = ny - g1 * t1y - g2 * t2y, mz = nz - g2 * t2z;
      var ml = math.sqrt(mx * mx + my * my + mz * mz);
      if (ml == 0) ml = 1;
      mx /= ml;
      my /= ml;
      mz /= ml;
      var kk = 1.0;
      if (k >= 0) {
        final tx = locks[b + 8], ty = locks[b + 9], tz = locks[b + 10];
        final fx = 0.9 * tx + 0.44 * nx, fy = 0.9 * ty + 0.44 * ny, fz = 0.9 * tz + 0.44 * nz;
        var fn = math.sqrt(fx * fx + fy * fy + fz * fz);
        if (fn == 0) fn = 1;
        final fK = (fx * k3.$1 + fy * k3.$2 + fz * k3.$3) / fn;
        kk = 1 - _pileKk + _pileKk * math.min(1.2, math.sqrt(math.max(0, 1 - fK * fK)) / 0.85);
      }
      final nKp = mx * k3.$1 + my * k3.$2 + mz * k3.$3;
      /* the key's shadow: a lock standing higher toward the light */
      final h0 = pileHt[i];
      var sh = 1.0;
      if (nKb > -0.25) {
        final sinE = nKb.clamp(0.05, 0.97), tanE = sinE / math.sqrt(1 - sinE * sinE);
        var occ = 0.0;
        for (var t = 0; t < nsh; t++) {
          final sx = x + shX[t], sy = y + shY[t];
          if (sx < 0 || sy < 0 || sx >= rb || sy >= rb) break;
          final oc = pileHt[sy * rb + sx] - h0 - shD[t] * tanE;
          if (oc > occ) occ = oc;
        }
        sh = 1 - _pileShadow * smoothstep(0, 0.35 * hMax, occ);
      }
      var ao = 1 - _pileAo * smoothstep(0, 0.6 * hMax, pileB[i] - h0);
      if (k >= 0) ao *= 1 - _pileRoot * (1 - smoothstep(0, 0.35, s));
      final fillP = _pileAmb + _pileFill * math.max(0.0, mx * f3.$1 + my * f3.$2 + mz * f3.$3);
      final fillB = _pileAmb + _pileFill * math.max(0.0, nx * f3.$1 + ny * f3.$2 + nz * f3.$3);
      var rr = (ao * (fillP + keyOn(nKp) * sh * kk) * _pileGain) / (fillB + keyOn(nKb));
      if (k >= 0) rr *= (1 + 0.15 * s * s) * (1 + 0.08 * (_hash2(k, 5) - 0.5));
      final crease = fib[8];
      rr *= 1 - _pileCrease * crease * (0.6 + 0.4 * smoothstep(0, 0.6 * hMax, pileB[i] - h0));
      rr = 1 + (rr - 1) * depthK;
      final on = fib[9], lq = (fillB + keyOn(nKb)) / _pileLit;
      final lbs = (lq >= 1 ? 1 : gamLut[(lq * powN).toInt()]) * on + 0.75 * (1 - on);
      var m0 = math.sqrt(rr > 2.4 ? 2.4 : rr);
      if (m0 > 1) m0 = 1 + (m0 - 1) / (1 + 2.5 * lbs * (m0 - 1));
      final strand = strandBuf[i];
      var cast = 0.0;
      if (nKb > 0) {
        final kx = k3.$1 - nKb * nx, ky = k3.$2 - nKb * ny, kt = math.sqrt(1 - nKb * nKb);
        final reachS = kt > 1e-3 ? (_strandCastH * px * math.min(3, kt / math.max(0.2, nKb))) / kt : 0.0;
        final cx = (x + kx * reachS).clamp(0.0, rb - 1.001), cy = (y + ky * reachS).clamp(0.0, rb - 1.001);
        final cx0 = cx.toInt(), cy0 = cy.toInt(), tx = cx - cx0, ty = cy - cy0, ci = cy0 * rb + cx0;
        final caster =
            (strandBuf[ci] * (1 - tx) + strandBuf[ci + 1] * tx) * (1 - ty) +
            (strandBuf[ci + rb] * (1 - tx) + strandBuf[ci + rb + 1] * tx) * ty;
        cast = math.max(0.0, caster - math.max(0.0, strand)) * smoothstep(0, 0.3, nKb);
      }
      var m =
          m0 * (1 + strandK * (strand * (0.45 + 0.55 * fib[2]) * (0.75 + 0.5 * s) - _strandCast * cast)) +
          0.04 * (fib[10] - 0.5) +
          _pileBias * depthK * on;
      final edgeD = math.min(math.min(xX + o, filmSpan - o - xX), math.min(yY + o, filmSpan - o - yY));
      final fadeE = edgeD >= 8 ? 1.0 : (edgeD <= 0 ? 0.0 : (edgeD / 8) * (edgeD / 8) * (3 - (2 * edgeD) / 8));
      m = 1 + (m - 1) * fadeE;
      if (m < 1) {
        darkA[i] = _a8(math.min(1.0, ((1 - m) * lbs) / math.max(0.4, lbs - gapRef)));
      } else {
        lightA[i] = _a8(
          math.min(1.0, ((_pileLift * (_tipTop - 1) * lbs) / (_tipTop - lbs)) * (m - 1) * (1 - 0.7 * crease)),
        );
      }
      final lit = (4 * (m0 - 1)).clamp(-2.0, 2.0);
      final xl = x >> 1, yl = y >> 1;
      if (xl < rl && yl < rl) {
        final jj = yl * rl + xl;
        lock[jj] += 0.25 * h0;
        lockLit[jj] += 0.25 * lit;
      }
      final tipK = smoothstep(-0.4, 1, lit) * (0.65 + 0.25 * strand).clamp(0.0, 1.4);
      glintA[i] = _a8(math.min(1.0, fib[0] * tipK));
      backA[i] = _a8(math.min(1.0, fib[1] * (0.5 + 0.4 * strand).clamp(0.0, 1.6)));
      final onPile = (0.85 + 0.15 * strand + 0.12 * lit).clamp(0.55, 1.3);
      softA[i] = _a8(math.min(1.0, 0.85 * fib[3] * onPile));
    }
  }
  {
    /* the half-resolution height brought to one spread, as the tufts read it */
    final nl = rl * rl;
    var lsum = 0.0, lsum2 = 0.0;
    for (var i = 0; i < nl; i++) {
      lsum += lock[i];
      lsum2 += lock[i] * lock[i];
    }
    final mean = lsum / nl, sdv = math.sqrt(math.max(1e-9, lsum2 / nl - mean * mean));
    for (var i = 0; i < nl; i++) {
      lock[i] = ((lock[i] - mean) / sdv).clamp(-2.5, 2.5);
    }
  }

  /* 2. single hairs over the fleece, at two scales: guard hairs and fine
     hairs, bucketed by shade */
  final strokes = <FurStroke>[];
  void stroke(FurLayer layer, List<double> cmds, double width, double alpha, {bool erase = false}) {
    if (cmds.isEmpty || alpha <= 0) return;
    strokes.add(FurStroke(layer, Float32List.fromList(cmds), width, alpha, erase: erase));
  }

  const shades = 16;
  const area = filmSpan * filmSpan;
  final fine = r >= 512 ? 1.0 : (r >= 320 ? 0.45 : 0.0);
  final kinds = [
    _Kind(0.12, 1.2, 1.0, 0.6, 0.09, 30, 0.4, 1, 0.25, 0.46, 0.34, 0.93, 1, 0, 0, 0, 1, 0, false, 0),
    _Kind(
      0.4 * fine,
      0.9,
      1.2,
      0.35,
      0.13,
      100,
      0.26,
      0.2,
      0.18,
      0.55,
      0.06,
      1.2,
      1,
      _jsRound(1 + 2 * clumps),
      0.08 + 0.07 * clumps,
      0.25,
      2,
      0.25,
      true,
      1,
    ),
  ];
  int shadeOf(double v) => _jsRound(((v.clamp(-1.0, 1.0) + 1) / 2) * (shades - 1)).clamp(0, shades - 1);
  const glints = 6;
  int glintOf(double v) => math.min(glints - 1, (v * glints).toInt());
  const segs = 4;
  final hx = Float64List(segs + 1), hy = Float64List(segs + 1);
  for (final kind in kinds) {
    if (kind.count <= 0) continue;
    final perRoot = kind.clumpMin + 0.5 * kind.clumpMore;
    final parts = math.max(
      1,
      ((area * kind.count * kDen * (kind.crowd ? 2 : 1) * (0.5 + 0.5 * perRoot)) / 9000).ceil(),
    );
    for (var part = 0; part < parts; part++) {
      final buckets = List.generate(shades, (_) => <double>[]);
      final glintP = List.generate(glints, (_) => <double>[]), backP = List.generate(glints, (_) => <double>[]);
      final shadeP = List.generate(3, (_) => <double>[]);
      final over = <double>[];
      final count = _jsRound((area * kind.count * kDen * (kind.crowd ? 2 : 1)) / parts);
      for (var nn = 0; nn < count; nn++) {
        final xX = rand() * filmSpan - o, yY = rand() * filmSpan - o;
        final r0 = rand(), r1 = rand(), r2 = rand(), r3 = rand(), r4 = rand(), r5 = rand();
        if (r5 * 8 > math.min(math.min(xX + o, filmSpan - o - xX), math.min(yY + o, filmSpan - o - yY))) continue;
        if (kind.crowd && r5 > (sdAt(xX, yY) > 0 ? 0.5 / math.max(0.25, gridAt(nZg, xX, yY)) : 0.5)) continue;
        final (fx, fy) = dirAt(xX, yY);
        final tiltS = gridAt(tiltG, xX, yY), vl = gridAt(foreG, xX, yY) / _pileCos;
        final ang = (r1 - 0.5) * (0.6 + 0.8 * curl) * (1 - 0.5 * tiltS);
        final ca = math.cos(ang), sa = math.sin(ang);
        final ux = fx * ca - fy * sa, uy = fx * sa + fy * ca;
        final longer = r2 < 0.1 ? 1.35 + 0.6 * r3 : 1.0;
        final len =
            (kind.len + kind.vary * r3 * r3) * px * kLen * longer * vl * (1 - kind.endOn + 1.25 * kind.endOn * tiltS);
        fibreLight(xX, yY, ux, uy, 0.1 + 0.5 * _hash2(nn, 7 + part));
        var v = 0.22 * lockAt(lock, xX, yY) + 0.3 * lockAt(lockLit, xX, yY);
        final lit = r0 < kind.light * (0.4 + 0.6 * fib[2]);
        if (lit) {
          v += 0.2 + 0.28 * r4;
        } else if (r0 < kind.light + kind.dark) {
          v -= 0.2 + 0.28 * r4;
        }
        v += kind.lift;
        v += 0.45 * (fib[2] - 0.5) - 0.35 * fib[8];
        if (v > 0) v *= 0.3 + 0.7 * fib[2];
        final deepen = 0.15 * (1 - fib[2]);
        final x0 = (xX + pad) * px, y0 = (yY + pad) * px;
        final b1 = (rand() - 0.5) * kind.bend * curl * len, b2 = r4 < 0.3 ? -0.6 * b1 : b1 * (0.6 + 0.8 * rand());
        final hairs = kind.clumpMin + (rand() * (kind.clumpMore + 1)).toInt();
        final wC = kind.clumpW * px * math.min(1.5, kLen);
        for (var k = 0; k < hairs; k++) {
          final oo = hairs > 1 ? rand() - 0.5 : 0.0, f = hairs > 1 ? 0.7 + 0.3 * rand() : 1.0;
          final jj = hairs > 1 ? (rand() - 0.5) * 0.3 : 0.0;
          final rx = x0 - uy * oo * wC, ry = y0 + ux * oo * wC;
          final lk = len * f, e1 = b1 + jj * lk, e2 = b2 + jj * lk - oo * wC * 0.7;
          final c1x = rx + ux * lk * 0.33 - uy * e1, c1y = ry + uy * lk * 0.33 + ux * e1;
          final c2x = rx + ux * lk * 0.67 - uy * e2, c2y = ry + uy * lk * 0.67 + ux * e2;
          final x1 = rx + ux * lk - uy * (b2 - oo * wC * 0.75), y1 = ry + uy * lk + ux * (b2 - oo * wC * 0.75);
          final sg = lk < 4 ? 2 : (lk < 10 ? 3 : segs);
          for (var s = 0; s <= sg; s++) {
            final t = s / sg, q = 1 - t;
            final a = q * q * q, b = 3 * q * q * t, c = 3 * q * t * t, d = t * t * t;
            hx[s] = a * rx + b * c1x + c * c2x + d * x1;
            hy[s] = a * ry + b * c1y + c * c2y + d * y1;
          }
          final vh = v + (hairs > 1 ? (rand() - 0.5) * 0.25 : 0), rise = 0.3 + 0.15 * fib[2];
          for (var s = 0; s < sg; s++) {
            buckets[shadeOf(vh - 0.3 - deepen * (1 - s / sg) + (rise * (s + 0.5)) / sg)].addAll([
              0,
              hx[s],
              hy[s],
              1,
              hx[s + 1],
              hy[s + 1],
            ]);
          }
          if (lit && kind.over > 0) {
            over.addAll([0, hx[1], hy[1]]);
            for (var s = 2; s <= sg; s++) {
              over.addAll([1, hx[s], hy[s]]);
            }
          }
          if (k == 0 && kind.shadow > 0 && fib[2] > 0.25 && v > -0.2) {
            final kk = kind.shadow * px * math.min(1.0, kLen), sh = shadeP[math.min(2, ((fib[2] - 0.25) * 4).toInt())];
            for (var s = 1; s <= sg; s++) {
              final t = s / sg, ox = -lX * kk * t, oy = -lY * kk * t + 0.3 * kk * t;
              if (s == 1) sh.addAll([0, hx[0], hy[0]]);
              sh.addAll([1, hx[s] + ox, hy[s] + oy]);
            }
          }
          final h = sg >> 1;
          if (fib[0] > 0.3) {
            final gb = glintP[glintOf(fib[0])];
            gb.addAll([0, hx[h], hy[h]]);
            for (var s = h + 1; s <= sg; s++) {
              gb.addAll([1, hx[s], hy[s]]);
            }
          }
          if (fib[1] > 0.1) {
            final bb = backP[glintOf(fib[1])];
            bb.addAll([0, hx[h], hy[h]]);
            for (var s = h + 1; s <= sg; s++) {
              bb.addAll([1, hx[s], hy[s]]);
            }
          }
        }
      }
      final shortK = math.pow(math.min(1.0, kLen), kind.short).toDouble();
      final lw = math.max(0.45, kind.width * px * (0.5 + 0.5 * shortK));
      if (kind.over > 0) stroke(FurLayer.dark, over, lw, kind.over * shortK, erase: true);
      if (kind.shadow > 0) {
        for (var i = 0; i < 3; i++) {
          stroke(FurLayer.dark, shadeP[i], lw * kind.shadowW, 0.03 * (i + 1) * shortK);
        }
      }
      for (var i = 0; i < shades; i++) {
        final v = _furMid + ((i / (shades - 1)) * 2 - 1) * kind.spread;
        final dark = v < _furMid;
        stroke(
          dark ? FurLayer.dark : FurLayer.light,
          buckets[i],
          lw,
          kind.alpha * shortK * (dark ? kind.deep * (1 - v / _furMid) : (v - _furMid) / (255 - _furMid)),
        );
      }
      for (var i = 0; i < glints; i++) {
        stroke(FurLayer.glint, glintP[i], lw, (0.4 * (i + 0.5)) / glints);
        stroke(FurLayer.back, backP[i], lw, (0.8 * (i + 0.5)) / glints);
      }
    }
  }

  /* 3. the fuzz: fibres rooted just inside the edge, standing out past it */
  final fringe = <double>[];
  final fringeBack = List.generate(glints, (_) => <double>[]);
  final cells = <int>[];
  final cu = span / n;
  for (var i = 0; i < n * n; i++) {
    if (job.sd[i] > -1.6 && job.sd[i] < 2.2) cells.add(i);
  }
  final edgeTries = _jsRound(
    cells.length *
        cu *
        cu *
        24 *
        (0.3 + 1.4 * fuzz) *
        math.sqrt(kDen) *
        (0.5 + 0.5 * math.min(1, r / 512)) *
        (1 - 0.55 * fine),
  );
  for (var nn = 0; nn < edgeTries && cells.isNotEmpty; nn++) {
    final c = cells[(rand() * cells.length).toInt()];
    final xX = ((c % n) + rand()) * cu - pad, yY = ((c ~/ n) + rand()) * cu - pad;
    final d0 = sdAt(xX, yY);
    if (d0 < -1.2 || d0 > 1.8) continue;
    final d = d0 + tuftAt(xX, yY);
    if (d < -0.2 || d > 1.2) continue;
    final (fx, fy) = flow(xX, yY);
    final (ox, oy) = outward(xX, yY);
    final ang = (rand() - 0.5) * 1.1;
    final ca = math.cos(ang), sa = math.sin(ang);
    var ux = fx * ca - fy * sa, uy = fx * sa + fy * ca;
    final r1 = rand();
    final hang = 1 + 0.5 * gravity * math.max(0.0, oy) - 0.35 * gravity * math.max(0.0, -oy);
    var fl = (0.3 + 1.5 * r1 * r1 * r1) * px * kLen * (0.5 + fuzz) * hang;
    final x0 = (xX + pad) * px, y0 = (yY + pad) * px;
    var bend = (rand() - 0.5) * 1.17 * curl * fl;
    /* a few flyaways on top: out over the edge, then arching down */
    if (oy < -0.3 && rand() < 0.06 * (0.3 + fuzz)) {
      ux = ox * 0.8 + (rand() - 0.5) * 0.6;
      uy = oy * 0.8;
      fl *= 1.2;
      bend = (rand() < 0.5 ? -1 : 1) * (0.25 + 0.3 * gravity) * fl;
    }
    final qx = x0 + ux * fl * 0.5 - uy * bend, qy = y0 + uy * fl * 0.5 + ux * bend;
    final ex = x0 + ux * fl, ey = y0 + uy * fl + gravity * fl * 0.25;
    fringe.addAll([0, x0, y0, 2, qx, qy, ex, ey]);
    fibreLight(xX, yY, ux, uy, 0.3);
    if (fib[1] > 0.08) fringeBack[glintOf(fib[1])].addAll([0, x0, y0, 2, qx, qy, ex, ey]);
  }
  /* the silhouette's locks: tufts of hairs standing past it */
  final tufts = <double>[], tuftTips = List.generate(3, (_) => <double>[]);
  final tuftBack = List.generate(glints, (_) => <double>[]);
  {
    final band = cells.length * cu * cu, around = band / 3.8;
    final count = _jsRound((around / (0.45 + 0.3 * kLen)) * (0.3 + 0.8 * fuzz) * math.sqrt(kDen) * (1 + 0.6 * fine));
    for (var nn = 0, tries = 0; nn < count && tries < 6 * count && cells.isNotEmpty; tries++) {
      final c = cells[(rand() * cells.length).toInt()];
      final xX = ((c % n) + rand()) * cu - pad, yY = ((c ~/ n) + rand()) * cu - pad;
      final r0 = rand(), r1 = rand(), r2 = rand(), r3 = rand();
      final d0 = sdAt(xX, yY);
      if (d0 < -0.5 || d0 > 1.6) continue;
      final d = d0 + tuftAt(xX, yY);
      if (d < 0 || d > 0.9) continue;
      if (lockAt(lock, xX, yY) < -0.4 + 0.8 * r3) continue;
      nn++;
      final (fx, fy) = flow(xX, yY);
      final (ox, oy) = outward(xX, yY);
      final a = (r0 - 0.5) * 0.8 * (0.5 + curl), ca = math.cos(a), sa = math.sin(a);
      var sx = 0.75 * ox + 0.25 * fx, sy = 0.75 * oy + 0.25 * fy;
      var ex = 0.55 * fx + 0.45 * ox, ey = 0.55 * fy + 0.45 * oy + 0.35 * gravity;
      var sl = math.sqrt(sx * sx + sy * sy), el = math.sqrt(ex * ex + ey * ey);
      if (sl == 0) sl = 1;
      if (el == 0) el = 1;
      (sx, sy) = ((sx * ca - sy * sa) / sl, (sx * sa + sy * ca) / sl);
      (ex, ey) = ((ex * ca - ey * sa) / el, (ex * sa + ey * ca) / el);
      final hang = 1 + 0.5 * gravity * math.max(0.0, oy) - 0.35 * gravity * math.max(0.0, -oy);
      final lt = (0.5 + 1.1 * r1 * r1) * px * kLen * (0.5 + fuzz) * hang;
      final wT = (0.3 + 0.35 * r2) * px * math.min(1.5, kLen);
      final x0 = (xX + pad) * px, y0 = (yY + pad) * px;
      final cx = x0 + sx * lt * 0.5, cy = y0 + sy * lt * 0.5;
      final tx = x0 + (sx * 0.4 + ex * 0.6) * lt, ty = y0 + (sy * 0.4 + ey * 0.6) * lt;
      final qx = -sy, qy = sx;
      fibreLight(xX, yY, ex, ey, 0.4);
      final fb = fib[1] > 0.08 ? tuftBack[glintOf(fib[1])] : null;
      final tt = tuftTips[math.min(2, (fib[2] * 3).toInt())];
      final hairs = 4 + (rand() * 5).toInt();
      for (var k = 0; k < hairs; k++) {
        final oo = rand() - 0.5, f = 0.7 + 0.3 * rand(), w = (rand() - 0.5) * 0.35;
        final hx0 = x0 + qx * oo * wT, hy0 = y0 + qy * oo * wT;
        final hcx = cx + qx * oo * wT * 0.6, hcy = cy + qy * oo * wT * 0.6;
        final htx = hx0 + (tx + qx * (oo * 0.25 + w) * wT - hx0) * f;
        final hty = hy0 + (ty + qy * (oo * 0.25 + w) * wT - hy0) * f;
        tufts.addAll([0, hx0, hy0, 2, hcx, hcy, htx, hty]);
        final mx = 0.25 * hx0 + 0.5 * hcx + 0.25 * htx, my = 0.25 * hy0 + 0.5 * hcy + 0.25 * hty;
        tt.addAll([0, mx, my, 2, 0.5 * (hcx + htx), 0.5 * (hcy + hty), htx, hty]);
        fb?.addAll([0, mx, my, 2, 0.5 * (hcx + htx), 0.5 * (hcy + hty), htx, hty]);
      }
    }
  }
  {
    /* the tufts: their tips a touch lighter, clear of the gaps' shade */
    final tw = math.max(0.4, 0.11 * px);
    for (var i = 0; i < 3; i++) {
      stroke(FurLayer.dark, tuftTips[i], tw, 0.6, erase: true);
      stroke(FurLayer.light, tuftTips[i], tw, 0.08 + 0.11 * i);
    }
    for (var i = 0; i < glints; i++) {
      stroke(FurLayer.back, tuftBack[i], tw, (i + 0.5) / glints);
    }
    /* the edge hairs seen side-on against the light */
    final fw = math.max(0.35, 0.08 * px);
    stroke(FurLayer.light, fringe, fw, 0.5 * ((140 - _furMid) / (255 - _furMid)));
    for (var i = 0; i < glints; i++) {
      stroke(FurLayer.back, fringeBack[i], fw, (i + 0.5) / glints);
    }
    stroke(FurLayer.dark, fringe, fw, 0.7, erase: true);
  }

  /* 4. the halo: the body's coverage laid over the silhouette, solid inside;
     past the outline a haze of fine hairs streaked along the flow */
  final maskA = Uint8List(r * r), hazeA = Uint8List(r * r), coreA = Uint8List(r * r);
  final hOut = 0.5 + 1.2 * fuzz, reachOut = hOut + tuftK;
  final haloA = _haloA * (1 - 0.6 * fine), haloStreak = _haloStreak * (1 + 1.2 * fine);
  final hn = math.max(1, _jsRound(_haloHair * kLen * px)), hs1 = hn + 1;
  final hsd = (wSd * math.sqrt(1 + (hn * (2 * hn + 1)) / (3 * hs1))) / hs1;
  final off = _jsRound(filmM * px);
  for (var y = 0; y < r; y++) {
    final yY = (y + 0.5) / px - pad;
    for (var x = 0; x < r; x++) {
      final xX = (x + 0.5) / px - pad;
      final k = y * r + x;
      final d0 = sdAt(xX, yY);
      if (d0 >= tuftK + haloCore) {
        maskA[k] = coreA[k] = 255;
        continue;
      }
      final d = d0 <= -reachOut ? d0 : d0 + tuftAt(xX, yY);
      if (d >= 0) {
        maskA[k] = 255;
        coreA[k] = _a8(smoothstep(0.25 * haloCore, haloCore, d));
        continue;
      }
      final z = math.min(1.0, -d / (2 * hOut));
      final nB = gridAt(nXg, xX, yY) * b3.$1 + gridAt(nYg, xX, yY) * b3.$2;
      hazeA[k] = _a8(_haloLift * z * z * (3 - 2 * z) * (0.45 + 0.55 * smoothstep(-0.3, 0.6, nB)));
      if (d <= -hOut) continue;
      final oo = 1 + d / hOut, f = oo * oo * (3 - 2 * oo);
      final (ux, uy) = freeDirAt(xX, yY);
      var acc = 0.0;
      for (var t = -hn; t <= hn; t++) {
        final sx = _jsRound(x + off + ux * t), sy = _jsRound(y + off + uy * t);
        acc += (sx < 0 || sy < 0 || sx >= rb || sy >= rb ? wMean : white[sy * rb + sx]) * (1 - t.abs() / hs1);
      }
      final strand = (acc / hs1 - wMean) / hsd;
      maskA[k] = _a8((f * (haloA + haloStreak * strand)).clamp(0.0, 1.0));
    }
  }
  stroke(FurLayer.mask, fringe, math.max(0.35, 0.08 * px), 0.45);
  stroke(FurLayer.mask, tufts, math.max(0.4, 0.11 * px), 0.8);

  final soft = Uint8List(r * r);
  for (var y = 0; y < r; y++) {
    for (var x = 0; x < r; x++) {
      final d = bilerp(job.sd, n, (((x + 0.5) / px) / span) * n - 0.5, (((y + 0.5) / px) / span) * n - 0.5);
      final t = (d + 0.2) / 0.6;
      soft[y * r + x] = t >= 1 ? 255 : (t <= 0 ? 0 : (255 * t * t * (3 - 2 * t)).round());
    }
  }

  return FurBake(
    soft: soft,
    r: r,
    rb: rb,
    dark: darkA,
    light: lightA,
    glint: glintA,
    back: backA,
    backSoft: softA,
    mask: maskA,
    haze: hazeA,
    core: coreA,
    strokes: strokes,
  );
}

/* a kind of single hair: count per unit² of the film (times the density),
   base length and how much longer, how much shorter end-on, width, the
   shades' spread and strength, how much the shaded hairs keep, how far into
   the light, the shares lit and in shade, how wavy, how many in a clump and
   how wide, a clump's shadow, how much of the gaps it hides, crowding, and
   how much finer on a shorter pile */
class _Kind {
  const _Kind(
    this.count,
    this.len,
    this.vary,
    this.endOn,
    this.width,
    this.spread,
    this.alpha,
    this.deep,
    this.lift,
    this.light,
    this.dark,
    this.bend,
    this.clumpMin,
    this.clumpMore,
    this.clumpW,
    this.shadow,
    this.shadowW,
    this.over,
    this.crowd,
    this.short,
  );

  final double count;
  final double len;
  final double vary;
  final double endOn;
  final double width;
  final double spread;
  final double alpha;
  final double deep;
  final double lift;
  final double light;
  final double dark;
  final double bend;
  final int clumpMin;
  final int clumpMore;
  final double clumpW;
  final double shadow;
  final double shadowW;
  final double over;
  final bool crowd;
  final double short;
}
