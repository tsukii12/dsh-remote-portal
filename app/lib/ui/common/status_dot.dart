// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/semantic_colors.dart';

/// 状态语义。业务层把自己的枚举(引擎状态、远程连接状态)映射到这里。
enum StatusTone {
  /// 运行中 / 已连接。
  ok,

  /// 启动中 / 连接中 / 安装中(会呼吸)。
  busy,

  /// 降级、需要注意。
  warn,

  /// 失败 / 已崩溃。
  error,

  /// 已停止 / 未连接。
  idle,
}

/// 状态圆点。[StatusTone.busy] 时缓慢呼吸(透明度 1 ↔ 0.35)。
///
/// 颜色**不是唯一信号**:旁边总要配文字("运行中"/"已停止"),
/// 色弱用户和读屏都靠文字。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.tone, this.size = 8});

  final StatusTone tone;
  final double size;

  static Color colorFor(BuildContext context, StatusTone tone) {
    final colors = DshColors.of(context);
    return switch (tone) {
      StatusTone.ok => colors.success,
      StatusTone.busy => Theme.of(context).colorScheme.primary,
      StatusTone.warn => colors.warning,
      StatusTone.error => colors.danger,
      StatusTone.idle => Theme.of(context).colorScheme.outline,
    };
  }

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
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
  void didUpdateWidget(StatusDot oldWidget) {
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
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: StatusDot.colorFor(context, widget.tone), shape: BoxShape.circle),
      ),
    );
  }
}
