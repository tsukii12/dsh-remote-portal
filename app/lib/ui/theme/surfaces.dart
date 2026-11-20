import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'accent.dart';
import 'palette.dart';

/// 玻璃层级。决定填充透明度、是否模糊、描边与阴影。
///
/// | 层级 | 用在哪 | 模糊 |
/// |---|---|---|
/// | [chrome] | 顶栏胶囊、圆钮、输入条、底栏 —— 浮在滚动内容上的 | 有 |
/// | [sheet] | 底部弹层、菜单、抽屉 | 有 |
/// | [card] | 设置卡、审批卡、工具组 —— 躺在页面背景上的 | 无 |
/// | [pill] | 思考胶囊、模型胶囊、状态 chip —— 滚动列表里的小件 | 无 |
///
/// 只有 chrome / sheet 真模糊:它们背后是会滚动的内容,模糊才有意义;
/// card / pill 背后只是静态渐变,半透明白(或白光)就已经读作"磨砂",
/// 再上 `BackdropFilter` 只是白白烧 GPU(列表里几十个就是几十次模糊)。
enum GlassTier { chrome, sheet, card, pill }

/// 一种玻璃材质的全部参数。
@immutable
class GlassStyle {
  const GlassStyle({
    required this.fill,
    required this.fallbackFill,
    required this.hairline,
    required this.rim,
    this.blurSigma = 0,
    this.saturation = 1,
    this.hairlineWidth = 0.5,
    this.shadows = const [],
  });

  /// 开启模糊时的填充(带透明度)。
  final Color fill;

  /// 关闭模糊时的填充(低端机、省电、"减少透明度"、高对比度模式)。
  /// 必须接近不透明,否则没有模糊时背后的字会透出来干扰阅读。
  final Color fallbackFill;

  /// 发丝描边:界定玻璃边缘。浅色是冷墨 8%,深色是白 9%。
  final Color hairline;
  final double hairlineWidth;

  /// 顶边高光起始色,向下 45% 处渐隐到透明 —— 光从上方打在玻璃边上。
  final Color rim;

  /// 高斯模糊 σ(逻辑像素)。0 = 不模糊。
  final double blurSigma;

  /// 模糊后的饱和度增益(1 = 不变)。iOS 式"透色":背后的颜色透过来更鲜一点。
  final double saturation;

  /// 只画在形状**外部**的投影(玻璃内部不被阴影弄脏)。
  final List<BoxShadow> shadows;

  bool get blurs => blurSigma > 0;

  GlassStyle copyWith({
    Color? fill,
    Color? fallbackFill,
    Color? hairline,
    Color? rim,
    double? blurSigma,
    double? saturation,
    double? hairlineWidth,
    List<BoxShadow>? shadows,
  }) {
    return GlassStyle(
      fill: fill ?? this.fill,
      fallbackFill: fallbackFill ?? this.fallbackFill,
      hairline: hairline ?? this.hairline,
      rim: rim ?? this.rim,
      blurSigma: blurSigma ?? this.blurSigma,
      saturation: saturation ?? this.saturation,
      hairlineWidth: hairlineWidth ?? this.hairlineWidth,
      shadows: shadows ?? this.shadows,
    );
  }

  static GlassStyle lerp(GlassStyle a, GlassStyle b, double t) {
    return GlassStyle(
      fill: Color.lerp(a.fill, b.fill, t)!,
      fallbackFill: Color.lerp(a.fallbackFill, b.fallbackFill, t)!,
      hairline: Color.lerp(a.hairline, b.hairline, t)!,
      rim: Color.lerp(a.rim, b.rim, t)!,
      blurSigma: lerpDouble(a.blurSigma, b.blurSigma, t)!,
      saturation: lerpDouble(a.saturation, b.saturation, t)!,
      hairlineWidth: lerpDouble(a.hairlineWidth, b.hairlineWidth, t)!,
      shadows: BoxShadow.lerpList(a.shadows, b.shadows, t) ?? const [],
    );
  }
}

/// 页面材质扩展:背景渐变、光晕、用户气泡、四种玻璃。
///
/// 与 `DshColors` 不同,这里**随 accent 变**(光晕与气泡带主色调),
/// 也随"是否允许模糊"变。
class DshSurfaces extends ThemeExtension<DshSurfaces> {
  const DshSurfaces({
    required this.backdropTop,
    required this.backdropBottom,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.userBubble,
    required this.onUserBubble,
    required this.scrim,
    required this.chrome,
    required this.sheet,
    required this.card,
    required this.pill,
    this.accent = AppAccent.mist,
    this.blurEnabled = true,
  });

  /// 页面竖向渐变的顶 / 底。
  final Color backdropTop;
  final Color backdropBottom;

  /// 右上角主色光晕(已含透明度)。
  final Color glowPrimary;

  /// 左下角光晕(已含透明度):配主色的邻近色,雾蓝配暮紫。
  final Color glowSecondary;

  /// 用户气泡:比页面深一档的主色调("按进去"的软气泡)。
  final Color userBubble;
  final Color onUserBubble;

  /// 抽屉 / 模态遮罩(已含透明度)。
  final Color scrim;

  final GlassStyle chrome;
  final GlassStyle sheet;
  final GlassStyle card;
  final GlassStyle pill;

  /// 这套材质出自哪套配色。主题之外另起主题的地方(分享卡、终端页)
  /// 用它照着当前配色重建,而不是退回默认。
  final AppAccent accent;

  /// 总开关。关掉后所有 [GlassTier] 都走 `fallbackFill`,不再创建
  /// `BackdropFilter`。由设置里的"减少透明效果"或性能探测决定。
  final bool blurEnabled;

  static DshSurfaces of(BuildContext context) => Theme.of(context).extension<DshSurfaces>()!;

  GlassStyle glass(GlassTier tier) => switch (tier) {
    GlassTier.chrome => chrome,
    GlassTier.sheet => sheet,
    GlassTier.card => card,
    GlassTier.pill => pill,
  };

  /// 浅色:晨雾渐变 + 白玻璃。渐变、阴影、实色兜底跟配色的中性色走;
  /// 玻璃本身是白的,高光也是白的 —— 换了配色,玻璃还是玻璃。
  factory DshSurfaces.light(AppAccent accent, {bool blurEnabled = true}) {
    final n = NeutralTones.forAccent(accent);
    final ink = n.shadowInk;
    const white = Color(0xFFFFFFFF);
    return DshSurfaces(
      backdropTop: n.mistTop,
      backdropBottom: n.mistBottom,
      glowPrimary: accent.glow.withValues(alpha: 0.42),
      glowSecondary: accent.haze.withValues(alpha: 0.38),
      userBubble: accent.bubble,
      onUserBubble: n.ink,
      scrim: n.scrim.withValues(alpha: 0.32),
      accent: accent,
      blurEnabled: blurEnabled,
      chrome: GlassStyle(
        fill: white.withValues(alpha: 0.70),
        fallbackFill: n.mistLowest.withValues(alpha: 0.96),
        hairline: ink.withValues(alpha: 0.08),
        rim: white.withValues(alpha: 0.85),
        blurSigma: 18,
        saturation: 1.3,
        shadows: [
          BoxShadow(color: ink.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8)),
          BoxShadow(color: ink.withValues(alpha: 0.05), blurRadius: 3, offset: const Offset(0, 1)),
        ],
      ),
      sheet: GlassStyle(
        fill: n.mistLow.withValues(alpha: 0.82),
        fallbackFill: n.mistLow,
        hairline: ink.withValues(alpha: 0.07),
        rim: white.withValues(alpha: 0.90),
        blurSigma: 24,
        saturation: 1.4,
        shadows: [BoxShadow(color: ink.withValues(alpha: 0.10), blurRadius: 32, offset: const Offset(0, 8))],
      ),
      card: GlassStyle(
        fill: white.withValues(alpha: 0.62),
        fallbackFill: white.withValues(alpha: 0.72),
        hairline: ink.withValues(alpha: 0.06),
        rim: white.withValues(alpha: 0.70),
      ),
      pill: GlassStyle(
        fill: white.withValues(alpha: 0.55),
        fallbackFill: white.withValues(alpha: 0.66),
        hairline: ink.withValues(alpha: 0.07),
        rim: white.withValues(alpha: 0.75),
      ),
    );
  }

  /// 深色:深海石板渐变 + 烟灰玻璃(石板与烟灰跟配色的中性色走)。
  factory DshSurfaces.dark(AppAccent accent, {bool blurEnabled = true}) {
    final n = NeutralTones.forAccent(accent);
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);
    // 雾蓝里是 OKLCH(0.30, 0.022, 266):比页面高一档的石板灰。
    final smoke = n.smoke;
    return DshSurfaces(
      backdropTop: n.nightTop,
      backdropBottom: n.nightBottom,
      glowPrimary: accent.glowDark.withValues(alpha: 0.28),
      glowSecondary: accent.hazeDark.withValues(alpha: 0.24),
      userBubble: accent.bubbleDark,
      onUserBubble: n.paper,
      scrim: black.withValues(alpha: 0.48),
      accent: accent,
      blurEnabled: blurEnabled,
      chrome: GlassStyle(
        fill: smoke.withValues(alpha: 0.72),
        fallbackFill: smoke.withValues(alpha: 0.97),
        hairline: white.withValues(alpha: 0.09),
        rim: white.withValues(alpha: 0.12),
        blurSigma: 18,
        saturation: 1.2,
        shadows: [
          BoxShadow(color: black.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8)),
          BoxShadow(color: black.withValues(alpha: 0.25), blurRadius: 3, offset: const Offset(0, 1)),
        ],
      ),
      sheet: GlassStyle(
        fill: n.sheetDark.withValues(alpha: 0.86),
        fallbackFill: n.sheetDark,
        hairline: white.withValues(alpha: 0.08),
        rim: white.withValues(alpha: 0.10),
        blurSigma: 24,
        saturation: 1.2,
        shadows: [BoxShadow(color: black.withValues(alpha: 0.40), blurRadius: 32, offset: const Offset(0, 8))],
      ),
      card: GlassStyle(
        fill: white.withValues(alpha: 0.05),
        fallbackFill: white.withValues(alpha: 0.06),
        hairline: white.withValues(alpha: 0.07),
        rim: white.withValues(alpha: 0.06),
      ),
      pill: GlassStyle(
        fill: white.withValues(alpha: 0.06),
        fallbackFill: white.withValues(alpha: 0.07),
        hairline: white.withValues(alpha: 0.08),
        rim: white.withValues(alpha: 0.08),
      ),
    );
  }

  @override
  DshSurfaces copyWith({
    Color? backdropTop,
    Color? backdropBottom,
    Color? glowPrimary,
    Color? glowSecondary,
    Color? userBubble,
    Color? onUserBubble,
    Color? scrim,
    GlassStyle? chrome,
    GlassStyle? sheet,
    GlassStyle? card,
    GlassStyle? pill,
    AppAccent? accent,
    bool? blurEnabled,
  }) {
    return DshSurfaces(
      backdropTop: backdropTop ?? this.backdropTop,
      backdropBottom: backdropBottom ?? this.backdropBottom,
      glowPrimary: glowPrimary ?? this.glowPrimary,
      glowSecondary: glowSecondary ?? this.glowSecondary,
      userBubble: userBubble ?? this.userBubble,
      onUserBubble: onUserBubble ?? this.onUserBubble,
      scrim: scrim ?? this.scrim,
      chrome: chrome ?? this.chrome,
      sheet: sheet ?? this.sheet,
      card: card ?? this.card,
      pill: pill ?? this.pill,
      accent: accent ?? this.accent,
      blurEnabled: blurEnabled ?? this.blurEnabled,
    );
  }

  @override
  DshSurfaces lerp(DshSurfaces? other, double t) {
    if (other is! DshSurfaces) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return DshSurfaces(
      backdropTop: mix(backdropTop, other.backdropTop),
      backdropBottom: mix(backdropBottom, other.backdropBottom),
      glowPrimary: mix(glowPrimary, other.glowPrimary),
      glowSecondary: mix(glowSecondary, other.glowSecondary),
      userBubble: mix(userBubble, other.userBubble),
      onUserBubble: mix(onUserBubble, other.onUserBubble),
      scrim: mix(scrim, other.scrim),
      chrome: GlassStyle.lerp(chrome, other.chrome, t),
      sheet: GlassStyle.lerp(sheet, other.sheet, t),
      card: GlassStyle.lerp(card, other.card, t),
      pill: GlassStyle.lerp(pill, other.pill, t),
      accent: t < 0.5 ? accent : other.accent,
      blurEnabled: t < 0.5 ? blurEnabled : other.blurEnabled,
    );
  }
}
