// The voice-input kit as an r14 Host (bridge R7) serves it, on the screens
// that list it: 设置 › 引擎参数 › 插件, the bundle's sheet, the inventory sheet,
// the settings search and the page itself. Three entries named apart
// (「语音输入 · …」), the one an overlay covers marked 「由配置文件固定」 in every
// list and on its page; nothing marked where the Host does not say (an older
// bridge), and nothing at all while the plugin list is not the Host's
// confirmed answer (CR-a17797b). The decisions behind it run on the recorded
// Host in plugin_config_r7_test.dart.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const _fixed = '由配置文件固定';
const _fixedNote = '由配置文件固定，这里只能查看';
const _listFailed = '插件清单读取失败，稍后重试';

/// A button that opens [open] from a context under the app's providers.
Future<void> _launch(WidgetTester tester, void Function(BuildContext context) open, MemoryPluginConfigApi api) async {
  await pumpPage(
    tester,
    Consumer(
      builder: (context, ref, _) {
        // As in the app: the plugin settings were read before.
        ref.watch(pluginConfigProvider);
        return Center(
          child: TextButton(onPressed: () => open(context), child: const Text('open')),
        );
      },
    ),
    overrides: configOverrides(api, host: voiceKitHost()),
  );
  await tester.tap(find.text('open'));
  await flush(tester);
}

Finder _tile(String title) => find.widgetWithText(SettingsTile, title);

/// A 设置 row of the bundle's sheet (its load status lists the rows too).
Finder _row(String title) =>
    find.byWidgetPredicate((w) => w is ListPageRow && w.icon == AppIcons.configure && w.title == title);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('设置 › 引擎参数 › 插件: three names apart, the covered one marked', (tester) async {
    await pumpConfigPage(tester, const EngineSettingsHubPage(), voiceKitApi(), host: voiceKitHost(), height: 1200);
    for (final title in ['语音输入 · 语音识别', '语音输入 · SenseVoice 本地识别', '语音输入 · 语音转写接口', '翻译', '天气']) {
      expect(_tile(title), findsOneWidget, reason: title);
    }
    expect(find.text(_fixed), findsOneWidget);
    expect(find.descendant(of: _tile('语音输入 · SenseVoice 本地识别'), matching: find.text(_fixed)), findsOneWidget);
    await tester.tap(find.text('语音输入 · SenseVoice 本地识别'));
    await flush(tester);
    expect(find.byType(PluginConfigPage), findsOneWidget);
    expect(find.text(_fixedNote), findsOneWidget);
  });

  testWidgets('the covered page says so; a writable one of the same kit does not', (tester) async {
    await pumpConfigPage(
      tester,
      const PluginConfigPage(ns: 'speech-to-text-sensevoice'),
      voiceKitApi(),
      host: voiceKitHost(),
    );
    expect(find.text('语音输入 · SenseVoice 本地识别'), findsWidgets);
    expect(find.text(_fixedNote), findsOneWidget);
  });

  testWidgets('a writable entry of the kit: no note', (tester) async {
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'speech-to-text'), voiceKitApi(), host: voiceKitHost());
    expect(find.text('语音输入 · 语音识别'), findsWidgets);
    expect(find.text(_fixedNote), findsNothing);
  });

  testWidgets('the bundle\'s sheet: each by its own name, the covered one marked, the page named as in the hub', (
    tester,
  ) async {
    final bundle = PluginBundle.fromJson(voiceKitBundles().first);
    await _launch(tester, (context) => showBundleSheet(context, bundle), voiceKitApi());
    for (final name in ['语音识别', 'SenseVoice 本地识别', '语音转写接口']) {
      expect(_row(name), findsOneWidget, reason: name);
    }
    expect(find.descendant(of: _row('SenseVoice 本地识别'), matching: find.text(_fixed)), findsOneWidget);
    expect(find.descendant(of: _row('语音识别'), matching: find.text(_fixed)), findsNothing);
    await tester.tap(_row('SenseVoice 本地识别'));
    await flush(tester);
    expect(find.byType(PluginConfigPage), findsOneWidget);
    expect(find.text('语音输入 · SenseVoice 本地识别'), findsWidgets);
    expect(find.text(_fixedNote), findsOneWidget);
  });

  testWidgets('the settings search finds them by those names, in either language', (tester) async {
    await _launch(
      tester,
      (context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsSearchPage())),
      voiceKitApi(),
    );
    await tester.enterText(find.byType(TextField), 'SenseVoice');
    await flush(tester);
    expect(find.text('语音输入 · SenseVoice 本地识别'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'transcription api');
    await flush(tester);
    expect(find.text('语音输入 · 语音转写接口'), findsOneWidget, reason: 'the English name finds the Chinese row');
  });

  testWidgets('English', (tester) async {
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    await pumpConfigPage(tester, const EngineSettingsHubPage(), voiceKitApi(), host: voiceKitHost(), height: 1200);
    expect(_tile('Voice input · Local SenseVoice recognition'), findsOneWidget);
    expect(_tile('Voice input · Speech recognition'), findsOneWidget);
    expect(find.text('Set by configuration file'), findsOneWidget);
  });

  testWidgets('the plugin list failed: no entry and no mark in the hub, the failure and 重试 instead', (tester) async {
    final host = voiceKitHost();
    await pumpConfigPage(tester, const EngineSettingsHubPage(), voiceKitApi(), host: host, height: 1200);
    expect(find.text(_fixed), findsOneWidget);
    host.failListBundles = true;
    final c = ProviderScope.containerOf(tester.element(find.byType(EngineSettingsHubPage)));
    await tester.runAsync(() => c.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
    await flush(tester);
    expect(find.text(_listFailed), findsOneWidget);
    expect(_tile('语音输入 · SenseVoice 本地识别'), findsNothing);
    expect(find.text(_fixed), findsNothing);
    host.failListBundles = false;
    await tester.tap(find.text(_listFailed));
    await flush(tester);
    expect(find.descendant(of: _tile('语音输入 · SenseVoice 本地识别'), matching: find.text(_fixed)), findsOneWidget);
  });

  testWidgets('the plugin list failed on the covered page: the failure replaces the form and its note', (tester) async {
    final host = voiceKitHost();
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'speech-to-text-sensevoice'), voiceKitApi(), host: host);
    expect(find.text(_fixedNote), findsOneWidget);
    host.failListBundles = true;
    final c = ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage)));
    await tester.runAsync(() => c.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
    await flush(tester);
    expect(find.text(_listFailed), findsOneWidget);
    expect(find.text(_fixedNote), findsNothing);
    host.failListBundles = false;
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(find.text(_fixedNote), findsOneWidget);
  });

  testWidgets('the same kit before R7: each row by its own title, no mark (as before)', (tester) async {
    await pumpConfigPage(
      tester,
      const EngineSettingsHubPage(),
      voiceKitApi(r7: false),
      host: voiceKitHost(),
      height: 1200,
    );
    for (final title in ['语音识别', 'SenseVoice 本地识别', '语音转写接口', '翻译', '天气']) {
      expect(_tile(title), findsOneWidget, reason: title);
    }
    expect(find.textContaining('语音输入 ·'), findsNothing);
    expect(find.text(_fixed), findsNothing);
    expect(find.text('只读'), findsNothing);
    await tester.tap(find.text('SenseVoice 本地识别'));
    await flush(tester);
    expect(find.byType(PluginConfigPage), findsOneWidget);
    expect(find.text(_fixedNote), findsNothing, reason: 'the list did not say; the form is read-only as before');
  });
}
