import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/hosts_state.dart';
import '../../state/plugin_load_status.dart';
import '../common/list_page_row.dart';
import '../onboarding/runtime_setup_page.dart' show showRuntimeLogSheet;
import '../theme/app_icons.dart';
import 'plugin_widgets.dart' show PluginLogBox;

/// Extra detail only when the current inventory reports an incomplete load or
/// metadata issue. A failed inventory request is not evidence of plugin failure;
/// its retry and connection state remain on the existing inventory page.
class PluginLoadStatus extends ConsumerWidget {
  const PluginLoadStatus({super.key, required this.bundle});

  final PluginBundle bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!bundle.enabled || bundle.rows.isEmpty) return const SizedBox.shrink();
    final async = ref.watch(pluginInventoryProvider);
    if (async.isLoading || async.hasError || async.value == null) return const SizedBox.shrink();
    final rows = bundleLoadRows(bundle, async.value!.inventory);
    final issues = rows.where((row) => row.hasIssue).toList(growable: false);
    if (issues.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final local = ref.watch(activeHostProvider.select((host) => host.isLocal));
    final running = rows.where((row) => row.status == InventoryStatus.running).length;
    final incomplete = rows.any((row) => row.incomplete);
    final failed = rows.any((row) => row.status == InventoryStatus.failed);
    final summary = running > 0 && incomplete
        ? l10n.pluginsLoadPartial
        : failed
        ? l10n.pluginsLoadFailed
        : incomplete
        ? l10n.pluginsLoadNotReady
        : l10n.pluginsLoadMetadata;
    final locale = Localizations.localeOf(context).toLanguageTag();
    String status(BundleRowLoad row) => switch (row.status) {
      InventoryStatus.running => l10n.commonRunning,
      InventoryStatus.failed => l10n.pluginsLoadFailed,
      InventoryStatus.loading => l10n.stateLoading,
      InventoryStatus.waiting => l10n.stateInventoryWaiting,
      InventoryStatus.idle => l10n.stateNotRunning,
      InventoryStatus.off => l10n.stateInventoryDisabled,
      InventoryStatus.conditional => l10n.stateInventoryConditional,
      null => l10n.pluginsLoadUnreported,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListPageCard(
        key: const ValueKey('plugin-load-status'),
        margin: EdgeInsets.zero,
        children: [
          ListPageRow(
            icon: AppIcons.diagnostics,
            title: l10n.pluginsLoadStatus,
            subtitle: '$summary · ${l10n.pluginsLoadRunningCount(running, rows.length)}',
            subtitleMaxLines: 3,
          ),
          for (final row in issues) ...[
            ListPageRow(
              title: row.row.meta?.title?.resolve(locale) ?? row.row.moduleName,
              titleMaxLines: 2,
              subtitle: row.row.entryId,
              subtitleMaxLines: 2,
              value: status(row),
            ),
            if (row.metadataErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: PluginLogBox(text: row.metadataErrors.join('\n\n'), title: l10n.pluginsLoadMetadata),
              ),
          ],
          if (failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(l10n.pluginsLoadNoRuntimeDetail, style: Theme.of(context).textTheme.bodySmall),
            ),
          ListPageRow(
            icon: AppIcons.refresh,
            title: l10n.pluginsRefresh,
            onTap: () => ref.invalidate(pluginInventoryProvider),
          ),
          if (local)
            ListPageRow(
              icon: AppIcons.terminal,
              title: l10n.shellEngineLogs,
              onTap: () {
                if (ref.read(activeHostProvider).isLocal) showRuntimeLogSheet(context);
              },
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(l10n.pluginsLoadRemoteLogs, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
