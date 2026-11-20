import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The one designed shape for empty, loading-failed and "not yet" states: a
/// soft round graphic, one line of title, an optional short message and at most
/// one button. Centred; never fills the screen with a spinner.
///
/// ```dart
/// EmptyView(
///   icon: AppIcons.time,
///   title: '还没有自动化任务',
///   message: '定时让 DSH 帮你跑一遍',
///   actionLabel: '新建',
///   onAction: create,
/// )
/// ```
///
/// - [icon] draws the standard round glass badge; [art] replaces it with any
///   widget (a brand mark, an illustration).
/// - [actionLabel] + [onAction] build the standard button; [action] takes a
///   ready-made widget instead (use one or the other).
/// - [compact] is the tighter size for narrow places (the drawer, a card).
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    this.icon,
    this.art,
    required this.title,
    this.message,
    this.action,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.padding,
  }) : assert(action == null || actionLabel == null, 'Pass either action or actionLabel, not both');

  final IconData? icon;
  final Widget? art;
  final String title;
  final String? message;
  final Widget? action;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  /// Outer padding. Defaults to 32 horizontally (24 when [compact]).
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final badge = compact ? 48.0 : 64.0;
    Widget? graphic = art;
    if (graphic == null && icon != null) {
      graphic = SizedBox.square(
        dimension: badge,
        child: GlassSurface(
          tier: GlassTier.card,
          circle: true,
          child: Center(
            child: Icon(icon, size: compact ? 22 : 28, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final button =
        action ??
        (actionLabel == null
            ? null
            : OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(0, compact ? 38 : 44),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(actionLabel!),
              ));
    return Padding(
      padding: padding ?? EdgeInsets.symmetric(horizontal: compact ? 24 : 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (graphic != null) ...[graphic, SizedBox(height: compact ? 14 : 18)],
          Text(
            title,
            textAlign: TextAlign.center,
            style: compact ? theme.textTheme.titleSmall : theme.textTheme.titleMedium,
          ),
          if (message case final message?) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: (compact ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)?.copyWith(
                  color: colors.textTertiary,
                ),
              ),
            ),
          ],
          if (button != null) ...[SizedBox(height: compact ? 14 : 20), button],
        ],
      ),
    );
  }
}
