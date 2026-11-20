// Hosts whose plugin-config list does not say who carries an entry — 0.9.9's
// runtime r12 (no dsh-go plugin-config routes: DSH's own settings/describe)
// and a bridge before R7 — see exactly what they saw before the R7 changes:
// the same entries, the same names (a row's own title), no read-only mark,
// the same page titles and search results. This file only uses what the app
// had before R7, so it runs unchanged against that code too.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_entries.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart';
import 'support.dart';

/// The voice-input kit before R7: three entries with settings (SenseVoice
/// covered by an overlay, which such a Host only says once it is read),
/// the translator and the weather plugin.
MemoryPluginConfigApi _kit() => MemoryPluginConfigApi([
  MemoryPluginEntry(
    ns: 'speech-to-text',
    schema: fields({'language': str(def: 'auto', zh: '识别语言', en: 'Recognition language', live: true)}),
    base: {'language': 'auto'},
  ),
  voiceEntry(),
  MemoryPluginEntry(
    ns: 'api-speech-to-text',
    schema: fields({'maxDurationSeconds': natural(def: 120, min: 1, zh: '时长上限', en: 'Duration limit')}),
    base: {'maxDurationSeconds': 120},
  ),
  translatorEntry(),
  weatherEntry(),
], writable: true);

/// [configBundles] with the kit's rows and titles as the Host lists them.
List<Object?> _kitBundles() => [
  for (final bundle in configBundles().cast<Map<String, Object?>>())
    if (bundle['name'] == '@deepseek-ai/dsh-experimental-voice-input-bundle')
      {
        ...bundle,
        'rows': [
          for (final (id, zh, en) in const [
            ('speech-to-text', '语音识别', 'Speech recognition'),
            ('speech-to-text-sensevoice', 'SenseVoice 本地识别', 'Local SenseVoice recognition'),
            ('api-speech-to-text', '语音转写接口', 'Speech transcription API'),
          ])
            {
              'rowId': id,
              'moduleName': '@deepseek-ai/dsh-experimental-$id',
              'meta': {
                'title': {'en': en, 'zh': zh},
              },
            },
          {'rowId': 'ui-voice-input', 'moduleName': '@deepseek-ai/dsh-experimental-client-ui-voice-input'},
        ],
      }
    else
      bundle,
];

FakeSettingsHost _kitHost() => FakeSettingsHost()..bundles = _kitBundles();

/// The titles of 设置 › 引擎参数's plugin rows, in order.
List<String> _hubPlugins(WidgetTester tester) => [
  for (final tile in tester.widgetList<SettingsTile>(find.byType(SettingsTile)))
    if (tile.icon == AppIcons.plugin) tile.title ?? tile.spot!.title(lookupL10n(AppLocale.zhCN)),
];

/// The 设置 rows of a bundle's sheet.
List<String> _sheetRows(WidgetTester tester) => [
  for (final row in tester.widgetList<ListPageRow>(find.byType(ListPageRow)))
    if (row.icon == AppIcons.configure) row.title!,
];

/// A bundle sheet's 设置 row titled [title] (its load status lists rows too).
Finder _row(String title) =>
    find.byWidgetPredicate((w) => w is ListPageRow && w.icon == AppIcons.configure && w.title == title);

/// A settings search result titled [title].
Finder _result(String title) => find.byWidgetPredicate((w) => w is ListPageRow && w.title == title);

Future<void> _openSheet(WidgetTester tester, PluginBundle bundle, List<Override> overrides) async {
  await pumpPage(
    tester,
    Consumer(
      builder: (context, ref, _) {
        ref.watch(pluginConfigProvider);
        return Center(
          child: TextButton(onPressed: () => showBundleSheet(context, bundle), child: const Text('open')),
        );
      },
    ),
    overrides: overrides,
  );
  await tester.tap(find.text('open'));
  await flush(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('runtime r12: no plugin-config routes (DSH\'s own settings)', () {
    FakeSettingsHost host() => FakeSettingsHost()..bundles = recordedBundles();

    testWidgets('设置 › 引擎参数 › 插件: the same rows, named as before, no mark', (tester) async {
      await pumpPage(
        tester,
        const EngineSettingsHubPage(),
        overrides: engineOverrides(DshClient.withCarrier(host())),
        height: 1100,
      );
      expect(_hubPlugins(tester), ['思考过程翻译', '插件市场索引']);
      expect(find.text('由配置文件固定'), findsNothing);
      expect(find.text('只读'), findsNothing);
      await tester.tap(find.text('插件市场索引'));
      await flush(tester);
      expect(find.byType(PluginConfigPage), findsOneWidget);
      expect(find.text('插件市场索引'), findsWidgets);
    });

    testWidgets('the bundle\'s sheet: 设置, the page under the bundle\'s name', (tester) async {
      final fake = host();
      final bundle = PluginBundle.fromJson(fake.bundles.last);
      await _openSheet(tester, bundle, engineOverrides(DshClient.withCarrier(fake)));
      expect(_sheetRows(tester), ['设置']);
      await tester.tap(find.text('设置'));
      await flush(tester);
      expect(find.text('@deepseek-ai/dsh-experimental-plugin-market-bundle'), findsWidgets);
    });
  });

  group('a bridge before R7', () {
    testWidgets('设置 › 引擎参数 › 插件: each row by its own title, the covered one unmarked', (tester) async {
      await pumpConfigPage(tester, const EngineSettingsHubPage(), _kit(), host: _kitHost(), height: 1200);
      expect(_hubPlugins(tester), ['语音识别', 'SenseVoice 本地识别', '语音转写接口', '翻译', '天气']);
      expect(find.text('由配置文件固定'), findsNothing);
      expect(find.text('只读'), findsNothing);
      await tester.tap(find.text('SenseVoice 本地识别'));
      await flush(tester);
      expect(find.byType(PluginConfigPage), findsOneWidget);
      expect(find.text('SenseVoice 本地识别'), findsWidgets);
      expect(find.text('由配置文件固定，这里只能查看'), findsNothing);
    });

    testWidgets('the kit\'s sheet: each row by its own title, the page under it', (tester) async {
      await _openSheet(tester, PluginBundle.fromJson(_kitBundles().first), configOverrides(_kit(), host: _kitHost()));
      expect(_sheetRows(tester), ['语音识别', 'SenseVoice 本地识别', '语音转写接口']);
      expect(find.text('由配置文件固定'), findsNothing);
      await tester.tap(_row('语音转写接口'));
      await flush(tester);
      expect(find.byType(PluginConfigPage), findsOneWidget);
      expect(find.text('语音转写接口'), findsWidgets);
    });

    testWidgets('a page opened on its own: the row\'s title', (tester) async {
      await pumpConfigPage(tester, const PluginConfigPage(ns: 'speech-to-text-sensevoice'), _kit(), host: _kitHost());
      expect(find.text('SenseVoice 本地识别'), findsWidgets);
      expect(find.text('语音输入 · SenseVoice 本地识别'), findsNothing);
      // The one-entry sample kit: its row's title too.
      await pumpConfigPage(tester, const PluginConfigPage(ns: 'translator'), sampleConfigApi());
      expect(find.text('翻译'), findsWidgets);
    });

    testWidgets('the settings search: the same names, in the app\'s language only', (tester) async {
      await _openSearch(tester);
      await tester.enterText(find.byType(TextField), 'SenseVoice');
      await flush(tester);
      expect(_result('SenseVoice 本地识别'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '语音转写接口');
      await flush(tester);
      expect(_result('语音转写接口'), findsOneWidget);
    });

    test('the recorded r13 Host: the same entries and names', () {
      Object? fixture(String name) => jsonDecode(File('test/plugin_config/fixtures/$name').readAsStringSync());
      final bundles = [for (final b in fixture('plugin_bundles_r13.json')! as List) PluginBundle.fromJson(b)];
      final listed = [
        for (final e in (fixture('bridge_catalog_r13.json')! as Map)['entries'] as List)
          ?PluginConfigEntrySummary.fromJson(e),
      ];
      final state = PluginConfigState(
        forms: const {},
        lazy: true,
        complete: true,
        entries: {
          for (final e in listed)
            e.entryId: PluginConfigEntry(
              e.entryId,
              package: e.package,
              label: e.label,
              state: e.state,
              configurable: e.configurable,
              reason: e.reason,
            ),
        },
        scope: PluginConfigScope.of(bundles),
      );
      final shown = pluginConfigEntries(state);
      expect(shown, ['speech-to-text', 'speech-to-text-sensevoice', 'api-speech-to-text', 'local-notes']);
      expect(
        [for (final ns in shown) pluginConfigTitle(ns, bundles, state: state)],
        ['语音识别', 'SenseVoice 本地识别', '语音转写接口', 'dsh-go-fixture-local-notes'],
      );
    });
  });
}

/// Settings search, opened once the plugin settings were read (as from the
/// hub).
Future<void> _openSearch(WidgetTester tester) async {
  await pumpPage(
    tester,
    Consumer(
      builder: (context, ref, _) {
        ref.watch(pluginConfigProvider);
        return Center(
          child: TextButton(
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsSearchPage())),
            child: const Text('open'),
          ),
        );
      },
    ),
    overrides: configOverrides(_kit(), host: _kitHost()),
  );
  await tester.tap(find.text('open'));
  await flush(tester);
}
