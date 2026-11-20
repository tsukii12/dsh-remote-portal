// A plugin's configuration page end to end over the in-memory Host
// interface: live fields at once, the rest held with the save bar, the
// reload's progress, a failed reload retried or put back, write-only keys,
// a plugin's own web page beside its native fields, search, 全部恢复默认,
// leaving with held edits; and where the page is reached from — the detail
// sheet (official, market) and 设置 › 引擎参数 › 插件 — with no entry for a
// plugin that has nothing to set.

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/ui/engine_settings/engine_settings_hub.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart' show seatWebOpenerProvider;
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const _status = ValueKey('plugin-config-status');
const _primary = ValueKey('plugin-config-primary');
const _secondary = ValueKey('plugin-config-secondary');

String _statusText(WidgetTester tester) => tester.widget<Text>(find.byKey(_status)).data!;

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage)));

Future<void> _open(WidgetTester tester, String ns, MemoryPluginConfigApi api) =>
    pumpConfigPage(tester, PluginConfigPage(ns: ns), api, height: 1400);

void main() {
  testWidgets('a live field takes effect at once: no bar', (tester) async {
    final api = sampleConfigApi();
    await _open(tester, 'speech-to-text-sensevoice', api);
    await tester.tap(find.text('识别语言'));
    await settle(tester);
    await tester.tap(find.text('ja').last);
    await settle(tester);
    expect(api.entries['speech-to-text-sensevoice']!.user, {'language': 'ja'});
    expect(find.byKey(_status), findsNothing);
    expect(find.text('未保存'), findsNothing);
  });

  testWidgets('a reload field waits for 保存, then reloads with progress', (tester) async {
    final api = sampleConfigApi()..gate = Completer<void>();
    await _open(tester, 'speech-to-text-sensevoice', api);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    expect(find.text('未保存'), findsOneWidget);
    expect(_statusText(tester), '1 项更改 · 保存后重新载入插件');
    expect(api.calls.where((c) => c.$1 == 'apply'), isEmpty);

    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(_statusText(tester), '正在保存…');
    expect(tester.widget<FilledButton>(find.byKey(_primary)).onPressed, isNull);
    final first = api.gate!;
    api.gate = Completer<void>();
    first.complete();
    await settle(tester);
    expect(_statusText(tester), '正在重新载入…');
    api.gate!.complete();
    await settle(tester);
    expect(_statusText(tester), '已生效');
    expect(api.entries['speech-to-text-sensevoice']!.user, {'punctuation': false});
    expect(find.text('未保存'), findsNothing);

    await tester.pump(PluginConfigController.doneFor);
    await settle(tester);
    expect(find.byKey(_status), findsNothing, reason: '已生效 stays a moment, then the bar goes');
  });

  testWidgets('a failed reload the Host undid: 重试', (tester) async {
    final api = sampleConfigApi()..failNextReload = 'model missing';
    await _open(tester, 'speech-to-text-sensevoice', api);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(_statusText(tester), '没能生效 · 已恢复原设置');
    expect(find.descendant(of: find.byKey(_primary), matching: find.text('重试')), findsOneWidget);
    expect(find.descendant(of: find.byKey(_secondary), matching: find.text('放弃')), findsOneWidget);
    expect(find.text('未保存'), findsOneWidget, reason: 'the edit is still there');
    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(_statusText(tester), '已生效');
    expect(api.entries['speech-to-text-sensevoice']!.user, {'punctuation': false});
  });

  testWidgets('a failed reload the Host could not undo: 恢复原设置', (tester) async {
    final api = sampleConfigApi()
      ..failNextReload = 'crashed'
      ..undoFails = true;
    await _open(tester, 'speech-to-text-sensevoice', api);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(_statusText(tester), '没能生效，原设置也没能恢复');
    expect(find.text('插件没有启动'), findsOneWidget);
    await tester.tap(find.byKey(_secondary));
    await settle(tester);
    expect(api.entries['speech-to-text-sensevoice']!.user, isEmpty);
    expect(api.entries['speech-to-text-sensevoice']!.failed, isFalse);
    expect(find.text('插件没有启动'), findsNothing);
  });

  testWidgets('放弃 drops held edits and puts the values back', (tester) async {
    final api = sampleConfigApi();
    await _open(tester, 'speech-to-text-sensevoice', api);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    await tester.tap(find.byKey(_secondary));
    await settle(tester);
    expect(find.byKey(_status), findsNothing);
    final shown = _container(tester).read(pluginConfigProvider).value!.settingsFor('speech-to-text-sensevoice');
    expect(shown.valueOf(voice(['punctuation'])), isTrue);
  });

  testWidgets('a key reads 已设置 or 未设置, never its value', (tester) async {
    final api = sampleConfigApi();
    api.entries['weather']!.secrets['apiKey'] = 'k-123';
    await _open(tester, 'weather', api);
    expect(find.text('已设置'), findsOneWidget);
    expect(find.textContaining('k-123'), findsNothing);
    api.entries['weather']!.secrets.clear();
    await _container(tester).read(pluginConfigProvider.notifier).refresh();
    await settle(tester);
    expect(find.text('已设置'), findsNothing);
    expect(find.text('未设置'), findsWidgets);
  });

  testWidgets('a plugin with its own web page keeps the way there, and its native fields', (tester) async {
    final api = sampleConfigApi();
    final opened = <DshWebTarget>[];
    await pumpPage(
      tester,
      const PluginConfigPage(ns: 'weather'),
      overrides: [
        ...configOverrides(api),
        seatWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target)),
      ],
    );
    expect(find.text('城市'), findsOneWidget);
    expect(find.text('单位'), findsOneWidget);
    final web = find.text('在网页版设置');
    expect(web, findsOneWidget);
    expect(tester.getTopLeft(web).dy, lessThan(tester.getTopLeft(find.text('城市')).dy), reason: 'its page comes first');
    await tester.tap(web);
    await settle(tester);
    expect(opened.single.pluginItem, ['天气', 'Weather', '@acme/dsh-weather']);
  });

  testWidgets('a Host that reads forms one at a time: the page reads its own', (tester) async {
    final api = MemoryPluginConfigApi([translatorEntry()], lazy: true)
      ..unavailable['nested'] = ('unsupported', 'nested-include')
      // A market plugin (configBundles) that is switched off.
      ..unavailable['clock'] = ('inactive', 'not-active');
    await _open(tester, 'translator', api);
    expect(api.calls, contains(('read', 'translator')));
    expect(find.text('翻译服务'), findsOneWidget);

    await _open(tester, 'nested', api);
    expect(find.text('暂不支持在这里设置'), findsOneWidget);
    expect(api.calls, isNot(contains(('read', 'nested'))), reason: 'not asked for a form it cannot give');
    await _open(tester, 'clock', api);
    expect(find.text('插件没有在运行'), findsOneWidget);
  });

  testWidgets('DSH\'s own entry, listed and configurable on the Host: not drawn, not read', (tester) async {
    final api = MemoryPluginConfigApi([
      translatorEntry(),
      MemoryPluginEntry(
        ns: 'webserver',
        schema: fields({'host': str(def: '127.0.0.1')}),
      ),
    ], lazy: true);
    await _open(tester, 'webserver', api);
    expect(find.text('暂不支持在这里设置'), findsOneWidget);
    expect(find.text('127.0.0.1'), findsNothing);
    expect(api.calls, isNot(contains(('read', 'webserver'))));
  });

  testWidgets('the plugin list can\'t be read: no form, said so, and 重试 brings it back (CR-a17797b)', (tester) async {
    final host = FakeSettingsHost()..bundles = configBundles();
    await pumpConfigPage(tester, const PluginConfigPage(ns: 'translator'), sampleConfigApi(), host: host, height: 1400);
    expect(find.text('翻译服务'), findsOneWidget);
    host.failListBundles = true;
    final c = ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage)));
    await tester.runAsync(() => c.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
    await flush(tester);
    expect(find.text('插件清单读取失败，稍后重试'), findsOneWidget);
    expect(find.text('翻译服务'), findsNothing, reason: 'the list on screen is not the Host\'s answer any more');
    host.failListBundles = false;
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(find.text('翻译服务'), findsOneWidget);
  });

  testWidgets('设置 › 引擎参数 offers to read the plugin list again when it failed', (tester) async {
    final host = FakeSettingsHost()..bundles = configBundles();
    await pumpConfigPage(tester, const EngineSettingsHubPage(), sampleConfigApi(), host: host, height: 1400);
    expect(find.text('翻译'), findsOneWidget);
    host.failListBundles = true;
    final c = ProviderScope.containerOf(tester.element(find.byType(EngineSettingsHubPage)));
    await tester.runAsync(() => c.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
    await flush(tester);
    expect(find.text('插件清单读取失败，稍后重试'), findsOneWidget);
    expect(find.text('翻译'), findsNothing);
    host.failListBundles = false;
    await tester.tap(find.text('插件清单读取失败，稍后重试'));
    await flush(tester);
    expect(find.text('翻译'), findsOneWidget);
  });

  testWidgets('a plugin without a web page has no such row', (tester) async {
    await _open(tester, 'translator', sampleConfigApi());
    expect(find.text('在网页版设置'), findsNothing);
  });

  testWidgets('search finds folded fields; nothing found says so', (tester) async {
    await _open(tester, 'speech-to-text-sensevoice', sampleConfigApi());
    expect(find.text('识别超时'), findsNothing, reason: 'folded under 高级');
    expect(find.text('高级'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'timeout');
    await settle(tester);
    expect(find.text('识别超时'), findsOneWidget);
    expect(find.text('识别语言'), findsNothing);
    expect(find.text('高级'), findsNothing);
    await tester.enterText(find.byType(TextField), 'zzz');
    await settle(tester);
    expect(find.text('没有匹配的设置'), findsOneWidget);
  });

  testWidgets('a short form has no search', (tester) async {
    await _open(tester, 'weather', sampleConfigApi());
    expect(find.byKey(const ValueKey('plugin-config-search')), findsNothing);
  });

  testWidgets('全部恢复默认 asks first', (tester) async {
    final api = sampleConfigApi();
    api.entries['translator']!.user = {'provider': 'google'};
    await _open(tester, 'translator', api);
    await tester.tap(find.text('全部恢复默认'));
    await settle(tester);
    expect(find.text('全部恢复默认？'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await settle(tester);
    expect(api.entries['translator']!.user, isEmpty);
    expect(find.text('全部恢复默认'), findsNothing);
  });

  testWidgets('leaving with held edits asks; 放弃 drops them', (tester) async {
    final api = sampleConfigApi();
    await pumpPage(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PluginConfigPage(ns: 'speech-to-text-sensevoice')),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: configOverrides(api),
    );
    await tester.tap(find.text('open'));
    await flush(tester);
    await tester.tap(find.text('自动加标点'));
    await settle(tester);
    final container = _container(tester);
    await tester.tap(find.byTooltip('返回'));
    await settle(tester);
    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('放弃').last);
    await settle(tester);
    expect(find.byType(PluginConfigPage), findsNothing);
    expect(container.read(pluginConfigProvider).value!.hasDraft('speech-to-text-sensevoice'), isFalse);
  });

  group('entries', () {
    Future<void> openSheet(WidgetTester tester, MemoryPluginConfigApi api, int index) async {
      final bundle = PluginBundle.fromJson(configBundles()[index]);
      await pumpPage(
        tester,
        Builder(
          builder: (context) => Center(
            child: TextButton(onPressed: () => showBundleSheet(context, bundle), child: const Text('open')),
          ),
        ),
        overrides: configOverrides(api),
      );
      await tester.tap(find.text('open'));
      await flush(tester);
    }

    testWidgets('an official plugin: 设置 opens its page', (tester) async {
      await openSheet(tester, sampleConfigApi(), 0);
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await flush(tester);
      expect(find.byType(PluginConfigPage), findsOneWidget);
      expect(find.text('模型精度'), findsOneWidget, reason: 'a field DSH 0.2.1 never served');
    });

    testWidgets('a market plugin: its native page, not only the web', (tester) async {
      await openSheet(tester, sampleConfigApi(), 2);
      await tester.tap(find.text('设置'));
      await flush(tester);
      expect(find.text('城市'), findsOneWidget);
    });

    testWidgets('a plugin with nothing to set: no entry', (tester) async {
      await openSheet(tester, sampleConfigApi(), 3);
      expect(find.text('时钟'), findsWidgets);
      expect(find.text('设置'), findsNothing);
    });

    testWidgets('设置 › 引擎参数 › 插件 lists every plugin with settings', (tester) async {
      final api = sampleConfigApi();
      await pumpConfigPage(tester, const EngineSettingsHubPage(), api, height: 1200);
      expect(find.text('本机语音识别'), findsOneWidget);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.text('天气'), findsOneWidget);
      await tester.tap(find.text('天气'));
      await flush(tester);
      expect(find.byType(PluginConfigPage), findsOneWidget);
      expect(find.text('城市'), findsOneWidget);
    });

    testWidgets('English: the page and its bar', (tester) async {
      AppLocale.use(AppLocale.en);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      await _open(tester, 'speech-to-text-sensevoice', sampleConfigApi());
      expect(find.text('On-device recognition'), findsWidgets);
      expect(find.text('Model precision'), findsOneWidget);
      expect(find.text('Advanced'), findsOneWidget);
      await tester.tap(find.text('Add punctuation'));
      await settle(tester);
      expect(_statusText(tester), '1 change · Saving reloads the plugin');
      expect(find.text('Unsaved'), findsOneWidget);
    });
  });
}
