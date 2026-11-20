// Goldens of the native engine settings (light + dark): the curated pages,
// the generated form of a plugin, a number sheet, a locked page, the plugin
// inventory and its detail sheet, and the hub.
//
//   flutter test --update-goldens test/engine_settings

import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/general_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/runtime_settings_pages.dart';
import 'package:dsh_app/ui/engine_settings/subagent_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/web_search_page.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void engineGolden(
  String name,
  Widget Function() page, {
  FakeSettingsHost Function()? host,
  double height = 844,
  bool local = true,
  AppSettings? settings,
  Future<void> Function(WidgetTester tester)? before,
}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      final fake = host?.call() ?? FakeSettingsHost();
      final client = DshClient.withCarrier(fake);
      await pumpPage(
        tester,
        page(),
        overrides: engineOverrides(client, local: local, settings: settings),
        brightness: brightness,
        height: height,
        fonts: true,
      );
      if (before != null) await before(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

/// The recorded Host with a few of the user's own values.
FakeSettingsHost customized() {
  final host = FakeSettingsHost()..bundles = recordedBundles();
  host.namespaces['ui-chat']!.user = {'linkOpening': 'new-tab'};
  host.namespaces['subagent']!.user = {'maxDepth': 2};
  host.namespaces['subagent-model-selection-settings']!.user = {
    'enabled': true,
    'allowedModels': [
      {'provider': 'deepseek-official', 'model': 'deepseek-v4-pro'},
      {'provider': 'gone', 'model': 'old-model'},
    ],
  };
  host.namespaces['bash-sandbox']!.user = {'timeoutMs': 90000};
  host.namespaces['plugin-market']!.user = {
    'indexes': ['https://api.dshfind.com/market/dsh-index.json'],
  };
  return host;
}

void main() {
  engineGolden('general_settings', () => const GeneralSettingsPage(), host: customized, height: 1000);

  engineGolden('subagent_settings', () => const SubagentSettingsPage(), host: customized, height: 1180);

  engineGolden('shell_settings', () => const ShellSettingsPage(), host: customized);

  engineGolden(
    'web_search_settings',
    () => const WebSearchSettingsPage(),
    host: () => FakeSettingsHost()..credentials['DEEPSEEK_API_KEY'] = 'sk-x',
    local: false,
  );

  engineGolden('plugin_settings_generated', () => const EngineSettingsPage(ns: 'cot-translation', title: '思考过程机器翻译'));

  engineGolden(
    'number_sheet',
    () => const ShellSettingsPage(),
    host: customized,
    before: (tester) async {
      await tester.tap(find.text('命令超时'));
      await settle(tester);
    },
  );

  engineGolden(
    'agent_loop_locked',
    () => const AgentLoopSettingsPage(),
    host: () => FakeSettingsHost()..namespaces['agent-loop']!.overlay = {'maxParallelToolCalls': 3},
  );

  engineGolden(
    'plugin_inventory',
    () => const PluginInventoryPage(),
    height: 1700,
    host: () => FakeSettingsHost()
      ..inventory = recordedInventory()
      ..bundles = sampleBundles(),
  );

  engineGolden(
    'plugin_inventory_sheet',
    () => const PluginInventoryPage(),
    host: () => FakeSettingsHost()
      ..inventory = recordedInventory()
      ..bundles = sampleBundles(),
    before: (tester) async {
      await tester.enterText(find.byType(TextField), '循环');
      await settle(tester);
      await tester.tap(find.text('智能体运行循环'));
      await settle(tester);
    },
  );

  engineGolden('engine_settings_hub', () => const EngineSettingsHubPage(), host: customized, height: 900);
}
