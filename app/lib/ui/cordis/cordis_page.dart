// Native mirror of the official Cordis panel (`dsh-client-ui-cordis`, the
// badge at the bottom of DSH Web's sidebar): the Host's dynamic plugins,
// grouped like the official panel (this conversation first). A row opens its
// sheet; the plugin's own panel opens in DSH Web.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/cordis_state.dart';
import '../../state/sessions_state.dart';
import '../common/list_page_row.dart';
import '../common/status_dot.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'cordis_plugin_sheet.dart';

StatusTone cordisTone(CordisPluginStatus status) => switch (status) {
  CordisPluginStatus.idle => StatusTone.idle,
  CordisPluginStatus.awaitingApproval => StatusTone.warn,
  CordisPluginStatus.starting => StatusTone.busy,
  CordisPluginStatus.running => StatusTone.ok,
  CordisPluginStatus.failed => StatusTone.error,
};

/// 「Cordis」: every dynamic plugin on the active host.
class CordisPage extends ConsumerWidget {
  const CordisPage({super.key, this.sessionId});

  /// The conversation open in the chat (its plugins come first); defaults to
  /// the chat's current one.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final reach = ref.watch(cordisReachProvider);
    final inventory = ref.watch(cordisInventoryProvider);
    final current = sessionId ?? ref.watch(currentSessionProvider);
    final list = inventory.value;
    final groups = list == null ? null : cordisGroups(list, current);
    // Group titles only when both groups have rows.
    final titled = groups != null && groups.current.isNotEmpty && groups.others.isNotEmpty;
    var index = 0;
    Widget row(CordisPlugin plugin) => FadeSlideIn(
      index: index++,
      child: CordisPluginRow(plugin: plugin, onTap: () => unawaited(showCordisPluginSheet(context, plugin))),
    );

    return AppPage.list(
      title: 'Cordis',
      subtitle: Text(l10n.featuresCordisSubtitle),
      children: [
        if (reach == CordisReach.offline)
          const FeatureOffline()
        else if (reach == CordisReach.unsupported)
          FeatureMessage(
            icon: AppIcons.offline,
            title: l10n.featuresCordisUnavailable,
            body: l10n.featuresCordisRemoteUnavailable,
          )
        else if (list == null && inventory.hasError)
          FeatureMessage.error(
            title: l10n.featuresCordisReadFailed,
            error: inventory.error!,
            onRetry: () => ref.invalidate(cordisInventoryProvider),
          )
        else if (groups == null)
          const FeatureLoading()
        else if (list!.isEmpty)
          FeatureMessage(icon: AppIcons.cordis, title: l10n.featuresCordisEmpty, body: l10n.featuresCordisEmptyHint)
        else ...[
          if (groups.current.isNotEmpty)
            ListPageCard(
              title: titled ? l10n.featuresCurrentChat : null,
              children: [for (final p in groups.current) row(p)],
            ),
          if (titled) const SizedBox(height: 24),
          if (groups.others.isNotEmpty)
            ListPageCard(
              title: titled ? l10n.featuresOtherChats : null,
              children: [for (final p in groups.others) row(p)],
            ),
        ],
      ],
    );
  }
}

/// One plugin: status dot, name, purpose, and the status in words.
class CordisPluginRow extends StatelessWidget {
  const CordisPluginRow({super.key, required this.plugin, required this.onTap});

  final CordisPlugin plugin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final status = plugin.status;
    return ListPageRow(
      leading: StatusDot(tone: cordisTone(status)),
      title: plugin.name,
      subtitle: plugin.purpose.isEmpty ? null : plugin.purpose,
      meta: cordisStatusLabel(status),
      metaColor: switch (status) {
        CordisPluginStatus.failed => colors.danger,
        CordisPluginStatus.awaitingApproval => colors.warning,
        _ => null,
      },
      onTap: onTap,
    );
  }
}
