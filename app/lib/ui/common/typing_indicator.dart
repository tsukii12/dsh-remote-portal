import 'package:flutter/material.dart';

import '../fx/orbs/thinking_orb.dart';

/// 等待首个 token 时的指示:Libraries.dev 的思考光球(正对着的一圈慢慢变形,作者给
/// "思考中"用的那一档),20 号,跟一行字一样高。墨色默认跟主题色走。
class TypingIndicator extends StatelessWidget {
  const TypingIndicator({super.key, this.color, this.state = OrbState.breathing});

  /// 指定墨色;默认跟主题色。
  final Color? color;

  /// 光球演哪一段(默认 [OrbState.breathing])。
  final OrbState state;

  @override
  Widget build(BuildContext context) {
    final color = this.color;
    return ThinkingOrb(
      state: state,
      size: OrbSize.px20,
      ink: color == null ? const OrbInk.theme() : OrbInk.tint(color),
    );
  }
}
