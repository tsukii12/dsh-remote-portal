// A long plugin form draws only what changed: an edit draws its own row
// again (not the page, not the other rows), the keyboard sliding in draws
// neither, a group opened builds only its rows, a form read while the page
// slides in waits until it is in; the layout and the documentation are
// worked out once per schema, and a row knows when its field changed
// (SchemaFieldWatch). Measured on the 80-field plugin of perf_fixture.dart;
// `flutter test --dart-define=PERF_REPORT=true test/plugin_config/plugin_config_perf_test.dart`
// prints the numbers as well.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/engine_settings/schema_documentation.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_app/ui/features/feature_widgets.dart' show FeatureLoading;
import 'package:dsh_app/ui/plugins/config/plugin_config_layout.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart';
import 'perf_fixture.dart';
import 'support.dart';

const _report = bool.fromEnvironment('PERF_REPORT');

FieldRef _big(List<String> path) => FieldRef(bigNs, path);

Future<PluginConfigState> _loaded(ProviderContainer container) async {
  await container.read(pluginConfigProvider.future);
  for (var i = 0; i < 50 && !container.read(pluginConfigProvider).value!.isPlugin(bigNs); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return container.read(pluginConfigProvider).value!;
}

Future<ProviderContainer> _container(MemoryPluginConfigApi api) async {
  final container = ProviderContainer(overrides: configOverrides(api, host: bigHost()));
  addTearDown(container.dispose);
  final sub = container.listen(pluginConfigProvider, (_, _) {});
  addTearDown(sub.close);
  await _loaded(container);
  return container;
}

void main() {
  group('rows draw again on their own', () {
    testWidgets('a held edit: its row and the save bar, not the page or the other rows', (tester) async {
      await openBig(tester, bigApi());
      expect(find.byType(SchemaFieldTile), findsAtLeastNWidgets(8), reason: 'a long form on screen');
      final counter = await measure(tester, () => tester.tap(find.text('流式输出')));
      expect(counter.fields, 1);
      expect(counter.of(PluginConfigPage), 0);
      expect(find.text('未保存'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('plugin-config-status'))).data, startsWith('1 项更改'));

      final again = await measure(tester, () => tester.tap(find.text('流式输出')));
      expect(again.fields, 1);
      expect(again.of(PluginConfigPage), 0);
      expect(find.byKey(const ValueKey('plugin-config-status')), findsNothing, reason: 'taken back: nothing held');
    });

    testWidgets('a live edit: its row, through the write and the read after it', (tester) async {
      final api = bigApi();
      await openBig(tester, api);
      final counter = await measure(tester, () => tester.tap(find.text('启用')), async: true);
      expect(api.entries[bigNs]!.user, {'enabled': false});
      expect(counter.fields, 1);
      final row = find.ancestor(of: find.text('启用'), matching: find.byType(SchemaFieldTile));
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value, isFalse);
    });

    testWidgets('a value changed elsewhere shows once read again', (tester) async {
      final api = bigApi();
      await openBig(tester, api);
      expect(find.text('deepseek-chat'), findsOneWidget);
      api.externalSet(bigNs, ['model'], 'deepseek-reasoner');
      await tester.pump(const Duration(milliseconds: 300));
      await flush(tester);
      expect(find.text('deepseek-reasoner'), findsOneWidget);
    });

    testWidgets('the keyboard sliding in draws neither the page nor its rows', (tester) async {
      await openBig(tester, bigApi());
      await tester.tap(find.text('流式输出'));
      await settle(tester);
      final counter = await measure(tester, () => slideKeyboardIn(tester));
      expect(counter.of(PluginConfigPage), 0);
      expect(counter.fields, 0);
      final bar = tester.getRect(find.byKey(const ValueKey('plugin-config-bar')));
      expect(bar.bottom, 844 - 300, reason: 'the save bar still rides above the keyboard');
    });

    testWidgets('opening a group builds only its rows', (tester) async {
      await openBig(tester, bigApi());
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('音频'), 200, scrollable: scrollable);
      await settle(tester);
      final before = find.byType(SchemaFieldTile).evaluate().length;
      final counter = await measure(tester, () => tester.tap(find.text('音频')));
      final opened = find.byType(SchemaFieldTile).evaluate().length - before;
      expect(opened, greaterThan(0));
      expect(counter.of(SchemaFieldTile), opened);
      expect(counter.of(PluginConfigPage), 0);
    });
  });

  testWidgets('a form read while the page slides in is drawn once it is in', (tester) async {
    final api = MemoryPluginConfigApi([bigEntry(), translatorEntry()], lazy: true);
    await pumpPage(
      tester,
      pushButton(const PluginConfigPage(ns: bigNs)),
      overrides: configOverrides(api, host: bigHost()),
    );
    await tester.tap(find.text('open'));
    var sliding = 0;
    for (var i = 0; i < 30; i++) {
      final counter = BuildCounter()..start();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      counter.stop();
      final page = find.byType(PluginConfigPage, skipOffstage: false);
      if (ModalRoute.of(tester.element(page))?.animation?.status != AnimationStatus.forward) break;
      sliding++;
      expect(counter.fields, 0, reason: 'frame ${i + 1} of the push builds no rows');
      if (i > 2) expect(find.byType(FeatureLoading), findsOneWidget);
    }
    expect(sliding, greaterThan(5), reason: 'the push was watched');
    expect(api.calls, contains(('read', bigNs)), reason: 'the form was read during the push');
    await settle(tester);
    expect(find.byType(SchemaFieldTile), findsAtLeastNWidgets(8));
    expect(find.byType(FeatureLoading), findsNothing);
  });

  group('worked out once', () {
    test('a layout per schema, language and search', () async {
      final container = await _container(bigApi());
      final form = container.read(pluginConfigProvider).value![bigNs]!;
      final layout = cachedPluginConfigLayout(form);
      expect(cachedPluginConfigLayout(form), same(layout));
      // A live write's answer: the same schema with other values.
      final written = PluginConfigForm(form.view.copyWith(value: {'enabled': false}, user: {'enabled': false}));
      expect(cachedPluginConfigLayout(written), same(layout));
      final search = cachedPluginConfigLayout(form, query: 'max');
      expect(search, isNot(same(layout)));
      expect(cachedPluginConfigLayout(form, query: 'max'), same(search));
      expect(
        search.sections.expand((s) => s.fields).length,
        pluginConfigLayout(form, query: 'max').sections.expand((s) => s.fields).length,
      );
      AppLocale.use(AppLocale.en);
      addTearDown(() => AppLocale.use(AppLocale.zhCN));
      final english = cachedPluginConfigLayout(form);
      expect(english, isNot(same(layout)));
      expect(english.sections.map((s) => s.title), contains('Network'));
    });

    test('the documentation per schema and language', () async {
      final container = await _container(bigApi());
      final schema = container.read(pluginConfigProvider).value![bigNs]!.view.schema;
      final docs = cachedSchemaDocumentation(schema, 'zh-CN');
      expect(docs, isNotEmpty);
      expect(cachedSchemaDocumentation(schema, 'zh-CN'), same(docs));
      expect(cachedSchemaDocumentation(schema, 'en'), isNot(same(docs)));
    });
  });

  group('SchemaFieldWatch', () {
    const streaming = SchemaFieldSpec(bigNs, ['streaming']);
    const apiKey = SchemaFieldSpec(bigNs, ['apiKey']);

    test('another field\'s edit leaves a row as it was; its own does not', () async {
      final container = await _container(bigApi());
      final controller = container.read(pluginConfigProvider.notifier);
      EngineSettings settings() => container.read(pluginConfigProvider).value!.settingsFor(bigNs);
      final before = SchemaFieldWatch(settings(), streaming);
      final keyBefore = SchemaFieldWatch(settings(), apiKey);

      await controller.set(_big(['temperature']), 1.2);
      expect(SchemaFieldWatch(settings(), streaming), before);
      expect(SchemaFieldWatch(settings(), apiKey), keyBefore);

      await controller.set(_big(['streaming']), false);
      final edited = SchemaFieldWatch(settings(), streaming);
      expect(edited, isNot(before), reason: 'its value and 未保存');
      expect(settings().isStaged(_big(['streaming'])), isTrue);

      controller.discard(bigNs);
      expect(SchemaFieldWatch(settings(), streaming), before);
    });

    test('a key\'s row sees its secret set', () async {
      final api = bigApi();
      final container = await _container(api);
      final controller = container.read(pluginConfigProvider.notifier);
      EngineSettings settings() => container.read(pluginConfigProvider).value!.settingsFor(bigNs);
      final before = SchemaFieldWatch(settings(), apiKey);
      await controller.setSecret(_big(['apiKey']), 'sk-test');
      expect(settings().secretConfigured(_big(['apiKey'])), isTrue);
      expect(SchemaFieldWatch(settings(), apiKey), isNot(before));
    });
  });

  if (_report) {
    final report = <String>[];
    tearDownAll(() {
      // The numbers, asked for with PERF_REPORT.
      // ignore: avoid_print
      report.forEach(print);
    });
    perfReportTests(report);
  }
}
