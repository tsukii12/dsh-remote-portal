// 设置 › 插件 keeps up with what the engine has: a list read earlier is read
// again on entering, pulling down reads it again, and so does a change in
// the engine's plugins (the contributions coming back changed). Rows and the
// detail sheet name a plugin by its own title, the package name only as the
// quiet line in the sheet.

import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'native/support.dart' show FakeBridge, contributions, plugin;
import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late int lists;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lists = 0;
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) {
      lists++;
      return sampleBundles;
    };
  });

  tearDown(() => client.close());

  /// A home that has read the list already (as the chat page does), with a
  /// button into 设置 › 插件.
  Future<void> pumpHome(WidgetTester tester, {FakeBridge? bridge}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Consumer(
          builder: (context, ref, _) {
            ref.watch(installedPluginsProvider);
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen())),
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
        overrides: [
          ...pluginOverrides(fakeHost(client)),
          if (bridge != null) nativeBridgeProvider.overrideWithValue(bridge),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('entering reads a list read earlier again', (tester) async {
    await pumpHome(tester);
    expect(lists, 1);
    await open(tester);
    expect(lists, 2);
    expect(find.widgetWithText(BundleTile, 'dsh-approval-gate'), findsOneWidget);
  });

  testWidgets('pulling down reads it again', (tester) async {
    await pumpHome(tester);
    await open(tester);
    final before = lists;
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1200);
    await tester.pumpAndSettle();
    expect(lists, before + 1);
  });

  testWidgets('the engine\'s plugins change: the open list reads again', (tester) async {
    final bridge = FakeBridge(contributions([], rev: 'r1'));
    await pumpHome(tester, bridge: bridge);
    await open(tester);
    final before = lists;
    bridge.raw = contributions([plugin('dsh-approval-gate', title: '危险确认')], rev: 'r2');
    final container = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
    container.invalidate(nativeRawContributionsProvider);
    await tester.pumpAndSettle();
    expect(lists, before + 1);
  });

  testWidgets('a plugin goes by its own title; the package is the quiet line in its sheet', (tester) async {
    final bridge = FakeBridge(contributions([plugin('dsh-approval-gate', title: '危险确认')]));
    await pumpHome(tester, bridge: bridge);
    await open(tester);
    expect(find.widgetWithText(BundleTile, '危险确认'), findsOneWidget);
    expect(find.descendant(of: find.byType(BundleTile), matching: find.text('dsh-approval-gate')), findsNothing);

    await tester.tap(find.widgetWithText(BundleTile, '危险确认'));
    await tester.pumpAndSettle();
    final hero = find.byType(PluginHero);
    expect(find.descendant(of: hero, matching: find.text('危险确认')), findsOneWidget);
    expect(find.descendant(of: hero, matching: find.text('dsh-approval-gate')), findsOneWidget);
  });

  testWidgets('without a title of its own: the package name once, not twice', (tester) async {
    await pumpHome(tester);
    await open(tester);
    await tester.tap(find.widgetWithText(BundleTile, 'dsh-approval-gate'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PluginHero), matching: find.text('dsh-approval-gate')), findsOneWidget);
  });
}
