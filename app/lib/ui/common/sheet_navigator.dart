// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import 'smooth_size.dart';

/// 底部弹层内部的页面栈。
///
/// 弹层自己持有页面栈:进二级页是 push,选完是 pop,弹层本身不动。避免
/// "用一个正在卸载的 context 开新弹层、选完整摞关掉、回不到上一层"。
class SheetNavigator extends StatefulWidget {
  const SheetNavigator({super.key, required this.root});

  final WidgetBuilder root;

  static SheetNavigatorState of(BuildContext context) {
    final state = context.findAncestorStateOfType<SheetNavigatorState>();
    // l10n:keep developer-only assertion
    assert(state != null, '这个 widget 不在 SheetNavigator 里');
    return state!;
  }

  /// 不在 `SheetNavigator` 里时返回 null —— `SheetHeader` 据此决定画返回还是关闭。
  static SheetNavigatorState? maybeOf(BuildContext context) => context.findAncestorStateOfType<SheetNavigatorState>();

  @override
  State<SheetNavigator> createState() => SheetNavigatorState();
}

class SheetNavigatorState extends State<SheetNavigator> {
  final List<WidgetBuilder> _stack = [];

  /// 最近一次是 push(true)还是 pop(false):决定两页各往哪边走。
  bool _forward = true;

  bool get canPop => _stack.isNotEmpty;

  void push(WidgetBuilder page) => setState(() {
    _forward = true;
    _stack.add(page);
  });

  void pop() {
    if (_stack.isEmpty) return;
    setState(() {
      _forward = false;
      _stack.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final builder = _stack.isEmpty ? widget.root : _stack.last;
    final duration = AppMotion.of(context, AppMotion.standard);
    final current = ValueKey(_stack.length);
    // 与整页路由同一方向感:push 时新页从右进、旧页往左退;pop 反过来。
    const travel = 0.12;
    final incomingFrom = Offset(_forward ? travel : -travel, 0);
    final outgoingTo = Offset(_forward ? -travel : travel, 0);
    return SmoothSize(
      duration: duration,
      curve: AppMotion.enter,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) {
          // 退场的那页动画从 1 倒放到 0:begin 写它要去的位置。
          final incoming = child.key == current;
          return SlideTransition(
            position: Tween<Offset>(begin: incoming ? incomingFrom : outgoingTo, end: Offset.zero).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: KeyedSubtree(
          key: ValueKey(_stack.length),
          child: Builder(builder: builder),
        ),
      ),
    );
  }
}
