import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  setUpAll(loadTestFonts);
  late FakePluginCarrier carrier;
  late DshClient client;
  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
  });
  tearDown(() => client.close());

  Future<void> pump(WidgetTester tester, Brightness brightness) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const PluginsScreen(initialTab: PluginsTab.market),
        brightness: brightness,
        overrides: pluginOverrides(fakeHost(client), official: () async => officialFixtureMarket()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('English cards fit at 360dp and 1.3 text scale', (tester) async {
    AppLocale.use(const Locale('en'));
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    usePhoneView(tester);
    tester.view.physicalSize = const Size(720, 1688);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: const Locale('en'),
            child: MediaQuery.withClampedTextScaling(
              minScaleFactor: 1.3,
              maxScaleFactor: 1.3,
              child: const PluginsScreen(initialTab: PluginsTab.market),
            ),
          ),
        ),
        overrides: pluginOverrides(fakeHost(client), official: () async => officialFixtureMarket()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Images & video'), findsWidgets);
    final scroll = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
    final card = find.widgetWithText(MarketCard, 'Native helper').hitTestable();
    for (var i = 0; i < 15 && card.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -180));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    await tester.tap(card.first);
    await tester.pumpAndSettle();
    expect(find.byType(MarketPluginSheet), findsOneWidget);
    expect(find.text('High risk'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('official market sections ${brightness.name}', (tester) async {
      await pump(tester, brightness);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/market_official_${brightness.name}.png'));
    });

    testWidgets('official detail ${brightness.name}', (tester) async {
      await pump(tester, brightness);
      await tester.tap(find.widgetWithText(MarketCard, '天气').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/market_official_detail_${brightness.name}.png'),
      );
    });
  }
}
