// 「Cordis」: the native mirror of the official Cordis panel. Grouping and
// states, the plugin sheet and its Remote calls, the DSH Web hand-off, and
// goldens (light + dark). Regenerate the goldens with
// `flutter test --update-goldens test/cordis`.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/cordis_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/cordis/cordis_page.dart';
import 'package:dsh_app/ui/cordis/cordis_plugin_sheet.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart';
import 'support.dart';

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(home: const CordisPage(), brightness: Brightness.light, overrides: overrides));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _openSheet(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// A Host serving the sample inventory through the real providers.
class _Host {
  _Host() : carrier = FakePluginCarrier() {
    client = DshClient.withCarrier(carrier);
    carrier.handlers['dynamicCordisRunner/inventory'] = (_) => rows;
    carrier.handlers['dynamicCordisRunner/stopFromPanel'] = (_) => {'ok': true};
    carrier.handlers['dynamicCordisRunner/undefineFromPanel'] = (_) => {'ok': true, 'wasRunning': true};
  }

  final FakePluginCarrier carrier;
  late final DshClient client;
  List<Object?> rows = [...sampleCordisRows];

  List<Override> get overrides => [
    activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
    sessionsProvider.overrideWith(() => FakeSessions(cordisSessions)),
    currentSessionProvider.overrideWith(() => FakeCurrentSession('s1')),
  ];
}

class _RelayCarrier extends FakePluginCarrier {
  @override
  bool allowsEndpoint(String endpoint) => !endpoint.startsWith('dynamicCordisRunner/');
}

void main() {
  group('state', () {
    test('groups: this conversation first, waiting rows first in each', () {
      final groups = cordisGroups(samplePlugins, 's1');
      expect(groups.current.map((p) => p.name), ['构建通知', '桌面时钟']);
      expect(groups.others.map((p) => p.name), ['翻译助手', '天气卡片']);
      final none = cordisGroups(samplePlugins, null);
      expect(none.current, isEmpty);
      expect(none.others, hasLength(4));
    });

    test('labels and failure lines', () {
      expect(samplePlugins.map((p) => cordisStatusLabel(p.status)), ['运行中', '待确认', '运行失败', '未运行']);
      expect(cordisFailureText(samplePlugins[2].failure!), '后台部分没能启动');
      expect(cordisMakeup(samplePlugins[0].shown!), '后台和界面');
      expect(cordisMakeup(samplePlugins[2].shown!), '仅后台');
      expect(cordisMakeup(samplePlugins[3].shown!), '仅界面');
    });

    test('the inventory is read again on cordis/* announcements', () async {
      final host = _Host();
      addTearDown(host.client.close);
      final container = ProviderContainer(overrides: host.overrides);
      addTearDown(container.dispose);
      container.listen(cordisInventoryProvider, (_, _) {});
      await host.client.mux.ready(timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await container.read(cordisInventoryProvider.future))!, hasLength(4));
      final before = host.carrier.argsOf('dynamicCordisRunner/inventory').length;

      host.rows = [sampleCordisRows.first];
      host.carrier.emit('cordis/dynamic-retract', {'pluginId': 'notify-c3d4'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.carrier.argsOf('dynamicCordisRunner/inventory').length, before + 1);
      expect((await container.read(cordisInventoryProvider.future))!.single.pluginId, 'clock-a1b2');

      // Other announcements leave it alone.
      host.carrier.emit('plugin-manager/changed', {'reason': 'install'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.carrier.argsOf('dynamicCordisRunner/inventory').length, before + 1);
    });

    test('the relay tunnel cannot reach Cordis', () {
      final client = DshClient.withCarrier(_RelayCarrier());
      addTearDown(client.close);
      final container = ProviderContainer(
        overrides: [activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client, kind: HostKind.portal)))],
      );
      addTearDown(container.dispose);
      expect(container.read(cordisReachProvider), CordisReach.unsupported);
    });
  });

  group('page', () {
    testWidgets('both groups, with names, purposes and states', (tester) async {
      await _pump(tester, cordisOverrides());
      expect(find.text('当前对话'), findsOneWidget);
      expect(find.text('其他对话'), findsOneWidget);
      for (final text in ['桌面时钟', '在侧边栏显示时间和日期', '构建通知', '翻译助手', '天气卡片']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      for (final label in ['运行中', '待确认', '运行失败', '未运行']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Waiting for an answer comes first in its group.
      expect(tester.getTopLeft(find.text('构建通知')).dy, lessThan(tester.getTopLeft(find.text('桌面时钟')).dy));
    });

    testWidgets('one group needs no titles', (tester) async {
      await _pump(tester, cordisOverrides(plugins: samplePlugins.where((p) => p.agentId != 's1').toList()));
      expect(find.text('当前对话'), findsNothing);
      expect(find.text('其他对话'), findsNothing);
      expect(find.text('翻译助手'), findsOneWidget);
    });

    testWidgets('empty and unreachable states', (tester) async {
      await _pump(tester, cordisOverrides(plugins: const []));
      expect(find.text('还没有动态插件'), findsOneWidget);
      await _pump(tester, cordisOverrides(reach: CordisReach.unsupported));
      expect(find.text('这个连接看不到 Cordis'), findsOneWidget);
    });
  });

  group('sheet', () {
    testWidgets('facts, and 在网页版打开 lands on the panel in its conversation', (tester) async {
      final opened = <DshWebTarget>[];
      await _pump(tester, [
        ...cordisOverrides(),
        cordisWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target)),
      ]);
      await _openSheet(tester, '桌面时钟');
      final sheet = find.byType(CordisPluginSheet);
      Finder inSheet(String text) => find.descendant(of: sheet, matching: find.text(text));
      expect(inSheet('在侧边栏显示时间和日期'), findsOneWidget);
      expect(inSheet('运行中'), findsOneWidget);
      expect(inSheet('做一个桌面时钟插件'), findsOneWidget);
      expect(inSheet('2 个'), findsOneWidget);
      expect(inSheet('后台和界面'), findsOneWidget);

      await tester.tap(inSheet('在网页版打开'));
      await tester.pump();
      expect(opened, [const DshWebTarget(sessionId: 's1', panel: DshWebPanel.cordis)]);
    });

    testWidgets('a stopped plugin cannot be stopped again', (tester) async {
      await _pump(tester, cordisOverrides());
      await _openSheet(tester, '天气卡片');
      final stop = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '停止'));
      expect(stop.onPressed, isNull);
      final remove = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '移除'));
      expect(remove.onPressed, isNotNull);
    });

    testWidgets('a failure reads in words; the Host message is behind 详情', (tester) async {
      await _pump(tester, cordisOverrides());
      await _openSheet(tester, '翻译助手');
      expect(find.text('后台部分没能启动'), findsOneWidget);
      final message = find.textContaining('TypeError');
      expect(message, findsNothing);
      await tester.tap(find.text('详情'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(message, findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('停止 calls stopFromPanel with the owner and the plugin', (tester) async {
      final host = _Host();
      addTearDown(host.client.close);
      await _pump(tester, host.overrides);
      await _openSheet(tester, '桌面时钟');
      host.rows = [
        {...sampleCordisRows.first, 'activeRun': null, 'latestRun': attempt('pkg-2', 'stopped')},
        ...sampleCordisRows.skip(1),
      ];
      await tester.tap(find.widgetWithText(OutlinedButton, '停止'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.carrier.argsOf('dynamicCordisRunner/stopFromPanel'), [
        {'agentId': 's1', 'pluginId': 'clock-a1b2'},
      ]);
      // The sheet follows the inventory read after it.
      expect(find.descendant(of: find.byType(CordisPluginSheet), matching: find.text('未运行')), findsOneWidget);
    });

    testWidgets('移除 confirms, calls undefineFromPanel, closes and says so', (tester) async {
      final host = _Host();
      addTearDown(host.client.close);
      await _pump(tester, host.overrides);
      await _openSheet(tester, '桌面时钟');
      await tester.tap(find.widgetWithText(OutlinedButton, '移除'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('移除「桌面时钟」？'), findsOneWidget);
      expect(find.text('会停止它，并删除全部 2 个版本。'), findsOneWidget);
      host.rows = [...sampleCordisRows.skip(1)];
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(host.carrier.argsOf('dynamicCordisRunner/undefineFromPanel'), [
        {'agentId': 's1', 'pluginId': 'clock-a1b2'},
      ]);
      expect(find.byType(CordisPluginSheet), findsNothing);
      expect(find.text('已移除'), findsOneWidget);
    });

    testWidgets('a failed stop says so inside the sheet', (tester) async {
      final host = _Host();
      addTearDown(host.client.close);
      host.carrier.handlers['dynamicCordisRunner/stopFromPanel'] = (_) =>
          throw const DshRemoteException('session/not-found', 'session "s1" not found');
      await _pump(tester, host.overrides);
      await _openSheet(tester, '桌面时钟');
      await tester.tap(find.widgetWithText(OutlinedButton, '停止'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没能停止：这个对话已经不在了'), findsOneWidget);
    });
  });

  group('goldens', () {
    goldenBoth('cordis', () => const CordisPage(), overrides: cordisOverrides);
    goldenBoth('cordis_empty', () => const CordisPage(), overrides: () => cordisOverrides(plugins: const []));
    goldenBoth(
      'cordis_sheet',
      () => const CordisPage(),
      overrides: cordisOverrides,
      before: (tester) async {
        await _openSheet(tester, '翻译助手');
        await tester.tap(find.text('详情'));
        await tester.pump(const Duration(milliseconds: 600));
      },
    );
  });
}
