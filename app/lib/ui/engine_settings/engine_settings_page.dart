// Any settings namespace as a page: the curated page when the app has one,
// otherwise the plugin's configuration page (lib/ui/plugins/config/), which
// draws every field its Config declares.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart' show SettingsNamespaceView;

import '../features/feature_widgets.dart' show FeatureMessage;
import '../plugins/config/plugin_config_page.dart';
import '../theme/app_icons.dart';
import '../settings/media_settings_page.dart';
import 'general_settings_page.dart';
import 'namespace_copy.dart';
import 'runtime_settings_pages.dart';
import 'schema_documentation.dart';
import 'schema_fields.dart' show humanizeKey;
import 'schema_form.dart';
import 'subagent_settings_page.dart';
import 'web_search_page.dart';

/// The generated form of one namespace, live fields only
/// (`settings/describe`); plugins open [PluginConfigPage].
class EngineSettingsPage extends StatelessWidget {
  const EngineSettingsPage({super.key, required this.ns, this.title});

  final String ns;

  /// Defaults to the namespace's known title, else its id in words.
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: title ?? namespaceTitle(ns),
      namespaces: [ns],
      missingTitle: l10n.engineSettingsPluginStopped,
      missingBody: l10n.engineSettingsEnablePlugin,
      actions: (context, settings) => [
        SchemaDocumentationButton(schema: settings[ns]!.schema, title: title ?? namespaceTitle(ns)),
      ],
      builder: (context, settings) {
        final view = settings[ns]!;
        final groups = schemaFormGroups(schemaSections(view, copy: namespaceCopy[ns] ?? const {}), settings: settings);
        if (groups.isEmpty) {
          return [FeatureMessage(icon: AppIcons.configure, title: l10n.engineSettingsNoEditableFields)];
        }
        return groups;
      },
    );
  }
}

/// A namespace's page title.
String namespaceTitle(String ns) => namespaceTitles[ns] ?? humanizeKey(ns);

/// Namespaces that have a curated page of their own.
const curatedNamespaces = {
  'subagent',
  'subagent-model-selection-settings',
  'agent-loop',
  'bash-sandbox',
  'pwsh-sandbox',
  'web',
  'web-search-deepseek',
  'web-deepseek-api',
  'ui-settings',
  'ui-chat',
  'ui-conversation',
  'session-log-deepseek',
  // 设置 › 图像与视频.
  'dsh-media',
  'media',
};

/// The engine's own plumbing and the web client's private state: native
/// pages of their own elsewhere, or nothing to set on a phone. Not what
/// makes an entry a plugin: that is `PluginConfigScope` (an allowlist), for
/// the plugin settings page and everything that lists it.
const internalNamespaces = {
  'permission',
  'agent-preset-registry',
  'agent-default-model',
  'locale',
  'ui-theme',
  'ui-settings-account',
  'ui-settings-general',
  'llm-pi-ai',
  'llm-deepseek',
  'llm-deepseek-account',
};

/// A namespace's live settings worth a generated form: not curated, not
/// plumbing, offered by the plugin (or known to the app), with fields.
/// Whether it is a plugin at all is `PluginConfigScope.allows`'s call.
bool isPluginForm(SettingsNamespaceView view) =>
    !curatedNamespaces.contains(view.ns) &&
    !internalNamespaces.contains(view.ns) &&
    (view.autoGenerate || namespaceCopy.containsKey(view.ns)) &&
    hasFormFields(view);

/// The page for [ns]: curated when there is one, the plugin's
/// configuration otherwise.
Widget settingsPageFor(String ns, {String? title}) => switch (ns) {
  'subagent' || 'subagent-model-selection-settings' => const SubagentSettingsPage(),
  'agent-loop' => const AgentLoopSettingsPage(),
  'bash-sandbox' || 'pwsh-sandbox' => const ShellSettingsPage(),
  'web' || 'web-search-deepseek' || 'web-deepseek-api' => const WebSearchSettingsPage(),
  'ui-settings' || 'ui-chat' || 'ui-conversation' || 'session-log-deepseek' => const GeneralSettingsPage(),
  'dsh-media' || 'media' => const MediaSettingsPage(),
  _ => PluginConfigPage(ns: ns, title: title),
};

/// Pushes [settingsPageFor] on the root navigator's stack.
Future<void> openSettingsPage(BuildContext context, String ns, {String? title}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => settingsPageFor(ns, title: title)));
