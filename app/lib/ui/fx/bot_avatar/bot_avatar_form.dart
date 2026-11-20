// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

/* The form: once per outline (× texture size × depth) the outline is
   rasterised into a small grid and turned into a signed distance, a pillow
   height field (the torsion function of the outline, so lobes are domes,
   rays are tubes and there is no crease), its normals as matcap cells, and
   baked ambient occlusion. Pure Dart on typed lists, so it bakes off the UI
   isolate. A port of the author's plastic.ts (form, relief, rim). */

import 'dart:math' as math;
import 'dart:typed_data';

/// The texture covers design units [-pad, 100 + pad].
const pad = 3.0;
const span = 100 + 2 * pad;

/// Matcap side: (nx, ny) ∈ [-1, 1]² in m × m cells.
const matcapM = 64;
const _inf = 1e12;

/// Texture size for an avatar `devicePx` wide (logical px × dpr, dpr capped at 2).
int formTier(double devicePx) => devicePx <= 100 ? 64 : (devicePx <= 224 ? 96 : 128);

/// One baked outline at one texture size.
class BotAvatarForm {
  BotAvatarForm({
    required this.n,
    required this.i00,
    required this.wx,
    required this.wy,
    required this.ao,
    required this.sd,
    required this.h,
  });

  final int n;

  /// bilinear cell in the matcap: index of the top-left cell …
  final Uint16List i00;

  /// … and the weights inside it, 0–255
  final Uint8List wx;
  final Uint8List wy;

  /// baked occlusion × edge darkening, gamma-compensated, 0–255; 0 = not drawn
  final Uint8List ao;

  /// signed distance to the outline in design units (positive inside), and the
  /// pillow height
  final Float32List sd;
  final Float32List h;

  final _reliefs = <String, Relief>{};
  Float32List? _rim;
  Ring? _ring;
  Lift? _lift;

  /// fabric's halo misses, by turn step (see [measureMiss])
  final misses = <String, (double, double)>{};

  /// the surface's highest point
  late final double top = () {
    var t = 0.0;
    for (final v in h) {
      if (v > t) t = v;
    }
    return t;
  }();
}

/* ── the raster ──────────────────────────────────────────────────────── */

/// Coverage (0–255) of closed polygons under the affine `m` (a, b, c, d, e, f:
/// x' = a·x + c·y + e, y' = b·x + d·y + f) on an n × n pixel grid, non-zero
/// winding, four sub-rows a pixel with exact coverage along each.
Uint8List rasterize(List<Float64List> polys, int n, List<double> m) {
  const sub = 4;
  final rows = n * sub;
  final count = Int32List(rows + 1);
  final edges = <double>[];
  for (final p in polys) {
    final k = p.length ~/ 2;
    for (var i = 0; i < k; i++) {
      final ax = p[2 * i], ay = p[2 * i + 1];
      final j = (i + 1) % k;
      final bx = p[2 * j], by = p[2 * j + 1];
      final x0 = m[0] * ax + m[2] * ay + m[4], y0 = m[1] * ax + m[3] * ay + m[5];
      final x1 = m[0] * bx + m[2] * by + m[4], y1 = m[1] * bx + m[3] * by + m[5];
      if (y0 == y1) continue;
      edges.addAll([x0, y0, x1, y1]);
      final lo = math.min(y0, y1) * sub - 0.5, hi = math.max(y0, y1) * sub - 0.5;
      final r0 = math.max(0, lo.ceil()), r1 = math.min(rows - 1, (hi - 1e-9).floor());
      for (var r = r0; r <= r1; r++) {
        count[r + 1]++;
      }
    }
  }
  for (var r = 0; r < rows; r++) {
    count[r + 1] += count[r];
  }
  final xs = Float64List(count[rows]), dirs = Int8List(count[rows]), fill = Int32List(rows);
  for (var e = 0; e < edges.length; e += 4) {
    final x0 = edges[e], y0 = edges[e + 1], x1 = edges[e + 2], y1 = edges[e + 3];
    final lo = math.min(y0, y1) * sub - 0.5, hi = math.max(y0, y1) * sub - 0.5;
    final r0 = math.max(0, lo.ceil()), r1 = math.min(rows - 1, (hi - 1e-9).floor());
    for (var r = r0; r <= r1; r++) {
      final y = (r + 0.5) / sub;
      final at = count[r] + fill[r]++;
      xs[at] = x0 + (x1 - x0) * (y - y0) / (y1 - y0);
      dirs[at] = y1 > y0 ? 1 : -1;
    }
  }
  final acc = Float64List(n * n);
  for (var r = 0; r < rows; r++) {
    final a = count[r], b = count[r + 1];
    /* insertion sort: a sub-row crosses a handful of edges */
    for (var i = a + 1; i < b; i++) {
      final x = xs[i], d = dirs[i];
      var j = i - 1;
      while (j >= a && xs[j] > x) {
        xs[j + 1] = xs[j];
        dirs[j + 1] = dirs[j];
        j--;
      }
      xs[j + 1] = x;
      dirs[j + 1] = d;
    }
    final o = (r ~/ sub) * n;
    var wind = 0;
    var start = 0.0;
    for (var i = a; i < b; i++) {
      final was = wind;
      wind += dirs[i];
      if (was == 0 && wind != 0) {
        start = xs[i];
      } else if (was != 0 && wind == 0) {
        _span(acc, o, n, start, xs[i], 1 / sub);
      }
    }
  }
  final cov = Uint8List(n * n);
  for (var i = 0; i < n * n; i++) {
    cov[i] = (255 * acc[i]).round().clamp(0, 255);
  }
  return cov;
}

void _span(Float64List acc, int o, int n, double xa, double xb, double w) {
  if (xb <= 0 || xa >= n) return;
  xa = math.max(0, xa);
  xb = math.min(n.toDouble(), xb);
  final ia = xa.floor(), ib = math.min(n - 1, xb.floor());
  if (ia == ib) {
    acc[o + ia] += (xb - xa) * w;
    return;
  }
  acc[o + ia] += (ia + 1 - xa) * w;
  for (var i = ia + 1; i < ib; i++) {
    acc[o + i] += w;
  }
  if (ib < n) acc[o + ib] += (xb - ib) * w;
}

/// The coverage of an outline over design units [-pad, 100 + pad].
Uint8List rasterizeOutline(List<Float64List> polys, int n) {
  final u = span / n;
  return rasterize(polys, n, [1 / u, 0, 0, 1 / u, pad / u, pad / u]);
}

/* ── distance, blur, the pillow ──────────────────────────────────────── */

/* Felzenszwalb–Huttenlocher 1-D squared distance transform; s gets the index
   of the nearest site. */
void _edt1d(Float64List f, int n, Float64List d, Int32List s, Int32List v, Float64List z) {
  var k = 0;
  v[0] = 0;
  z[0] = -1e30;
  z[1] = 1e30;
  for (var q = 1; q < n; q++) {
    var x = 0.0;
    for (;;) {
      final vk = v[k];
      x = (f[q] + q * q - f[vk] - vk * vk) / (2 * (q - vk));
      if (x > z[k]) break;
      k--;
    }
    k++;
    v[k] = q;
    z[k] = x;
    z[k + 1] = 1e30;
  }
  k = 0;
  for (var q = 0; q < n; q++) {
    while (z[k + 1] < q) {
      k++;
    }
    final vk = v[k];
    d[q] = (q - vk) * (q - vk) + f[vk];
    s[q] = vk;
  }
}

/// Squared texel distance from every texel to the nearest texel whose mask
/// equals `site`, and (optionally) that texel's index.
void edt2d(Uint8List mask, int site, int n, Float64List out, Int32List? near) {
  final f = Float64List(n), d = Float64List(n), z = Float64List(n + 1);
  final s = Int32List(n), v = Int32List(n);
  final g = Float64List(n * n), row = Int32List(n * n);
  for (var x = 0; x < n; x++) {
    for (var y = 0; y < n; y++) {
      f[y] = mask[y * n + x] == site ? 0 : _inf;
    }
    _edt1d(f, n, d, s, v, z);
    for (var y = 0; y < n; y++) {
      g[y * n + x] = d[y];
      row[y * n + x] = s[y];
    }
  }
  for (var y = 0; y < n; y++) {
    final o = y * n;
    for (var x = 0; x < n; x++) {
      f[x] = g[o + x];
    }
    _edt1d(f, n, d, s, v, z);
    for (var x = 0; x < n; x++) {
      out[o + x] = d[x];
      if (near != null) near[o + x] = row[o + s[x]] * n + s[x];
    }
  }
}

/* Separable binomial blur [1 4 6 4 1]/16, edges clamped. */
void _blur5(Float32List a, int n, Float32List tmp) {
  for (var y = 0; y < n; y++) {
    final o = y * n;
    for (var x = 0; x < n; x++) {
      final x0 = x < 2 ? 0 : x - 2, x1 = x < 1 ? 0 : x - 1, x3 = x > n - 2 ? n - 1 : x + 1;
      final x4 = x > n - 3 ? n - 1 : x + 2;
      tmp[o + x] = (a[o + x0] + 4 * a[o + x1] + 6 * a[o + x] + 4 * a[o + x3] + a[o + x4]) * 0.0625;
    }
  }
  for (var x = 0; x < n; x++) {
    for (var y = 0; y < n; y++) {
      final y0 = y < 2 ? 0 : y - 2, y1 = y < 1 ? 0 : y - 1, y3 = y > n - 2 ? n - 1 : y + 1;
      final y4 = y > n - 3 ? n - 1 : y + 2;
      a[y * n + x] =
          (tmp[y0 * n + x] + 4 * tmp[y1 * n + x] + 6 * tmp[y * n + x] + 4 * tmp[y3 * n + x] + tmp[y4 * n + x]) * 0.0625;
    }
  }
}

class _Level {
  _Level(this.n, this.mask) : phi = Float32List(n * n);
  final int n;
  final Uint8List mask;
  final Float32List phi;
}

/* Δφ = −1 on the inside texels, φ = 0 outside: Gauss–Seidel with
   over-relaxation, cascaded from a quarter-size grid. */
Float32List _poisson(Uint8List cov, int nn, double u) {
  final levels = <_Level>[];
  for (var n = nn, f = 1; (f <= 4 && n % 2 == 0) || f == 1; n >>= 1, f <<= 1) {
    final mask = Uint8List(n * n);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        var sum = 0;
        for (var j = 0; j < f; j++) {
          for (var i = 0; i < f; i++) {
            sum += cov[(y * f + j) * nn + x * f + i];
          }
        }
        mask[y * n + x] = sum >= 128 * f * f ? 1 : 0;
      }
    }
    levels.add(_Level(n, mask));
    if (f == 4) break;
  }
  void sweep(_Level l, double s, int iters, double om) {
    final n = l.n, mask = l.mask, phi = l.phi, s2 = s * s;
    for (var it = 0; it < iters; it++) {
      for (var y = 1; y < n - 1; y++) {
        final o = y * n;
        for (var x = 1; x < n - 1; x++) {
          final i = o + x;
          if (mask[i] == 0) continue;
          final v = (phi[i - 1] + phi[i + 1] + phi[i - n] + phi[i + n] + s2) * 0.25;
          phi[i] += om * (v - phi[i]);
        }
      }
    }
  }

  for (var l = levels.length - 1; l >= 0; l--) {
    final lv = levels[l], f = 1 << l;
    if (l < levels.length - 1) {
      /* bilinear prolongation from the coarser level */
      final c = levels[l + 1], n = lv.n, cn = c.n;
      for (var y = 0; y < n; y++) {
        final fy = ((y + 0.5) / 2 - 0.5).clamp(0.0, cn - 1.0), y0 = fy.floor(), y1 = math.min(cn - 1, y0 + 1);
        final ty = fy - y0;
        for (var x = 0; x < n; x++) {
          final i = y * n + x;
          if (lv.mask[i] == 0) continue;
          final fx = ((x + 0.5) / 2 - 0.5).clamp(0.0, cn - 1.0), x0 = fx.floor(), x1 = math.min(cn - 1, x0 + 1);
          final tx = fx - x0;
          lv.phi[i] =
              (c.phi[y0 * cn + x0] * (1 - tx) + c.phi[y0 * cn + x1] * tx) * (1 - ty) +
              (c.phi[y1 * cn + x0] * (1 - tx) + c.phi[y1 * cn + x1] * tx) * ty;
        }
      }
    }
    final om = math.min(1.9, 2 / (1 + math.sin(math.pi / lv.n)) - 0.05);
    sweep(lv, u * f, 4, 1);
    sweep(lv, u * f, l == 2 ? 100 : (l == 1 ? 30 : 16), om);
    sweep(lv, u * f, 8, 1);
  }
  return levels[0].phi;
}

const _dx = [1, 1, 0, -1, -1, -1, 0, 1], _dy = [0, 1, 1, 1, 0, -1, -1, -1];
const _dl = [1.0, math.sqrt2, 1.0, math.sqrt2, 1.0, math.sqrt2, 1.0, math.sqrt2];

/// The form of one outline from its coverage raster (n × n, 0–255, over design
/// units [-pad, 100 + pad]).
BotAvatarForm buildForm(Uint8List cov, int n, double halfDepth) {
  final u = span / n, nn = n * n;
  final mask = Uint8List(nn);
  for (var i = 0; i < nn; i++) {
    mask[i] = cov[i] >= 128 ? 1 : 0;
  }

  /* signed distance to the outline, in design units, positive inside;
     antialiased edge texels give the sub-texel offset */
  final dIn = Float64List(nn), dOut = Float64List(nn), nearIn = Int32List(nn);
  edt2d(mask, 0, n, dIn, null);
  edt2d(mask, 1, n, dOut, nearIn);
  final sd = Float32List(nn), tmp = Float32List(nn);
  for (var i = 0; i < nn; i++) {
    final a = cov[i] / 255;
    sd[i] = u * (a > 0 && a < 1 ? a - 0.5 : (mask[i] != 0 ? math.sqrt(dIn[i]) - 0.5 : 0.5 - math.sqrt(dOut[i])));
  }
  /* round the medial-axis crease into a ridge (σ ≈ 2.2 texels) */
  _blur5(sd, n, tmp);
  _blur5(sd, n, tmp);

  /* the pillow: the torsion function; its height follows the inradius, so
     thin parts are their own low tubes */
  final phi = _poisson(cov, n, u);
  var phiMax = 0.0;
  for (var i = 0; i < nn; i++) {
    if (phi[i] > phiMax) phiMax = phi[i];
  }
  final rIn = 2 * math.sqrt(phiMax);
  final hMax = math.min(1.5 * halfDepth + 0.32 * rIn, 1.4 * rIn);
  final kh = phiMax > 0 ? hMax / math.sqrt(phiMax) : 0.0;
  final h = Float32List(nn);
  for (var i = 0; i < nn; i++) {
    h[i] = phi[i] > 0 ? kh * math.sqrt(phi[i]) : 0;
  }
  _blur5(h, n, tmp);

  /* normals, silhouette fix, horizon AO, matcap cells */
  final i00 = Uint16List(nn), wx = Uint8List(nn), wy = Uint8List(nn), ao = Uint8List(nn);
  final steps = n <= 64 ? const [1, 2, 3, 5, 8] : (n <= 96 ? const [1, 2, 4, 7, 11] : const [1, 2, 4, 7, 11, 15]);
  const halo = 64; // outside texels within 8 texels borrow their nearest inside texel
  final last = n - 1;
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final i = y * n + x;
      final src = mask[i] != 0 ? i : (dOut[i] <= halo ? nearIn[i] : -1);
      if (src < 0) continue;
      final sx = src % n, sy = (src - sx) ~/ n;
      final xl = sx > 0 ? sx - 1 : 0, xr = sx < last ? sx + 1 : last, yu = sy > 0 ? sy - 1 : 0;
      final yd = sy < last ? sy + 1 : last;
      var nx = -(h[sy * n + xr] - h[sy * n + xl]) / (2 * u);
      var ny = -(h[yd * n + sx] - h[yu * n + sx]) / (2 * u);
      var nz = 1.0;
      var len = math.sqrt(nx * nx + ny * ny + 1);
      nx /= len;
      ny /= len;
      nz /= len;
      final dd = math.max(0.0, sd[src]);
      if (dd < 2) {
        /* toward the in-plane outward direction, so the silhouette grazes */
        var gx = sd[sy * n + xr] - sd[sy * n + xl], gy = sd[yd * n + sx] - sd[yu * n + sx];
        var gl = math.sqrt(gx * gx + gy * gy);
        if (gl == 0) gl = 1;
        gx /= gl;
        gy /= gl;
        final w = 0.7 * (1 - dd / 2);
        nx += w * (-gx - nx);
        ny += w * (-gy - ny);
        nz += w * (0 - nz);
        len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len == 0) len = 1;
        nx /= len;
        ny /= len;
        nz /= len;
      }
      /* horizon-based occlusion on the height field */
      final h0 = h[src];
      var occ = 0.0;
      for (var d = 0; d < 8; d++) {
        var m = 0.0;
        for (final r in steps) {
          var qx = sx + _dx[d] * r, qy = sy + _dy[d] * r;
          if (qx < 0) {
            qx = 0;
          } else if (qx > last) {
            qx = last;
          }
          if (qy < 0) {
            qy = 0;
          } else if (qy > last) {
            qy = last;
          }
          final t = (h[qy * n + qx] - h0) / (r * u * _dl[d]);
          if (t > m) m = t;
        }
        occ += m / math.sqrt(1 + m * m);
      }
      final e = 1 - math.min(1.0, dd / 3);
      final edge = 1 - 0.2 * e * e;
      final aoLin = math.pow(1 - 0.9 * occ / 8, 1.5) * edge;
      ao[i] = math.max(1, (255 * math.pow(aoLin, 1 / 2.2)).round());
      final fx = (nx * 0.5 + 0.5) * (matcapM - 1), fy = (ny * 0.5 + 0.5) * (matcapM - 1);
      final cx = fx.floor().clamp(0, matcapM - 2), cy = fy.floor().clamp(0, matcapM - 2);
      i00[i] = cy * matcapM + cx;
      wx[i] = (255 * (fx - cx).clamp(0.0, 1.0)).round();
      wy[i] = (255 * (fy - cy).clamp(0.0, 1.0)).round();
    }
  }
  return BotAvatarForm(n: n, i00: i00, wx: wx, wy: wy, ao: ao, sd: sd, h: h);
}

/// A field on the form's grid read at any point, bilinear.
double bilerp(Float32List f, int n, double x, double y) {
  final last = n - 1;
  final fx = x < 0 ? 0.0 : (x > last ? last.toDouble() : x), fy = y < 0 ? 0.0 : (y > last ? last.toDouble() : y);
  final x0 = math.min(last - 1, fx.floor()), y0 = math.min(last - 1, fy.floor());
  final tx = fx - x0, ty = fy - y0, i = y0 * n + x0;
  return (f[i] * (1 - tx) + f[i + 1] * tx) * (1 - ty) + (f[i + n] * (1 - tx) + f[i + n + 1] * tx) * ty;
}

/* ── the profile: an inflated body, not an extruded one ────────────── */

/// The body's slices through its depth: at each depth the outline scaled to
/// the area and centre of where the surface stands at least that high.
class Relief {
  Relief(this.top, this.z, this.scale, this.cx, this.cy, this.inset, this.q);

  final double top;
  final Float32List z;
  final Float32List scale;
  final Float32List cx;
  final Float32List cy;
  final Float32List inset;
  final double q;
}

Relief reliefFor(BotAvatarForm form, int k, double round) {
  final q = round.clamp(0.05, 1.0);
  final key = '$k|${q.toStringAsFixed(2)}';
  final hit = form._reliefs[key];
  if (hit != null) return hit;
  final n = form.n, h = form.h, sd = form.sd;
  final top = form.top;
  final u = span / n;
  final z = Float32List(k), scale = Float32List(k), cx = Float32List(k), cy = Float32List(k);
  final inset = Float32List(k);
  inset[0] = 1.2;
  (double, double, double) measure(bool Function(int) inside) {
    var cnt = 0, sx = 0.0, sy = 0.0;
    var i = 0;
    for (var j = 0; j < n; j++) {
      for (var x = 0; x < n; x++, i++) {
        if (inside(i)) {
          cnt++;
          sx += x;
          sy += j;
        }
      }
    }
    return cnt > 0 ? (cnt.toDouble(), (sx / cnt + 0.5) * u - pad, (sy / cnt + 0.5) * u - pad) : (0.0, 50.0, 50.0);
  }

  final (a0, x0, y0) = measure((i) => sd[i] >= 0);
  scale[0] = 1;
  cx[0] = x0;
  cy[0] = y0;
  for (var l = 1; l < k; l++) {
    final s = l / k;
    z[l] = top * s;
    final tau = top * math.pow(s, 1 / q);
    final (ak, xk, yk) = measure((i) => sd[i] >= 0 && h[i] >= tau);
    scale[l] = math.min(scale[l - 1], a0 > 0 ? math.sqrt(ak / a0) : 1.0);
    cx[l] = xk;
    cy[l] = yk;
    final band = top / (2 * k);
    var cnt = 0, sum = 0.0;
    for (var i = 0; i < n * n; i++) {
      if (sd[i] > 0 && (h[i] - tau).abs() < band) {
        sum += sd[i];
        cnt++;
      }
    }
    inset[l] = math.max(inset[l - 1], cnt > 0 ? sum / cnt : inset[l - 1]);
  }
  final r = Relief(top, z, scale, cx, cy, inset, q);
  if (form._reliefs.length > 6) form._reliefs.clear();
  form._reliefs[key] = r;
  return r;
}

/// How high the surface stands at a design point: its depth from the centre
/// plane, in design units.
double surfaceAt(BotAvatarForm form, double x, double y, double round) {
  final n = form.n;
  final u = span / n;
  final v = bilerp(form.h, n, (x + pad) / u - 0.5, (y + pad) / u - 0.5);
  final top = form.top;
  if (top <= 0) return 0;
  final q = round.clamp(0.05, 1.0);
  return top * math.pow(math.max(0, v) / top, q);
}

/* ── the rim: the outline's extent along any direction ─────────────── */

/// The texels just inside the outline, each with its distance in (x, y, d).
Float32List rimOf(BotAvatarForm form) {
  final hit = form._rim;
  if (hit != null) return hit;
  final n = form.n, sd = form.sd;
  final u = span / n;
  final pts = <double>[];
  var i = 0;
  for (var j = 0; j < n; j++) {
    for (var x = 0; x < n; x++, i++) {
      if (sd[i] >= 0 && sd[i] < 2 * u) pts.addAll([(x + 0.5) * u - pad, (j + 0.5) * u - pad, sd[i]]);
    }
  }
  return form._rim = Float32List.fromList(pts);
}

/// About a hundred of the rim's points, in order round its middle.
class Ring {
  Ring(this.x, this.y, this.d);
  final Float32List x;
  final Float32List y;
  final Float32List d;
}

Ring ringOf(BotAvatarForm form) {
  final hit = form._ring;
  if (hit != null) return hit;
  final rim = rimOf(form);
  final cnt = rim.length ~/ 3;
  var mx = 0.0, my = 0.0;
  for (var i = 0; i < rim.length; i += 3) {
    mx += rim[i];
    my += rim[i + 1];
  }
  mx /= cnt == 0 ? 1 : cnt;
  my /= cnt == 0 ? 1 : cnt;
  final all = [
    for (var i = 0; i < rim.length; i += 3) (rim[i], rim[i + 1], math.atan2(rim[i + 1] - my, rim[i] - mx), rim[i + 2]),
  ];
  all.sort((p, q) => p.$3.compareTo(q.$3));
  final step = math.max(1, all.length ~/ 96);
  final pts = [for (var i = 0; i < all.length; i += step) all[i]];
  return form._ring = Ring(
    Float32List.fromList([for (final p in pts) p.$1]),
    Float32List.fromList([for (final p in pts) p.$2]),
    Float32List.fromList([for (final p in pts) p.$4]),
  );
}

/// The ring's points from the one nearest angle `a` outward, both ways.
int ringOrder(int n, double a, int k) {
  final start = (((a + math.pi) / (2 * math.pi)) * n).round();
  final off = k & 1 == 1 ? (k + 1) >> 1 : -(k >> 1);
  return (((start + off) % n) + n) % n;
}

/// How far the outline reaches along (ex, ey).
double reach(Float32List rim, double ex, double ey) {
  var m = -_inf;
  for (var i = 0; i < rim.length; i += 3) {
    final v = rim[i] * ex + rim[i + 1] * ey + rim[i + 2];
    if (v > m) m = v;
  }
  return m;
}

/* ── fabric's lift and soft edge ───────────────────────────────────── */

/// Fabric's lift near the edge, per texel: the baked occlusion with the edge's
/// darkening taken back out (a pile's edge catches the light), and a gain.
class Lift {
  Lift(this.ao, this.k);
  final Uint8List ao;
  final Float32List k;
}

Lift edgeLift(BotAvatarForm form) {
  final hit = form._lift;
  if (hit != null) return hit;
  final n = form.n, sd = form.sd, ao = form.ao;
  final l = Lift(Uint8List(n * n), Float32List(n * n));
  for (var i = 0; i < n * n; i++) {
    if (ao[i] == 0) continue;
    final dd = math.max(0.0, sd[i]);
    final e = 1 - math.min(1.0, dd / 3);
    final edge = 1 - 0.2 * e * e;
    final lin = math.min(1.0, math.pow(ao[i] / 255, 2.2) / edge);
    l.ao[i] = math.max(1, (255 * math.pow(lin, 1 / 2.2)).round());
    l.k[i] = 1;
  }
  return form._lift = l;
}

/* ── how far fabric's stretched halo misses a turned stack ─────────── */

const missN = 96;
const missStep = 0.1;

/// The stack's cells outside the outline (`cut`) and the outline's cells away
/// from the stack (`over`), in design units, with the halo stretch `s` undone.
(double, double) measureMiss(
  BotAvatarForm form,
  List<Float64List> polys,
  Relief rel,
  int k,
  List<double> s,
  double dxs,
  double dys,
) {
  final u = span / missN;
  final det = s[0] * s[3] - s[1] * s[2];
  final ia = s[3] / det, ib = -s[1] / det, ic = -s[2] / det, id = s[0] / det;
  final ie = -(ia * s[4] + ic * s[5]), jf = -(ib * s[4] + id * s[5]);
  final on = Uint8List(missN * missN);
  for (var l = 0; l < k; l++) {
    for (final z in l > 0 ? [rel.z[l], -rel.z[l]] : const [0.0]) {
      var m = <double>[1 / u, 0, 0, 1 / u, pad / u, pad / u];
      m = mulAffine(m, [ia, ib, ic, id, ie, jf]);
      m = mulAffine(m, [1, 0, 0, 1, z * dxs, z * dys]);
      final sk = rel.scale[l];
      if (l > 0) m = mulAffine(m, [sk, 0, 0, sk, rel.cx[l] - sk * rel.cx[0], rel.cy[l] - sk * rel.cy[0]]);
      final cov = rasterize(polys, missN, m);
      for (var i = 0; i < cov.length; i++) {
        if (cov[i] > 127) on[i] = 1;
      }
    }
  }
  final dist = Float64List(missN * missN);
  edt2d(on, 1, missN, dist, null);
  var cut = 0.0, over = 0.0;
  var i = 0;
  for (var y = 0; y < missN; y++) {
    for (var x = 0; x < missN; x++, i++) {
      final d = bilerp(form.sd, form.n, ((x + 0.5) / missN) * form.n - 0.5, ((y + 0.5) / missN) * form.n - 0.5);
      if (on[i] != 0 && d < 0) cut = math.max(cut, -d);
      if (on[i] == 0 && d > 0) over = math.max(over, math.sqrt(dist[i]) * u);
    }
  }
  return (cut, over);
}

/// A · B for canvas affines (a, b, c, d, e, f).
List<double> mulAffine(List<double> a, List<double> b) => [
  a[0] * b[0] + a[2] * b[1],
  a[1] * b[0] + a[3] * b[1],
  a[0] * b[2] + a[2] * b[3],
  a[1] * b[2] + a[3] * b[3],
  a[0] * b[4] + a[2] * b[5] + a[4],
  a[1] * b[4] + a[3] * b[5] + a[5],
];
