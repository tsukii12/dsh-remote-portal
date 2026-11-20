// Agent 预设: 新建 / 复制 / 编辑 hand creator mode the exact bundle (a new
// conversation switched to `cordis`, one request with both files), 删除
// removes the declaring bundle; goldens (light + dark). Regenerate with
// `flutter test --update-goldens test/features/preset_editor_test.dart`.

import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/agent_presets_page.dart';
import 'package:dsh_app/ui/features/preset_editor/preset_editor_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

String _fixture(String id) => File('test/features/fixtures/preset_$id.yaml').readAsStringSync();

class _Sessions extends SessionsController {
  int creates = 0;

  @override
  Future<List<SessionSummary>> build() async => const [];

  @override
  Future<String> createForConnection(
    HostConnection conn, {
    required bool Function() isCurrent,
    bool autoApprove = true,
  }) async {
    creates++;
    return 'new-1';
  }

  @override
  Future<void> refresh() async {}
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Current extends CurrentSessionController {
  @override
  String? build() => null;
}

const _reviewBundle = {
  'name': '@local/dsh-preset-review',
  'official': false,
  'availability': 'profile',
  'enabled': true,
  'installed': true,
  'optional': false,
  'removable': true,
  'rows': [
    {'rowId': 'preset-review', 'moduleName': '@deepseek-ai/dsh-agent-preset'},
  ],
  'overrides': <Object?>[],
};

void main() {
  setUpAll(loadTestFonts);

  late FakePluginCarrier carrier;
  late DshClient client;
  late _Sessions sessions;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    sessions = _Sessions();
    carrier.handlers['agentPresets/list'] = (_) => {
      'presets': [
        {'id': 'standard', 'order': 1, 'isDefault': true},
        {'id': 'ptc', 'order': 2, 'isDefault': false},
        {'id': 'minimal', 'order': 3, 'isDefault': false},
        {'id': 'cordis', 'order': 4, 'isDefault': false},
        {'id': 'review', 'order': 10, 'isDefault': false, 'name': '代码审查', 'description': '只读审查改动'},
      ],
    };
    carrier.handlers['agentPresets/read'] = (args) {
      final id = args['agentPreset']! as String;
      return {'agentPreset': id, 'content': _fixture(id == 'review' ? 'standard' : id)};
    };
    carrier.handlers['pluginManager/listBundles'] = (_) => [_reviewBundle];
    carrier.handlers['agentPresets/select'] = (args) => args['agentPreset'];
    carrier.handlers['session/prompt'] = (_) => {'accepted': true};
  });
  tearDown(() => client.close());

  List<Override> overrides() => [
    activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
    sessionsProvider.overrideWith(() => sessions),
    currentSessionProvider.overrideWith(_Current.new),
    settingsProvider.overrideWith(_Settings.new),
    localRuntimeProvider.overrideWith(StaticRuntime.new),
    deviceTimeZoneProvider.overrideWith((ref) async => 'Asia/Shanghai'),
  ];

  Future<void> pump(WidgetTester tester, Widget page, {Brightness brightness = Brightness.light}) async {
    usePhoneView(tester);
    await tester.pumpWidget(testApp(page, brightness: brightness, overrides: overrides()));
    await pumpFrames(tester, 8);
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.4);
    await pumpFrames(tester);
    // Clear of the pinned bottom bar.
    if (tester.getCenter(finder).dy > 600) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -240));
      await tester.pumpAndSettle();
    }
  }

  String sentText() {
    final request = carrier.argsOf('session/prompt').single['request']! as Map;
    return ((request['content']! as List).single as Map)['text']! as String;
  }

  for (final description in <String?>['Saved custom preset', null]) {
    testWidgets('loading diagnostic is visible with description=$description', (tester) async {
      const broken = 'Cannot resolve @deepseek-ai/dsh-tool-subagent-control/list-agents';
      carrier.handlers['agentPresets/list'] = (_) => {
        'presets': [
          {'id': 'review', 'name': 'Broken preset', 'description': description, 'broken': broken},
        ],
      };
      await pump(tester, const AgentPresetsPage());
      await tester.tap(find.text('Broken preset'));
      await tester.pumpAndSettle();
      expect(find.text(broken), findsOneWidget);
      await tester.tap(find.text('设为新对话默认'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('settings/update'), isEmpty);
    });
  }

  testWidgets('healthy preset keeps its description', (tester) async {
    carrier.handlers['agentPresets/list'] = (_) => {
      'presets': [
        {'id': 'review', 'name': 'Healthy preset', 'description': 'Saved custom preset'},
      ],
    };
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.text('Healthy preset'));
    await tester.pumpAndSettle();
    // The list row shows the description too; look inside the sheet only.
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('Saved custom preset')),
      findsOneWidget,
    );
  });

  testWidgets('新建: creator mode gets the bundle, the chat opens', (tester) async {
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    expect(find.text('新建 Agent 预设'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextField, '比如：代码审查'), 'Code Review');
    await pumpFrames(tester);
    expect(find.widgetWithText(TextField, 'code-review'), findsOneWidget, reason: 'id follows the name');
    await tester.enterText(find.widgetWithText(TextField, '一句话说明它适合做什么'), '只读审查改动');
    await tester.enterText(
      find.widgetWithText(TextField, 'You are a coding agent powered by the {{model}} model.'),
      '你是代码审查员，只读不改。',
    );
    await reveal(tester, find.text('网页搜索与读取工具'));
    await tester.tap(find.text('网页搜索与读取工具'));
    await pumpFrames(tester);

    await tester.tap(find.text('开始创建'));
    await tester.pumpAndSettle();

    expect(sessions.creates, 1);
    expect(carrier.argsOf('agentPresets/select').single, {'agentId': 'new-1', 'agentPreset': 'cordis'});
    final text = sentText();
    expect(text, startsWith('新建 Agent 预设「Code Review」（code-review）：在工作区写下这两个文件（内容原样）'));
    expect(text, contains('"name": "@local/dsh-preset-code-review"'));
    expect(text, contains('    - id: preset-code-review\n'));
    expect(text, contains('        description: "只读审查改动"\n        order: 11\n'));
    expect(
      text,
      contains(
        '          - id: tool-web\n            name: \'@deepseek-ai/dsh-tool-web\'\n            disabled: true\n',
      ),
    );
    expect(text, contains('            prefix: "你是代码审查员，只读不改。"'));
    expect(find.byType(PresetEditorPage), findsNothing, reason: 'back to the chat');
    final container = ProviderScope.containerOf(tester.element(find.byType(AgentPresetsPage)));
    expect(container.read(currentSessionProvider), 'new-1');
  });

  testWidgets('复制: a free id and the source composition', (tester) async {
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.text('PTC 模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制为新预设'));
    await tester.pumpAndSettle();
    expect(find.text('复制 Agent 预设'), findsWidgets);
    expect(find.widgetWithText(TextField, 'PTC 模式 副本'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'ptc-copy'), findsOneWidget);
    expect(find.text('基于'), findsNothing);
    expect((carrier.argsOf('agentPresets/read').last)['agentPreset'], 'ptc');
  });

  testWidgets('标识 already taken is flagged in place', (tester) async {
    await pump(tester, const PresetEditorPage());
    await tester.enterText(find.widgetWithText(TextField, '比如：代码审查'), 'Review');
    await pumpFrames(tester);
    await tester.enterText(find.widgetWithText(TextField, 'review-2'), 'review');
    await tester.tap(find.text('开始创建'));
    await tester.pumpAndSettle();
    expect(find.text('这个标识已被使用'), findsOneWidget);
    expect(carrier.argsOf('session/prompt'), isEmpty);
  });

  testWidgets('custom preset: 编辑 replaces its bundle, 删除 removes it', (tester) async {
    carrier.handlers['pluginManager/removeBundle'] = (_) => {'changed': true, 'application': 'applied'};
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.text('代码审查'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑 Agent 预设'), findsWidgets);
    final id = tester.widget<TextField>(find.widgetWithText(TextField, 'review'));
    expect(id.enabled, isFalse);
    await tester.tap(find.text('开始更新'));
    await tester.pumpAndSettle();
    final text = sentText();
    expect(text, startsWith('更新 Agent 预设「代码审查」（review）'));
    expect(text, contains('先移除组合包 `@local/dsh-preset-review`，再用 install_bundle 安装 `dsh-preset-review` 目录'));
    expect(text, contains('        order: 10\n'));
  });

  testWidgets('删除 asks, then removes the declaring bundle', (tester) async {
    carrier.handlers['pluginManager/removeBundle'] = (_) => {'changed': true, 'application': 'applied'};
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.text('代码审查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除「代码审查」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('pluginManager/removeBundle').single, {'name': '@local/dsh-preset-review'});
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('built-in presets offer no 编辑 / 删除', (tester) async {
    await pump(tester, const AgentPresetsPage());
    await tester.tap(find.text('标准模式'));
    await tester.pumpAndSettle();
    expect(find.text('复制为新预设'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('删除'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('new preset', (tester) async {
        await pump(tester, const PresetEditorPage(), brightness: brightness);
        await tester.enterText(find.widgetWithText(TextField, '比如：代码审查'), 'Code Review');
        await tester.enterText(find.widgetWithText(TextField, '一句话说明它适合做什么'), '只读审查改动，逐条列出问题');
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preset_editor_new_$mode.png'));
      });

      testWidgets('tool switches', (tester) async {
        await pump(tester, const PresetEditorPage(), brightness: brightness);
        await reveal(tester, find.text('文件搜索工具'));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preset_editor_tools_$mode.png'));
      });

      testWidgets('custom preset sheet', (tester) async {
        await pump(tester, const AgentPresetsPage(), brightness: brightness);
        await tester.tap(find.text('代码审查'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preset_sheet_custom_$mode.png'));
      });
    });
  }
}
