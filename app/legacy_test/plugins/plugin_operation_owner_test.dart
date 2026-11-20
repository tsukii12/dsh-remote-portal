import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../state/read_list_refresh_test.dart' show FixedHost, SwitchConnection, switchConnectionProvider;
import 'support/fake_plugin_host.dart';
import 'support/notice_on_top.dart';

Future<void> flush(ProviderContainer c) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await c.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final destination in ['same', 'other', 'disconnected', 'roundtrip', 'refresh', 'ready', 'ssh']) {
    testWidgets('uninstall consent belongs to opened connection: $destination', (tester) async {
      final a = FakePluginCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('owner-plugin')];
        carrier.handlers['pluginManager/removeBundle'] = (_) => {
          'target': 'owner-plugin',
          'changed': true,
          'application': 'applied',
        };
      }
      final ah = fakeHost(ac, label: 'A');
      final bh = fakeHost(bc, label: 'B', kind: destination == 'ssh' ? HostKind.portal : HostKind.portal);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(),
          overrides: [
            activeHostProvider.overrideWith(FixedHost.new),
            switchConnectionProvider.overrideWith(() => SwitchConnection(ah)),
            activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
            readListIdentityProvider.overrideWithValue(null),
            localSafeModeProvider.overrideWithValue(false),
            marketIndexFetcherProvider.overrideWithValue((url) async => parseMarketIndex(sampleIndex, url)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final c = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
      expect(c.read(installedPluginsProvider).value!.single.name, 'owner-plugin');
      await tester.tap(find.widgetWithText(BundleTile, 'owner-plugin'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      if (['other', 'disconnected', 'roundtrip', 'ssh'].contains(destination)) {
        if (destination == 'ssh') c.read(activeHostProvider.notifier).select(HostRef.portal('fake-host'));
        c.read(switchConnectionProvider.notifier).set(destination == 'disconnected' ? null : bh);
        await tester.pumpAndSettle();
        expect(c.read(pluginHostProvider)?.client, destination == 'disconnected' ? isNull : same(bc));
      }
      if (destination == 'roundtrip') {
        c.read(switchConnectionProvider.notifier).set(ah);
        await tester.pumpAndSettle();
      }
      if (destination == 'refresh') {
        await c.read(installedPluginsProvider.notifier).refresh();
        await tester.pumpAndSettle();
      }
      if (destination == 'ready') {
        await ac.mux.ready(); // Actual ready frame from the existing carrier link.
        await tester.pumpAndSettle();
        expect(ac.mux.lastReadyGenerationNumber, greaterThan(0));
      }
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('主机已切换，未执行'), !['same', 'refresh'].contains(destination) ? findsOneWidget : findsNothing);
      if (!['same', 'refresh'].contains(destination)) {
        expect(snackBarOnTop(tester, '主机已切换，未执行'), isTrue, reason: 'never left under the plugin sheet');
      }
      // An accepted uninstall waits out its undo window before reaching the Host.
      expect(a.argsOf('pluginManager/removeBundle'), isEmpty);
      await tester.pump(InstalledPluginsController.removalUndoWindow);
      await tester.pumpAndSettle();
      expect(b.argsOf('pluginManager/removeBundle'), isEmpty, reason: 'A consent must never remove B package');
      expect(a.argsOf('pluginManager/removeBundle').length, ['same', 'refresh'].contains(destination) ? 1 : 0);
    });
  }

  test('late failed toggle cannot roll back refreshed A after A to B to A', () async {
    final a = FakePluginCarrier();
    final b = FakePluginCarrier();
    final ac = DshClient.withCarrier(a);
    final bc = DshClient.withCarrier(b);
    addTearDown(ac.close);
    addTearDown(bc.close);
    var enabled = true;
    a.handlers['pluginManager/listBundles'] = (_) => [bundleJson('owner-plugin', enabled: enabled)];
    b.handlers['pluginManager/listBundles'] = (_) => [bundleJson('owner-plugin')];
    final reply = Completer<Object?>();
    a.handlers['pluginManager/setBundleEnabled'] = (_) => reply.future;
    final ah = fakeHost(ac);
    final bh = fakeHost(bc);
    final c = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(FixedHost.new),
        switchConnectionProvider.overrideWith(() => SwitchConnection(ah)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        readListIdentityProvider.overrideWithValue(null),
        localSafeModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);
    c.listen(installedPluginsProvider, (_, _) {});
    final original = (await c.read(installedPluginsProvider.future))!.single;
    final request = c.read(installedPluginsProvider.notifier).setEnabled(original, false);
    await flush(c);
    expect(a.argsOf('pluginManager/setBundleEnabled'), hasLength(1));
    c.read(switchConnectionProvider.notifier).set(bh);
    await flush(c);
    enabled = false; // authoritative A inventory independently changed while away.
    c.read(switchConnectionProvider.notifier).set(ah);
    await flush(c);
    expect(c.read(installedPluginsProvider).value!.single.enabled, isFalse);
    final followup = Completer<Object?>();
    a.handlers['pluginManager/listBundles'] = (_) => followup.future;
    reply.complete({'target': 'owner-plugin', 'changed': false, 'application': 'failed'});
    await request;
    await flush(c);
    final actual = c.read(installedPluginsProvider).value!.single.enabled;
    followup.complete([bundleJson('owner-plugin', enabled: false)]);
    await flush(c);
    expect(actual, isFalse, reason: 'retired operation cannot mutate newly confirmed inventory');
  });
}
