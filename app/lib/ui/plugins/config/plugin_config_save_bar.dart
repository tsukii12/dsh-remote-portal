// The bar under a plugin's configuration while edits wait for 保存: one
// status line, centred, over two equal buttons that mirror each other.
//
// ```
//            2 项更改 · 保存后重新载入插件
// |16| [      放弃      ] |12| [      保存      ] |16|
// ```
//
// Saving and reloading keep the line (with a quiet ring) and grey the
// buttons; 已生效 stays a moment on its own; a failure says so in red and
// offers 重试 beside 放弃 — or 恢复原设置 when the Host could not undo it.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/plugin_config/plugin_config_state.dart';
import '../../providers/provider_widgets.dart' show FormBottomBar;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

class PluginConfigSaveBar extends StatelessWidget {
  const PluginConfigSaveBar({
    super.key,
    required this.changes,
    required this.job,
    required this.onSave,
    required this.onDiscard,
    required this.onRetry,
    required this.onRestore,
  });

  /// Held edits.
  final int changes;
  final PluginConfigJob? job;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final VoidCallback onRetry;
  final VoidCallback onRestore;

  /// The buttons' height.
  static const buttonHeight = 48.0;

  /// Between the two buttons.
  static const gap = 12.0;

  /// The status line above them.
  static const statusGap = 10.0;

  /// Room a page leaves at its end so nothing hides under the bar.
  static const reserve = FormBottomBar.height + 36;

  /// Whether a bar shows for [changes] held edits and [job].
  static bool shows(int changes, PluginConfigJob? job) => changes > 0 || job != null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final job = this.job;
    final failure = job?.failure;
    final running = job?.running ?? false;
    final done = job?.done ?? false;

    final IconData? icon;
    final Color color;
    final String status;
    if (failure != null) {
      icon = AppIcons.error;
      color = colors.danger;
      status = switch (failure.kind) {
        PluginConfigFailureKind.reloadFailed when !failure.rolledBack => l10n.pluginConfigStopped,
        PluginConfigFailureKind.reloadFailed => '${l10n.pluginConfigFailed} · ${l10n.pluginConfigRestored}',
        _ => failure.message,
      };
    } else if (done) {
      icon = AppIcons.success;
      color = colors.success;
      status = l10n.pluginConfigApplied;
    } else if (running) {
      icon = null;
      color = theme.colorScheme.onSurfaceVariant;
      status = job?.step == PluginConfigStep.reloading ? l10n.pluginConfigReloading : l10n.pluginConfigSaving;
    } else {
      icon = null;
      color = theme.colorScheme.onSurfaceVariant;
      status = '${l10n.pluginConfigChanges(changes)} · ${l10n.pluginConfigAppliesOnReload}';
    }

    final style = theme.textTheme.bodySmall?.copyWith(color: color);
    final line = Semantics(
      liveRegion: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (running)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  strokeCap: StrokeCap.round,
                  color: colors.textTertiary,
                  backgroundColor: colors.textTertiary.withValues(alpha: 0.3),
                ),
              ),
            )
          else if (icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(icon, size: 16, color: color),
            ),
          Flexible(
            child: Text(
              status,
              key: const ValueKey('plugin-config-status'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );

    // Left: 放弃 or 恢复原设置; right: 保存 or 重试 (the one primary key).
    final unsettled = failure != null && !failure.settled;
    final left = unsettled ? l10n.pluginConfigRestore : l10n.pluginConfigDiscard;
    final right = failure != null ? l10n.commonRetry : l10n.commonSave;
    final idle = !running && !done;
    final size = WidgetStateProperty.all(const Size.fromHeight(buttonHeight));
    return FormBottomBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line,
          if (!done) ...[
            const SizedBox(height: statusGap),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('plugin-config-secondary'),
                    style: ButtonStyle(minimumSize: size),
                    onPressed: idle ? (unsettled ? onRestore : onDiscard) : null,
                    child: Text(left, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('plugin-config-primary'),
                    style: ButtonStyle(minimumSize: size),
                    onPressed: idle ? (failure != null ? onRetry : onSave) : null,
                    child: Text(right, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
