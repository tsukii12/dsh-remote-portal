import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// 展开 / 收起:**高度从上往下长 + 内容淡入**,收起时内容先淡出、高度再收。
///
/// 和 `AnimatedSize` + 条件子树的区别:收起的整个过程里内容一直在,高度
/// 平滑地收回去,而不是内容"啪"地消失后留一块空白再缩。完全收起后子树
/// 才从树上拿掉(不占布局、不跑里面的动画)。
///
/// 时长走 [AppMotion.of]:系统关闭动画时直接到位。
class ExpandReveal extends StatefulWidget {
  const ExpandReveal({
    super.key,
    required this.open,
    required this.child,
    this.duration = AppMotion.collapse,
    this.curve = AppMotion.collapseCurve,
  });

  final bool open;
  final Widget child;
  final Duration duration;

  /// 高度的缓动;要和别处同时动的东西(比如输入条上的胶囊)同步时换掉。
  final Curve curve;

  @override
  State<ExpandReveal> createState() => _ExpandRevealState();
}

class _ExpandRevealState extends State<ExpandReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration, value: widget.open ? 1 : 0)
        ..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && mounted) setState(() {});
        });

  // 收起也是先快后慢(不是展开倒放),和同时在动的东西同一节奏。
  late final Animation<double> _size = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
    reverseCurve: widget.curve.flipped,
  );

  // 展开时后 70% 才淡入(先让出空间);收起时前 70% 就淡完(先藏内容)。
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.3, 1, curve: Curves.easeOut),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.of(context, widget.duration);
  }

  @override
  void didUpdateWidget(ExpandReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = AppMotion.of(context, widget.duration);
    if (widget.open != oldWidget.open) {
      if (widget.open) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) {
      return const SizedBox.shrink();
    }
    // SizeTransition 内部用 Align 摆放子组件,横向约束会被放松;这里把
    // 宽度钉回父级的宽度,内容不会缩成一团居中。
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget child = FadeTransition(opacity: _fade, child: widget.child);
        if (constraints.hasBoundedWidth) {
          child = SizedBox(width: constraints.maxWidth, child: child);
        }
        return SizeTransition(sizeFactor: _size, alignment: AlignmentDirectional.topStart, child: child);
      },
    );
  }
}
