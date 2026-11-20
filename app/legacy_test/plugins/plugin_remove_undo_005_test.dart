import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
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
  for (final outcome in [
    'success',
    'failed',
    'throws',
    'restart',
    'cancel',
    'consent-host',
    'pending-host',
    'pending-roundtrip',
    'pending-dismiss',
    'pending-route',
  ]) {
    testWidgets('market uninstall notice and owner: $outcome', (tester) async {
      final carrier = FakePluginCarrier();
      final other = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      final otherClient = DshClient.withCarrier(other);
      addTearDown(client.close);
      addTearDown(otherClient.close);
      final host = fakeHost(client);
      for (final c in [carrier, other]) {
        c.handlers['pluginManager/listBundles'] = (_) => [bundleJson('dsh-approval-gate', version: '0.4.0')];
      }
      final reply = Completer<Object?>();
      carrier.handlers['pluginManager/removeBundle'] = (_) => reply.future;
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          const PluginsScreen(initialTab: PluginsTab.market),
          overrides: [
            activeHostProvider.overrideWith(FixedHost.new),
            switchConnectionProvider.overrideWith(() => SwitchConnection(host)),
            activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
            readListIdentityProvider.overrideWithValue(null),
            localSafeModeProvider.overrideWithValue(false),
            marketIndexFetcherProvider.overrideWithValue((url) async => parseMarketIndex(sampleIndex, url)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(PluginsScreen)));
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(MarketCard, 'Approval Gate'),
          matching: find.byType(PluginInstallButton),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '管理'));
      await tester.pumpAndSettle();
      final sheetContext = tester.element(find.byType(BundleSheet));
      final navigator = Navigator.of(sheetContext);
      await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
      await tester.pumpAndSettle();
      if (outcome == 'consent-host') {
        container.read(switchConnectionProvider.notifier).set(fakeHost(otherClient));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        outcome == 'cancel' ? find.widgetWithText(TextButton, '取消') : find.widgetWithText(FilledButton, '卸载'),
      );
      await tester.pumpAndSettle();
      if (outcome == 'cancel' || outcome == 'consent-host') {
        expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
        if (outcome == 'cancel') {
          expect(find.byType(BundleSheet), findsOneWidget);
          expect(find.byType(SnackBar), findsNothing);
        } else {
          expect(find.byType(BottomSheet), findsNothing);
          expect(snackBarOnTop(tester, '主机已切换，未执行'), isTrue);
        }
        return;
      }
      expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.pump(InstalledPluginsController.removalUndoWindow);
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
      if (outcome == 'pending-host' || outcome == 'pending-roundtrip') {
        container.read(switchConnectionProvider.notifier).set(fakeHost(otherClient));
        if (outcome == 'pending-roundtrip') {
          await tester.pumpAndSettle();
          container.read(switchConnectionProvider.notifier).set(host);
        }
      } else if (outcome == 'pending-dismiss') {
        unawaited(
          navigator.pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('replacement route'))),
          ),
        );
      } else if (outcome == 'pending-route') {
        unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('other route')))));
      }
      await tester.pumpAndSettle();
      if (outcome == 'throws') {
        reply.completeError(const DshRemoteException('unknown', 'test failure'));
      } else {
        reply.complete({
          'target': 'dsh-approval-gate',
          'changed': outcome != 'failed',
          'application': outcome == 'failed'
              ? 'failed'
              : outcome == 'restart'
              ? 'restart-required'
              : 'applied',
        });
      }
      await tester.pumpAndSettle();
      expect(other.argsOf('pluginManager/removeBundle'), isEmpty);
      if (outcome.startsWith('pending-')) {
        expect(find.byType(SnackBar), findsNothing, reason: 'retired UI cannot report on a new owner or route');
        if (outcome == 'pending-route') expect(find.text('other route'), findsOneWidget);

        if (outcome == 'pending-host') expect(find.byType(BottomSheet), findsNothing);
      } else if (outcome == 'success') {
        // The undo notice already said 已卸载; a plain success adds nothing.
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
      } else {
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        final text = tester
            .widget<Text>(find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).first)
            .data!;
        expect(text, contains(outcome == 'restart' ? '已卸载' : '没能卸载'));
        expect(
          snackBarOnTop(tester, text),
          isTrue,
          reason: 'notice must be hit-testable above the dismissed outer market sheet',
        );
      }
    });
  }
}
