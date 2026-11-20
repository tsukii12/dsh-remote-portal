import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

void main() {
  for (final official in [false, true]) {
    testWidgets('switch state follows the plugin when the host reorders rows: $official', (tester) async {
      usePhoneView(tester);
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      var rows = [
        bundleJson('alpha', enabled: true, official: official),
        bundleJson('beta', enabled: true, official: official),
        bundleJson('gamma', enabled: false, official: official),
      ];
      carrier.handlers['pluginManager/listBundles'] = (_) => rows;
      await tester.pumpWidget(testApp(const PluginsScreen(), overrides: pluginOverrides(fakeHost(client))));
      await tester.pumpAndSettle();
      Finder toggle(String name) => find.descendant(
        of: find.byWidgetPredicate((widget) => widget is BundleTile && widget.bundle.name == name),
        matching: find.byType(Switch),
      );
      final elements = {
        for (final name in ['alpha', 'beta', 'gamma']) name: tester.element(toggle(name)),
      };
      final container = ProviderScope.containerOf(tester.element(find.byType(InstalledPluginsSliver)));

      // The same enabled-first response the real host returns after a toggle.
      rows = [
        bundleJson('beta', enabled: true, official: official),
        bundleJson('alpha', enabled: false, official: official),
        bundleJson('gamma', enabled: false, official: official),
      ];
      await container.read(installedPluginsProvider.notifier).refresh();
      await tester.pump();
      for (final name in elements.keys) {
        expect(identical(tester.element(toggle(name)), elements[name]), isTrue, reason: '$name keeps its own subtree');
      }
      expect(tester.widget<Switch>(toggle('alpha')).value, isFalse);
      expect(tester.widget<Switch>(toggle('beta')).value, isTrue);
      expect(tester.widget<Switch>(toggle('gamma')).value, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
