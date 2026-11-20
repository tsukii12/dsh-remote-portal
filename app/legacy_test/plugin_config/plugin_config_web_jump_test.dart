// From a plugin's native configuration page to DSH Web, which edits the same
// configuration through its own page: never while a save is reloading the
// plugin (it would land on a plugin in the middle of its reload), held edits
// asked about and dropped before going (kept, a later 保存 would write them
// over what was set there), and the form's own 「在网页版编辑此项」 rows going
// the same way, to the plugin's card rather than to an entry id no card has.

import 'dart:async';

import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart' show seatWebOpenerProvider;
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const _web = ValueKey('plugin-config-web');
const _primary = ValueKey('plugin-config-primary');
const _status = ValueKey('plugin-config-status');

/// The weather plugin's card on DSH Web's Plugins page.
const _card = ['天气', 'Weather', '@acme/dsh-weather'];

/// 天气 with one more field the app can't draw (a number or a word): DSH
/// Web edits it.
MemoryPluginEntry _weatherWithWebField() => MemoryPluginEntry(
  ns: 'weather',
  autoGenerate: false,
  schema: fields({
    'city': str(zh: '城市', en: 'City', required: true),
    'units': choice(['metric', 'imperial'], def: 'metric', zh: '单位', en: 'Units'),
    'refresh': {
      'type': 'union',
      'list': [
        {'type': 'number'},
        {'type': 'const', 'value': 'auto'},
      ],
      'meta': {
        'description': {'zh': '刷新间隔', 'en': 'Refresh'},
      },
    },
  }),
  base: {'units': 'metric'},
);

Future<List<DshWebTarget>> _open(WidgetTester tester, MemoryPluginConfigApi api) async {
  final opened = <DshWebTarget>[];
  await pumpPage(
    tester,
    const PluginConfigPage(ns: 'weather'),
    height: 1400,
    overrides: [
      ...configOverrides(api),
      seatWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target)),
    ],
  );
  return opened;
}

/// A held edit: 单位 → imperial (applies on a reload).
Future<void> _holdEdit(WidgetTester tester) async {
  await tester.tap(find.text('单位'));
  await settle(tester);
  await tester.tap(find.text('imperial').last);
  await settle(tester);
  expect(find.text('未保存'), findsOneWidget);
}

PluginConfigState _state(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage))).read(pluginConfigProvider).value!;

void main() {
  testWidgets('held edits: 在网页版设置 asks first; 继续编辑 stays and nothing opens', (tester) async {
    final api = sampleConfigApi();
    final opened = await _open(tester, api);
    await _holdEdit(tester);

    await tester.tap(find.text('在网页版设置'));
    await settle(tester);
    expect(find.text('放弃修改？'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('继续编辑'));
    await settle(tester);
    expect(opened, isEmpty);
    expect(find.text('未保存'), findsOneWidget, reason: 'the edit is still there');
  });

  testWidgets('held edits: 放弃 drops them, then lands on the plugin\'s card; nothing written', (tester) async {
    final api = sampleConfigApi();
    final opened = await _open(tester, api);
    await _holdEdit(tester);

    await tester.tap(find.text('在网页版设置'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('plugin-config-web-discard')));
    await settle(tester);
    expect(opened.single.pluginItem, _card);
    expect(_state(tester).hasDraft('weather'), isFalse, reason: 'no later 保存 over what DSH Web sets');
    expect(find.text('未保存'), findsNothing);
    expect(api.calls.where((c) => c.$1 == 'apply'), isEmpty);
  });

  testWidgets('no held edits: straight there, no question', (tester) async {
    final opened = await _open(tester, sampleConfigApi());
    await tester.tap(find.text('在网页版设置'));
    await settle(tester);
    expect(find.text('放弃修改？'), findsNothing);
    expect(opened.single.pluginItem, _card);
  });

  testWidgets('while a save reloads the plugin the way to DSH Web is shut, and opens again after', (tester) async {
    final api = sampleConfigApi()..gate = Completer<void>();
    final opened = await _open(tester, api);
    await _holdEdit(tester);
    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(_status)).data, '正在保存…');
    expect(tester.widget<EngineFieldRow>(find.byKey(_web)).enabled, isFalse);
    await tester.tap(find.text('在网页版设置'), warnIfMissed: false);
    await settle(tester);
    expect(opened, isEmpty);
    expect(find.text('放弃修改？'), findsNothing);

    final first = api.gate!;
    api.gate = Completer<void>();
    first.complete();
    await settle(tester);
    expect(tester.widget<EngineFieldRow>(find.byKey(_web)).enabled, isFalse, reason: 'still reloading');
    api.gate!.complete();
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(_status)).data, '已生效');
    expect(tester.widget<EngineFieldRow>(find.byKey(_web)).enabled, isTrue);
    await tester.tap(find.text('在网页版设置'));
    await settle(tester);
    expect(find.text('放弃修改？'), findsNothing, reason: 'the save took them');
    expect(opened.single.pluginItem, _card);
  });

  testWidgets('a field only DSH Web edits goes the page\'s way: asks, then the plugin\'s card', (tester) async {
    final api = MemoryPluginConfigApi([voiceEntry(), translatorEntry(), _weatherWithWebField()]);
    final opened = await _open(tester, api);
    final row = find.text('在网页版编辑此项');
    expect(row, findsOneWidget);

    await tester.tap(row);
    await settle(tester);
    expect(opened.single.pluginItem, _card, reason: 'its entry id alone matches no card');

    await _holdEdit(tester);
    await tester.tap(row);
    await settle(tester);
    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await settle(tester);
    expect(opened, hasLength(1));
  });

  testWidgets('elsewhere, an entry id still lands on its plugin\'s card (网页模式)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(
      tester,
      Consumer(
        builder: (context, ref, _) {
          // The plugin list the launcher names cards from.
          ref.watch(installedPluginsProvider);
          return Center(
            child: TextButton(
              onPressed: () => openDshWeb(context, ref, target: const DshWebTarget(pluginItem: ['weather'])),
              child: const Text('go'),
            ),
          );
        },
      ),
      overrides: configOverrides(sampleConfigApi()),
    );
    final c = ProviderScope.containerOf(tester.element(find.text('go')));
    await tester.runAsync(() => c.read(uiModeProvider.notifier).set(UiMode.web));
    await tester.tap(find.text('go'));
    await settle(tester);
    expect(c.read(webOpenProvider)!.target.pluginItem, ['weather', ..._card]);
  });
}
