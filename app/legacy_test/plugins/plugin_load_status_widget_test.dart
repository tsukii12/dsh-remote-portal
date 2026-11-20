import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:dsh_app/ui/plugins/plugin_load_status.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show FakeRuntime;
import 'seats/support.dart' show FixedHost;
import 'support/fake_plugin_host.dart';

const _bundle = PluginBundle(
  name: 'example',
  enabled: true,
  installed: true,
  rows: [
    PluginBundleRow(rowId: 'worker', moduleName: 'worker', entryId: 'include:worker'),
    PluginBundleRow(rowId: 'panel', moduleName: 'panel', entryId: 'include:panel'),
  ],
);

PluginInventory _inventory({String? panel = 'failed', PluginDisplayMeta? meta}) => PluginInventory(
  entries: [
    const PluginInventoryEntry(entryId: 'include:worker', moduleName: 'worker', enabled: true, fiberPhase: 'active'),
    PluginInventoryEntry(entryId: 'include:panel', moduleName: 'panel', enabled: true, fiberPhase: panel, meta: meta),
  ],
);

InventorySnapshot _snapshot(PluginInventory inventory) =>
    InventorySnapshot(inventory: inventory, global: const [], presets: const {});

Future<void> _pump(
  WidgetTester tester, {
  PluginInventory? inventory,
  Future<InventorySnapshot?> Function()? read,
  PluginBundle bundle = _bundle,
  HostRef host = HostRef.none,
  Locale locale = AppLocale.zhCN,
  Brightness brightness = Brightness.light,
  double width = 390,
  double scale = 1,
}) async {
  usePhoneView(tester);
  tester.view.physicalSize = Size(width * 2, 1688);
  AppLocale.use(locale);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        pluginInventoryProvider.overrideWith((ref) async => read != null ? await read() : _snapshot(inventory!)),
        activeHostProvider.overrideWith(() => FixedHost(host)),
        localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => const ['plugin load log line']),
        localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true))),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: L10n.localizationsDelegates,
        theme: testTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: PluginLoadStatus(bundle: bundle),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final fallback in [false, true]) {
    testWidgets('installed details read actual inventory status (old host: $fallback)', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('example')];
      final entries = [
        {'entryId': 'include:example', 'moduleName': 'example', 'enabled': true, 'fiberPhase': 'failed'},
      ];
      if (fallback) {
        carrier.handlers['pluginManager/listPlugins'] = (_) => entries;
      } else {
        carrier.handlers['pluginInventory/list'] = (_) => {'entries': entries};
      }
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(),
          overrides: [
            ...pluginOverrides(fakeHost(client), selectHost: false),
            activeHostProvider.overrideWith(() => FixedHost(HostRef.none)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('example'));
      await tester.pumpAndSettle();
      expect(find.text('加载状态'), findsOneWidget);
      expect(find.text('include:example'), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      expect(carrier.argsOf(fallback ? 'pluginManager/listPlugins' : 'pluginInventory/list'), isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('问 AI sits before refresh and asks about plugins', (tester) async {
    final carrier = FakePluginCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
    carrier.handlers['pluginInventory/list'] = (_) => {'entries': <Object?>[]};
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const PluginsScreen(),
        overrides: [
          ...pluginOverrides(fakeHost(client), selectHost: false),
          activeHostProvider.overrideWith(() => FixedHost(HostRef.none)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final ask = tester.getRect(find.byTooltip('问 AI'));
    final refresh = tester.getRect(find.byTooltip('刷新'));
    expect(ask.size, refresh.size);
    expect(ask.top, refresh.top);
    expect(refresh.left - ask.right, 8, reason: 'the bar spaces its keys 8 apart');
    await tester.tap(find.byTooltip('问 AI'));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(c.read(composeInboxProvider).single.text, '/dsh-go-guide 插件能做什么？装第三方插件要注意什么？');
  });

  testWidgets('partial load exposes the exact failing row and no invented runtime cause', (tester) async {
    await _pump(tester, inventory: _inventory());
    expect(find.text('加载状态'), findsOneWidget);
    expect(find.text('部分生效 · 1 / 2 个组件运行中'), findsOneWidget);
    expect(find.text('include:panel'), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('主机未返回运行时错误详情，请查看引擎日志。'), findsOneWidget);
    expect(find.text('元数据诊断'), findsNothing);
    await tester.tap(find.text('引擎日志'));
    await tester.pumpAndSettle();
    expect(find.byType(LogView), findsOneWidget);
  });

  testWidgets('healthy and disabled bundles take no additional layout space', (tester) async {
    await _pump(tester, inventory: _inventory(panel: 'active'));
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
    await _pump(
      tester,
      inventory: _inventory(),
      bundle: PluginBundle(name: 'disabled', rows: _bundle.rows),
    );
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
  });

  testWidgets('waiting, loading and missing rows do not invent failure reasons', (tester) async {
    await _pump(tester, inventory: _inventory(panel: 'pending'));
    expect(find.text('等待依赖'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
    await _pump(tester, inventory: _inventory(panel: 'loading'));
    expect(find.text('加载中'), findsOneWidget);
    await _pump(tester, inventory: const PluginInventory(entries: []));
    expect(find.text('状态未报告'), findsNWidgets(2));
    expect(find.text('尚未就绪 · 0 / 2 个组件运行中'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });

  testWidgets('metadata errors remain separate from runtime error details', (tester) async {
    await _pump(
      tester,
      inventory: _inventory(
        panel: 'active',
        meta: const PluginDisplayMeta(error: 'Invalid title map at /title'),
      ),
    );
    expect(find.text('元数据诊断 · 2 / 2 个组件运行中'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
    await tester.tap(find.text('元数据诊断'));
    await pumpFrames(tester);
    expect(find.text('Invalid title map at /title'), findsOneWidget);
  });

  testWidgets('remote failure never opens the local engine log', (tester) async {
    await _pump(tester, inventory: _inventory(), host: const HostRef.portal('development'));
    expect(find.text('请在这台主机上查看引擎日志。'), findsOneWidget);
    expect(find.text('引擎日志'), findsNothing);
    expect(find.byType(LogView), findsNothing);
  });

  testWidgets('refresh clears a resolved load problem without polling', (tester) async {
    var inventory = _inventory();
    var reads = 0;
    await _pump(
      tester,
      read: () async {
        reads++;
        return _snapshot(inventory);
      },
    );
    expect(reads, 1);
    expect(find.text('加载状态'), findsOneWidget);
    inventory = _inventory(panel: 'active');
    await tester.tap(find.text('刷新'));
    await pumpFrames(tester);
    expect(reads, 2);
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
  });

  testWidgets('unreadable, disconnected and loading inventories establish no load failure', (tester) async {
    await _pump(tester, read: () async => throw StateError('inventory unavailable'));
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
    await _pump(tester, read: () async => null);
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
    final pending = Completer<InventorySnapshot?>();
    await _pump(tester, read: () => pending.future);
    expect(tester.getSize(find.byType(PluginLoadStatus)).height, 0);
    pending.complete(_snapshot(_inventory()));
    await pumpFrames(tester);
    expect(find.text('加载状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in AppLocale.supported) {
    for (final brightness in Brightness.values) {
      final suffix = '${locale.languageCode}_${brightness.name}';
      testWidgets('diagnostics fit 320 dp at 2x with symmetric gutters ($suffix)', (tester) async {
        await _pump(tester, inventory: _inventory(), locale: locale, brightness: brightness, width: 320, scale: 2);
        final rect = tester.getRect(find.byKey(const ValueKey('plugin-load-status')));
        expect(rect.left, 20);
        expect(320 - rect.right, 20);
        final l10n = lookupL10n(locale);
        final logs = find.widgetWithText(ListPageRow, l10n.shellEngineLogs);
        expect(tester.getSize(logs).height, greaterThanOrEqualTo(48));
        expect(find.text(l10n.pluginsLoadNoRuntimeDetail), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('golden load diagnostics ($suffix)', (tester) async {
        await _pump(tester, inventory: _inventory(), locale: locale, brightness: brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugin_load_$suffix.png'));
      }, tags: ['golden']);
    }
  }
}
