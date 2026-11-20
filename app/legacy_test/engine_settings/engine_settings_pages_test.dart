// Flows of the native engine settings pages against the fake Host: what is
// written for each control, inline errors, locks, the secret sheet, the
// subagent models, the web-search switch, the plugin detail's 设置 row and
// the plugin inventory.

import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/general_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/ui/engine_settings/subagent_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/web_search_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late FakeSettingsHost host;

  Future<void> open(
    WidgetTester tester,
    Widget page, {
    FakeSettingsHost? fake,
    bool local = true,
    AppSettings? settings,
  }) async {
    host = fake ?? FakeSettingsHost();
    await pumpPage(
      tester,
      page,
      overrides: engineOverrides(DshClient.withCarrier(host), local: local, settings: settings),
      height: 1100,
    );
  }

  List<Object?> lastOps() => host.mutates().last['ops']! as List<Object?>;

  testWidgets('a switch and a capsule write at once; picking the inherited value clears it', (tester) async {
    await open(tester, const GeneralSettingsPage());
    await tester.tap(find.text('显示代码工作视图'));
    await flush(tester);
    expect(host.mutates().last['ns'], 'ui-settings');
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['enabled'],
        'value': false,
      },
    ]);
    expect(find.text('已修改'), findsOneWidget);

    await tester.tap(find.text('默认浏览器'));
    await flush(tester);
    expect(host.mutates().last['ns'], 'ui-chat');
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['linkOpening'],
        'value': 'new-tab',
      },
    ]);
    await tester.tap(find.text('应用内侧栏'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['linkOpening'],
      },
    ]);
    expect(host.namespaces['ui-chat']!.user, isEmpty);
  });

  testWidgets('a long choice opens a picker; legacy values read as their choice', (tester) async {
    final fake = FakeSettingsHost();
    fake.namespaces['ui-chat']!.user = {'transcriptView': 'expanded'};
    await open(tester, const GeneralSettingsPage(), fake: fake);
    expect(find.text('详细'), findsWidgets);
    await tester.tap(find.text('工作步骤展示'));
    await settle(tester);
    expect(find.text('完全展开'), findsOneWidget);
    await tester.tap(find.text('简洁').last);
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['transcriptView'],
        'value': 'compact',
      },
    ]);
  });

  testWidgets('the number sheet steps, checks bounds, saves and restores', (tester) async {
    await open(
      tester,
      const WebSearchSettingsPage(),
      fake: FakeSettingsHost()
        ..namespaces['web']!.user = {'searchProvider': 'deepseek-search-api', 'fetchProvider': 'deepseek-fetch-api'},
    );
    expect(find.text('每次搜索结果数'), findsOneWidget);
    expect(find.text('10 条'), findsOneWidget);
    await tester.tap(find.text('每次搜索结果数'));
    await settle(tester);
    expect(find.text('1–50 条 · 默认 10 条'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('step-up')));
    await tester.tap(find.byKey(const ValueKey('step-up')));
    await settle(tester);
    expect(find.text('12'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('number-input')), '80');
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(find.text('请填 1–50 之间的数'), findsOneWidget, reason: 'checked before anything is sent');
    expect(host.mutates(), isEmpty);
    await tester.enterText(find.byKey(const ValueKey('number-input')), '20');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(host.mutates().last['ns'], 'web-deepseek-api');
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['count'],
        'value': 20,
      },
    ]);
    expect(find.text('20 条'), findsOneWidget);

    await tester.tap(find.text('每次搜索结果数'));
    await settle(tester);
    await tester.tap(find.text('恢复默认'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['count'],
      },
    ]);
    expect(find.text('10 条'), findsOneWidget);
  });

  testWidgets('milliseconds are typed in seconds', (tester) async {
    await open(tester, const ShellSettingsPage());
    expect(find.text('1 分钟'), findsOneWidget);
    await tester.tap(find.text('命令超时'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('number-input')), '1.5');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['timeoutMs'],
        'value': 1500,
      },
    ]);
    expect(find.text('1.5 秒'), findsOneWidget);
  });

  testWidgets('a refusal from the engine shows under the row and the value goes back', (tester) async {
    final fake = FakeSettingsHost();
    // The engine checks something the form does not know about.
    fake.beforeMutate = (ns) => throw const DshRemoteException(
      'settings/rejected',
      r'invalid config:\n  - $.maxParallelToolCalls expected number <= 4 but got 6 (at maxParallelToolCalls)',
    );
    await open(tester, const AgentLoopSettingsPage(), fake: fake);
    await tester.tap(find.text('每步并行工具调用上限'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('number-input')), '6');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(find.text('不能大于 4'), findsOneWidget);
    expect(find.text('10 个'), findsOneWidget);
  });

  testWidgets('a home patch locks the page: calm hint, nothing opens', (tester) async {
    final fake = FakeSettingsHost()..namespaces['agent-loop']!.overlay = {'maxParallelToolCalls': 3};
    await open(tester, const AgentLoopSettingsPage(), fake: fake);
    expect(find.text('由配置文件固定'), findsOneWidget);
    expect(find.text('3 个'), findsOneWidget);
    await tester.tap(find.text('每步并行工具调用上限'));
    await settle(tester);
    expect(find.text('完成'), findsNothing);
  });

  testWidgets('text: empty restores the default, the pattern is checked first', (tester) async {
    final fake = FakeSettingsHost();
    await open(tester, const EngineSettingsPage(ns: 'cot-translation'), fake: fake);
    expect(find.text('思考过程翻译'), findsWidgets);
    await tester.tap(find.text('目标语言'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('text-input')), '中文');
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(find.text('填 auto 或语言代码，如 zh、en、ja'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('text-input')), 'ja');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['targetLanguage'],
        'value': 'ja',
      },
    ]);
    await tester.tap(find.text('目标语言'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('text-input')), '');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['targetLanguage'],
      },
    ]);

    await tester.tap(find.text('翻译服务'));
    await settle(tester);
    await tester.tap(find.text('Google'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['provider'],
        'value': 'google',
      },
    ]);
  });

  testWidgets('a list editor adds and removes items, each written at once', (tester) async {
    await open(tester, const EngineSettingsPage(ns: 'plugin-market'));
    expect(find.text('索引源'), findsOneWidget);
    expect(find.text('无'), findsOneWidget);
    await tester.tap(find.text('索引源'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('list-input')), 'ftp://nope');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('以 http:// 或 https:// 开头的地址'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('list-input')), 'https://a.example/index.json');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['indexes'],
        'value': ['https://a.example/index.json'],
      },
    ]);
    expect(find.text('https://a.example/index.json'), findsOneWidget);
    await tester.tap(find.byTooltip('移除 https://a.example/index.json'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['indexes'],
      },
    ]);
  });

  testWidgets('a secret goes to its credential; the local DeepSeek key opens the app page', (tester) async {
    final fake = FakeSettingsHost();
    fake.namespaces['web-search-deepseek']!.base = {
      ...fake.namespaces['web-search-deepseek']!.base,
      'apiKeyEnv': 'SEARCH_KEY',
    };
    await open(tester, const WebSearchSettingsPage(), fake: fake);
    expect(find.text('未配置'), findsOneWidget);
    await tester.tap(find.text('API Key'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('secret-input')), 'sk-search-1');
    await tester.pump();
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(host.credentials, {'SEARCH_KEY': 'sk-search-1'});
    expect(find.text('已配置'), findsOneWidget);
    expect(find.text('完成'), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('on this phone the shared DeepSeek key is the app\'s own', (tester) async {
    await open(
      tester,
      const WebSearchSettingsPage(),
      settings: const AppSettings(loaded: true, apiKey: 'sk-0123456789abcdef'),
    );
    expect(find.text('与模型共用'), findsOneWidget);
  });

  testWidgets('the web-search switch writes both providers, clearing the composed ones', (tester) async {
    await open(tester, const WebSearchSettingsPage(), local: false);
    expect(find.text('DeepSeek 搜索'), findsOneWidget);
    await tester.tap(find.text('新版搜索 API'));
    await flush(tester);
    expect(host.mutates().last['ns'], 'web');
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['searchProvider'],
        'value': 'deepseek-search-api',
      },
      {
        'op': 'set',
        'path': ['fetchProvider'],
        'value': 'deepseek-fetch-api',
      },
    ]);
    expect(find.text('DeepSeek 搜索'), findsOneWidget);
    expect(find.text('每次搜索结果数'), findsOneWidget);
    await tester.tap(find.text('新版搜索 API'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['searchProvider'],
      },
      {
        'op': 'unset',
        'path': ['fetchProvider'],
      },
    ]);
  });

  testWidgets('subagent models: on needs a first model, the last one stays', (tester) async {
    await open(tester, const SubagentSettingsPage());
    expect(find.text('DeepSeek-V4-Pro'), findsNothing);
    await tester.tap(find.text('允许 AI 给子代理选模型'));
    await flush(tester);
    expect(host.mutates(), isEmpty, reason: 'nothing to allow yet');
    expect(find.text('选一个模型后生效'), findsOneWidget);
    await tester.tap(find.text('DeepSeek-V4-Pro'));
    await flush(tester);
    expect(host.mutates().single['ns'], 'subagent-model-selection-settings');
    expect(lastOps(), [
      {
        'op': 'set',
        'path': ['enabled'],
        'value': true,
      },
      {
        'op': 'set',
        'path': ['allowedModels'],
        'value': [
          {'provider': 'deepseek-official', 'model': 'deepseek-v4-pro'},
        ],
      },
    ]);
    await tester.tap(find.text('Qwen3 Coder'));
    await flush(tester);
    expect((lastOps().single as Map)['value'], hasLength(2));
    await tester.tap(find.text('Qwen3 Coder'));
    await flush(tester);
    await tester.tap(find.text('DeepSeek-V4-Pro'));
    await flush(tester);
    expect(find.text('至少保留一个模型'), findsOneWidget);
    expect(host.mutates(), hasLength(3));
    await tester.tap(find.text('允许 AI 给子代理选模型'));
    await flush(tester);
    expect(lastOps(), [
      {
        'op': 'unset',
        'path': ['enabled'],
      },
    ]);
    expect(find.text('DeepSeek-V4-Pro'), findsNothing);
  });

  testWidgets('a namespace the host does not serve says so', (tester) async {
    final fake = FakeSettingsHost()..namespaces.remove('agent-loop');
    await open(tester, const AgentLoopSettingsPage(), fake: fake);
    expect(find.text('这台主机没有这项设置'), findsOneWidget);
  });

  testWidgets('a plugin with settings gets a 设置 row in its detail sheet', (tester) async {
    final fake = FakeSettingsHost()..bundles = sampleBundles();
    final bundle = PluginBundle.fromJson(sampleBundles()[2]);
    await open(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => showBundleSheet(context, bundle), child: const Text('open')),
        ),
      ),
      fake: fake,
    );
    await tester.tap(find.text('open'));
    await flush(tester);
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await flush(tester);
    expect(find.text('翻译服务'), findsOneWidget);
    expect(find.text('思考过程机器翻译'), findsWidgets);
    expect(bundleSettingsRows(bundle, null), isEmpty);
  });

  testWidgets('the inventory groups, searches, shows presets and details', (tester) async {
    final fake = FakeSettingsHost()
      ..inventory = recordedInventory()
      ..bundles = sampleBundles();
    await open(tester, const PluginInventoryPage(), fake: fake);
    expect(find.text('17 个组件 · 13 个已启用'), findsOneWidget);
    expect(find.text('DSH 内置 · 0.2.1-rc.2'), findsOneWidget);
    expect(find.text('已启用'), findsNothing);
    expect(find.byType(AnimatedStatusDot), findsWidgets);
    expect(find.text('未启用'), findsNothing);
    await tester.enterText(find.byType(TextField), 'bash');
    await settle(tester);
    expect(find.text('Bash 沙箱执行'), findsOneWidget);
    expect(find.text('插件管理服务'), findsNothing);
    expect(find.text('@deepseek-ai/dsh-bash-sandbox'), findsNothing, reason: 'a Chinese one-liner instead');
    await tester.enterText(find.byType(TextField), '');
    await settle(tester);
    // No English on the page: components without Chinese copy fold into
    // 「系统组件」 and read by package id.
    expect(find.textContaining('Method-level'), findsNothing);
    await tester.scrollUntilVisible(find.text('系统组件'), 300, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    expect(find.text('系统组件'), findsOneWidget);
    expect(find.text('@deepseek-ai/dsh-api-remote-access'), findsNothing);
    await tester.tap(find.text('系统组件'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('api-remote-access'), 300, scrollable: find.byType(Scrollable).first);
    expect(
      find.text('@deepseek-ai/dsh-api-remote-access'),
      findsNothing,
      reason: 'descriptionless rows are single-line',
    );
    expect(find.text('api-remote-access'), findsOneWidget);
    expect(find.textContaining('Method-level'), findsNothing);
    await tester.scrollUntilVisible(find.byType(TextField), -300, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(TextField), 'zzzz');
    await settle(tester);
    expect(find.text('没有匹配的插件'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await settle(tester);
    await tester.tap(find.text('Agent 预设'));
    await settle(tester);
    expect(find.textContaining('（默认）'), findsWidgets);
    expect(find.text('条件启用'), findsNothing);
    await tester.tap(find.text('全局插件'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '运行循环');
    await settle(tester);
    await tester.tap(find.text('智能体运行循环'));
    await flush(tester);
    expect(find.text('@deepseek-ai/dsh-agent-loop'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await flush(tester);
    expect(find.text('每步并行工具调用上限'), findsOneWidget);
  });

  for (final local in [false, true]) {
    testWidgets('hub only identifies remote hosts: $local', (tester) async {
      await open(tester, const EngineSettingsHubPage(), local: local);
      expect(find.text('本机'), findsNothing);
      expect(find.text('Messages'), findsNothing);
      expect(find.text('电脑 · SSH'), local ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('the hub opens each page and lists plugin forms', (tester) async {
    await open(tester, const EngineSettingsHubPage(), fake: FakeSettingsHost()..bundles = recordedBundles());
    expect(find.text('1 层'), findsOneWidget);
    expect(find.text('10 个'), findsOneWidget);
    expect(find.text('插件市场索引'), findsOneWidget);
    expect(find.text('思考过程翻译'), findsWidgets);
    expect(find.text('网页版外观'), findsNothing);
    await tester.tap(find.text('命令执行'));
    await flush(tester);
    expect(find.text('输出上限'), findsOneWidget);
  });

  testWidgets('not connected', (tester) async {
    await pumpPage(tester, const GeneralSettingsPage(), overrides: engineOverrides(null));
    expect(find.text('没能连上引擎'), findsOneWidget);
  });
}
