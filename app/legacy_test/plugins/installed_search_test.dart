import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../state/read_list_refresh_test.dart' show ListHost, listOverrides, switchConnectionProvider;
import 'native/support.dart' show FakeBridge, contributions, plugin;
import 'support/fake_plugin_host.dart';

final _bundles = [
  bundleJson(
    'memo-box',
    title: {'zh': '记忆盒', 'en': 'Memory Box'},
    description: {'zh': '保存有用的片段', 'en': 'Keep useful snippets'},
  ),
  {...bundleJson('approval-gate'), 'description': 'Protect dangerous commands'},
  bundleJson('sleeping-addon', enabled: false, title: '休眠插件'),
  bundleJson(
    '@deepseek-ai/search',
    official: true,
    optional: true,
    title: {'zh': '会话搜索', 'en': 'Session Search'},
    description: {'zh': '搜索历史会话', 'en': 'Find earlier sessions'},
  ),
  bundleJson('@deepseek-ai/dsh-base', installed: false, readOnlyReason: 'management-required'),
];

Set<String> _shown(WidgetTester tester) =>
    tester.widgetList<BundleTile>(find.byType(BundleTile)).map((tile) => tile.bundle.name).toSet();

Future<void> _query(WidgetTester tester, String text) async {
  expect(find.byType(TextField), findsOneWidget);
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late FakeBridge bridge;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    carrier = FakePluginCarrier()..handlers['pluginManager/listBundles'] = (_) => _bundles;
    client = DshClient.withCarrier(carrier);
    bridge = FakeBridge(contributions([]));
  });
  tearDown(() => client.close());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const PluginsScreen(),
        overrides: [...pluginOverrides(fakeHost(client)), nativeBridgeProvider.overrideWithValue(bridge)],
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
  }

  testWidgets('installed search filters package names and all provided translations', (tester) async {
    await pump(tester);
    final reads = carrier.argsOf('pluginManager/listBundles').length;
    for (final (text, name) in [
      ('MEMO-BOX', 'memo-box'),
      ('记忆', 'memo-box'),
      ('memory SNIPPETS', 'memo-box'),
      ('dangerous', 'approval-gate'),
      ('EARLIER', '@deepseek-ai/search'),
      ('休眠', 'sleeping-addon'),
    ]) {
      await _query(tester, text);
      expect(_shown(tester), {name}, reason: text);
    }
    expect(carrier.argsOf('pluginManager/listBundles'), hasLength(reads), reason: 'filtering is local');
    expect(carrier.argsOf('pluginManager/setBundleEnabled'), isEmpty);
  });

  testWidgets('installed search has a no-match state and clear restores the list', (tester) async {
    await pump(tester);
    await _query(tester, 'nothing-like-this');
    expect(_shown(tester), isEmpty);
    expect(find.text(appL10n.pluginsNoMatchingPlugins), findsOneWidget);
    expect(find.text(appL10n.pluginsNoThirdParty), findsNothing);
    await tester.tap(find.byIcon(AppIcons.clear));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(_shown(tester), {'memo-box', 'approval-gate', 'sleeping-addon', '@deepseek-ai/search'});
    await _query(tester, '   ');
    expect(_shown(tester), {'memo-box', 'approval-gate', 'sleeping-addon', '@deepseek-ai/search'});
    expect(find.text('@deepseek-ai/dsh-base'), findsNothing);
  });

  testWidgets('installed search matches the native title actually shown by the row', (tester) async {
    bridge.raw = contributions([plugin('memo-box', title: '随身记事本')]);
    await pump(tester);
    expect(find.text('随身记事本'), findsOneWidget);
    await _query(tester, '随身');
    expect(_shown(tester), {'memo-box'});
    expect(find.text('随身记事本'), findsOneWidget);
  });

  testWidgets('filtered rows keep their actual toggle target', (tester) async {
    carrier.handlers['pluginManager/setBundleEnabled'] = (args) => {
      'stage': 'enable',
      'target': args['name'],
      'changed': true,
      'application': 'applied',
    };
    await pump(tester);
    await _query(tester, 'dangerous');
    await tester.tap(find.descendant(of: find.byType(BundleTile), matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(carrier.argsOf('pluginManager/setBundleEnabled').single, {'name': 'approval-gate', 'enabled': false});
    expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  testWidgets('installed search filters a pending install by its title without duplicating rows', (tester) async {
    final finish = Completer<Object?>();
    carrier.handlers['pluginManager/installBundle'] = (_) => finish.future;
    final container = await pump(tester);
    final done = container
        .read(pluginInstallsProvider.notifier)
        .install(const PluginInstallRequest(name: 'new-plugin', spec: 'new-plugin@1.0.0', title: '新工具箱'));
    await tester.pumpAndSettle();
    await _query(tester, '工具箱');
    expect(find.text('新工具箱'), findsOneWidget);
    expect(_shown(tester), isEmpty);
    await _query(tester, 'memo');
    expect(find.text('新工具箱'), findsNothing);
    expect(_shown(tester), {'memo-box'});
    carrier.handlers['pluginManager/listBundles'] = (_) => [..._bundles, bundleJson('new-plugin', title: '新工具箱')];
    finish.complete(installResult(target: 'new-plugin'));
    await done;
    await _query(tester, 'new-plugin');
    expect(_shown(tester), {'new-plugin'});
    expect(find.text('新工具箱'), findsOneWidget);
  });

  testWidgets('offline search stays read-only and follows the next host inventory', (tester) async {
    usePhoneView(tester);
    final first = ListHost('first');
    final next = ListHost('next');
    addTearDown(first.client.close);
    addTearDown(next.client.close);
    first.carrier.handlers['pluginManager/listBundles'] = (_) => _bundles;
    next.carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('memo-next')];
    await tester.pumpWidget(
      testApp(
        const PluginsScreen(),
        overrides: [
          ...listOverrides(first),
          nativeBridgeProvider.overrideWithValue(bridge),
          officialMarketFetcherProvider.overrideWithValue(() async => emptyOfficialMarket),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
    await _query(tester, 'memo');
    container.read(switchConnectionProvider.notifier).set(null);
    await tester.pumpAndSettle();
    expect(_shown(tester), {'memo-box'});
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await _query(tester, 'no-such-plugin');
    expect(_shown(tester), isEmpty);
    expect(find.textContaining(appL10n.readListOffline), findsOneWidget);
    await _query(tester, 'dangerous');
    expect(_shown(tester), {'approval-gate'});
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await _query(tester, 'memo');
    container.read(switchConnectionProvider.notifier).set(next.connection);
    await tester.pumpAndSettle();
    expect(_shown(tester), {'memo-next'});
    expect(first.carrier.argsOf('pluginManager/setBundleEnabled'), isEmpty);
    expect(next.carrier.argsOf('pluginManager/setBundleEnabled'), isEmpty);
  });

  testWidgets('an actually empty installed list keeps its browse action', (tester) async {
    carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
    await pump(tester);
    expect(find.text(appL10n.pluginsNoThirdParty), findsOneWidget);
    await _query(tester, 'example');
    expect(find.text(appL10n.pluginsNoMatchingPlugins), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.text(appL10n.pluginsBrowseMarket));
    await tester.pumpAndSettle();
    expect(find.text('novel-writer'), findsOneWidget);
  });

  testWidgets('installed query is separate from market search and disposes on tab exit', (tester) async {
    await pump(tester);
    await _query(tester, 'memo');
    await tester.tap(find.text(appL10n.pluginsMarketTitle));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await _query(tester, 'novel');
    await tester.tap(find.text(appL10n.commonInstalled).first);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(_shown(tester), {'memo-box', 'approval-gate', 'sleeping-addon', '@deepseek-ai/search'});
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
