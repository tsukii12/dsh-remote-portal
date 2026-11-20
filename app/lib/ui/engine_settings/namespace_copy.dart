// SPDX-FileCopyrightText: 2026 DeepSeek
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Chinese copy for the engine's own settings namespaces, adapted from the
// official settings pages (`dsh-client-ui-settings-*`, `dsh-client-ui-chat`,
// `dsh-client-ui-conversation`, the experimental thinking-translation page,
// the plugin market and the package READMEs). The curated pages and the
// generated form read the same entries, so a field reads the same wherever
// it shows up.

import '../../l10n/l10n.dart';
import 'schema_fields.dart';
import 'plugin_namespace_copy_zh.dart';

/// Page titles of namespaces (the generated form's fallback title).
Map<String, String> get namespaceTitles => <String, String>{
  if (!AppLocale.isEnglish) ...pluginNamespaceTitlesZh,
  'subagent': appL10n.engineSubagentTitle,
  'subagent-model-selection-settings': appL10n.engineSubagentModelsTitle,
  'agent-loop': appL10n.engineAgentLoopTitle,
  'bash-sandbox': appL10n.engineShellTitle,
  'pwsh-sandbox': appL10n.engineShellTitle,
  'web': appL10n.engineSearchTitle,
  'web-search-deepseek': appL10n.engineSearchTitle,
  'web-deepseek-api': appL10n.engineSearchTitle,
  'session-log-deepseek': appL10n.engineChatLogTitle,
  'cot-translation': appL10n.engineThinkingTranslationTitle,
  'plugin-market': appL10n.enginePluginIndexesTitle,
  'permission': appL10n.enginePermissionTitle,
  'agent-preset-registry': appL10n.engineAgentPresetsTitle,
  'agent-default-model': appL10n.engineDefaultModelTitle,
  'ui-theme': appL10n.engineWebAppearanceTitle,
  'ui-chat': appL10n.engineGeneralTitle,
  'ui-conversation': appL10n.engineGeneralTitle,
  'ui-settings': appL10n.engineGeneralTitle,
  'locale': appL10n.engineLanguageTitle,
};

Map<String, FieldCopy> get _shell => <String, FieldCopy>{
  'timeoutMs': FieldCopy(label: appL10n.engineFieldCommandTimeout, unit: FieldUnit.milliseconds),
  'maxOutputBytes': FieldCopy(label: appL10n.engineFieldMaxOutput, unit: FieldUnit.bytes),
  'maxTimeoutMs': FieldCopy(label: appL10n.engineFieldMaxTimeout, unit: FieldUnit.milliseconds),
  'maxSpillBytes': FieldCopy(label: appL10n.engineFieldMaxSpill, unit: FieldUnit.bytes),
  'graceMs': FieldCopy(label: appL10n.engineFieldGracePeriod, unit: FieldUnit.milliseconds),
  'cwd': FieldCopy(label: appL10n.engineFieldDefaultCwd, placeholder: appL10n.engineFieldFollowChat),
};

const _apiKey = FieldCopy(label: 'API Key');

/// Copy by namespace, then by dotted field path.
Map<String, Map<String, FieldCopy>> get namespaceCopy => <String, Map<String, FieldCopy>>{
  if (!AppLocale.isEnglish) ...pluginNamespaceCopyZh,
  'subagent': {
    'maxDepth': FieldCopy(
      label: appL10n.engineSubagentMaxDepth,
      suffix: appL10n.engineFieldLayersUnit,
      countUnit: FieldCountUnit.layers,
    ),
    'maxActiveSubagents': FieldCopy(
      label: appL10n.engineSubagentMaxActive,
      suffix: appL10n.engineFieldCountUnit,
      countUnit: FieldCountUnit.items,
    ),
  },
  'subagent-model-selection-settings': {
    'enabled': FieldCopy(label: appL10n.engineSubagentAllowModelChoice),
    'allowedModels': FieldCopy(label: appL10n.engineSubagentAllowedModels),
  },
  'agent-loop': {
    'maxParallelToolCalls': FieldCopy(
      label: appL10n.engineAgentMaxParallelCalls,
      suffix: appL10n.engineFieldCountUnit,
      countUnit: FieldCountUnit.items,
    ),
  },
  'bash-sandbox': _shell,
  'pwsh-sandbox': _shell,
  'web': {
    'searchProvider': FieldCopy(label: appL10n.engineFieldSearchProvider),
    'fetchProvider': FieldCopy(label: appL10n.engineFieldFetchProvider),
  },
  'web-search-deepseek': {
    'apiKey': _apiKey,
    'baseURL': FieldCopy(label: appL10n.engineFieldBaseUrl, placeholder: appL10n.commonDefault),
    'maxUses': FieldCopy(
      label: appL10n.engineSearchMaxUses,
      suffix: appL10n.engineFieldTimesUnit,
      countUnit: FieldCountUnit.uses,
    ),
    'model': FieldCopy(label: appL10n.engineSearchHelperModel),
    'apiVersion': FieldCopy(label: appL10n.engineFieldApiVersion),
    'maxTokens': FieldCopy(label: appL10n.engineFieldMaxTokens, unit: FieldUnit.tokens),
  },
  'web-deepseek-api': {
    'apiKey': _apiKey,
    'baseURL': FieldCopy(label: appL10n.engineFieldBaseUrl, placeholder: appL10n.commonDefault),
    'count': FieldCopy(
      label: appL10n.engineSearchResultsPerSearch,
      suffix: appL10n.engineFieldResultsUnit,
      countUnit: FieldCountUnit.results,
    ),
    'sendOriginalQuestion': FieldCopy(label: appL10n.engineSearchSendOriginalQuestion),
  },
  'session-log-deepseek': {'enabled': FieldCopy(label: appL10n.engineChatLogUpload)},
  'cot-translation': {
    'provider': FieldCopy(
      label: appL10n.engineTranslationProvider,
      choices: {
        'bing': 'Bing',
        'google': 'Google',
        'deepseek-account': appL10n.engineTranslationAccountPaid,
        'deepseek-official': appL10n.engineTranslationApiPaid,
      },
    ),
    'targetLanguage': FieldCopy(
      label: appL10n.engineTranslationTargetLanguage,
      shown: {'auto': appL10n.engineTranslationFollowLanguage},
      placeholder: 'auto',
      patternMessage: appL10n.engineTranslationLanguageHint,
    ),
  },
  'plugin-market': {
    'indexes': FieldCopy(
      label: appL10n.enginePluginIndexSources,
      itemLabel: appL10n.enginePluginIndexUrl,
      placeholder: 'https://example.com/index.json',
      patternMessage: appL10n.engineFieldHttpUrlHint,
    ),
  },
  'permission': {'defaultPreset': FieldCopy(label: appL10n.enginePermissionNewChat)},
  'agent-preset-registry': {'selectedDefault': FieldCopy(label: appL10n.engineAgentDefaultPreset)},
  'agent-default-model': {
    'provider': FieldCopy(label: appL10n.engineProviderTitle),
    'model': FieldCopy(label: appL10n.engineModelTitle),
    'reasoningEffort': FieldCopy(label: appL10n.engineFieldReasoningEffort),
  },
  'ui-settings': {'enabled': FieldCopy(label: appL10n.engineGeneralShowCodingView)},
  'ui-chat': {
    'transcriptView': FieldCopy(
      label: appL10n.engineGeneralWorkDetails,
      choices: {
        'compact': appL10n.engineFieldCompact,
        'standard': appL10n.engineFieldStandard,
        'detailed': appL10n.engineFieldDetailed,
        'verbose': appL10n.engineFieldVerbose,
      },
      aliases: {'normal': 'detailed', 'expanded': 'detailed'},
      fallback: 'detailed',
    ),
    'collapseTiming': FieldCopy(
      label: appL10n.engineGeneralCollapseTiming,
      choices: {'completion': appL10n.engineGeneralOnCompletion, 'next-input': appL10n.engineGeneralOnNewMessage},
    ),
    'performanceUsage': FieldCopy(
      label: appL10n.engineGeneralPerformanceUsage,
      choices: {'compact': appL10n.engineFieldCompact, 'detailed': appL10n.engineFieldDetailed},
    ),
    'linkOpening': FieldCopy(
      label: appL10n.engineGeneralLinkOpening,
      choices: {'sidebar': appL10n.engineGeneralAppSidebar, 'new-tab': appL10n.engineGeneralDefaultBrowser},
    ),
  },
  'ui-conversation': {
    'busyEnter': FieldCopy(
      label: appL10n.engineGeneralBusySend,
      choices: {'queue': appL10n.engineGeneralQueueSend, 'steer': appL10n.engineGeneralSteerSend},
    ),
  },
  'ui-theme': {
    'preference': FieldCopy(
      label: appL10n.engineFieldTheme,
      choices: {'system': appL10n.commonFollowSystem, 'light': appL10n.commonLight, 'dark': appL10n.commonDark},
    ),
    'fontSize': FieldCopy(label: appL10n.engineFieldFontSize),
    'codeFontSize': FieldCopy(label: appL10n.engineFieldCodeFontSize),
    'terminalFontSize': FieldCopy(label: appL10n.engineFieldTerminalFontSize),
    'textFontFamily': FieldCopy(label: appL10n.engineFieldTextFont, placeholder: appL10n.commonDefault),
    'codeFontFamily': FieldCopy(label: appL10n.engineFieldCodeFont, placeholder: appL10n.commonDefault),
    'terminalFontFamily': FieldCopy(label: appL10n.engineFieldTerminalFont, placeholder: appL10n.commonDefault),
  },
  'locale': {
    'preference': FieldCopy(label: appL10n.engineFieldInterfaceLanguage, placeholder: appL10n.commonFollowSystem),
  },
};

/// The copy of one field; empty when none is written.
FieldCopy copyOf(String ns, List<String> path) => namespaceCopy[ns]?[path.join('.')] ?? const FieldCopy();
