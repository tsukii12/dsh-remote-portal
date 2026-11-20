// Portions derived from Libraries.dev Bot avatars (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' show Color;

/// An `hsl()` colour as the author's canvas strings carry it: hue in degrees,
/// saturation and lightness in percent, each rounded to one decimal.
class Hsl {
  const Hsl(this.h, this.s, this.l);

  final double h;
  final double s;
  final double l;

  Color get color {
    final (r, g, b) = _hslToRgb(h / 360, s / 100, l / 100);
    return Color.fromARGB(255, r.round(), g.round(), b.round());
  }

  @override
  bool operator ==(Object other) => other is Hsl && other.h == h && other.s == s && other.l == l;

  @override
  int get hashCode => Object.hash(h, s, l);
}

/// 0–255 channels of a colour.
(double, double, double) rgbOf(Color c) => (c.r * 255, c.g * 255, c.b * 255);

double _lin255(double v) {
  final x = v / 255;
  return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
}

/// Relative luminance (WCAG), 0–1.
double luminance(Color color) {
  final (r, g, b) = rgbOf(color);
  return 0.2126 * _lin255(r) + 0.7152 * _lin255(g) + 0.0722 * _lin255(b);
}

const darkInk = Color(0xFF1E1A33);
const lightInk = Color(0xFFF7F5F2);

/// Face ink for a body colour: dark ink, or light ink on a dark body.
Color autoInk(Color color) => luminance(color) < 0.13 ? lightInk : darkInk;

(double, double, double) _rgbToHsl(double r, double g, double b) {
  r /= 255;
  g /= 255;
  b /= 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  if (mx == mn) return (0, 0, l);
  final d = mx - mn;
  final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  double h;
  if (mx == r) {
    h = (g - b) / d + (g < b ? 6 : 0);
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return (h / 6, s, l);
}

(double, double, double) _hslToRgb(double h, double s, double l) {
  if (s == 0) return (l * 255, l * 255, l * 255);
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  double f(double t) {
    t = ((t % 1) + 1) % 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  return (f(h + 1 / 3) * 255, f(h) * 255, f(h - 1 / 3) * 255);
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
double _round1(double v) => (v * 10).roundToDouble() / 10;

/// A shade of a colour: `dl` moves the lightness (−1..1), `ds` the
/// saturation. Darker shades get a touch more saturation so they stay rich
/// instead of going grey, the way a painted surface falls into shadow.
Hsl shade(Color color, double dl, [double ds = 0]) {
  final (r, g, b) = rgbOf(color);
  final (h, s, l) = _rgbToHsl(r, g, b);
  return Hsl(
    _round1(h * 360),
    _round1(_clamp01(s + ds + (dl < 0 ? -dl * 0.25 : 0)) * 100),
    _round1(_clamp01(l + dl) * 100),
  );
}

/// Interpolates the numbers of two hsl colours, as the author's `mixCss`.
Hsl mixHsl(Hsl a, Hsl b, double t) =>
    Hsl(_round1(a.h + (b.h - a.h) * t), _round1(a.s + (b.s - a.s) * t), _round1(a.l + (b.l - a.l) * t));

/* OKLab, for moving a colour along its own hue (Björn Ottosson's) */
double _toLinear(double u) => u <= 0.04045 ? u / 12.92 : math.pow((u + 0.055) / 1.055, 2.4).toDouble();
double _toSrgb(double u) => u <= 0.0031308 ? 12.92 * u : 1.055 * math.pow(u, 1 / 2.4) - 0.055;
double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

(double, double, double) _oklab(double r, double g, double b) {
  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return (
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  );
}

(double, double, double) _fromOklab(double lL, double a, double b) {
  final l = math.pow(lL + 0.3963377774 * a + 0.2158037573 * b, 3).toDouble();
  final m = math.pow(lL - 0.1055613458 * a - 0.0638541728 * b, 3).toDouble();
  final s = math.pow(lL - 0.0894841775 * a - 1.291485548 * b, 3).toDouble();
  return (
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  );
}

bool _inGamut((double, double, double) c) =>
    c.$1 >= -1e-4 && c.$1 <= 1 + 1e-4 && c.$2 >= -1e-4 && c.$2 <= 1 + 1e-4 && c.$3 >= -1e-4 && c.$3 <= 1 + 1e-4;

/// A more vivid version of a colour, `t` 0–1: its chroma raised along its own
/// hue (in OKLab) by up to half again. Where the screen cannot show that at the
/// same lightness, the colour deepens a little — by at most 15% of its
/// lightness — and the chroma stops at whatever the screen can show.
Color richer(Color color, double t) {
  if (!(t > 0)) return color;
  final (r, g, b) = rgbOf(color);
  final (lL, a, bb) = _oklab(_toLinear(r / 255), _toLinear(g / 255), _toLinear(b / 255));
  final c = math.sqrt(a * a + bb * bb);
  if (c < 1e-4) return color;
  final ua = a / c, ub = bb / c;
  final want = c * (1 + 0.5 * t);
  (double, double, double)? best;
  var bestC = c;
  for (var k = 0; k <= 6; k++) {
    final lk = lL * (1 - (0.15 * t * k) / 6);
    var lo = 0.0, hi = want;
    for (var it = 0; it < 18; it++) {
      final mid = (lo + hi) / 2;
      if (_inGamut(_fromOklab(lk, ua * mid, ub * mid))) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    /* deeper only for what it gains: each step must buy real chroma */
    if (lo > bestC + 0.004 * k) {
      bestC = lo;
      best = _fromOklab(lk, ua * lo, ub * lo);
    }
    if (lo >= want - 1e-4) break;
  }
  if (best == null) return color;
  int ch(double v) => (255 * _toSrgb(_clamp01(v))).round();
  return Color.fromARGB(255, ch(best.$1), ch(best.$2), ch(best.$3));
}

/// The body colour the author's component derives from a picked colour, its
/// brightness and saturation: a shade, then [richer] past saturation 1.5.
Color bodyColor(Color picked, {double brightness = 1, double saturation = 1.5}) {
  final vivid = saturation.clamp(1.5, 2.5) - 1.5;
  final base = brightness == 1 && saturation == 1
      ? picked
      : shade(picked, (brightness.clamp(0.0, 2.0) - 1) * 0.35, (saturation.clamp(0.0, 1.5) - 1) * 0.5).color;
  return richer(base, vivid);
}
