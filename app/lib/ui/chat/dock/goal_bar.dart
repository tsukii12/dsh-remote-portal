// The goal bar above the composer, after DSH's `dsh-client-ui-goal` GoalBar
// (`conversation.input.dock#goal`): the session's long-term goal, its state,
// and a tap for the actions.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/goal_dock_state.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'dock_pill.dart';

/// 「⚑ 目标 把登录迁到新接口… ⋯」;暂停时图形换成暂停、目标字淡下去、右边
/// 写「已暂停」,受阻时是警示色的「受阻」。点一下打开目标操作。
class GoalBar extends StatelessWidget {
  const GoalBar({super.key, required this.goal, this.onTap});

  final DockGoal goal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    final look = GoalLook.of(goal, colors: colors, dsh: dsh);
    final objective = goalHeadline(goal.goal.objective);
    return Semantics(
      button: onTap != null,
      label: look.state == null
          ? l10n.chatGoalSemantics(objective)
          : l10n.chatGoalStateSemantics(objective, look.state!),
      onTapHint: l10n.chatGoalActions,
      onTap: onTap,
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: DockMetrics.shape,
        grouped: true,
        onTap: onTap,
        child: DockRow(
          leading: DockGlyph.icon(look.icon, color: look.iconColor),
          content: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Row(
              key: ValueKey('$objective\u0000${look.state}'),
              children: [
                Text(l10n.chatGoal, style: DockText.title(context)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    objective,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: DockText.detail(context, color: goal.stopped ? dsh.textTertiary : null),
                  ),
                ),
              ],
            ),
          ),
          accessory: look.state == null
              ? null
              : Text(look.state!, style: DockText.title(context, color: look.stateColor)),
          trailing: DockGlyph(
            child: goal.busy
                ? SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6, color: dsh.textTertiary),
                  )
                : Icon(AppIcons.more, size: DockGlyph.iconSize, color: dsh.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// The objective on one line: its first non-empty line.
String goalHeadline(String objective) {
  for (final line in objective.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return objective.trim();
}

/// How a goal's state reads: the bar's glyph and status word, the sheet's
/// status line.
class GoalLook {
  const GoalLook({required this.icon, required this.iconColor, required this.status, this.state, this.stateColor});

  factory GoalLook.of(DockGoal goal, {required ColorScheme colors, required DshColors dsh}) {
    if (goal.phase == GoalPhase.blocked) {
      return GoalLook(
        icon: AppIcons.error,
        iconColor: dsh.warning,
        status: appL10n.chatGoalBlocked,
        state: appL10n.chatGoalBlocked,
        stateColor: dsh.warning,
      );
    }
    if (goal.stopped) {
      return GoalLook(
        icon: AppIcons.paused,
        iconColor: dsh.textTertiary,
        status: appL10n.commonPaused,
        state: appL10n.commonPaused,
        stateColor: dsh.textTertiary,
      );
    }
    return GoalLook(icon: AppIcons.goal, iconColor: colors.onSurfaceVariant, status: appL10n.commonInProgress);
  }

  final IconData icon;
  final Color iconColor;

  /// The sheet's status word: 「进行中」「已暂停」「受阻」.
  final String status;

  /// The bar's status word; null while the goal simply runs.
  final String? state;
  final Color? stateColor;
}
