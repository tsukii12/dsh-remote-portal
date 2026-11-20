// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'presets.dart';

/// The shader maths of shaders/fx/img_fx_*.frag on the CPU, line for line: the
/// renderer falls back to it when the fragment programs can't load (widget
/// tests), and the reveal samples the raw field through it there.
///
/// Coordinates follow the shader: uv in 0..1 with the origin at the bottom left.
class FxField {
  FxField(FxPresetMode mode, FxLook look, {double strength = 1})
    : effect = mode.effectIndex,
      speed = mode.speed,
      intensity = mode.intensity * _boost(strength),
      scale = mode.scale,
      direction = mode.direction * math.pi / 180,
      distortion = mode.distortion,
      complexity = mode.complexity,
      shape = mode.shape,
      flicker = mode.flicker,
      blur = mode.blur,
      sweepEase = mode.sweepEase.floor(),
      vignette = mode.vignette,
      vigOpacity = mode.vigOpacity,
      highlight = mode.highlight * _boost(strength),
      hlScale = mode.pixel.hlScale,
      _colors = Float64List.fromList([
        for (var i = 0; i < 5; i++) ...[look.colors[i].r, look.colors[i].g, look.colors[i].b],
      ]);

  /// renderer.ts: strength above 1 boosts intensity and highlight.
  static double _boost(double strength) => 1 + math.max(0, strength - 1) * 2.2;

  final int effect;
  final double speed, intensity, scale, direction, distortion, complexity, shape, flicker, blur;
  final int sweepEase;
  final double vignette, vigOpacity, highlight, hlScale;
  final Float64List _colors;

  // Scratch for the two-component helpers.
  double _wx = 0, _wy = 0;

  static double _fract(double x) => x - x.floorToDouble();
  static double _mod289(double x) => x - (x * (1 / 289)).floorToDouble() * 289;
  static double _permute(double x) => _mod289((x * 34 + 1) * x);
  static double _smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Ashima 2D simplex noise (`snoise`).
  static double snoise(double vx, double vy) {
    const cx = 0.211324865405187, cy = 0.366025403784439, cz = -0.577350269189626, cw = 0.024390243902439;
    final s = (vx + vy) * cy;
    var ix = (vx + s).floorToDouble();
    var iy = (vy + s).floorToDouble();
    final t = (ix + iy) * cx;
    final x0x = vx - ix + t, x0y = vy - iy + t;
    final i1x = x0x > x0y ? 1.0 : 0.0, i1y = x0x > x0y ? 0.0 : 1.0;
    final x12x = x0x + cx - i1x, x12y = x0y + cx - i1y;
    final x12z = x0x + cz, x12w = x0y + cz;
    ix = _mod289(ix);
    iy = _mod289(iy);
    final p0 = _permute(_permute(iy) + ix);
    final p1 = _permute(_permute(iy + i1y) + ix + i1x);
    final p2 = _permute(_permute(iy + 1) + ix + 1);
    var m0 = math.max(0.5 - (x0x * x0x + x0y * x0y), 0.0);
    var m1 = math.max(0.5 - (x12x * x12x + x12y * x12y), 0.0);
    var m2 = math.max(0.5 - (x12z * x12z + x12w * x12w), 0.0);
    m0 = m0 * m0;
    m0 = m0 * m0;
    m1 = m1 * m1;
    m1 = m1 * m1;
    m2 = m2 * m2;
    m2 = m2 * m2;
    final xa = 2 * _fract(p0 * cw) - 1, xb = 2 * _fract(p1 * cw) - 1, xc = 2 * _fract(p2 * cw) - 1;
    final ha = xa.abs() - 0.5, hb = xb.abs() - 0.5, hc = xc.abs() - 0.5;
    final aa = xa - (xa + 0.5).floorToDouble(), ab = xb - (xb + 0.5).floorToDouble();
    final ac = xc - (xc + 0.5).floorToDouble();
    m0 *= 1.79284291400159 - 0.85373472095314 * (aa * aa + ha * ha);
    m1 *= 1.79284291400159 - 0.85373472095314 * (ab * ab + hb * hb);
    m2 *= 1.79284291400159 - 0.85373472095314 * (ac * ac + hc * hc);
    final g0 = aa * x0x + ha * x0y;
    final g1 = ab * x12x + hb * x12y;
    final g2 = ac * x12z + hc * x12w;
    return 130 * (m0 * g0 + m1 * g1 + m2 * g2);
  }

  double _nfbm(double px, double py) {
    final n = (2 + complexity * 2).toInt();
    var val = 0.0, amp = 0.5;
    for (var i = 0; i < 4 && i < n; i++) {
      val += amp * snoise(px, py);
      px *= 2;
      py *= 2;
      amp *= 0.5;
    }
    return val;
  }

  void _warp(double px, double py, double t) {
    final str = distortion * 2;
    final x = _nfbm(px + t * 0.1, py);
    final y = _nfbm(px + 5, py + t * 0.12 + 5);
    _wx = x * str;
    _wy = y * str;
  }

  double _sweepEaseFn(double x) => switch (sweepEase) {
    1 => x * x * (3 - 2 * x),
    2 => 1 - math.pow(1 - x, 3),
    3 => x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) * 0.5,
    4 => 1 - math.pow(2, -10 * x) * (1 - x),
    _ => x,
  }.toDouble();

  void _palette(double t, Float64List out) {
    t = t.clamp(0.0, 1.0);
    t = t * t * (3 - 2 * t);
    const k = 64.0;
    final w = [
      math.exp(-k * t * t),
      math.exp(-k * (t - 0.25) * (t - 0.25)),
      math.exp(-k * (t - 0.5) * (t - 0.5)),
      math.exp(-k * (t - 0.75) * (t - 0.75)),
      math.exp(-k * (t - 1) * (t - 1)),
    ];
    final total = w[0] + w[1] + w[2] + w[3] + w[4] + 0.0001;
    for (var c = 0; c < 3; c++) {
      var v = 0.0;
      for (var i = 0; i < 5; i++) {
        v += _colors[i * 3 + c] * w[i];
      }
      out[c] = v / total;
    }
  }

  void _softBlend(double a, double b, double c, Float64List out) {
    a = a.clamp(0.0, 1.0);
    a *= a;
    b = b.clamp(0.0, 1.0);
    b *= b;
    c = c.clamp(0.0, 1.0);
    c *= c;
    var d = (a * 0.7 + c * 0.3).clamp(0.0, 1.0);
    d *= d;
    var e = (b * 0.5 + c * 0.5).clamp(0.0, 1.0);
    e *= e;
    final w = [a, b, c, d, e];
    final total = a + b + c + d + e;
    final floorW = math.max(0.001 - total, 0.0);
    for (var ch = 0; ch < 3; ch++) {
      var v = 0.0, fallback = 0.0;
      for (var i = 0; i < 5; i++) {
        v += _colors[i * 3 + ch] * w[i];
        fallback += _colors[i * 3 + ch];
      }
      out[ch] = (v + fallback * 0.2 * floorW) / (total + floorW);
    }
  }

  /// `computeEffect` for the three bundled effects; [cells] is the mosaic grid
  /// (Gradient Sweep's flicker cells).
  void computeEffect(double u, double v, double aspect, double t, int gx, int gy, Float64List out) {
    final dist = distortion, cpx = complexity, shp = shape;
    var px = (u - 0.5) * scale * aspect;
    var py = (v - 0.5) * scale;
    px += math.cos(direction) * t * 0.15;
    py += math.sin(direction) * t * 0.15;
    switch (effect) {
      case 11:
        final qx = _nfbm(px * 0.5 + t * 0.05, py * 0.5);
        final qy = _nfbm(px * 0.5, py * 0.5 + t * 0.07);
        final k = 1 + dist * 1.5;
        final rx = _nfbm(px * 0.6 + qx * k + 1.7 + t * 0.03, py * 0.6 + qy * k + 9.2 + t * 0.03);
        final ry = _nfbm(px * 0.6 + qx * k + 8.3 + t * 0.04, py * 0.6 + qy * k + 2.8 + t * 0.04);
        final f = _nfbm(px + rx * 1.5, py + ry * 1.5);
        final f2 = _nfbm(px * 0.7 + rx + 3, py * 0.7 + ry + 7);
        final f3 = _nfbm(px * 0.4 - t * 0.02, py * 0.4 - t * 0.02);
        _softBlend((f * 0.5 + 0.5) * intensity, (f2 * 0.5 + 0.5) * intensity, (f3 * 0.5 + 0.5) * intensity, out);
      case 22:
        _warp(px * 0.7, py * 0.7, t * 0.5);
        final wx = _wx, wy = _wy;
        _warp(px * 0.4 + wx * 0.3, py * 0.4 + wy * 0.3, t * 0.3);
        final w2x = _wx, w2y = _wy;
        final wpx = px + wx * (0.4 + dist * 0.6), wpy = py + wy * (0.4 + dist * 0.6);
        final s1 = 1.4 + cpx * 1.6;
        final n1 = snoise(wpx * s1 + t * 0.14, wpy * s1 + t * 0.14);
        final s2 = 2 + cpx * 2;
        final n2 = snoise((wpx + w2x * dist * 0.4) * s2 + 3 - t * 0.1, (wpy + w2y * dist * 0.4) * s2 + 7 - t * 0.1);
        final ridge1 = math.pow(1 - n1.abs(), 5 + shp * 12).toDouble();
        final ridge2 = math.pow(1 - n2.abs(), 4 + shp * 10).toDouble();
        final base = (n1 + n2) * 0.25 + 0.5;
        _softBlend(
          (base * 0.6 + ridge1 * 1.2) * intensity,
          ((1 - base) * 0.6 + ridge2) * intensity,
          (ridge1 * 0.8 + ridge2 * 0.6) * intensity,
          out,
        );
      case 25:
        final d = (u + (1 - v)) * 0.5;
        final w = 0.9 / math.max(scale, 0.25);
        final cyc = t * 0.08;
        final pA = -w + (1 + 2 * w) * _sweepEaseFn(_fract(cyc));
        final pB = -w + (1 + 2 * w) * _sweepEaseFn(_fract(cyc + 0.5));
        final band = math.max((1 - (d - pA).abs() / w).clamp(0.0, 1.0), (1 - (d - pB).abs() / w).clamp(0.0, 1.0));
        var val = band * intensity;
        final cellX = (u * gx).floorToDouble(), cellY = (v * gy).floorToDouble();
        final clk = t * 1.6;
        final step0 = clk.floorToDouble() % 1024;
        final step1 = (step0 + 1) % 1024;
        final fz = _smoothstep(0, 1, _fract(clk));
        final seed = cellX * 127.1 + cellY * 311.7;
        final r1 = _fract(math.sin(seed + step0 * 17.23) * 43758.5453);
        final r2 = _fract(math.sin(seed + step1 * 17.23) * 43758.5453);
        val += (r1 + (r2 - r1) * fz - 0.5) * flicker * 0.9 * (0.15 + band * 0.85);
        _palette(val.clamp(0.0, 1.0), out);
      default:
        out[0] = out[1] = out[2] = 0;
    }
  }

  final _tap = Float64List(3);

  /// `imgfx_effectColor`: the effect colour with the 5-tap blur.
  void effectColor(double u, double v, double aspect, double t, int gx, int gy, Float64List out) {
    if (blur < 0.01) {
      computeEffect(u, v, aspect, t, gx, gy, out);
      return;
    }
    final r = blur * 0.02;
    computeEffect(u, v, aspect, t, gx, gy, out);
    for (var c = 0; c < 3; c++) {
      out[c] *= 0.4;
    }
    for (final (du, dv) in const [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)]) {
      computeEffect(u + du * r, v + dv * r, aspect, t, gx, gy, _tap);
      for (var c = 0; c < 3; c++) {
        out[c] += _tap[c] * 0.15;
      }
    }
  }

  /// `imgfx_cellHighlight`.
  double cellHighlight(double u, double v, double aspect, double t) {
    if (highlight <= 0.01 && hlScale <= 0.01) return 0;
    final x = (u - 0.5) * scale * aspect, y = (v - 0.5) * scale;
    var lw = math.sin(x * 3 + t * 1.5) * 0.5 + 0.5;
    lw *= math.sin(y * 2.5 - t * 1.1) * 0.5 + 0.5;
    lw += (snoise(x * 2 + t * 0.6, y * 2 + t * 0.6) * 0.5 + 0.5) * 0.3;
    final h = lw.clamp(0.0, 1.0);
    return h * h;
  }

  /// Vignette factor at [edgeDistPx] (`imgfx_shade`).
  double vignetteAt(double edgeDistPx) {
    final range = 40 * (1 + vignette * 3);
    final vig = _smoothstep(0, 1, edgeDistPx * edgeDistPx / (range * range));
    return 1 + (vig - 1) * vignette * vigOpacity;
  }

  static double edgeDistance(double u, double v, Size size) {
    final x = u * size.width, y = v * size.height;
    return math.min(math.min(x, size.width - x), math.min(y, size.height - y));
  }

  /// The raw field (u_dotMode 0) sampled on an [n]×[n] grid, row 0 at the top,
  /// as RGBA bytes: what the reveal reads back from the GPU.
  Uint8List rawSample(int n, Size size, double time, int gx, int gy) {
    final out = Uint8List(n * n * 4);
    final col = Float64List(3);
    final aspect = size.width / size.height;
    final t = time * speed;
    for (var r = 0; r < n; r++) {
      final v = (n - (r + 0.5)) / n;
      for (var c = 0; c < n; c++) {
        final u = (c + 0.5) / n;
        effectColor(u, v, aspect, t, gx, gy, col);
        final vig = vignetteAt(edgeDistance(u, v, size));
        final i = (r * n + c) * 4;
        for (var ch = 0; ch < 3; ch++) {
          final x = math.pow(col[ch], 1.3) * vig;
          out[i + ch] = (x.clamp(0.0, 1.0) * 255 + 0.5).floor();
        }
        out[i + 3] = 255;
      }
    }
    return out;
  }
}
