// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 波往哪走。
enum DistortionWaveType {
  /// 从底部一个宽的源(按钮)往上:先贴着按钮轮廓,再张成弧线;跟着手指偏。
  vertical,

  /// 竖向那种转个身:从左边一个高的源(边缘、侧栏)往右。
  horizontal,

  /// 从圆形源(头像、图标)中心一圈圈扩散;源本身不动、不糊、不上色,可以原地变形。
  center,
}

/// CSS `cubic-bezier()` 同款控制点的缓动。
@immutable
class DistortionWaveEasing extends Curve {
  const DistortionWaveEasing(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// [x] 时刻(0–1)的缓动值;区间外夹到 0 和 1。
  double call(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // x grows with the curve's parameter, so halving always finds it.
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 24; i++) {
      final s = (low + high) / 2;
      if (_bezier(s, x1, x2) < x) {
        low = s;
      } else {
        high = s;
      }
    }
    return _bezier((low + high) / 2, y1, y2);
  }

  @override
  double transformInternal(double t) => call(t);

  static double _bezier(double s, double a, double b) {
    final r = 1 - s;
    return 3 * r * r * s * a + 3 * r * s * s * b + s * s * s;
  }

  @override
  bool operator ==(Object other) =>
      other is DistortionWaveEasing && other.x1 == x1 && other.y1 == y1 && other.x2 == x2 && other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);
}

/// 波的配色:沿波前和边缘流动的几种颜色,加波前前方、后方各一道色边。
///
/// 着色器最多用前 8 种颜色。
@immutable
class DistortionWavePalette {
  const DistortionWavePalette({required this.colors, required this.ahead, required this.behind});

  /// 跟主题走:主色相和左右邻近色相,饱和度压低,浅色 / 深色各一档明度。
  ///
  /// 和通话光球的 CallPalette 同一思路,只是多几种颜色,前方色边浅一些、
  /// 后方色边深一些。
  factory DistortionWavePalette.fromScheme(ColorScheme scheme) {
    final light = scheme.brightness == Brightness.light;
    final base = HSLColor.fromColor(scheme.primary);
    // A grey theme still gets a whisper of colour; a loud one is calmed down.
    final sat = (base.saturation * 0.62).clamp(0.28, 0.5);
    final l = light ? 0.64 : 0.7;
    Color tone(double shift, double s, double lightness) =>
        HSLColor.fromAHSL(1, (base.hue + shift) % 360, s.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0)).toColor();
    return DistortionWavePalette(
      colors: [
        tone(-30, sat * 0.9, l + 0.06),
        tone(14, sat, l - 0.04),
        tone(-8, sat * 1.1, l - 0.08),
        tone(32, sat * 0.85, l + 0.05),
        tone(-18, sat, l),
        tone(6, sat * 0.9, l + 0.08),
        tone(24, sat * 1.05, l - 0.03),
      ],
      ahead: tone(-22, sat * 0.8, l + 0.12),
      behind: tone(20, sat * 1.05, l - 0.12),
    );
  }

  final List<Color> colors;

  /// 波前前方的色边。
  final Color ahead;

  /// 波前后方的色边。
  final Color behind;

  /// 原作的彩色(VoiceGlow 那套):粉色前边,蓝色后边。
  static const colorful = DistortionWavePalette(
    colors: [
      Color(0xFFFFC915),
      Color(0xFF7EC4FF),
      Color(0xFFB428E6),
      Color(0xFFEB64A0),
      Color(0xFFFFB07A),
      Color(0xFF9AA0FF),
      Color(0xFF7FD9EE),
    ],
    ahead: Color(0xFFFF7AB6),
    behind: Color(0xFF5ABEFF),
  );

  /// 只用绿色,从成功徽标的 #35BA00 到青柠和薄荷。
  static const green = DistortionWavePalette(
    colors: [
      Color(0xFF35BA00),
      Color(0xFF8CEB5A),
      Color(0xFF00C46E),
      Color(0xFFBEFA82),
      Color(0xFF28A03C),
      Color(0xFF6EE1A0),
      Color(0xFF5AD228),
    ],
    ahead: Color(0xFFC4FF78),
    behind: Color(0xFF009646),
  );

  /// 蓝和青。
  static const ocean = DistortionWavePalette(
    colors: [
      Color(0xFF2878FF),
      Color(0xFF5AC8FF),
      Color(0xFF1450C8),
      Color(0xFF78E6F0),
      Color(0xFF3C96FF),
      Color(0xFF96B4FF),
      Color(0xFF00B4DC),
    ],
    ahead: Color(0xFF96E6FF),
    behind: Color(0xFF1E46DC),
  );

  /// 橙、粉、洋红。
  static const sunset = DistortionWavePalette(
    colors: [
      Color(0xFFFF8C3C),
      Color(0xFFFF5A78),
      Color(0xFFFFC850),
      Color(0xFFF0465A),
      Color(0xFFFFAA78),
      Color(0xFFDC5AC8),
      Color(0xFFFF7850),
    ],
    ahead: Color(0xFFFFDC78),
    behind: Color(0xFFC83CA0),
  );

  /// 白和银。
  static const mono = DistortionWavePalette(
    colors: [
      Color(0xFFF0F0F5),
      Color(0xFFC8CDD7),
      Color(0xFFFFFFFF),
      Color(0xFFAAAFBE),
      Color(0xFFE1E4EB),
      Color(0xFFBEC3CD),
      Color(0xFFF5F5FA),
    ],
    ahead: Color(0xFFFFFFFF),
    behind: Color(0xFFA0A5B4),
  );

  /// 单色:前方浅一些,后方深一些。
  factory DistortionWavePalette.single(Color color) {
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    return DistortionWavePalette(
      colors: [color, Color.lerp(color, white, 0.25)!, color, Color.lerp(color, black, 0.15)!],
      ahead: Color.lerp(color, white, 0.45)!,
      behind: Color.lerp(color, black, 0.3)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DistortionWavePalette &&
      other.ahead == ahead &&
      other.behind == behind &&
      listEquals(other.colors, colors);

  @override
  int get hashCode => Object.hash(ahead, behind, Object.hashAll(colors));
}

/// sRGB → OKLab, as the band shader mixes in.
List<double> waveOklab(Color color) {
  double linear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
  final lr = linear(color.r);
  final lg = linear(color.g);
  final lb = linear(color.b);
  final l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  final m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  final s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

/// 一道扭曲波的样子和节奏。从三种类型调好的默认值([vertical]、[horizontal]、
/// [center])出发,用 [copyWith] 改需要的。
///
/// 长度单位都是逻辑像素,时间单位是秒。[palette] 留空就跟主题走
/// ([DistortionWavePalette.fromScheme]);原作的配色在 [DistortionWavePalette] 上。
@immutable
class DistortionWaveStyle {
  const DistortionWaveStyle._({
    required this.type,
    this.anticipation = 0.5,
    this.travel = 2.28,
    this.launchGap = 0,
    this.linger = -0.35,
    this.rimFade = 3.03,
    this.rimEasing = const DistortionWaveEasing(0.42, 0, 0.58, 1),
    this.returnSpeed = 1.45,
    this.easing = const DistortionWaveEasing(0.22, 1, 0.36, 1),
    this.pull = 24,
    this.inhale = 56,
    this.gatherGlow = 0.33,
    this.gatherDots = 1,
    this.amplitude = 34,
    this.lensWidth = 150,
    this.aberration = 0.78,
    this.swell = 22,
    this.blur = 18,
    this.blurAhead = 90,
    this.blurBehind = 240,
    this.lead = 130,
    this.tail = 300,
    this.strength = 0.92,
    this.rimWidth = 14,
    this.rimUnevenness = 1,
    this.rimStrength = 0.82,
    this.rimSoftness = 343,
    this.cornerRadius = 62,
    this.rimPulse = 0.6,
    this.hairlineWidth = 1.5,
    this.hairlineOpacity = 0.9,
    this.hairlineWhite = 0.95,
    this.hairlineLinger = 0.47,
    this.hairlineFade = 3,
    this.orientation = 0.91,
    this.particleCount = 64,
    this.particleSize = 1.8,
    this.particleReach = 150,
    this.particleFlight = 30,
    this.particleGap = 24,
    this.particleLife = 2.19,
    this.particleSpread = 1,
    this.palette,
  });

  /// 从底部按钮往上,整屏,原作调好的默认值。
  static const vertical = DistortionWaveStyle._(type: DistortionWaveType.vertical);

  /// 从左边高的源往右。
  static const horizontal = DistortionWaveStyle._(type: DistortionWaveType.horizontal);

  /// 从头像或图标扩散,按约 500 高的面板或卡片调的:圈走得慢些,只在出发前收一下,
  /// 颜色轻一些,没有色散(会把白色拆成红蓝),小点留在画面里。原作这一型配绿色
  /// ([DistortionWavePalette.green]);这里默认跟主题。
  static const center = DistortionWaveStyle._(
    type: DistortionWaveType.center,
    anticipation: 0.25,
    travel: 3.43,
    rimFade: 2.51,
    hairlineLinger: 0.96,
    strength: 0.6,
    rimStrength: 0.6,
    aberration: 0,
    gatherGlow: 0,
    gatherDots: 0,
    particleCount: 89,
    particleLife: 3.93,
    particleSpread: 0.64,
    cornerRadius: 48,
    // A sheet is about 0.6 the height of a screen: its lengths are too.
    pull: 14.4,
    inhale: 33.6,
    amplitude: 20.4,
    lensWidth: 90,
    swell: 13.2,
    blur: 10.8,
    blurAhead: 54,
    blurBehind: 144,
    lead: 78,
    tail: 180,
    rimSoftness: 205.8,
    particleReach: 90,
    particleFlight: 18,
    particleGap: 11,
  );

  /// [type] 调好的默认值。
  static DistortionWaveStyle of(DistortionWaveType type) => switch (type) {
    DistortionWaveType.vertical => vertical,
    DistortionWaveType.horizontal => horizontal,
    DistortionWaveType.center => center,
  };

  final DistortionWaveType type;

  // ── Timing ──

  /// 出发前把一切往源拉的秒数。
  final double anticipation;

  /// 从离开源到波前停稳的秒数。
  final double travel;

  /// 波前从源轮廓往外多远起步。
  final double launchGap;

  /// 离开源后多少秒开始擦掉边缘的颜色;负数是提前,紧跟着波前。
  final double linger;

  /// 边缘颜色擦掉要多少秒。
  final double rimFade;

  /// 擦边缘颜色的缓动:慢起慢停。
  final DistortionWaveEasing rimEasing;

  /// 收回比展开快多少倍。
  final double returnSpeed;

  /// 波前在 [travel] 里怎么走:全速离开源,在屏幕另一头轻轻停下。
  final DistortionWaveEasing easing;

  // ── Gravity ──

  /// 出发前把内容往源拉多远。
  final double pull;

  /// 落到源上的那圈颜色从多远开始。
  final double inhale;

  /// 出发前颜色多浓,0–2:1 到出发时攒到一半,2 攒满;0 出发前不上色。
  final double gatherGlow;

  /// 出发前往源跳的小点多明显,0–1。
  final double gatherDots;

  // ── Swell ──

  /// 鼓包经过时把内容抬多高。
  final double amplitude;

  /// 鼓包的宽度。
  final double lensWidth;

  /// 红蓝分开的程度,按内容被挪动的距离算:没挪动的地方颜色不分开。
  final double aberration;

  /// 波前沿长度方向弯多少。
  final double swell;

  // ── Progressive blur ──

  /// 波前上的模糊半径。
  final double blur;

  /// 模糊在波前前方多远内聚起。
  final double blurAhead;

  /// 模糊在波前后方多远内散开。
  final double blurBehind;

  // ── Colour on the front ──

  /// 颜色在波前前方羽化多远。
  final double lead;

  /// 颜色拖在波前后面多长。
  final double tail;

  /// 颜色最浓时的不透明度。
  final double strength;

  // ── Colour on the edges ──

  /// 边缘颜色往里伸多远。
  final double rimWidth;

  /// 边缘颜色厚薄多不均,0–2。
  final double rimUnevenness;

  /// 边缘颜色最浓时的不透明度。
  final double rimStrength;

  /// 边缘颜色擦除的软边。
  final double rimSoftness;

  /// 波铺满的那块区域的圆角(屏幕的,或面板的),边缘颜色和细线顺着它走。
  final double cornerRadius;

  /// 边缘颜色有多"活",0–1:团块漂移呼吸、亮光绕边跑、颜色流动。
  final double rimPulse;

  /// 贴着边的细线宽度;0 不画。
  final double hairlineWidth;

  /// 细线最浓时的不透明度。
  final double hairlineOpacity;

  /// 亮光经过处细线发白的程度。
  final double hairlineWhite;

  /// 边缘颜色开始擦掉后,细线再多留几秒。
  final double hairlineLinger;

  /// 细线擦掉要多少秒。
  final double hairlineFade;

  // ── Touch ──

  /// 跟着按下的位置偏多少,0–1;center 类型不偏。
  final double orientation;

  // ── Particles ──

  /// 小点个数。
  final int particleCount;

  /// 最大的小点直径。
  final double particleSize;

  /// 出发前最远的小点在源外多远出生。
  final double particleReach;

  /// 每跳往源飞多远。
  final double particleFlight;

  /// 小点淡出前离源最近多远。
  final double particleGap;

  /// 出发后多少秒内最后一个小点淡出。
  final double particleLife;

  /// 小点被甩多远,按波前走的路程算,0–1。
  final double particleSpread;

  // ── Colour ──

  /// 沿波前和边缘流动的颜色;null 跟主题。
  final DistortionWavePalette? palette;

  /// 整个过程的秒数:到这时鼓包停了、边缘清了、最后一个小点也灭了。
  double get duration =>
      anticipation +
      math.max(
        math.max(travel * 0.6, linger + rimFade),
        math.max(linger + hairlineLinger + hairlineFade, particleLife),
      );

  /// [palette],没给就从 [scheme] 取。
  DistortionWavePalette paletteFor(ColorScheme scheme) => palette ?? DistortionWavePalette.fromScheme(scheme);

  DistortionWaveStyle copyWith({
    double? anticipation,
    double? travel,
    double? launchGap,
    double? linger,
    double? rimFade,
    DistortionWaveEasing? rimEasing,
    double? returnSpeed,
    DistortionWaveEasing? easing,
    double? pull,
    double? inhale,
    double? gatherGlow,
    double? gatherDots,
    double? amplitude,
    double? lensWidth,
    double? aberration,
    double? swell,
    double? blur,
    double? blurAhead,
    double? blurBehind,
    double? lead,
    double? tail,
    double? strength,
    double? rimWidth,
    double? rimUnevenness,
    double? rimStrength,
    double? rimSoftness,
    double? cornerRadius,
    double? rimPulse,
    double? hairlineWidth,
    double? hairlineOpacity,
    double? hairlineWhite,
    double? hairlineLinger,
    double? hairlineFade,
    double? orientation,
    int? particleCount,
    double? particleSize,
    double? particleReach,
    double? particleFlight,
    double? particleGap,
    double? particleLife,
    double? particleSpread,
    DistortionWavePalette? palette,
  }) => DistortionWaveStyle._(
    type: type,
    anticipation: anticipation ?? this.anticipation,
    travel: travel ?? this.travel,
    launchGap: launchGap ?? this.launchGap,
    linger: linger ?? this.linger,
    rimFade: rimFade ?? this.rimFade,
    rimEasing: rimEasing ?? this.rimEasing,
    returnSpeed: returnSpeed ?? this.returnSpeed,
    easing: easing ?? this.easing,
    pull: pull ?? this.pull,
    inhale: inhale ?? this.inhale,
    gatherGlow: gatherGlow ?? this.gatherGlow,
    gatherDots: gatherDots ?? this.gatherDots,
    amplitude: amplitude ?? this.amplitude,
    lensWidth: lensWidth ?? this.lensWidth,
    aberration: aberration ?? this.aberration,
    swell: swell ?? this.swell,
    blur: blur ?? this.blur,
    blurAhead: blurAhead ?? this.blurAhead,
    blurBehind: blurBehind ?? this.blurBehind,
    lead: lead ?? this.lead,
    tail: tail ?? this.tail,
    strength: strength ?? this.strength,
    rimWidth: rimWidth ?? this.rimWidth,
    rimUnevenness: rimUnevenness ?? this.rimUnevenness,
    rimStrength: rimStrength ?? this.rimStrength,
    rimSoftness: rimSoftness ?? this.rimSoftness,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    rimPulse: rimPulse ?? this.rimPulse,
    hairlineWidth: hairlineWidth ?? this.hairlineWidth,
    hairlineOpacity: hairlineOpacity ?? this.hairlineOpacity,
    hairlineWhite: hairlineWhite ?? this.hairlineWhite,
    hairlineLinger: hairlineLinger ?? this.hairlineLinger,
    hairlineFade: hairlineFade ?? this.hairlineFade,
    orientation: orientation ?? this.orientation,
    particleCount: particleCount ?? this.particleCount,
    particleSize: particleSize ?? this.particleSize,
    particleReach: particleReach ?? this.particleReach,
    particleFlight: particleFlight ?? this.particleFlight,
    particleGap: particleGap ?? this.particleGap,
    particleLife: particleLife ?? this.particleLife,
    particleSpread: particleSpread ?? this.particleSpread,
    palette: palette ?? this.palette,
  );
}
