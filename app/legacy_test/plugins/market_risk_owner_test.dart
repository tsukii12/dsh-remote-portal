import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../state/read_list_refresh_test.dart' show FixedHost;
import 'support/fake_plugin_host.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in ['same', 'other', 'roundtrip', 'ready']) {
    testWidgets('risk approval retains its original host: $mode', (tester) async {
      final a = FakePluginCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
        carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: '@someone/dsh-weather');
      }
      final ah = fakeHost(ac);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(initialTab: PluginsTab.market),
          overrides: [
            ...pluginOverrides(
              ah,
              selectHost: false,
              official: () async => officialFixtureMarket(),
              npmIntegrity: (name, _) async => officialFixtureMarket().byName[name]?.listing?.integrity,
            ),
            activeHostProvider.overrideWith(FixedHost.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final c = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
      await tester.tap(find.widgetWithText(MarketCard, '天气').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '安装到本机'));
      await tester.pumpAndSettle();
      expect(find.text('「天气」有风险特征'), findsOneWidget);
      if (mode == 'other' || mode == 'roundtrip') {
        c.read(activeHostProvider.notifier).select(HostRef.portal('fake-host'));
        if (mode == 'roundtrip') c.read(activeHostProvider.notifier).select(HostRef.none);
        await tester.pump();
      }
      if (mode == 'ready') {
        await ac.mux.ready();
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(FilledButton, '仍然安装'));
      await tester.pumpAndSettle();
      expect(a.argsOf('pluginManager/installBundle'), mode == 'same' ? hasLength(1) : isEmpty);
      expect(b.argsOf('pluginManager/installBundle'), isEmpty);
    });
  }
}
