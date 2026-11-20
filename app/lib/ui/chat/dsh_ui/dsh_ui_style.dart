// The measurements, colors and small motions the dsh-ui components share
// (docs/design/page-design.md §4–§5).

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'dsh_ui_plugin_styles.dart';

/// dsh-ui 的尺寸。间距都是 4 的倍数（页面设计 §4）。
abstract final class DshUiMetrics {
  /// 视图外框：卡片圆角 20。
  static const cardRadius = AppShape.lg;
  static const cardPadding = 16.0;

  /// 卡片里的小井（选项行、对比卡、提示条、占位）。
  static const wellRadius = 12.0;

  /// 小标签（徽章）。
  static const tagRadius = 8.0;

  /// 竖排里相邻组件的间距；标题到内容同。
  static const gap = 16.0;

  /// 横排里相邻组件的间距。
  static const rowGap = 12.0;

  /// 选项行 / 确认按钮的最小高度（触控 ≥ 44）。
  static const control = 48.0;

  /// 柱状 / 折线图：绘图区 + 类别标签的总高。
  static const chartHeight = 196.0;

  /// 横向柱状图每一类的行高。
  static const hbarRow = 32.0;

  /// 环形图直径。
  static const donut = 148.0;
}

/// 图表的类别色：固定顺序，不随配色变（主色只给可点的东西；类别色是数据的
/// 语义，换了配色同一组数据还是同一组颜色）。
///
/// 两套都校验过（相邻色在色盲模拟下 ΔE ≥ 8.4，
/// 正常视觉 ≥ 16，对卡片底色 ≥ 3:1）：
/// - 浅色对 `#F8FAFE`（浅色卡片叠在晨雾上的实际颜色）；
/// - 深色对 `#272A33`。
abstract final class DshUiPalette {
  static const light = [
    Color(0xFF3D6FD6), // 蓝
    Color(0xFFDC6530), // 橙
    Color(0xFF169470), // 青绿
    Color(0xFFB88000), // 黄
    Color(0xFFD0628F), // 品红
    Color(0xFF6B58D0), // 紫
  ];

  static const dark = [
    Color(0xFF5B8EE6),
    Color(0xFFD9692F),
    Color(0xFF1F9E76),
    Color(0xFFB88510),
    Color(0xFFD6649A),
    Color(0xFF8A7DE0),
  ];

  /// 环形图折叠出来的「其他」:中性灰,随配色换色调(雾蓝下就是这两个值)。
  static const otherLight = Color(0xFF9AA0AA);
  static const otherDark = Color(0xFF6B707A);

  static List<Color> of(BuildContext context) {
    final style = DshUiPluginStyles.styleOf(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (style != null && style.chartColors.isNotEmpty) {
      return [for (final pair in style.chartColors) Color(0xFF000000 | pair.at(isDark))];
    }
    return isDark ? dark : light;
  }

  static Color other(BuildContext context) {
    final adjusted = DshUiPluginStyles.styleOf(context)?.chartOther;
    if (adjusted != null) return Color(0xFF000000 | adjusted.at(Theme.of(context).brightness == Brightness.dark));
    return NeutralTones.tint(
      Theme.of(context).brightness == Brightness.dark ? otherDark : otherLight,
      DshSurfaces.of(context).accent,
    );
  }
}

/// dsh-ui 共用的颜色取法。
extension DshUiColors on BuildContext {
  /// 卡片里的小井：比卡片深（浅色）/ 亮（深色）一点点，不画边。
  Color get dshUiWell {
    final style = DshUiPluginStyles.styleOf(this);
    if (style != null) return Theme.of(this).colorScheme.surface;
    return Theme.of(this).brightness == Brightness.dark
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.05)
        : NeutralTones.current(this).shadowInk.withValues(alpha: 0.04);
  }

  /// 卡片实际看上去的颜色（玻璃叠在页面渐变的中段上）：图表的「表面环」
  /// 和柱间缝用它，看起来就是挖空的。
  Color get dshUiCardSurface {
    if (DshUiPluginStyles.viewOf(this) != null) return Theme.of(this).colorScheme.surface;
    final surfaces = DshSurfaces.of(this);
    final page = Color.lerp(surfaces.backdropTop, surfaces.backdropBottom, 0.5)!;
    return Color.alphaBlend(surfaces.card.fill, page);
  }
}

/// 第一次出现：淡入 + 上移 8，只播一次；[enabled] 为 false 或系统关了动画
/// 时直接是终态。只动绘制，不动布局。
class DshUiAppear extends StatefulWidget {
  const DshUiAppear({super.key, required this.child, this.enabled = true, this.index = 0});

  final Widget child;
  final bool enabled;

  /// 同一批里的第几项：晚 30ms × index 起步，最多前 8 项错开。
  final int index;

  @override
  State<DshUiAppear> createState() => _DshUiAppearState();
}

class _DshUiAppearState extends State<DshUiAppear> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _t;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || !widget.enabled || AppMotion.reduced(context)) {
      return;
    }
    final delay = Duration(milliseconds: 30 * widget.index.clamp(0, 7));
    final total = delay + AppMotion.standard;
    final controller = AnimationController(vsync: this, duration: total);
    _controller = controller;
    _t = CurvedAnimation(
      parent: controller,
      curve: Interval(delay.inMicroseconds / total.inMicroseconds, 1, curve: AppMotion.enter),
    );
    controller.forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child;
    return AnimatedBuilder(
      animation: t,
      child: widget.child,
      builder: (context, child) {
        final v = t.value;
        if (v >= 1) return child!;
        return Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
        );
      },
    );
  }
}

/// 数字和单位：数字等宽，单位（前缀 ¥、后缀 %、万、分钟…）小一号、次要色
/// （页面设计 §4「数据」）。没有数字的文字整段按 [number] 样式。
TextSpan dshUiNumberSpan(String text, {required TextStyle number, required TextStyle unit}) {
  final match = _numberPattern.firstMatch(text);
  if (match == null) return TextSpan(text: text, style: number);
  final before = text.substring(0, match.start);
  final digits = match.group(0)!;
  final after = text.substring(match.end);
  // 「3/5」「2024-10」这类不止一个数：整段等宽，不拆单位。
  if (_digit.hasMatch(before) || _digit.hasMatch(after)) {
    return TextSpan(text: text, style: AppType.tabular(number));
  }
  return TextSpan(
    children: [
      if (before.isNotEmpty) TextSpan(text: before, style: unit),
      TextSpan(text: digits, style: AppType.tabular(number)),
      if (after.isNotEmpty) TextSpan(text: after, style: unit),
    ],
  );
}

final _numberPattern = RegExp(r'[-+−]?\d[\d,]*(?:\.\d+)?');
final _digit = RegExp(r'\d');
