// Goldens of a plugin's configuration page (light + dark): a long official
// plugin (search, groups, 「高级」 folded, then open, then searched), held
// edits with the save bar, the reload in progress, a failed reload the Host
// undid, and a market plugin that ships its own web page. Then the
// voice-input kit as an r14 Host (bridge R7) serves it, where it is listed —
// 设置 › 引擎参数 › 插件 and the kit's sheet — and the covered entry's page:
// three names apart, the covered one 「由配置文件固定」.
//
//   flutter test --update-goldens test/plugin_config/plugin_config_golden_test.dart

import 'dart:async';

import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'support.dart';

PluginConfigController controllerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage))).read(pluginConfigProvider.notifier);

void configGolden(
  String name,
  Widget Function() page, {
  MemoryPluginConfigApi Function()? api,
  FakeSettingsHost Function()? host,
  double height = 844,
  Future<void> Function(WidgetTester tester, MemoryPluginConfigApi api)? before,
}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      final memory = api?.call() ?? sampleConfigApi();
      await pumpConfigPage(
        tester,
        page(),
        memory,
        brightness: brightness,
        height: height,
        fonts: true,
        host: host?.call(),
      );
      if (before != null) await before(tester, memory);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

void main() {
  configGolden('plugin_config_voice', () => const PluginConfigPage(ns: 'speech-to-text-sensevoice'), height: 960);

  configGolden(
    'plugin_config_advanced',
    () => const PluginConfigPage(ns: 'speech-to-text-sensevoice'),
    height: 1640,
    before: (tester, api) async {
      await tester.tap(find.text('高级'));
      await settle(tester);
    },
  );

  configGolden(
    'plugin_config_search',
    () => const PluginConfigPage(ns: 'speech-to-text-sensevoice'),
    before: (tester, api) async {
      await tester.enterText(find.byType(TextField), '超时');
      await settle(tester);
    },
  );

  configGolden(
    'plugin_config_staged',
    () => const PluginConfigPage(ns: 'translator'),
    before: (tester, api) async {
      final controller = controllerOf(tester);
      await controller.set(translator(['timeoutMs']), 20000);
      await controller.setSecret(translator(['apiKey']), 'sk-held');
      await settle(tester);
    },
  );

  configGolden(
    'plugin_config_reloading',
    () => const PluginConfigPage(ns: 'translator'),
    before: (tester, api) async {
      api.gate = Completer<void>();
      final controller = controllerOf(tester);
      await controller.set(translator(['timeoutMs']), 20000);
      unawaited(controller.save('translator'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      api.gate!.complete();
      api.gate = Completer<void>();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
    },
  );

  configGolden(
    'plugin_config_failed',
    () => const PluginConfigPage(ns: 'translator'),
    api: () => sampleConfigApi()..failNextReload = 'endpoint unreachable',
    before: (tester, api) async {
      final controller = controllerOf(tester);
      await controller.set(translator(['timeoutMs']), 20000);
      await tester.runAsync(() => controller.save('translator'));
      await flush(tester);
    },
  );

  configGolden('plugin_config_web', () => const PluginConfigPage(ns: 'weather'), height: 700);

  configGolden(
    'plugin_config_hub_r7',
    () => const EngineSettingsHubPage(),
    api: voiceKitApi,
    host: voiceKitHost,
    height: 900,
  );

  configGolden(
    'plugin_config_fixed',
    () => const PluginConfigPage(ns: 'speech-to-text-sensevoice'),
    api: voiceKitApi,
    host: voiceKitHost,
    height: 960,
  );

  configGolden(
    'plugin_config_bundle_sheet',
    () => Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showBundleSheet(context, PluginBundle.fromJson(voiceKitBundles().first)),
          child: const Text('open'),
        ),
      ),
    ),
    api: voiceKitApi,
    host: voiceKitHost,
    before: (tester, api) async {
      await tester.tap(find.text('open'));
      await flush(tester);
    },
  );
}
