// The shared make-up of the bars docked above the composer (todo, goal),
// sized to stack with the activity strip.

import 'package:flutter/material.dart';

import '../../common/expand_reveal.dart';
import '../../pets/pet_perch.dart';
import '../../theme/theme.dart';

/// 停靠在输入条上方的一组条:和思考胶囊同高、同字号、同左右边,一根接一根
/// 往上叠,间距都是 [gap]。
///
/// ```
/// ( ☑  3/7 · 正在：跑测试                ▰▰▱  ˄ )   待办
/// ( ⚑  目标  把登录迁到新接口…                ⋯ )   目标
/// ( 🐋 跑  flutter test test/auth          0:19 )   思考胶囊
/// [ ＋  给 DSH 发消息…                      🎤 ]    输入条
/// ```
///
/// 胶囊两端的图形都放在 [glyph] 见方的格子里,格子离胶囊边 [edge]:
/// 图形中心正好落在端盖圆心上(离边 [height] / 2),左右镜像。正文从
/// [textStart] 起,和思考胶囊的正文左边对齐。
abstract final class DockMetrics {
  /// 一根条的高度(= 思考胶囊)。
  static const height = 36.0;

  /// 端盖半径;展开的待办卡片也用它。
  static const radius = height / 2;

  /// 两端图形的格子。
  static const glyph = 20.0;

  /// 图形格子到胶囊边。
  static const edge = (height - glyph) / 2;

  /// 正文左边(= 思考胶囊:9 + 鲸尾 25 + 6)。
  static const textStart = 40.0;

  /// 图形到正文。
  static const glyphGap = textStart - edge - glyph;

  /// 正文与右端件之间。
  static const trailingGap = 10.0;

  /// 上下相邻两根条之间(= 思考胶囊到输入条)。
  static const gap = 6.0;

  static const shape = BorderRadius.all(Radius.circular(radius));
}

/// 条两端的图形格子([DockMetrics.glyph] 见方,内容居中)。
class DockGlyph extends StatelessWidget {
  const DockGlyph({super.key, required this.child});

  /// 一个 [iconSize] 的图标。
  DockGlyph.icon(IconData icon, {Key? key, required Color color})
    : this(
        key: key,
        child: Icon(icon, size: iconSize, color: color),
      );

  static const iconSize = 18.0;

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: DockMetrics.glyph,
    child: Center(child: child),
  );
}

/// 一根条的一行:左图形 · 正文 · 右端件 · 右图形,高 [DockMetrics.height]
/// (随系统字号可以长高)。
class DockRow extends StatelessWidget {
  const DockRow({super.key, required this.leading, required this.content, this.accessory, this.trailing});

  final Widget leading;
  final Widget content;

  /// 右图形左边的小件(进度细条、状态字)。
  final Widget? accessory;

  /// 右端的图形(展开箭头、更多)。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: DockMetrics.height),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DockMetrics.edge),
        child: Row(
          children: [
            leading,
            const SizedBox(width: DockMetrics.glyphGap),
            Expanded(child: content),
            if (accessory != null) ...[const SizedBox(width: DockMetrics.trailingGap), accessory!],
            if (trailing != null) ...[
              const SizedBox(width: DockMetrics.trailingGap),
              trailing!,
            ] else
              // Text ends where a trailing glyph's slot would start.
              const SizedBox(width: DockMetrics.edge),
          ],
        ),
      ),
    );
  }
}

/// 条里的字:标题(12 / 600)+ 第二段(12 / 次要色),和思考胶囊一样的两档。
abstract final class DockText {
  static TextStyle title(BuildContext context, {Color? color}) {
    final theme = Theme.of(context);
    return theme.textTheme.labelMedium!.copyWith(color: color ?? theme.colorScheme.onSurface, height: 1.3);
  }

  static TextStyle detail(BuildContext context, {Color? color}) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!.copyWith(color: color ?? theme.colorScheme.onSurfaceVariant, height: 1.3);
  }
}

/// 一根细进度条:3 高的胶囊槽,完成时变成功色;数值变化时平滑走过去。
class DockProgressLine extends StatelessWidget {
  const DockProgressLine({super.key, required this.fraction, this.width = 28});

  final double fraction;
  final double width;

  static const thickness = 3.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    final target = fraction.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      builder: (context, value, _) => Container(
        width: width,
        height: thickness,
        alignment: Alignment.centerLeft,
        decoration: ShapeDecoration(color: colors.onSurface.withValues(alpha: 0.10), shape: const StadiumBorder()),
        child: FractionallySizedBox(
          widthFactor: value,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: target >= 1 ? dsh.success : colors.primary,
              shape: const StadiumBorder(),
            ),
            child: const SizedBox(height: thickness),
          ),
        ),
      ),
    );
  }
}

/// 停靠条的位置:有内容时长出来(内容先让出空间再淡入,从下面那根条的背后
/// 升起),没有时收回去;收回的过程里仍画着最后的内容。节奏和思考胶囊同步
/// ([AppMotion.standard] / [AppMotion.std])。
class DockSlot extends StatefulWidget {
  const DockSlot({super.key, this.child});

  /// Null: nothing to show.
  final Widget? child;

  @override
  State<DockSlot> createState() => _DockSlotState();
}

class _DockSlotState extends State<DockSlot> {
  Widget? _last;

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (child != null) _last = child;
    final last = _last;
    if (last == null) return const SizedBox(width: double.infinity);
    return ExpandReveal(
      open: child != null,
      duration: AppMotion.standard,
      curve: AppMotion.std,
      child: Padding(
        padding: const EdgeInsets.only(bottom: DockMetrics.gap),
        // The chat page's pet may stand on the bar (not while it folds away).
        child: PetPerch(kind: PerchKind.dock, active: child != null, child: last),
      ),
    );
  }
}
