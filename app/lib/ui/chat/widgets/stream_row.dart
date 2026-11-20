// The one anatomy every "process" row of a turn shares (thinking, tool calls,
// tool groups, the folded turn, slash commands, notices), so they line up on
// the same two columns as the answer text.

import 'package:flutter/material.dart';

import '../../common/bleed.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// 过程行的几何:**左 24 图形列 + 8 间距 + 文字列**,和正文左缘对齐。
///
/// ```
/// |▣ 运行 · flutter test            ◌|   ← 图形贴正文左缘,行尾贴正文右缘
/// |│ (展开的内容从 32 起)            |   ← 细线在图形中线 x=12
/// ```
///
/// 点按高亮向两侧各溢出 [bleed](见 [Bleed]),内容本身不缩进。
abstract final class StreamRow {
  /// 图形列宽(工具图标块、思考图形、状态图标都放在这一格里居中)。
  static const lead = 24.0;

  /// 图形与文字之间。
  static const gap = 8.0;

  /// 文字列的起点;展开内容从这里起。
  static const indent = lead + gap;

  /// 单行最小高度(24 图形 + 上下各 4)。
  static const minHeight = 32.0;

  /// 点按高亮溢出到正文外的宽度。
  static const bleed = 8.0;

  /// 行标签(动词、摘要):次级色 14 号 —— 过程比回答安静一档。
  static TextStyle? label(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.3);

  /// 行内细节(命令、路径、预览):三级色 13 号。
  static TextStyle? detail(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontSize: 13, color: DshColors.of(context).textTertiary, height: 1.3);
}

/// 一行过程行的外壳:最小 32 高、上下 4、点按高亮向两侧溢出 8。
class StreamRowFrame extends StatelessWidget {
  const StreamRowFrame({super.key, required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: StreamRow.minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: StreamRow.bleed, vertical: 4),
        child: child,
      ),
    );
    return Bleed(
      horizontal: StreamRow.bleed,
      child: onTap == null && onLongPress == null
          ? content
          : InkWell(onTap: onTap, onLongPress: onLongPress, customBorder: Squircle.border(AppShape.sm), child: content),
    );
  }
}

/// 图形列的一格:24×24,子组件居中。
class StreamLead extends StatelessWidget {
  const StreamLead({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: StreamRow.lead,
    child: Center(child: child),
  );
}

/// 行尾的展开箭头:收起朝下,展开朝上,和折叠同一条曲线转。
class StreamChevron extends StatelessWidget {
  const StreamChevron({super.key, required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0.5 : 0,
    duration: AppMotion.of(context, AppMotion.collapse),
    curve: AppMotion.collapseCurve,
    child: Icon(AppIcons.expand, size: 16, color: DshColors.of(context).textTertiary),
  );
}

/// 展开内容:左边一道 1px 细线在图形列中线上(x = 12),内容从文字列起。
///
/// 表示"这些属于上面那一行"(思考全文、工具组里的各次调用、收起的一轮)。
class StreamThread extends StatelessWidget {
  const StreamThread({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return CustomPaint(
      painter: _RailPainter(color.withValues(alpha: 0.8)),
      child: Padding(
        padding: const EdgeInsets.only(left: StreamRow.indent),
        child: child,
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 8) return;
    const x = StreamRow.lead / 2;
    canvas.drawLine(
      const Offset(x, 4),
      Offset(x, size.height - 4),
      Paint()
        ..color = color
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RailPainter old) => old.color != color;
}

/// 动词与摘要之间的间隔点(3dp,竖直居中,两边各 6)。
class StreamDot extends StatelessWidget {
  const StreamDot({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: SizedBox.square(
      dimension: 3,
      child: DecoratedBox(
        decoration: BoxDecoration(color: DshColors.of(context).textTertiary, shape: BoxShape.circle),
      ),
    ),
  );
}
