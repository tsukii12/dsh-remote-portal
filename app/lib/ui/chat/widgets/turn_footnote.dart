// The quiet per-turn footnote (duration, steps, cost, tokens) that opens the
// turn's trajectory.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../run_info.dart';
import '../usage_sheet.dart' show formatTokens;

/// 一轮结束后的**回合脚注**:`47 秒 · 12 步 · 约 ¥0.03 · 36 万 tokens ›`。
///
/// 放不下时依次省掉 tokens、步数、花费,时长总在。点开本轮轨迹。
class TurnFootnote extends StatelessWidget {
  const TurnFootnote({super.key, required this.trace, this.onTap});

  final TurnTrace trace;
  final VoidCallback? onTap;

  /// 从全到简的几种写法(第一种放得下就用它)。
  static List<String> variants(TurnTrace trace) {
    final duration = trace.duration;
    final time = duration == null ? appL10n.commonInProgress : formatSpan(duration);
    final steps = trace.steps > 0 ? appL10n.chatTurnSteps(trace.steps) : null;
    final cost = turnCostLabel(trace);
    final tokens = trace.usage.isEmpty ? null : '${formatTokens(trace.usage.total)} tokens';
    String join(List<String?> parts) => parts.whereType<String>().join(' · ');
    return [
      join([time, steps, cost, tokens]),
      join([time, steps, cost]),
      join([time, cost]),
      time,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final style = AppType.tabular(
      theme.textTheme.labelSmall!.copyWith(fontSize: 12, color: dsh.textTertiary, height: 1.3),
    );
    final options = variants(trace);
    return Semantics(
      button: onTap != null,
      label: l10n.chatTurnFootnoteSemantics(options.first),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        customBorder: Squircle.border(AppShape.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          // 放进 Bleed(8) 的操作行里:左 8 让文字贴正文左缘;右 4 是光学补偿,
          // 箭头字形在 16 的格子里右侧自带约 5 的空白,补完后笔画贴正文右缘。
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final room = constraints.maxWidth - 16;
                final text = options.firstWhere((o) => _width(context, o, style) <= room, orElse: () => options.last);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: style),
                    ),
                    Icon(AppIcons.disclosure, size: 16, color: dsh.textTertiary),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
