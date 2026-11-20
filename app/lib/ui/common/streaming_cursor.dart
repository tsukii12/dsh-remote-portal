// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 流式输出末尾的呼吸竖线光标。
///
/// 作为 `WidgetSpan`(`PlaceholderAlignment.middle`)嵌进正文末尾:跟着换行走,
/// 不破坏 `SelectableText` 的可选中性;固定宽度不随字体度量抖动;
/// 透明度 1.0 ↔ 0.25,周期 1s,比硬闪柔和,不和 token 刷新节奏打架。
class StreamingCursor extends StatefulWidget {
  const StreamingCursor({super.key, this.color, this.width = 2.5, this.height = 18});

  /// 默认 `colorScheme.primary`。
  final Color? color;
  final double width;

  /// 建议取正文行高的 ~72%。
  final double height;

  @override
  State<StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<StreamingCursor> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  late final Animation<double> _opacity = _controller.drive(
    Tween(begin: 1.0, end: 0.25).chain(CurveTween(curve: AppMotion.std)),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.all(Radius.circular(1.5))),
      ),
    );
  }
}
