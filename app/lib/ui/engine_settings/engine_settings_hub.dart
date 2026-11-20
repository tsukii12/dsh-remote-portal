// 「引擎参数」: the current host's engine parameters — subagents, the agent
// loop, command execution — the plugin inventory, and the settings of every
// plugin that brings a form of its own (named and marked read-only as in
// plugin_config_entries.dart). Each row shows the value that matters most.
// (联网搜索 has its own row in 设置 › 能力; the web app's preferences moved to
// 设置 › 界面 and the log upload to 隐私与分享.)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/plugin_config/plugin_config_state.dart';
import '../../state/plugins_state.dart';
import '../features/feature_widgets.dart';
import '../plugins/config/plugin_config_entries.dart';
import '../plugins/config/plugin_config_page.dart';
import '../plugins/plugin_inventory_page.dart';
import '../settings/index/spots.dart';
import '../settings/settings_widgets.dart' as sw show SettingsSection, SettingsTile;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'namespace_copy.dart';
import 'runtime_settings_pages.dart';
import 'schema_fields.dart';
import 'subagent_settings_page.dart';

class EngineSettingsHubPage extends ConsumerWidget {
  const EngineSettingsHubPage({super.key});

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(engineSettingsProvider);
    final settings = async.value;
    String? number(String ns, String key) {
      final value = settings?.valueOf(FieldRef(ns, [key]));
      if (value is! num) return null;
      final copy = copyOf(ns, [key]);
      final node = settings?.nodeOf(FieldRef(ns, [key]));
      return formatFieldNumber(value, copy.unit ?? (node == null ? FieldUnit.plain : unitFor(key, node)), copy);
    }

    final shellNs = settings != null && settings.served('pwsh-sandbox') && !settings.served('bash-sandbox')
        ? 'pwsh-sandbox'
        : 'bash-sandbox';
    final depth = settings?.valueOf(const FieldRef('subagent', ['maxDepth']));
    // Every plugin with something to set, live fields or not.
    final config = settings == null ? null : ref.watch(pluginConfigProvider).value;
    final plugins = pluginConfigEntries(config);
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final rows = <(IconData, SettingsPageId, String?, Widget)>[
      (
        AppIcons.subagents,
        SettingsPageId.subagent,
        depth is num ? (depth is int ? l10n.engineLayerCount(depth) : l10n.engineLayerValue('$depth')) : null,
        const SubagentSettingsPage(),
      ),
      (
        AppIcons.agentLoop,
        SettingsPageId.agentLoop,
        number('agent-loop', 'maxParallelToolCalls'),
        const AgentLoopSettingsPage(),
      ),
      (AppIcons.commandTimeout, SettingsPageId.shell, number(shellNs, 'timeoutMs'), const ShellSettingsPage()),
    ];
    return AppPage.list(
      title: l10n.engineSettingsTitle,
      subtitle: settings == null || settings.local ? null : Text(settings.hostLabel),
      children: [
        if (settings == null && async.hasError)
          FeatureMessage(
            icon: AppIcons.error,
            title: l10n.engineSettingsReadFailed,
            body: describeSettingsError(async.error!),
            action: (l10n.commonRetry, () => ref.invalidate(engineSettingsProvider)),
          )
        else if (settings == null && async.isLoading)
          const FeatureLoading()
        else if (settings == null)
          const FeatureOffline()
        else ...[
          sw.SettingsSection(
            title: l10n.engineSettingsRun,
            children: [
              for (final (icon, id, value, page) in rows)
                sw.SettingsTile(
                  icon: icon,
                  tinted: false,
                  spot: SettingsIndex.entry(id),
                  value: value == null ? null : Text(value),
                  onTap: () => _open(context, page),
                ),
            ],
          ),
          sw.SettingsSection(
            title: l10n.engineSettingsPlugins,
            children: [
              sw.SettingsTile(
                icon: AppIcons.pluginInventory,
                tinted: false,
                spot: SettingsIndex.entry(SettingsPageId.pluginInventory),
                onTap: () => _open(context, const PluginInventoryPage()),
              ),
              // No confirmed plugin list: no plugin's settings, and a way to ask again.
              if (config?.scope.status == PluginScopeStatus.failed)
                sw.SettingsTile(
                  icon: AppIcons.error,
                  tinted: false,
                  title: l10n.pluginConfigListFailed,
                  value: Text(l10n.commonRetry),
                  onTap: () => retryPluginList(ref),
                ),
              for (final ns in plugins)
                sw.SettingsTile(
                  icon: AppIcons.plugin,
                  tinted: false,
                  spot: pluginFormSpot(ns, (l) => pluginConfigTitle(ns, bundles, state: config, l10n: l)),
                  // Fixed by an overlay: said here, not only once opened.
                  subtitle: pluginConfigReadOnlyNote(config, ns, l10n: l10n),
                  onTap: () => _open(
                    context,
                    PluginConfigPage(
                      ns: ns,
                      title: pluginConfigTitle(ns, bundles, state: config, l10n: l10n),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
