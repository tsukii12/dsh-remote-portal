// A long plugin form and the means to see how much of it draws again: an
// 80-field plugin with nested groups, live and reload fields, keys and
// lists ([bigEntry]); the widgets the framework builds per interaction
// ([BuildCounter], from debugOnRebuildDirtyWidget); and the numbers
// plugin_config_perf_test.dart reports with `--dart-define=PERF_REPORT=true`
// ([perfReportTests]: builds and debug-build frame times for opening the
// page, a tap, a keystroke, a group opened, the keyboard sliding in, the
// push from the bundle sheet, and what one page build computes).

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_app/ui/engine_settings/schema_documentation.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_entries.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_layout.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const bigNs = 'big-assistant';

/// A long plugin as a market one is written: a dozen top-level fields (a
/// live service, a key, choices, plumbing), seven groups — two of them with
/// groups of their own — about 80 fields in all.
MemoryPluginEntry bigEntry() => MemoryPluginEntry(
  ns: bigNs,
  schema: fields({
    'enabled': boolean(def: true, zh: '启用', en: 'Enabled', live: true),
    'provider': choice(
      ['openai', 'azure', 'deepseek', 'local', 'custom'],
      def: 'deepseek',
      zh: '服务',
      en: 'Service',
      live: true,
    ),
    'model': str(def: 'deepseek-chat', zh: '模型', en: 'Model', live: true),
    'apiKey': str(zh: 'API Key', en: 'API Key', role: 'secret'),
    'mode': choice(['fast', 'balanced', 'accurate'], def: 'balanced', zh: '模式', en: 'Mode'),
    'temperature': number(def: 0.7, min: 0, max: 2, zh: '温度', en: 'Temperature'),
    'streaming': boolean(def: true, zh: '流式输出', en: 'Streaming'),
    'language': choice(['auto', 'zh', 'en'], def: 'auto', zh: '语言', en: 'Language', live: true),
    'stopWords': strings(def: [], zh: '停止词', en: 'Stop words'),
    'systemPrompt': str(def: '', zh: '系统提示', en: 'System prompt'),
    'requestTimeoutMs': natural(def: 30000, min: 1, zh: '请求超时', en: 'Request timeout'),
    'maxRetries': natural(def: 3, zh: '重试次数', en: 'Retries'),
    'debugLog': boolean(def: false, zh: '调试日志', en: 'Debug log'),
    'cacheDir': str(zh: '缓存目录', en: 'Cache directory'),
    'network': fields(
      {
        'proxyUrl': str(zh: '代理', en: 'Proxy'),
        'keepAlive': boolean(def: true, zh: '保持连接', en: 'Keep alive'),
        'concurrency': natural(def: 4, min: 1, zh: '并发', en: 'Concurrency'),
        'userAgent': str(def: 'dsh', zh: 'UA', en: 'User agent'),
        'endpoint': str(def: 'https://api.example.com', zh: '地址', en: 'Endpoint'),
        'connectTimeoutMs': natural(def: 5000, min: 1, zh: '连接超时', en: 'Connect timeout'),
        'readTimeoutMs': natural(def: 60000, min: 1, zh: '读取超时', en: 'Read timeout'),
        'retryBackoffMs': natural(def: 500, min: 1, zh: '重试间隔', en: 'Retry backoff'),
      },
      zh: '网络',
      en: 'Network',
    ),
    'audio': fields(
      {
        'sampleRate': choice(['16000', '24000', '48000'], def: '16000', zh: '采样率', en: 'Sample rate'),
        'channels': natural(def: 1, min: 1, max: 2, zh: '声道', en: 'Channels'),
        'denoise': boolean(def: true, zh: '降噪', en: 'Denoise'),
        'gain': number(def: 1, min: 0, max: 4, role: 'slider', zh: '增益', en: 'Gain'),
        'vad': fields(
          {
            'enabled': boolean(def: true, zh: '语音检测', en: 'Voice detection'),
            'threshold': number(def: 0.5, min: 0, max: 1, role: 'slider', zh: '灵敏度', en: 'Sensitivity'),
            'minSpeechSeconds': number(def: 0.25, min: 0, zh: '最短语音', en: 'Shortest speech'),
            'minSilenceSeconds': number(def: 0.5, min: 0.01, zh: '停顿判定', en: 'Pause length'),
            'onsetPaddingSeconds': number(def: 0.3, min: 0, max: 1, zh: '起始留白', en: 'Lead-in'),
          },
          zh: '语音检测',
          en: 'Voice detection',
        ),
        'segments': fields(
          {
            'segmentSeconds': number(def: 30, min: 1, max: 120, zh: '分段长度', en: 'Segment length'),
            'maxPending': natural(def: 4, min: 1, zh: '排队上限', en: 'Queue limit'),
            'overlapSeconds': number(def: 0.5, min: 0, zh: '重叠', en: 'Overlap'),
            'mergeShort': boolean(def: true, zh: '合并短句', en: 'Merge short'),
          },
          zh: '分段',
          en: 'Segments',
        ),
      },
      zh: '音频',
      en: 'Audio',
    ),
    'ui': fields(
      {
        'theme': choice(['system', 'light', 'dark'], def: 'system', zh: '主题', en: 'Theme', live: true),
        'compact': boolean(def: false, zh: '紧凑', en: 'Compact', live: true),
        'fontScale': number(def: 1, min: 0.5, max: 2, zh: '字号', en: 'Font scale'),
        'showTimestamps': boolean(def: true, zh: '显示时间', en: 'Timestamps'),
        'accentColor': str(def: '#3366ff', zh: '强调色', en: 'Accent'),
        'avatarStyle': choice(['round', 'square', 'none', 'emoji'], def: 'round', zh: '头像', en: 'Avatar'),
        'notifications': boolean(def: true, zh: '通知', en: 'Notifications'),
        'sound': boolean(def: false, zh: '提示音', en: 'Sound'),
      },
      zh: '界面',
      en: 'Interface',
    ),
    'limits': fields(
      {
        'maxInputTokens': natural(def: 32000, min: 1, zh: '输入上限', en: 'Input limit'),
        'maxOutputTokens': natural(def: 4000, min: 1, zh: '输出上限', en: 'Output limit'),
        'maxAudioBytes': natural(def: 4194304, min: 46, zh: '音频上限', en: 'Audio limit'),
        'maxResponseBytes': natural(def: 131072, min: 1, zh: '结果上限', en: 'Result limit'),
        'maxLogBytes': natural(def: 65536, min: 1, zh: '日志上限', en: 'Log limit'),
        'maxHistory': natural(def: 50, min: 1, zh: '历史上限', en: 'History limit'),
        'maxAttachments': natural(def: 8, min: 0, zh: '附件上限', en: 'Attachments'),
        'minIntervalMs': natural(def: 100, min: 0, zh: '最短间隔', en: 'Shortest interval'),
      },
      zh: '限制',
      en: 'Limits',
    ),
    'storage': fields(
      {
        'dataRoot': str(zh: '数据目录', en: 'Data directory', required: true),
        'modelDirectory': str(zh: '模型目录', en: 'Model directory'),
        'tempDirectory': str(zh: '临时目录', en: 'Temp directory'),
        'historyFile': str(zh: '历史文件', en: 'History file'),
        'exportPath': str(zh: '导出位置', en: 'Export path'),
        'keepDays': natural(def: 30, min: 1, zh: '保留天数', en: 'Keep days'),
        'compress': boolean(def: true, zh: '压缩', en: 'Compress'),
      },
      zh: '存储',
      en: 'Storage',
    ),
    'experimental': fields(
      {
        'enableBeta': boolean(def: false, zh: '测试功能', en: 'Beta features'),
        'flags': fields(
          {
            for (final (key, zh) in const [
              ('fastStart', '快速启动'),
              ('prefetch', '预取'),
              ('parallelTools', '并行工具'),
              ('memory', '记忆'),
              ('vision', '视觉'),
              ('autoTitle', '自动标题'),
            ])
              key: boolean(def: false, zh: zh, en: key),
          },
          zh: '开关',
          en: 'Flags',
        ),
        'sampling': fields(
          {
            'topP': number(def: 1, min: 0, max: 1, zh: 'Top P', en: 'Top P'),
            'topK': natural(def: 40, min: 1, zh: 'Top K', en: 'Top K'),
            'presencePenalty': number(def: 0, min: -2, max: 2, zh: '存在惩罚', en: 'Presence penalty'),
            'frequencyPenalty': number(def: 0, min: -2, max: 2, zh: '频率惩罚', en: 'Frequency penalty'),
            'seed': natural(def: 0, zh: '随机种子', en: 'Seed'),
          },
          zh: '采样',
          en: 'Sampling',
        ),
      },
      zh: '实验',
      en: 'Experimental',
    ),
    'integrations': fields(
      {
        'webhookUrl': str(zh: 'Webhook', en: 'Webhook'),
        'webhookSecret': str(zh: 'Webhook 密钥', en: 'Webhook secret', role: 'secret'),
        'slackChannel': str(zh: 'Slack 频道', en: 'Slack channel'),
        'emailTo': str(zh: '邮件', en: 'Email'),
        'retryOnFailure': boolean(def: true, zh: '失败重发', en: 'Retry on failure'),
        'events': strings(def: ['done'], zh: '事件', en: 'Events'),
      },
      zh: '集成',
      en: 'Integrations',
    ),
  }),
  base: {
    'enabled': true,
    'provider': 'deepseek',
    'model': 'deepseek-chat',
    'mode': 'balanced',
    'temperature': 0.7,
    'streaming': true,
    'language': 'auto',
    'network': {'keepAlive': true, 'concurrency': 4},
    'storage': {'dataRoot': '/root/.dsh/assistant'},
  },
);

/// The bundle that brings [bigEntry] (installed from the market).
Map<String, Object?> bigBundle() => {
  'name': '@acme/dsh-big-assistant',
  'version': '2.0.0',
  'source': 'npm',
  'meta': {
    'title': {'zh': '大助手', 'en': 'Big assistant'},
  },
  'enabled': true,
  'installed': true,
  'removable': true,
  'rows': [
    {'rowId': bigNs, 'moduleName': '@acme/dsh-big-assistant'},
  ],
};

/// The widgets built, by type, between [start] and [stop] (debug builds).
class BuildCounter {
  final counts = <Type, int>{};
  var total = 0;

  /// The first frame after the action, in ms (debug build: relative only).
  var frameMs = 0.0;

  void start() {
    counts.clear();
    total = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      total++;
      counts.update(element.widget.runtimeType, (n) => n + 1, ifAbsent: () => 1);
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  int of(Type type) => counts[type] ?? 0;

  /// The field widgets: each field's tile and the view that draws it.
  int get fields => of(SchemaFieldView) + of(SecretFieldTile);

  String get summary =>
      'fields ${of(SchemaFieldView)}+${of(SecretFieldTile)} tiles ${of(SchemaFieldTile)} '
      'rows ${of(EngineFieldRow)} page ${of(PluginConfigPage)} sheet ${of(BundleSheet)} total $total '
      'frame ${frameMs.toStringAsFixed(1)} ms';
}

MemoryPluginConfigApi bigApi() => MemoryPluginConfigApi([bigEntry(), translatorEntry()]);

Future<void> openBig(WidgetTester tester, MemoryPluginConfigApi api, {double height = 844}) => pumpConfigPage(
  tester,
  const PluginConfigPage(ns: bigNs),
  api,
  height: height,
  host: FakeSettingsHost()..bundles = [...configBundles(), bigBundle()],
);

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage)));

/// What [action] and the frames after it build: [settle], or [flush] when [async] (a write in flight).
Future<BuildCounter> measure(WidgetTester tester, Future<void> Function() action, {bool async = false}) async {
  final counter = BuildCounter()..start();
  try {
    await action();
    final watch = Stopwatch()..start();
    await tester.pump();
    counter.frameMs = watch.elapsedMicroseconds / 1000;
    if (async) {
      await flush(tester);
    } else {
      await settle(tester);
    }
  } finally {
    counter.stop();
  }
  return counter;
}

/// The host that lists [bigBundle] beside the usual ones.
FakeSettingsHost bigHost() => FakeSettingsHost()..bundles = [...configBundles(), bigBundle()];

/// A button that pushes [page] as the app does (a plain page route).
Widget pushButton(Widget page) => Builder(
  builder: (context) => Center(
    child: TextButton(
      onPressed: () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page))),
      child: const Text('open'),
    ),
  ),
);

/// The keyboard sliding in over [frames] frames, 300 high at the end.
Future<void> slideKeyboardIn(WidgetTester tester, {int frames = 6}) async {
  for (var i = 1; i <= frames; i++) {
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * 2 * i / frames);
    await tester.pump(const Duration(milliseconds: 16));
  }
  addTearDown(tester.view.resetViewInsets);
}

/// The numbers: each scenario adds its lines to [report].
void perfReportTests(List<String> report) {
  testWidgets('numbers: the page', (tester) async {
    final api = bigApi();
    final open = BuildCounter()..start();
    await openBig(tester, api);
    open.stop();
    report.add('open: ${open.summary}');

    final held = await measure(tester, () => tester.tap(find.text('流式输出')));
    report.add('held toggle: ${held.summary}');
    final heldAgain = await measure(tester, () => tester.tap(find.text('流式输出')));
    report.add('held toggle (again): ${heldAgain.summary}');

    final live = await measure(tester, () => tester.tap(find.text('启用')), async: true);
    report.add('live toggle (write + refresh): ${live.summary}');

    final keyboard = await measure(tester, () => slideKeyboardIn(tester));
    report.add('keyboard slides in (6 frames): ${keyboard.summary}');
    tester.view.resetViewInsets();
    await settle(tester);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('音频'), 200, scrollable: scrollable);
    await settle(tester);
    final expand = await measure(tester, () => tester.tap(find.text('音频')));
    report.add('open group 音频: ${expand.summary}');

    await tester.scrollUntilVisible(find.text('降噪'), 200, scrollable: scrollable);
    await settle(tester);
    final inGroup = await measure(tester, () => tester.tap(find.text('降噪')));
    report.add('held toggle in the open group: ${inGroup.summary}');

    await tester.scrollUntilVisible(find.byType(TextField), -200, scrollable: scrollable);
    await settle(tester);
    for (final text in ['m', 'ma', 'max']) {
      final key = await measure(tester, () => tester.enterText(find.byType(TextField), text));
      report.add('search "$text": ${key.summary}');
    }
  });

  testWidgets('numbers: from the bundle sheet', (tester) async {
    final api = bigApi();
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showBundleSheet(context, PluginBundle.fromJson(bigBundle())),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: configOverrides(api, host: bigHost()),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
    final push = await measure(tester, () => tester.tap(find.text('设置')), async: true);
    report.add('sheet → page: ${push.summary}');
    final held = await measure(tester, () => tester.tap(find.text('流式输出')));
    report.add('sheet below, held toggle: ${held.summary}');
    final live = await measure(tester, () => tester.tap(find.text('启用')), async: true);
    report.add('sheet below, live toggle: ${live.summary}');
  });

  testWidgets('numbers: a Host that reads forms one at a time, frame by frame of the push', (tester) async {
    final api = MemoryPluginConfigApi([bigEntry(), translatorEntry()], lazy: true);
    await pumpPage(
      tester,
      pushButton(const PluginConfigPage(ns: bigNs)),
      overrides: configOverrides(api, host: bigHost()),
    );
    await tester.tap(find.text('open'));
    final frames = <String>[];
    for (var i = 0; i < 22; i++) {
      final counter = BuildCounter()..start();
      final watch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      counter.frameMs = watch.elapsedMicroseconds / 1000;
      counter.stop();
      final route = ModalRoute.of(tester.element(find.byType(PluginConfigPage, skipOffstage: false)));
      if (counter.total > 40 || i == 0) {
        frames.add('${i * 16} ms (${route?.animation?.status.name}): ${counter.summary}');
      }
    }
    report
      ..add('lazy push, frames that built more than the transition:')
      ..addAll(frames.map((f) => '  $f'));
  });

  test('numbers: what one page build computes', () async {
    final container = ProviderContainer(overrides: configOverrides(bigApi(), host: bigHost()));
    addTearDown(container.dispose);
    final sub = container.listen(pluginConfigProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(pluginConfigProvider.future);
    for (var i = 0; i < 50 && !container.read(pluginConfigProvider).value!.isPlugin(bigNs); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final state = container.read(pluginConfigProvider).value!;
    final form = state[bigNs]!;
    double time(void Function() run, {int times = 200}) {
      for (var i = 0; i < 30; i++) {
        run();
      }
      final watch = Stopwatch()..start();
      for (var i = 0; i < times; i++) {
        run();
      }
      return watch.elapsedMicroseconds / times;
    }

    final layout = pluginConfigLayout(form);
    final settings = state.settingsFor(bigNs);
    final refs = [
      for (final s in [...layout.sections, ...layout.advanced])
        for (final f in s.fields) f.ref,
    ];
    String us(double v) => '${v.toStringAsFixed(0)} us';
    report
      ..add('fields ${layout.fieldCount}, sections ${layout.sections.length}, under 高级 ${layout.advancedCount}')
      ..add('pluginConfigLayout: ${us(time(() => pluginConfigLayout(form)))}')
      ..add('pluginConfigLayout "ma": ${us(time(() => pluginConfigLayout(form, query: 'ma')))}')
      ..add('hasPluginConfig: ${us(time(() => hasPluginConfig(state, bigNs)))}')
      ..add('schemaFormGroups: ${us(time(() => schemaFormGroups(layout.sections, settings: settings)))}')
      ..add(
        'schemaDocumentation: ${us(time(() => schemaDocumentation(form.view.schema, AppLocale.current.toLanguageTag())))}',
      )
      ..add('isLocked: ${us(time(() => settings.isLocked(bigNs)))}')
      ..add(
        'every row\'s layerOf + canWrite (x${refs.length}): ${us(time(() {
          for (final r in refs) {
            settings.layerOf(r);
            settings.canWrite(r.ns);
          }
        }))}',
      );
  });
}
