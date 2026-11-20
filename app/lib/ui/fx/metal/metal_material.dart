// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 原作的三套配色（metal-fx v2 `presets.ts`）：同一种银色材质，靠颜色加深（color-burn）
/// 的色调和红蓝色散区分。不传预设时用 [MetalMaterial.themed]（跟主题的石墨银）。
enum MetalPreset { chromatic, silver, gold }

/// Paper Shaders `liquidMetal` 的参数，加上 metal-fx 合成时乘的整体不透明度。
@immutable
class MetalMaterial {
  const MetalMaterial({
    this.colorBack = const Color(0x00000000),
    this.colorTint = const Color(0x00FFFFFF),
    this.speed = 1,
    this.repetition = 1.5,
    this.softness = 0.05,
    this.shiftRed = 0.3,
    this.shiftBlue = 0.3,
    this.distortion = 0.1,
    this.contour = 0.4,
    this.angle = 90,
    this.shaderOpacity = 1,
  });

  /// The author's three looks, in the theme's light or dark tuning.
  factory MetalMaterial.preset(MetalPreset preset, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch ((preset, dark)) {
      (MetalPreset.chromatic, true) => const MetalMaterial(
        colorTint: Color(0x2E88CCFF),
        shiftRed: 0.75,
        shiftBlue: 0.75,
        repetition: 2,
        softness: 0.09,
      ),
      (MetalPreset.chromatic, false) => const MetalMaterial(
        colorTint: Color(0x9966B0FF),
        shiftRed: 0.6,
        shiftBlue: 0.6,
      ),
      (MetalPreset.silver, true) => const MetalMaterial(colorTint: Color(0x66FFFFFF), shaderOpacity: 0.88),
      (MetalPreset.silver, false) => const MetalMaterial(colorTint: Color(0x40FFFFFF)),
      (MetalPreset.gold, true) => const MetalMaterial(colorTint: Color(0xCCFFCC55), speed: 0.85, shaderOpacity: 0.92),
      (MetalPreset.gold, false) => const MetalMaterial(colorTint: Color(0xAAF7D488)),
    };
  }

  /// 默认的石墨银：原作 silver 的材质，色调取主题主色的色相、饱和度压得很低，
  /// 色散也收一点，深浅主题都不扎眼。
  factory MetalMaterial.themed(Color primary, Brightness brightness) {
    final base = HSLColor.fromColor(primary);
    final tint = HSLColor.fromAHSL(0.55, base.hue, (base.saturation * 0.3).clamp(0.04, 0.14), 0.72).toColor();
    return MetalMaterial(
      colorTint: tint,
      shiftRed: 0.18,
      shiftBlue: 0.18,
      shaderOpacity: brightness == Brightness.dark ? 0.88 : 1,
    );
  }

  /// [preset] in [brightness]'s tuning, or the theme's graphite silver when null.
  static MetalMaterial resolve(MetalPreset? preset, Color primary, Brightness brightness) =>
      preset == null ? MetalMaterial.themed(primary, brightness) : MetalMaterial.preset(preset, brightness);

  /// Backdrop RGBA, composited under the material. Transparent for rings.
  final Color colorBack;

  /// Tint applied as colour-burn; its alpha is the blend amount, not an opacity.
  final Color colorTint;

  /// Time multiplier.
  final double speed;

  /// Stripe density (1..10).
  final double repetition;

  /// Stripe transition blur (0..1).
  final double softness;

  /// R / B channel dispersion (-1..1).
  final double shiftRed;
  final double shiftBlue;

  /// Simplex-noise warp over the stripes (0..1).
  final double distortion;

  /// Edge-following strength (0..1).
  final double contour;

  /// Drift direction, degrees.
  final double angle;

  /// Global alpha the material is composited at.
  final double shaderOpacity;

  @override
  bool operator ==(Object other) =>
      other is MetalMaterial &&
      other.colorBack == colorBack &&
      other.colorTint == colorTint &&
      other.speed == speed &&
      other.repetition == repetition &&
      other.softness == softness &&
      other.shiftRed == shiftRed &&
      other.shiftBlue == shiftBlue &&
      other.distortion == distortion &&
      other.contour == contour &&
      other.angle == angle &&
      other.shaderOpacity == shaderOpacity;

  @override
  int get hashCode => Object.hash(
    colorBack,
    colorTint,
    speed,
    repetition,
    softness,
    shiftRed,
    shiftBlue,
    distortion,
    contour,
    angle,
    shaderOpacity,
  );

  // ── CPU sampler ─────────────────────────────────────────────────────────
  // The shader's arithmetic on the CPU (minus dithering), as in the author's
  // SwiftUI port: the glow hunts luminance with it at 16 points instead of
  // reading pixels back from the GPU.

  /// Linear RGB (0..1) of the material at sheet coordinate ([u], [v]) after
  /// [time] seconds (before [speed]).
  (double, double, double) sample(double u, double v, double time) {
    final t = 0.3 * (time * speed + 2.8);
    final cw = repetition * 2;
    final noise = _snoise(u - t, v - t);
    final f = _field(u, v, t, noise, cw);
    final fx = _field(u + _texel, v, t, noise, cw);
    final fy = _field(u, v + _texel, t, noise, cw);
    final fw = (fx.direction - f.direction).abs() + (fy.direction - f.direction).abs();

    final uvcx = u.clamp(0.0, 1.0), uvcy = v.clamp(0.0, 1.0);
    final mx = math.min(uvcx, 1 - uvcx), my = math.min(uvcy, 1 - uvcy);
    final rawEdge = (1 - math.pow(_ss(0, 0.5, mx), 0.25) * math.pow(_ss(0, 0.5, my), 0.25)).clamp(0.0, 1.0);
    final opacity = 1 - _ss(0.9 - 0.004, 0.9, rawEdge.toDouble());

    final c2b = 0.1 + 0.1 * _ss(0.7, 1.3, f.diagTL);
    final bump = f.bump, edge = f.edge, direction = f.direction;
    final thin1 = 0.12 / cw * (1 - 0.4 * bump);
    final thin2 = 0.07 / cw * (1 + 0.4 * bump);
    final w0 = cw * thin1, w2 = 1 - thin1 - thin2;
    var w1 = cw * thin2;

    final dispersion = (1 - bump).clamp(0.0, 1.0);
    var dR = dispersion;
    dR += 0.03 * bump * noise;
    dR += 5 * (_ss(-0.1, 0.2, v) * (1 - _ss(0.1, 0.5, v))) * (_ss(0.4, 0.6, bump) * (1 - _ss(0.4, 1.0, bump)));
    dR -= f.diagBL;
    var dB = dispersion * 1.3;
    dB += (_ss(0, 0.4, v) * (1 - _ss(0.1, 0.8, v))) * (_ss(0.4, 0.6, bump) * (1 - _ss(0.4, 0.8, bump)));
    dB -= 0.2 * edge;
    dR *= shiftRed / 20;
    dB *= shiftBlue / 20;

    final blur = softness / 15 + fw;
    w1 -= 0.02 * _ss(0, 1, edge + bump);

    final r = _colorChanges(0.98, 0.1, _fract(direction + dR), w0, w1, w2, blur, bump, colorTint.r);
    final g = _colorChanges(0.98, 0.1, _fract(direction), w0, w1, w2, blur, bump, colorTint.g);
    final b = _colorChanges(1.0, c2b, _fract(direction - dB), w0, w1, w2, blur, bump, colorTint.b);
    final back = colorBack.a * (1 - opacity);
    return (r * opacity + colorBack.r * back, g * opacity + colorBack.g * back, b * opacity + colorBack.b * back);
  }

  /// Rec. 709 luminance of [sample].
  double luminance(double u, double v, double time) {
    final (r, g, b) = sample(u, v, time);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  static const _texel = 1.0 / 192.0;

  _Field _field(double u, double v, double t, double noise, double cw) {
    final uvcx = u.clamp(0.0, 1.0), uvcy = v.clamp(0.0, 1.0);
    final mx = math.min(uvcx, 1 - uvcx), my = math.min(uvcy, 1 - uvcy);
    final maskX = math.pow(_ss(0, 0.5, mx), 0.25);
    final maskY = math.pow(_ss(0, 0.5, my), 0.25);
    var edge = (1 - maskX * maskY).clamp(0.0, 1.0).toDouble();
    edge = _mix(_ss(0.9 - 0.004, 0.9, edge), edge, _ss(0, 0.4, contour));
    edge = 1.2 * edge;

    final a = (-angle + 70) * math.pi / 180;
    final cosA = math.cos(a), sinA = math.sin(a);
    final rx = u - 0.5, ry = v - 0.5;
    final rotX = rx * cosA - ry * sinA + 0.5;
    final rotY = rx * sinA + ry * cosA + 0.5;
    final diagBL = rotX - rotY;
    final diagTL = rotX + rotY;

    final gx = u - 0.5, gy = v - 0.5;
    final dist = math.sqrt(gx * gx + (gy + 0.2 * diagBL) * (gy + 0.2 * diagBL));
    final th = (0.25 - 0.2 * diagBL) * math.pi;
    var direction = math.cos(th) * gx - math.sin(th) * gy;

    final uy = math.max(uvcy, 0.0);
    var bump = 1 - math.pow(1.8 * dist, 1.2).toDouble();
    bump *= math.pow(uy, 0.3);

    edge += (1 - edge) * distortion * noise;

    direction += diagBL;
    final sE = _ss(0, 1, edge);
    direction -= 2 * noise * diagBL * (sE * (1 - sE));
    final c51 = _ss(0.5, 1, contour);
    direction *= _mix(1, 1 - edge, c51);
    direction -= 1.7 * edge * c51;
    direction += 0.2 * math.pow(contour, 4) * (1 - sE);

    bump *= math.pow(uy, 0.1).clamp(0.3, 1.0);
    direction *= 0.1 + (1.1 - edge) * bump;
    direction *= 0.4 + 0.6 * (1 - _ss(0.5, 1, edge));
    direction += 0.18 * (_ss(0.1, 0.2, v) * (1 - _ss(0.2, 0.4, v)));
    direction += 0.03 * (_ss(0.1, 0.2, 1 - v) * (1 - _ss(0.2, 0.4, 1 - v)));
    direction *= 0.5 + 0.5 * v * v;
    direction *= cw;
    direction -= t;
    return (direction: direction, bump: bump, edge: edge, diagBL: diagBL, diagTL: diagTL);
  }

  double _colorChanges(
    double c1,
    double c2,
    double p,
    double w0,
    double w1,
    double w2,
    double blurIn,
    double bump,
    double tint,
  ) {
    final blur = math.max(blurIn, 1e-5);
    var ch = _mix(c2, c1, _ss(0, 2 * blur, p));
    var border = w0;
    ch = _mix(ch, c2, _ss(border, border + 2 * blur, p));
    border = w0 + 0.4 * (1 - bump) * w1;
    ch = _mix(ch, c1, _ss(border, border + 2 * blur, p));
    border = w0 + 0.5 * (1 - bump) * w1;
    ch = _mix(ch, c2, _ss(border, border + 2 * blur, p));
    border = w0 + w1;
    ch = _mix(ch, c1, _ss(border, border + 2 * blur, p));
    final gradient = _mix(c1, c2, _ss(0, 1, (p - w0 - w1) / w2));
    ch = _mix(ch, gradient, _ss(border, border + 0.5 * blur, p));
    return _mix(ch, 1 - math.min(1, (1 - ch) / math.max(tint, 0.0001)), colorTint.a);
  }
}

typedef _Field = ({double direction, double bump, double edge, double diagBL, double diagTL});

/// How a box maps onto the web's material sheet. The web renders the material
/// onto one square sheet and crops a window per instance, sized by the box
/// against a 140×40 canonical pill divided by `shaderScale`; larger boxes clamp
/// to the whole sheet. `uv = origin + position * scale`.
@immutable
class MetalSheetMapping {
  factory MetalSheetMapping(Size size, double shaderScale) {
    final w = math.max(1.0, size.width), h = math.max(1.0, size.height);
    final fx = math.min(1.0, w / (canonicalWidth * shaderScale));
    final fy = math.min(1.0, h / (canonicalHeight * shaderScale));
    return MetalSheetMapping._(0.5 - 0.5 * fx, 0.5 - 0.5 * fy, fx / w, fy / h);
  }

  const MetalSheetMapping._(this.originX, this.originY, this.scaleX, this.scaleY);

  static const canonicalWidth = 140.0;
  static const canonicalHeight = 40.0;

  final double originX;
  final double originY;
  final double scaleX;
  final double scaleY;

  (double, double) uv(Offset p) => (originX + p.dx * scaleX, originY + p.dy * scaleY);
}

double _fract(double x) => x - x.floorToDouble();

double _mix(double a, double b, double t) => a + (b - a) * t;

/// The shader's `mfxSs`: a smoothstep that tolerates e1 <= e0.
double _ss(double e0, double e1, double x) {
  final e1c = math.max(e1, e0 + 1e-6);
  final t = ((x - e0) / (e1c - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _mod289(double x) => x - 289 * (x / 289).floorToDouble();

double _permute(double x) => _mod289((x * 34 + 1) * x);

double _snoise(double vx, double vy) {
  const cx = 0.211324865405187, cy = 0.366025403784439, cz = -0.577350269189626, cw = 0.024390243902439;
  final s = (vx + vy) * cy;
  var ix = (vx + s).floorToDouble();
  var iy = (vy + s).floorToDouble();
  final t = (ix + iy) * cx;
  final x0x = vx - ix + t, x0y = vy - iy + t;
  final i1x = x0x > x0y ? 1.0 : 0.0, i1y = 1 - i1x;
  final x1x = x0x + cx - i1x, x1y = x0y + cx - i1y;
  final x2x = x0x + cz, x2y = x0y + cz;
  ix = _mod289(ix);
  iy = _mod289(iy);
  final p0 = _permute(_permute(iy) + ix);
  final p1 = _permute(_permute(iy + i1y) + ix + i1x);
  final p2 = _permute(_permute(iy + 1) + ix + 1);
  double corner(double p, double ax, double ay) {
    var m = math.max(0.5 - (ax * ax + ay * ay), 0.0);
    m = m * m;
    m = m * m;
    final x = 2 * _fract(p * cw) - 1;
    final h = x.abs() - 0.5;
    final a0 = x - (x + 0.5).floorToDouble();
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    return m * (a0 * ax + h * ay);
  }

  return 130 * (corner(p0, x0x, x0y) + corner(p1, x1x, x1y) + corner(p2, x2x, x2y));
}
