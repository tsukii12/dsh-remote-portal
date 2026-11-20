import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 全 App 弹对话框的唯一入口,用法和 [showDialog] 一样。
///
/// 标准档就是 [showDialog]。灵动档([AppMotion.fluid])下对话框带一点回弹地弹出来,
/// 收起时快速缩小淡出;只多一个缩放,不多离屏层。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  if (!AppMotion.fluid(context)) {
    return showDialog<T>(context: context, builder: builder, barrierDismissible: barrierDismissible);
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    animationStyle: AnimationStyle(
      duration: AppMotion.popCurve.duration,
      reverseDuration: AppMotion.quick,
      // 这是路由整体的淡入:弹簧要走满,淡入不用等它。
      curve: const Interval(0, 0.35, curve: Curves.easeOut),
      reverseCurve: Curves.easeOut,
    ),
    builder: (context) => _DialogPop(child: Builder(builder: builder)),
  );
}

class _DialogPop extends StatefulWidget {
  const _DialogPop({required this.child});

  final Widget child;

  @override
  State<_DialogPop> createState() => _DialogPopState();
}

class _DialogPopState extends State<_DialogPop> {
  static const _from = 0.9;

  CurvedAnimation? _curved;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)?.animation;
    if (route == null || _curved?.parent == route) return;
    _curved?.dispose();
    _curved = CurvedAnimation(parent: route, curve: AppMotion.popCurve, reverseCurve: Curves.easeOut);
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    if (curved == null) return widget.child;
    return ScaleTransition(
      scale: Tween(begin: _from, end: 1.0).animate(curved),
      child: widget.child,
    );
  }
}
