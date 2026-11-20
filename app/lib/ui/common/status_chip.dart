// The status pill (dot + one word) for hub and detail pages, and a status dot
// whose colour glides when the state changes.

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'status_dot.dart';
import 'smooth_size.dart';

export 'status_dot.dart' show StatusTone, StatusDot;

/// [StatusDot] 的渐变版:换状态时颜色在 [AppMotion.standard] 内平滑过渡,
/// [StatusTone.busy] 时同样缓慢呼吸。系统关闭动画时直接换色、不呼吸。
class AnimatedStatusDot extends StatefulWidget {
  const AnimatedStatusDot({super.key, required this.tone, this.size = 8});

  final StatusTone tone;
  final double size;

  @override
  State<AnimatedStatusDot> createState() => _AnimatedStatusDotState();
}

class _AnimatedStatusDotState extends State<AnimatedStatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  late final Animation<double> _opacity = _pulse.drive(
    Tween(begin: 1.0, end: 0.35).chain(CurveTween(curve: AppMotion.std)),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AnimatedStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.tone == StatusTone.busy && !AppMotion.reduced(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: StatusDot.colorFor(context, widget.tone)),
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        builder: (context, color, _) => DecoratedBox(
          decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
          child: SizedBox.square(dimension: widget.size),
        ),
      ),
    );
  }
}

/// 带色点的小胶囊:`( ● 运行中 )`。
///
/// - 底色是状态色的淡彩,文字是同色相的深色;[StatusTone.idle] 是中性灰;
/// - 换状态时底色、点色、文字色一起渐变,文字交叉淡变,宽度平滑过渡;
/// - 左右内边距相等(色点没有自带留白,不做光学补偿)。
///
/// ```dart
/// StatusChip(tone: StatusTone.ok, label: '运行中')
/// ```
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.tone, required this.label, this.onTap});

  final StatusTone tone;
  final String label;

  /// Optional: the chip becomes a button (e.g. "open the engine page").
  final VoidCallback? onTap;

  /// 胶囊高度(文字放大时随之变高)。
  static const height = 24.0;

  /// 胶囊左右内边距。
  static const padding = 10.0;

  /// (底色, 前景色) for [tone].
  static (Color, Color) colorsFor(BuildContext context, StatusTone tone) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dot = StatusDot.colorFor(context, tone);
    return switch (tone) {
      StatusTone.idle => (
        dark ? Colors.white.withValues(alpha: 0.08) : theme.colorScheme.onSurface.withValues(alpha: 0.06),
        colors.textTertiary,
      ),
      StatusTone.ok => (dot.withValues(alpha: dark ? 0.2 : 0.12), dark ? colors.onSuccessContainer : colors.success),
      StatusTone.warn => (dot.withValues(alpha: dark ? 0.2 : 0.12), dark ? colors.onWarningContainer : colors.warning),
      StatusTone.error => (dot.withValues(alpha: dark ? 0.2 : 0.12), dark ? colors.onDangerContainer : colors.danger),
      StatusTone.busy => (
        dot.withValues(alpha: dark ? 0.2 : 0.1),
        dark ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.primary,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = colorsFor(context, tone);
    final duration = AppMotion.of(context, AppMotion.standard);
    final style = AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: fg, height: 1.2));
    Widget chip = AnimatedContainer(
      duration: duration,
      curve: AppMotion.std,
      constraints: const BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: padding),
      decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedStatusDot(tone: tone, size: 6),
          const SizedBox(width: 6),
          _SizeGlide(
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: AppMotion.std,
              switchOutCurve: AppMotion.std,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: AnimatedDefaultTextStyle(
                key: ValueKey(label),
                duration: duration,
                style: style,
                child: Text(label, maxLines: 1, softWrap: false),
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap != null) {
      chip = Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: chip),
      );
    }
    return Semantics(
      container: true,
      button: onTap != null,
      onTap: onTap,
      label: label,
      excludeSemantics: true,
      child: chip,
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class _SizeGlide extends StatelessWidget {
  const _SizeGlide({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.centerLeft, child: child);
  }
}
