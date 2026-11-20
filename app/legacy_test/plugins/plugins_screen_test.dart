import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  });

  tearDown(() => client.close());

  Future<void> pumpScreen(
    WidgetTester tester, {
    PluginsTab tab = PluginsTab.installed,
    HostConnection? host,
    bool connected = true,
  }) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(PluginsScreen(initialTab: tab), overrides: pluginOverrides(connected ? host ?? fakeHost(client) : null)),
    );
    await tester.pumpAndSettle();
  }

  Finder card(String title) => find.widgetWithText(MarketCard, title);

  Finder cardButton(String title) => find.descendant(of: card(title), matching: find.byType(PluginInstallButton));

  Future<void> openSheet(WidgetTester tester, String title) async {
    await tester.tap(cardButton(title));
    await tester.pumpAndSettle();
  }

  Future<void> tapSheetAction(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(FilledButton, label).last);
    await tester.pump();
    await tester.pump();
  }

  for (final remote in [false, true]) {
    testWidgets('restart-required toggle reports the host and offers local action: $remote', (tester) async {
      carrier.handlers['pluginManager/setBundleEnabled'] = (args) => {
        'stage': 'enable',
        'target': args['name'],
        'changed': true,
        'application': 'restart-required',
      };
      await pumpScreen(
        tester,
        host: fakeHost(client, kind: remote ? HostKind.portal : HostKind.portal, label: remote ? '电脑' : '本机'),
      );
      await tester.tap(
        find.descendant(of: find.widgetWithText(BundleTile, 'dsh-approval-gate'), matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(find.text(remote ? '已停用，重启电脑上的 DSH 后生效' : '已停用，重启引擎后生效'), findsOneWidget);
      expect(find.byType(SnackBarAction), remote ? findsNothing : findsOneWidget);
      if (!remote) expect(find.text('立即重启'), findsOneWidget);
    });
  }

  testWidgets('market and installed columns align', (tester) async {
    await pumpScreen(tester);
    final installed = tester.getRect(find.byType(PluginAvatar).first);
    expect(installed.left, closeTo(32, 0.01));
    expect(tester.getRect(find.text('已安装').last).left, closeTo(24, 0.01));
    await tester.tap(find.text('插件市场'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(PluginAvatar).first).left, closeTo(installed.left, 0.01));
    expect(tester.getRect(find.textContaining('个插件 · 来自 dshfind')).left, closeTo(24, 0.01));
    final switchText = find.textContaining('个网页版插件');
    expect(tester.getRect(switchText).right, closeTo(tester.getSize(find.byType(MaterialApp)).width - 24, 0.01));
  });

  group('已安装', () {
    testWidgets('lists third-party and official bundles, hides infrastructure, shows problems', (tester) async {
      await pumpScreen(tester);
      expect(find.text('插件'), findsWidgets);
      expect(find.text('安装到：本机'), findsOneWidget);
      expect(find.text('dsh-approval-gate'), findsOneWidget);
      expect(find.text('0.3.0 · 危险命令二次确认'), findsOneWidget);
      expect(find.text('会话搜索'), findsOneWidget);
      expect(find.text('官方'), findsOneWidget);
      expect(find.text('@deepseek-ai/dsh-base'), findsNothing);
      expect(find.text('不是 DSH 插件，无法加载'), findsOneWidget);
    });

    testWidgets('switch calls setBundleEnabled', (tester) async {
      carrier.handlers['pluginManager/setBundleEnabled'] = (args) => {
        'stage': 'enable',
        'target': args['name'],
        'changed': true,
        'application': 'applied',
      };
      await pumpScreen(tester);
      final toggle = find.descendant(
        of: find.widgetWithText(BundleTile, 'dsh-approval-gate'),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/setBundleEnabled').single, {'name': 'dsh-approval-gate', 'enabled': false});
    });

    testWidgets('remove asks first, hides the row behind 撤销, then calls removeBundle', (tester) async {
      carrier.handlers['pluginManager/removeBundle'] = (args) {
        carrier.handlers['pluginManager/listBundles'] = (_) => [
          for (final b in sampleBundles)
            if ((b! as Map)['name'] != 'dsh-approval-gate') b,
        ];
        return {'stage': 'remove', 'target': args['name'], 'changed': true, 'application': 'applied'};
      };
      await pumpScreen(tester);
      await tester.tap(find.text('dsh-approval-gate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
      await tester.pumpAndSettle();
      expect(find.text('卸载「dsh-approval-gate」？'), findsOneWidget);
      expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      expect(find.text('已卸载「dsh-approval-gate」'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      expect(find.widgetWithText(BundleTile, 'dsh-approval-gate'), findsNothing);
      expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      await tester.pump(InstalledPluginsController.removalUndoWindow);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle').single, {'name': 'dsh-approval-gate'});
      expect(find.widgetWithText(BundleTile, 'dsh-approval-gate'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('not connected', (tester) async {
      await pumpScreen(tester, connected: false);
      expect(find.text('没能连上引擎'), findsOneWidget);
    });

    testWidgets('list failure shows a retry', (tester) async {
      carrier.handlers['pluginManager/listBundles'] = (_) =>
          throw const DshRemoteException('gateway/method-not-found', 'nope');
      await pumpScreen(tester);
      expect(find.text('没能读取插件列表'), findsOneWidget);
      expect(find.text('当前引擎不支持插件管理'), findsOneWidget);
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pumpAndSettle();
      expect(find.text('dsh-approval-gate'), findsOneWidget);
    });
  });

  group('插件市场', () {
    testWidgets('search, categories and the web-only switch', (tester) async {
      await pumpScreen(tester, tab: PluginsTab.market);
      expect(card('novel-writer'), findsOneWidget);
      expect(card('Approval Gate'), findsOneWidget);
      expect(card('Memory Lite'), findsOneWidget);
      expect(card('Pink Skin'), findsNothing);
      expect(find.text('3 个插件 · 来自 dshfind'), findsOneWidget);
      expect(find.descendant(of: cardButton('Approval Gate'), matching: find.text('更新')), findsOneWidget);
      expect(find.descendant(of: cardButton('novel-writer'), matching: find.text('获取')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '小说');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(card('novel-writer'), findsOneWidget);
      expect(card('Approval Gate'), findsNothing);

      await tester.tap(find.byIcon(AppIcons.clear));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '工具集成'));
      await tester.pumpAndSettle();
      expect(card('Approval Gate'), findsOneWidget);
      expect(card('novel-writer'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示 1 个网页版插件'));
      await tester.pumpAndSettle();
      expect(card('Pink Skin'), findsOneWidget);
    });

    testWidgets('install: confirm sheet, 安装中, then 已安装', (tester) async {
      final finish = Completer<Object?>();
      carrier.handlers['pluginManager/installBundle'] = (_) => finish.future;
      await pumpScreen(tester, tab: PluginsTab.market);
      await openSheet(tester, 'novel-writer');
      expect(find.textContaining('插件以 DSH 的权限运行'), findsOneWidget);
      expect(find.textContaining('由第三方提供，DSH 官方未审核。'), findsOneWidget);
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty, reason: 'opening the sheet installs nothing');

      await tapSheetAction(tester, '安装到本机');
      expect(find.text('安装中…'), findsOneWidget);
      expect(find.text('正在下载安装'), findsOneWidget);
      final args = carrier.argsOf('pluginManager/installBundle').single;
      expect(args['spec'], 'novel-writer@1.0.2');

      carrier.handlers['pluginManager/listBundles'] = (_) => [
        ...sampleBundles,
        bundleJson('novel-writer', version: '1.0.2'),
      ];
      finish.complete(installResult());
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '管理'), findsWidgets);
      expect(find.text('已安装「novel-writer」'), findsOneWidget);

      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      expect(find.descendant(of: cardButton('novel-writer'), matching: find.text('已安装')), findsOneWidget);
    });

    testWidgets('pnpm missing maps to the phone message', (tester) async {
      carrier.handlers['pluginManager/installBundle'] = (_) =>
          installResult(application: 'failed', kind: 'pnpm-missing');
      await pumpScreen(tester, tab: PluginsTab.market);
      await openSheet(tester, 'novel-writer');
      await tapSheetAction(tester, '安装到本机');
      await tester.pumpAndSettle();
      expect(find.text('这台手机缺少 pnpm'), findsOneWidget);
      expect(find.text('「novel-writer」缺少 pnpm'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '安装到本机'), findsOneWidget);
    });

    testWidgets('blocked build scripts: explicit approval, then retry with approvedBuilds', (tester) async {
      carrier.handlers['pluginManager/installBundle'] = (args) {
        final options = args['options']! as Map;
        return options.containsKey('approvedBuilds')
            ? installResult()
            : installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']);
      };
      await pumpScreen(tester, tab: PluginsTab.market);
      await openSheet(tester, 'novel-writer');
      await tapSheetAction(tester, '安装到本机');
      await tester.pumpAndSettle();
      expect(find.text('需要运行构建脚本'), findsOneWidget);
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1));

      await tester.ensureVisible(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      expect(find.text('允许构建脚本？'), findsOneWidget);
      expect(find.text('• esbuild'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(1), reason: 'nothing without consent');

      await tester.ensureVisible(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许并重试'));
      await tester.pumpAndSettle();
      final calls = carrier.argsOf('pluginManager/installBundle');
      expect(calls, hasLength(2));
      expect((calls.last['options']! as Map)['approvedBuilds'], ['esbuild']);
      expect(find.text('需要重启引擎'), findsNothing, reason: 'a first install that applied needs no restart');
    });

    testWidgets('an update blocked on build scripts, approved and retried, still asks for a restart', (tester) async {
      carrier.handlers['pluginManager/removeBundle'] = (_) {
        carrier.handlers['pluginManager/listBundles'] = (_) => [
          for (final b in sampleBundles)
            if ((b! as Map)['name'] != 'dsh-approval-gate') b,
        ];
        return {'stage': 'remove', 'target': 'dsh-approval-gate', 'changed': true, 'application': 'applied'};
      };
      carrier.handlers['pluginManager/installBundle'] = (args) {
        final options = args['options']! as Map;
        return options.containsKey('approvedBuilds')
            ? installResult(target: 'dsh-approval-gate')
            : installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']);
      };
      await pumpScreen(tester, tab: PluginsTab.market);
      await openSheet(tester, 'Approval Gate');
      await tapSheetAction(tester, '更新到 0.4.0');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '更新').last);
      await tester.pumpAndSettle();
      expect(find.text('需要运行构建脚本'), findsOneWidget);

      await tester.ensureVisible(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许并重试'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1), reason: 'the retry only installs');
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(2));
      expect(find.text('需要重启引擎'), findsOneWidget);
      expect(find.text('「Approval Gate」重启引擎后生效，进行中的回复会中断。'), findsOneWidget);
    });

    testWidgets('restart-required on the phone offers 重启引擎', (tester) async {
      carrier.handlers['pluginManager/installBundle'] = (_) =>
          installResult(application: 'restart-required', restartReason: 'no-hmr');
      await pumpScreen(tester, tab: PluginsTab.market);
      await openSheet(tester, 'novel-writer');
      await tapSheetAction(tester, '安装到本机');
      await tester.pumpAndSettle();
      expect(find.text('需要重启引擎'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重启引擎'), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('需要重启引擎'), findsNothing);
    });

    for (final remote in [false, true]) {
      testWidgets('update asks before removing the installed version, then asks for a restart: $remote', (
        tester,
      ) async {
        carrier.handlers['pluginManager/removeBundle'] = (_) => {
          'stage': 'remove',
          'target': 'dsh-approval-gate',
          'changed': true,
          'application': 'applied',
        };
        carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: 'dsh-approval-gate');
        await pumpScreen(
          tester,
          tab: PluginsTab.market,
          host: fakeHost(client, kind: remote ? HostKind.portal : HostKind.portal, label: remote ? '电脑' : '本机'),
        );
        await openSheet(tester, 'Approval Gate');
        await tapSheetAction(tester, '更新到 0.4.0');
        await tester.pumpAndSettle();
        expect(find.text('更新「Approval Gate」？'), findsOneWidget);
        expect(find.textContaining('会先卸载 0.3.0，再安装 0.4.0'), findsOneWidget);
        // The dialog's button (the row's 更新 capsule sits under it).
        await tester.tap(find.widgetWithText(FilledButton, '更新').last);
        await tester.pumpAndSettle();
        final order = [
          for (final (e, _) in carrier.calls)
            if (e != 'pluginManager/listBundles') e,
        ];
        expect(order, ['pluginManager/removeBundle', 'pluginManager/installBundle']);
        // The Host answered `applied`, but the running engine keeps the old
        // code until it restarts: the restart offer appears, nothing restarts.
        expect(find.text('已安装「Approval Gate」'), findsNothing);
        if (remote) {
          expect(find.text('已安装「Approval Gate」，重启电脑上的 DSH 后生效'), findsOneWidget);
          expect(find.text('需要重启引擎'), findsNothing);
        } else {
          expect(find.text('需要重启引擎'), findsOneWidget);
          expect(find.text('「Approval Gate」重启引擎后生效，进行中的回复会中断。'), findsOneWidget);
          await tester.tap(find.text('稍后'));
          await tester.pumpAndSettle();
          expect(find.text('需要重启引擎'), findsNothing);
        }
      });
    }

    testWidgets('relay hosts get the command to copy', (tester) async {
      final relayCarrier = FakePluginCarrier(allowInstall: false);
      final relayClient = DshClient.withCarrier(relayCarrier);
      addTearDown(relayClient.close);
      relayCarrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      await pumpScreen(
        tester,
        tab: PluginsTab.market,
        host: fakeHost(relayClient, kind: HostKind.portal, label: '家里的 Mac · 远程'),
      );
      expect(find.text('家里的 Mac · 远程 · 经中转只能开关，安装请在那台电脑上进行'), findsOneWidget);
      await openSheet(tester, 'novel-writer');
      await tester.tap(find.text('获取安装命令'));
      await tester.pumpAndSettle();
      expect(find.text('dsh plugin --profile web add novel-writer@1.0.2'), findsOneWidget);
      expect(relayCarrier.argsOf('pluginManager/installBundle'), isEmpty);
    });

    testWidgets('index failure shows a retry', (tester) async {
      usePhoneView(tester);
      var attempts = 0;
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(initialTab: PluginsTab.market),
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
            localSafeModeProvider.overrideWithValue(false),
            marketIndexFetcherProvider.overrideWithValue((url) async {
              if (attempts++ == 0) {
                throw const MarketFetchException('网络连不上插件目录，请检查网络');
              }
              return parseMarketIndex(sampleIndex, url);
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('插件目录没打开'), findsOneWidget);
      expect(find.text('网络连不上插件目录，请检查网络'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pumpAndSettle();
      expect(card('novel-writer'), findsOneWidget);
    });
  });
}
