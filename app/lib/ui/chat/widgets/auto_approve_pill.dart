// The visible switch for per-conversation auto-approve.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'permission_pill.dart' show PermissionPillMetrics;

/// 「自动允许中 ⓧ」:浮在输入条左上方的警示色小胶囊,和插件胶囊一样高
/// ([PermissionPillMetrics.height])。
///
/// 自动允许意味着命令不再逐条询问,所以它必须一直看得见,而且一点就关。
/// 两端都是图标(左 ✓✓、右 ⓧ),左右内边距相等。
class AutoApprovePill extends StatelessWidget {
  const AutoApprovePill({super.key, required this.onDisable});

  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final fg = dsh.onWarningContainer;
    final style = theme.textTheme.labelMedium?.copyWith(color: fg);
    return Semantics(
      button: true,
      label: l10n.chatAutoApproveCommands,
      onTapHint: l10n.commonClose,
      onTap: onDisable,
      excludeSemantics: true,
      child: Material(
        color: Color.alphaBlend(dsh.warningContainer.withValues(alpha: 0.94), theme.colorScheme.surface),
        shape: StadiumBorder(side: BorderSide(color: dsh.warning.withValues(alpha: 0.35), width: 0.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onDisable,
          child: SizedBox(
            height: PermissionPillMetrics.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.autoApprove, size: 16, color: fg),
                  const SizedBox(width: 6),
                  Text(l10n.chatAutoApproving, style: style),
                  const SizedBox(width: 8),
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(color: fg.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: Icon(AppIcons.close, size: 12, color: fg),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
