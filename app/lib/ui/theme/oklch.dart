// The colour maths behind the palettes (accent.dart,
// palette.dart). OKLab after Björn Ottosson (2020), public domain matrices.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// 一个 OKLCH 颜色:明度 [l](0–1)、彩度 [c]、色相 [h](度)。
///
/// 整套配色都在这里推:同一个明度在任何色相上看起来一样亮,所以「换色相、
/// 留明度」就能让六套配色的对比度落在同一档。
@immutable
class Oklch {
  const Oklch(this.l, this.c, this.h);

  final double l;
  final double c;
  final double h;

  factory Oklch.fromColor(Color color) {
    final r = _toLinear(color.r);
    final g = _toLinear(color.g);
    final b = _toLinear(color.b);
    final lp = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final mp = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final sp = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp;
    final a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp;
    final bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp;
    final c = math.sqrt(a * a + bb * bb);
    final h = (math.atan2(bb, a) * 180 / math.pi) % 360;
    return Oklch(l, c, h);
  }

  Oklch copyWith({double? l, double? c, double? h}) => Oklch(l ?? this.l, c ?? this.c, h ?? this.h);

  /// 转回 sRGB。超出色域时**只降彩度**(明度和色相不动),所以对比度不受影响。
  Color toColor({double alpha = 1}) {
    final l = this.l.clamp(0.0, 1.0);
    var c = math.max(0.0, this.c);
    var rgb = _linear(l, c, h);
    if (!_inGamut(rgb)) {
      var lo = 0.0;
      var hi = c;
      for (var i = 0; i < 24; i++) {
        final mid = (lo + hi) / 2;
        if (_inGamut(_linear(l, mid, h))) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      c = lo;
      rgb = _linear(l, c, h);
    }
    int channel(double v) => (_toGamma(v.clamp(0.0, 1.0)) * 255).round().clamp(0, 255);
    return Color.fromARGB((alpha * 255).round(), channel(rgb.$1), channel(rgb.$2), channel(rgb.$3));
  }

  static (double, double, double) _linear(double l, double c, double h) {
    final rad = h * math.pi / 180;
    final a = c * math.cos(rad);
    final b = c * math.sin(rad);
    final lp = l + 0.3963377774 * a + 0.2158037573 * b;
    final mp = l - 0.1055613458 * a - 0.0638541728 * b;
    final sp = l - 0.0894841775 * a - 1.2914855480 * b;
    final l3 = lp * lp * lp;
    final m3 = mp * mp * mp;
    final s3 = sp * sp * sp;
    return (
      4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
      -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
      -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
    );
  }

  static bool _inGamut((double, double, double) rgb) {
    const eps = 1e-4;
    bool ok(double v) => v >= -eps && v <= 1 + eps;
    return ok(rgb.$1) && ok(rgb.$2) && ok(rgb.$3);
  }

  static double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

  static double _toLinear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  static double _toGamma(double v) => v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;

  @override
  bool operator ==(Object other) => other is Oklch && other.l == l && other.c == c && other.h == h;

  @override
  int get hashCode => Object.hash(l, c, h);

  @override
  String toString() => 'Oklch(${l.toStringAsFixed(3)}, ${c.toStringAsFixed(4)}, ${h.toStringAsFixed(1)})';
}

/// 把 [color] 换到另一种色调上:明度不变,色相转 [hueShift] 度,彩度乘
/// [chromaScale]。透明度保留。
///
/// 中性色(页面、文字、玻璃)跟着配色走就靠它:雾蓝的整条中性色阶原样
/// 转到别的色相上,明度一点不动,各级文字的对比度也就跟着不动。
Color retint(Color color, {required double hueShift, required double chromaScale}) {
  if (hueShift == 0 && chromaScale == 1) return color;
  final o = Oklch.fromColor(color);
  return o.copyWith(c: o.c * chromaScale, h: (o.h + hueShift) % 360).toColor(alpha: color.a);
}
