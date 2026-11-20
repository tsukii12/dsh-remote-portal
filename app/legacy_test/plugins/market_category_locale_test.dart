import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    testWidgets('market category follows $locale and still filters by its id', (tester) async {
      AppLocale.use(locale);
      final carrier = FakePluginCarrier();
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: locale,
              child: const Scaffold(body: CustomScrollView(slivers: [MarketSliver()])),
            ),
          ),
          overrides: pluginOverrides(fakeHost(client)),
        ),
      );
      await tester.pumpAndSettle();
      final english = locale.languageCode == 'en';
      final title = english ? 'Agent Boosters' : 'Agent 增强';
      final otherTitle = english ? 'Agent 增强' : 'Agent Boosters';
      await tester.ensureVisible(find.text(title));
      expect(find.text(title), findsOneWidget);
      expect(find.text(otherTitle), findsNothing);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(MarketSliver)));
      expect(container.read(marketFilterProvider).category, 'agent');
      expect(tester.takeException(), isNull);
    });
  }
}
