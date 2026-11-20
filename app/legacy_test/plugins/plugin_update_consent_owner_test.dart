import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in [
    'same',
    'cancel',
    'other',
    'roundtrip',
    'no-frame',
    'refresh',
    'ready',
    'disconnected',
    'version-changed',
    'removed',
  ]) {
    testWidgets('update confirmation belongs to original host: $mode', (tester) async {
      final a = FakePluginCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => [bundleJson('dsh-approval-gate', version: '0.3.0')];
        carrier.handlers['pluginManager/removeBundle'] = (_) => {
          'stage': 'remove',
          'target': 'dsh-approval-gate',
          'changed': true,
          'application': 'applied',
        };
        carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: 'dsh-approval-gate');
      }
      final ah = fakeHost(ac, label: 'A');
      final bh = fakeHost(bc, kind: HostKind.portal, label: 'B');
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(initialTab: PluginsTab.market),
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
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(MarketCard, 'Approval Gate'),
          matching: find.byType(PluginInstallButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '更新到 0.4.0'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('会先卸载 0.3.0，再安装 0.4.0'), findsOneWidget);
      if (['other', 'roundtrip', 'no-frame'].contains(mode)) {
        c.read(activeHostProvider.notifier).select(HostRef.portal('fake-host'));
        c.read(switchConnectionProvider.notifier).set(bh);
        if (mode != 'no-frame') {
          await tester.pumpAndSettle();
          expect(c.read(pluginHostProvider)!.client, same(bc));
        }
        if (mode != 'other') {
          c.read(activeHostProvider.notifier).select(HostRef.none);
          c.read(switchConnectionProvider.notifier).set(ah);
          if (mode != 'no-frame') await tester.pumpAndSettle();
        }
      }
      if (mode == 'ready') {
        await ac.mux.ready(); // Real DshMux ready frame from the controlled link.
        await tester.pumpAndSettle();
      }
      if (mode == 'disconnected') {
        c.read(switchConnectionProvider.notifier).set(null);
        await tester.pumpAndSettle();
      }
      if (mode == 'refresh') {
        await c.read(installedPluginsProvider.notifier).refresh();
        await tester.pumpAndSettle();
      }
      if (['version-changed', 'removed'].contains(mode)) {
        a.handlers['pluginManager/listBundles'] = (_) =>
            mode == 'removed' ? <Object?>[] : [bundleJson('dsh-approval-gate', version: '0.5.0')];
        await c.read(installedPluginsProvider.notifier).refresh();
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(mode == 'cancel' ? TextButton : FilledButton, mode == 'cancel' ? '取消' : '更新'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更新「Approval Gate」？'), findsNothing);
      // A dispatched update on the phone ends in the restart offer; nothing else opens one.
      expect(find.text('需要重启引擎'), ['same', 'refresh'].contains(mode) ? findsOneWidget : findsNothing);
      expect(
        find.text('主机已切换，未执行'),
        !['same', 'refresh', 'cancel', 'version-changed', 'removed'].contains(mode) ? findsOneWidget : findsNothing,
      );
      if (!['same', 'refresh', 'cancel', 'version-changed', 'removed'].contains(mode)) {
        expect(snackBarOnTop(tester, '主机已切换，未执行'), isTrue, reason: 'never left under the plugin sheet');
      }
      List<String> writes(FakePluginCarrier carrier) => [
        for (final (endpoint, _) in carrier.calls)
          if (endpoint == 'pluginManager/removeBundle' || endpoint == 'pluginManager/installBundle') endpoint,
      ];
      expect(writes(b), isEmpty, reason: 'confirmation for A cannot remove/install B package');
      final normal = ['same', 'refresh'].contains(mode);
      expect(
        writes(a),
        normal ? ['pluginManager/removeBundle', 'pluginManager/installBundle'] : isEmpty,
        reason: 'retired or cancelled confirmation cannot dispatch',
      );
      if (normal) expect(a.argsOf('pluginManager/installBundle').single['spec'], 'dsh-approval-gate@0.4.0');
    });
  }
}
