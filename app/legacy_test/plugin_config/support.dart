// Plugins for the configuration page tests, served by the in-memory Host
// interface (MemoryPluginConfigApi): a long voice plugin with groups and
// plumbing, a translator mixing live fields, a reload field and a key, and a
// market plugin that ships its own web page (`configure({ auto: false })`).

import 'package:dsh_app/state/engine_settings_state.dart' show FieldRef;
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';

Map<String, Object?> _text(String zh, String en) => {'zh': zh, 'en': en};

Map<String, Object?> _meta({
  Object? defaultValue,
  bool hasDefault = false,
  String? zh,
  String? en,
  bool live = false,
  bool required = false,
  String? role,
  num? min,
  num? max,
  num? step,
  bool collapse = false,
}) => {
  if (hasDefault || defaultValue != null) 'default': defaultValue,
  if (zh != null) 'description': _text(zh, en ?? zh),
  if (live) 'volatile': true,
  if (required) 'required': true,
  'role': ?role,
  'min': ?min,
  'max': ?max,
  'step': ?step,
  if (collapse) 'collapse': true,
};

Map<String, Object?> str({Object? def, String? zh, String? en, bool live = false, bool required = false, String? role}) =>
    {'type': 'string', 'meta': _meta(defaultValue: def, zh: zh, en: en, live: live, required: required, role: role)};

Map<String, Object?> natural({num? def, String? zh, String? en, bool live = false, num min = 0, num? max}) => {
  'type': 'number',
  'meta': _meta(defaultValue: def, zh: zh, en: en, live: live, min: min, max: max, step: 1),
};

Map<String, Object?> number({num? def, String? zh, String? en, bool live = false, num? min, num? max, String? role}) => {
  'type': 'number',
  'meta': _meta(defaultValue: def, zh: zh, en: en, live: live, min: min, max: max, role: role),
};

Map<String, Object?> boolean({bool? def, String? zh, String? en, bool live = false}) =>
    {'type': 'boolean', 'meta': _meta(defaultValue: def, zh: zh, en: en, live: live)};

Map<String, Object?> choice(List<String> values, {String? def, String? zh, String? en, bool live = false}) => {
  'type': 'union',
  'list': [
    for (final v in values) {'type': 'const', 'value': v},
  ],
  'meta': _meta(defaultValue: def, zh: zh, en: en, live: live),
};

Map<String, Object?> strings({List<String>? def, String? zh, String? en}) => {
  'type': 'array',
  'inner': {'type': 'string'},
  'meta': _meta(defaultValue: def, zh: zh, en: en),
};

Map<String, Object?> fields(Map<String, Object?> dict, {String? zh, String? en, bool collapse = false}) => {
  'type': 'object',
  'dict': dict,
  'meta': _meta(zh: zh, en: en, collapse: collapse),
};

/// 语音输入: 20 fields — a live language, model choices up front, three
/// groups, and plenty of timeouts, limits and paths.
MemoryPluginEntry voiceEntry() => MemoryPluginEntry(
  ns: 'speech-to-text-sensevoice',
  schema: fields({
    'language': choice(['auto', 'zh', 'en', 'ja'], def: 'auto', zh: '识别语言', en: 'Recognition language', live: true),
    'precision': choice(['int8', 'fp32'], def: 'int8', zh: '模型精度', en: 'Model precision'),
    'punctuation': boolean(def: true, zh: '自动加标点', en: 'Add punctuation'),
    'threads': natural(def: 2, min: 1, zh: '推理线程', en: 'Inference threads'),
    'modelOrigins': strings(
      def: ['https://huggingface.co', 'https://hf-mirror.com'],
      zh: '模型下载源',
      en: 'Model sources',
    ),
    'dataRoot': str(zh: '数据目录', en: 'Data directory'),
    'modelDirectory': str(zh: '模型目录', en: 'Model directory'),
    'vad': fields({
      'threshold': number(def: 0.5, min: 0, max: 1, role: 'slider', zh: '灵敏度', en: 'Sensitivity'),
      'minSpeechSeconds': number(def: 0.25, min: 0, zh: '最短语音', en: 'Shortest speech'),
      'minSilenceSeconds': number(def: 0.5, min: 0.01, zh: '停顿判定', en: 'Pause length'),
      'onsetPaddingSeconds': number(def: 0.3, min: 0, max: 1, zh: '起始留白', en: 'Lead-in'),
    }, zh: '语音检测', en: 'Voice detection'),
    'segments': fields({
      'segmentSeconds': number(def: 30, min: 1, max: 120, zh: '分段长度', en: 'Segment length'),
      'maxPending': natural(def: 4, min: 1, zh: '排队上限', en: 'Queue limit'),
    }, zh: '分段', en: 'Segments'),
    'limits': fields({
      'maxAudioBytes': natural(def: 4194304, min: 46, zh: '音频上限', en: 'Audio limit'),
      'maxResponseBytes': natural(def: 131072, min: 1, zh: '结果上限', en: 'Result limit'),
      'maxLogBytes': natural(def: 65536, min: 1, zh: '日志上限', en: 'Log limit'),
    }, zh: '限制', en: 'Limits'),
    'prepareTimeoutMs': natural(def: 3600000, min: 1, zh: '准备超时', en: 'Preparation timeout'),
    'inferenceTimeoutMs': natural(def: 120000, min: 1, zh: '识别超时', en: 'Recognition timeout'),
    'idleTimeoutMs': natural(def: 300000, zh: '空闲释放', en: 'Release when idle'),
    'graceMs': natural(def: 1000, min: 1, zh: '收尾等待', en: 'Wind-down wait'),
  }),
  base: {
    'language': 'auto',
    'precision': 'int8',
    'punctuation': true,
    'threads': 2,
    'modelOrigins': ['https://huggingface.co', 'https://hf-mirror.com'],
    'dataRoot': '/root/.dsh/speech-to-text/sensevoice',
    'vad': {'threshold': 0.5, 'minSpeechSeconds': 0.25, 'minSilenceSeconds': 0.5, 'onsetPaddingSeconds': 0.3},
    'segments': {'segmentSeconds': 30, 'maxPending': 4},
    'limits': {'maxAudioBytes': 4194304, 'maxResponseBytes': 131072, 'maxLogBytes': 65536},
    'prepareTimeoutMs': 3600000,
    'inferenceTimeoutMs': 120000,
    'idleTimeoutMs': 300000,
    'graceMs': 1000,
  },
);

/// 翻译: a live service choice, a reload-only timeout and endpoint, a key
/// kept with the plugin's values.
MemoryPluginEntry translatorEntry() => MemoryPluginEntry(
  ns: 'translator',
  schema: fields({
    'provider': choice(['google', 'bing', 'deepseek'], def: 'bing', zh: '翻译服务', en: 'Service', live: true),
    'apiKey': str(zh: 'API Key', en: 'API Key', role: 'secret'),
    'targetLanguage': str(def: 'zh-CN', zh: '目标语言', en: 'Target language', live: true),
    'timeoutMs': natural(def: 10000, min: 1, zh: '请求超时', en: 'Request timeout'),
    'bingEndpoint': str(def: 'https://edge.microsoft.com/translate', zh: 'Bing 地址', en: 'Bing endpoint'),
    'maxTextChars': natural(def: 4000, min: 2, zh: '单次字数上限', en: 'Characters per request'),
  }),
  base: {
    'provider': 'bing',
    'targetLanguage': 'zh-CN',
    'timeoutMs': 10000,
    'bingEndpoint': 'https://edge.microsoft.com/translate',
    'maxTextChars': 4000,
  },
);

/// 天气 (from the market): ships its own web page, three fields.
MemoryPluginEntry weatherEntry() => MemoryPluginEntry(
  ns: 'weather',
  autoGenerate: false,
  schema: fields({
    'city': str(zh: '城市', en: 'City', required: true),
    'units': choice(['metric', 'imperial'], def: 'metric', zh: '单位', en: 'Units'),
    'apiKey': str(zh: 'API Key', en: 'API Key', role: 'secret'),
  }),
  base: {'units': 'metric'},
);

/// The in-memory Host with the three plugins.
MemoryPluginConfigApi sampleConfigApi() => MemoryPluginConfigApi([voiceEntry(), translatorEntry(), weatherEntry()]);

/// The voice-input kit as an r14 Host serves it (bridge R7,
/// fixtures/bridge_catalog_r14.json): three entries to set — speech
/// recognition, local SenseVoice (an overlay fixes it: read-only), the
/// transcription API — beside the translator and the weather plugin, each
/// listed with who carries it. [r7] false: the same Host before R7, which
/// covers SenseVoice too but does not say so in its list.
MemoryPluginConfigApi voiceKitApi({bool r7 = true}) {
  const voice = '@deepseek-ai/dsh-experimental-voice-input-bundle';
  MemoryPluginEntry listed(MemoryPluginEntry entry, String owner, String bundle) => r7
      ? (entry
          ..owner = owner
          ..bundle = bundle)
      : entry;
  return MemoryPluginConfigApi([
    listed(
      MemoryPluginEntry(
        ns: 'speech-to-text',
        schema: fields({
          'defaultProvider': str(def: 'sensevoice-local', zh: '默认识别服务', en: 'Default service', live: true),
          'language': str(def: 'auto', zh: '识别语言', en: 'Recognition language', live: true),
        }),
        base: {'defaultProvider': 'sensevoice-local', 'language': 'auto'},
      ),
      'optional',
      voice,
    ),
    listed(voiceEntry()..overridden = true, 'optional', voice),
    listed(
      MemoryPluginEntry(
        ns: 'api-speech-to-text',
        schema: fields({
          'maxAudioBytes': natural(def: 4194304, min: 46, zh: '音频上限', en: 'Audio limit'),
          'maxDurationSeconds': natural(def: 120, min: 1, zh: '时长上限', en: 'Duration limit'),
        }),
        base: {'maxAudioBytes': 4194304, 'maxDurationSeconds': 120},
      ),
      'optional',
      voice,
    ),
    listed(translatorEntry(), 'optional', '@deepseek-ai/dsh-experimental-translator'),
    listed(weatherEntry(), 'installed', '@acme/dsh-weather'),
  ]);
}

/// [configBundles] with the voice-input kit's four rows and their titles as
/// the r14 Host lists them (fixtures/plugin_bundles_r14.json).
List<Object?> voiceKitBundles() => [
  for (final bundle in configBundles().cast<Map<String, Object?>>())
    if (bundle['name'] == '@deepseek-ai/dsh-experimental-voice-input-bundle')
      {
        ...bundle,
        'rows': [
          for (final (id, module, zh, en) in const [
            ('speech-to-text', 'speech-to-text', '语音识别', 'Speech recognition'),
            (
              'speech-to-text-sensevoice',
              'speech-to-text-sensevoice',
              'SenseVoice 本地识别',
              'Local SenseVoice recognition',
            ),
            ('api-speech-to-text', 'api-speech-to-text', '语音转写接口', 'Speech transcription API'),
            ('ui-voice-input', 'client-ui-voice-input', '录音输入', 'Voice recording'),
          ])
            {
              'rowId': id,
              'moduleName': '@deepseek-ai/dsh-experimental-$module',
              'entryId': 'include:$id',
              'meta': {
                'title': {'en': en, 'zh': zh},
              },
            },
        ],
      }
    else
      bundle,
];

/// A Host serving [voiceKitBundles].
FakeSettingsHost voiceKitHost() => FakeSettingsHost()..bundles = voiceKitBundles();

/// Bundles that bring them: the official voice and translator, the market
/// weather plugin, and one plugin without settings.
List<Object?> configBundles() => [
  {
    'name': '@deepseek-ai/dsh-experimental-voice-input-bundle',
    'official': true,
    'availability': 'installation',
    'version': '0.2.1-rc.4',
    'meta': {
      'title': {'zh': '语音输入', 'en': 'Voice input'},
    },
    'enabled': true,
    'installed': true,
    'optional': true,
    'rows': [
      {
        'rowId': 'speech-to-text-sensevoice',
        'moduleName': '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice',
        'meta': {
          'title': {'zh': '本机语音识别', 'en': 'On-device recognition'},
        },
      },
      {'rowId': 'ui-voice-input', 'moduleName': '@deepseek-ai/dsh-experimental-client-ui-voice-input'},
    ],
  },
  {
    'name': '@deepseek-ai/dsh-experimental-translator',
    'official': true,
    'availability': 'installation',
    'version': '0.2.1-rc.4',
    'meta': {
      'title': {'zh': '翻译', 'en': 'Translator'},
    },
    'enabled': true,
    'installed': true,
    'optional': true,
    'rows': [
      {'rowId': 'translator', 'moduleName': '@deepseek-ai/dsh-experimental-translator'},
    ],
  },
  {
    'name': '@acme/dsh-weather',
    'version': '1.2.0',
    'source': 'npm',
    'meta': {
      'title': {'zh': '天气', 'en': 'Weather'},
    },
    'enabled': true,
    'installed': true,
    'removable': true,
    'rows': [
      {'rowId': 'weather', 'moduleName': '@acme/dsh-weather'},
    ],
  },
  {
    'name': '@acme/dsh-clock',
    'version': '0.1.0',
    'source': 'npm',
    'meta': {
      'title': {'zh': '时钟', 'en': 'Clock'},
    },
    'enabled': true,
    'installed': true,
    'removable': true,
    'rows': [
      {'rowId': 'clock', 'moduleName': '@acme/dsh-clock'},
    ],
  },
];

/// What the page needs: a connected Host (bundles from [host]) and [api].
List<Override> configOverrides(MemoryPluginConfigApi api, {FakeSettingsHost? host, bool local = true}) {
  final fake = host ?? (FakeSettingsHost()..bundles = configBundles());
  return [
    ...engineOverrides(DshClient.withCarrier(fake), local: local),
    pluginConfigApiProvider.overrideWithValue(api),
  ];
}

/// A container on [api], read once so the catalog is loaded.
Future<ProviderContainer> configContainer(MemoryPluginConfigApi api) async {
  final container = ProviderContainer(overrides: configOverrides(api));
  addTearDown(container.dispose);
  final sub = container.listen(pluginConfigProvider, (_, _) {});
  addTearDown(sub.close);
  await container.read(pluginConfigProvider.future);
  return container;
}

/// A field of the voice plugin.
FieldRef voice(List<String> path) => FieldRef('speech-to-text-sensevoice', path);

/// A field of the translator.
FieldRef translator(List<String> path) => FieldRef('translator', path);

/// The page in a phone-sized app with fonts loaded (for goldens).
Future<void> pumpConfigPage(
  WidgetTester tester,
  Widget page,
  MemoryPluginConfigApi api, {
  Brightness brightness = Brightness.light,
  double height = 844,
  bool fonts = false,
  FakeSettingsHost? host,
}) => pumpPage(
  tester,
  page,
  overrides: configOverrides(api, host: host),
  brightness: brightness,
  height: height,
  fonts: fonts,
);
