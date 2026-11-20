// Goldens (light + dark) of 插件: the installed list, the market as
// app-store rows, and the detail sheet with its head, the three figures and
// the one primary button, and the 已卸载 undo notice. Regenerate with
// `flutter test --update-goldens test/plugins/plugins_golden_test.dart`.

import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;

  setUpAll(loadTestFonts);
  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  });
  tearDown(() => client.close());

  Future<void> pump(WidgetTester tester, PluginsTab tab, Brightness brightness) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        PluginsScreen(initialTab: tab),
        brightness: brightness,
        overrides: pluginOverrides(fakeHost(client)),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('installed', (tester) async {
        await pump(tester, PluginsTab.installed, brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugins_installed_$mode.png'));
      });

      testWidgets('market', (tester) async {
        await pump(tester, PluginsTab.market, brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugins_market_$mode.png'));
      });

      testWidgets('detail sheet', (tester) async {
        await pump(tester, PluginsTab.market, brightness);
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(MarketCard, 'novel-writer'),
            matching: find.byType(PluginInstallButton),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugins_detail_$mode.png'));
      });

      // 卸载 confirmed: the row leaves at once and 已卸载「…」 with 撤销 stands
      // for the undo window (nothing has reached the Host yet).
      testWidgets('uninstall undo', (tester) async {
        await pump(tester, PluginsTab.installed, brightness);
        await tester.tap(find.text('dsh-approval-gate'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '卸载'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugins_uninstall_undo_$mode.png'));
        await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
        await tester.pumpAndSettle();
        expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      });
    });
  }
}
