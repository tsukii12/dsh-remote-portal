import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/hosts_state.dart';
import '../../state/plugin_reload.dart';
import '../../state/plugins_state.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../theme/app_icons.dart';

/// A local development shortcut, with the full restart made explicit.
class PluginReloadAction extends ConsumerWidget {
  const PluginReloadAction({super.key, required this.bundle});

  final PluginBundle bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isLocalPluginSource(bundle.source)) return const SizedBox.shrink();
    final host = ref.watch(pluginHostProvider);
    final active = ref.watch(activeHostProvider);
    final runtime = ref.watch(localRuntimeProvider.select((state) => state.status));
    if (!canReloadLocalPlugin(bundle, host, active, runtime)) return const SizedBox.shrink();
    final busy = ref.watch(localPluginReloadProvider);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListPageCard(
        key: const ValueKey('plugin-reload-action'),
        margin: EdgeInsets.zero,
        children: [
          ListPageRow(
            icon: AppIcons.refresh,
            title: l10n.pluginsReloadLocal,
            titleMaxLines: 3,
            subtitle: l10n.pluginsReloadInterrupts,
            subtitleMaxLines: 2,
            trailing: busy
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: l10n.pluginsLoading),
                  )
                : null,
            onTap: busy ? null : () => _reload(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _reload(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(localPluginReloadProvider.notifier);
    final title = bundle.title(Localizations.localeOf(context).toLanguageTag());
    try {
      final result = await controller.reload(
        bundle,
        confirm: () async =>
            context.mounted &&
            await showAppDialog<bool>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: Text(l10n.pluginsReloadConfirm(title)),
                    content: Text(l10n.pluginsReloadExplanation),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: Text(l10n.pluginsReloadProceed),
                      ),
                    ],
                  ),
                ) ==
                true,
      );
      if (!(messenger?.mounted ?? false)) return;
      switch (result) {
        case PluginReloadResult.requested:
          messenger!.showBriefNotice(l10n.pluginsReloadRequested);
        case PluginReloadResult.unavailable:
          messenger!.showBriefNotice(l10n.pluginsReloadChanged);
        case PluginReloadResult.cancelled || PluginReloadResult.busy:
          break;
      }
    } on Object {
      if (messenger?.mounted ?? false) messenger!.showBriefNotice(l10n.pluginsReloadFailed);
    }
  }
}
