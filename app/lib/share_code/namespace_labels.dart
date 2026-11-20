// Product names for DSH settings namespaces (the Loader entry ids
// `settings/describe` reports), for the share checklist and the import diff.
// Unknown namespaces show their id.

import '../l10n/l10n.dart';

Map<String, String> get _labels => {
  'agent-default-model': appL10n.pluginsNamespaceDefaultModel,
  'agent-preset-registry': appL10n.pluginsNamespaceDefaultPreset,
  'agent-loop': appL10n.pluginsNamespaceAgent,
  'subagent': appL10n.pluginsNamespaceSubagent,
  'subagent-model-selection-settings': appL10n.pluginsNamespaceSubagentModels,
  'llm-deepseek': appL10n.pluginsNamespaceDeepSeekModel,
  'llm-deepseek-account': appL10n.pluginsNamespaceAccountModel,
  'llm-pi-ai': appL10n.pluginsNamespaceCustomModels,
  'web': appL10n.pluginsNamespaceNetwork,
  'web-search-deepseek': appL10n.pluginsNamespaceWebSearch,
  'web-deepseek-api': appL10n.pluginsNamespaceSearchApi,
  'bash-sandbox': appL10n.pluginsNamespaceCommands,
  'permission': appL10n.pluginsNamespacePermissions,
  'session-log-deepseek': appL10n.pluginsNamespaceChatLog,
  'cot-translation': appL10n.pluginsNamespaceThinkingTranslation,
  'translator': appL10n.pluginsNamespaceTranslation,
  'locale': appL10n.pluginsNamespaceLanguage,
  'ui-theme': appL10n.pluginsNamespaceWebAppearance,
  'ui-chat': appL10n.pluginsNamespaceWebChat,
  'ui-conversation': appL10n.pluginsNamespaceWebInput,
  'ui-settings': appL10n.pluginsNamespaceWebSettings,
  'ui-settings-general': appL10n.pluginsNamespaceWebGeneral,
  'auto-review': appL10n.pluginsNamespaceAutoReview,
  'agent-team': appL10n.pluginsNamespaceAgentTeam,
  'speech-to-text': appL10n.pluginsNamespaceVoiceInput,
};

/// 「子代理」 for `subagent`; the id itself when unknown.
String namespaceLabel(String ns) => _labels[ns] ?? ns;

/// Whether [ns] has a product name (unknown ones are drawn in mono).
bool hasNamespaceLabel(String ns) => _labels.containsKey(ns);
