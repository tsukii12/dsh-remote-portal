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
  for (final mode in ['same', 'cancel', 'other', 'roundtrip', 'no-frame', 'refresh', 'ready', 'disconnected']) {
    testWidgets('build approval belongs to original host: $mode', (tester) async {
      final a = FakePluginCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
        carrier.handlers['pluginManager/installBundle'] = (args) {
          final options = args['options']! as Map;
          return options.containsKey('approvedBuilds')
              ? installResult(target: 'novel-writer')
              : installResult(application: 'failed', kind: 'build-blocked', pendingBuilds: ['esbuild']);
        };
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
          of: find.widgetWithText(MarketCard, 'novel-writer'),
          matching: find.byType(PluginInstallButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '安装到A'));
      await tester.pumpAndSettle();
      expect(a.argsOf('pluginManager/installBundle'), hasLength(1));
      expect(find.text('需要运行构建脚本'), findsOneWidget);
      await tester.ensureVisible(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许构建脚本并重试'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('• esbuild'), findsOneWidget);
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
      await tester.tap(
        find.widgetWithText(mode == 'cancel' ? TextButton : FilledButton, mode == 'cancel' ? '取消' : '允许并重试'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('主机已切换，未执行'), !['same', 'refresh', 'cancel'].contains(mode) ? findsOneWidget : findsNothing);
      if (!['same', 'refresh', 'cancel'].contains(mode)) {
        expect(snackBarOnTop(tester, '主机已切换，未执行'), isTrue, reason: 'never left under the plugin sheet');
      }
      List<Map<String, Object?>> approved(FakePluginCarrier carrier) => [
        for (final args in carrier.argsOf('pluginManager/installBundle'))
          if ((args['options']! as Map).containsKey('approvedBuilds')) args,
      ];
      expect(approved(b), isEmpty, reason: 'approval for A cannot be sent to B');
      final normal = ['same', 'refresh'].contains(mode);
      expect(approved(a), hasLength(normal ? 1 : 0), reason: 'retired or cancelled consent cannot dispatch');
      if (normal) expect((approved(a).single['options']! as Map)['approvedBuilds'], ['esbuild']);
    });
  }
}
