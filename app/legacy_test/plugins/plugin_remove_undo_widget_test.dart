import 'dart:async';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugin_actions.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_widgets.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../state/read_list_refresh_test.dart' show FixedHost, SwitchConnection, switchConnectionProvider;
import 'support/fake_plugin_host.dart';
import 'support/notice_on_top.dart';

void main() {
  for (final outcome in ['undo', 'success', 'failure']) {
    final undo = outcome == 'undo';
    testWidgets('market removal hides before dispatch and outcome=$outcome', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      var installed = true;
      carrier.handlers['pluginManager/listBundles'] = (_) => [
        if (installed) bundleJson('dsh-approval-gate', version: '0.4.0'),
      ];
      carrier.handlers['pluginManager/removeBundle'] = (_) {
        if (outcome == 'failure') {
          return {'stage': 'remove', 'target': 'dsh-approval-gate', 'application': 'failed'};
        }
        installed = false;
        return {'stage': 'remove', 'target': 'dsh-approval-gate', 'changed': true, 'application': 'applied'};
      };
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(const PluginsScreen(initialTab: PluginsTab.market), overrides: pluginOverrides(fakeHost(client))),
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
      await tester.tap(find.widgetWithText(OutlinedButton, '卸载'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      expect(find.byType(BundleSheet), findsNothing);
      expect(find.byType(MarketPluginSheet), findsNothing);
      expect(container.read(installedPluginsProvider).value, isEmpty);
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      final content = tester.widget<SnackBar>(find.byType(SnackBar)).content as Text;
      expect(snackBarOnTop(tester, content.data!), isTrue);
      if (undo) {
        await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
        await tester.pumpAndSettle();
        expect(container.read(installedPluginsProvider).value, hasLength(1));
        await tester.pump(const Duration(seconds: 5));
        expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
      } else {
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
        expect(find.widgetWithText(SnackBarAction, '撤销'), findsNothing);
        expect(container.read(installedPluginsProvider).value, outcome == 'failure' ? hasLength(1) : isEmpty);
        if (outcome == 'failure') {
          final content = tester.widget<SnackBar>(find.byType(SnackBar)).content as Text;
          expect(content.data, startsWith('没能卸载'));
          expect(snackBarOnTop(tester, content.data!), isTrue);
        } else {
          expect(find.byType(SnackBar), findsNothing, reason: 'the undo notice already said 已卸载');
        }
      }
    });
  }
  for (final invalid in [false, true]) {
    testWidgets('a newer plan sends the older one at once; a rejected one keeps its undo: invalid=$invalid', (
      tester,
    ) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      final first = PluginBundle.fromJson(bundleJson('first'));
      final second = PluginBundle.fromJson(bundleJson('second'));
      var inventory = [bundleJson('first'), bundleJson('second')];
      carrier.handlers['pluginManager/listBundles'] = (_) => inventory;
      carrier.handlers['pluginManager/removeBundle'] = (args) {
        inventory = inventory.where((b) => b['name'] != args['name']).toList();
        return {'stage': 'remove', 'target': args['name'], 'changed': true, 'application': 'applied'};
      };
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                ref.watch(installedPluginsProvider);
                return Column(
                  children: [
                    TextButton(onPressed: () => removePluginBundle(context, first), child: const Text('First')),
                    TextButton(onPressed: () => removePluginBundle(context, second), child: const Text('Second')),
                  ],
                );
              },
            ),
          ),
          overrides: pluginOverrides(fakeHost(client)),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.text('First')));
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      final oldUndo = tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;
      if (invalid) {
        inventory = [bundleJson('first'), bundleJson('second', version: '2.0.0')];
        await container.read(installedPluginsProvider.notifier).refresh();
      }
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      List<String> names() => container.read(installedPluginsProvider).value!.map((b) => b.name).toList();
      List<Object?> removed() => carrier.argsOf('pluginManager/removeBundle').map((a) => a['name']).toList();
      if (invalid) {
        // The second request is refused; the first keeps its window and 撤销.
        expect(names(), ['second']);
        expect(removed(), isEmpty);
      } else {
        // The first lost its notice, so it went to the Host at once.
        expect(removed(), ['first']);
        expect(names(), isEmpty);
        final text = (tester.widget<SnackBar>(find.byType(SnackBar)).content as Text).data!;
        expect(text, '已卸载「second」');
        oldUndo(); // The first was sent: its old 撤销 does nothing.
        await tester.pump();
        expect(removed(), ['first']);
        expect(names(), isEmpty);
      }
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pump(const Duration(seconds: 5));
      expect(removed(), invalid ? isEmpty : ['first']);
      expect(names(), invalid ? hasLength(2) : ['second']);
    });
  }
  for (final outcome in ['success', 'failure', 'throws']) {
    testWidgets('committing A result never steals waiting B undo: $outcome', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      final first = PluginBundle.fromJson(bundleJson('first'));
      final second = PluginBundle.fromJson(bundleJson('second'));
      var inventory = [bundleJson('first'), bundleJson('second')];
      final reply = Completer<Object?>();
      carrier.handlers['pluginManager/listBundles'] = (_) => inventory;
      carrier.handlers['pluginManager/removeBundle'] = (_) => reply.future;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                ref.watch(installedPluginsProvider);
                return Column(
                  children: [
                    TextButton(onPressed: () => removePluginBundle(context, first), child: const Text('First')),
                    TextButton(onPressed: () => removePluginBundle(context, second), child: const Text('Second')),
                  ],
                );
              },
            ),
          ),
          overrides: pluginOverrides(fakeHost(client)),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.text('First')));
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await tester.pumpAndSettle();
      final waitingText = (tester.widget<SnackBar>(find.byType(SnackBar)).content as Text).data!;
      expect(waitingText, contains('second'));
      if (outcome == 'throws') {
        reply.completeError(const DshRemoteException('DENIED', 'controlled failure'));
      } else {
        if (outcome == 'success') inventory = [bundleJson('second')];
        reply.complete({
          'stage': 'remove',
          'target': 'first',
          'changed': outcome == 'success',
          'application': outcome == 'success' ? 'applied' : 'failed',
        });
      }
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SnackBarAction, '撤销'),
        findsOneWidget,
        reason: 'A result must not replace B while B can still cancel',
      );
      expect(snackBarOnTop(tester, waitingText), isTrue);
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pumpAndSettle();
      expect(container.read(installedPluginsProvider).value!.map((b) => b.name), contains('second'));
      if (outcome != 'success') {
        expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, const Duration(seconds: 4));
      }
      await tester.pump(const Duration(seconds: 5));
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
    });
  }
  for (final next in ['third', 'host', 'route', 'dispose']) {
    testWidgets('deferred A result rechecks newer undo and owner: $next', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      var inventory = [
        for (final name in ['first', 'second', 'third']) bundleJson(name),
      ];
      final originals = inventory.map(PluginBundle.fromJson).toList();
      final reply = Completer<Object?>();
      carrier.handlers['pluginManager/listBundles'] = (_) => inventory;
      carrier.handlers['pluginManager/removeBundle'] = (args) {
        if (args['name'] == 'first') return reply.future;
        inventory = inventory.where((b) => b['name'] != args['name']).toList();
        return {'stage': 'remove', 'target': args['name'], 'changed': true, 'application': 'applied'};
      };
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                ref.watch(installedPluginsProvider);
                return Column(
                  children: [
                    for (final b in originals)
                      TextButton(onPressed: () => removePluginBundle(context, b), child: Text(b.name)),
                  ],
                );
              },
            ),
          ),
          overrides: [
            activeHostProvider.overrideWith(FixedHost.new),
            switchConnectionProvider.overrideWith(() => SwitchConnection(fakeHost(client))),
            activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
            readListIdentityProvider.overrideWithValue(null),
            localSafeModeProvider.overrideWithValue(false),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.text('first'));
      final container = ProviderScope.containerOf(context);
      final navigator = Navigator.of(context);
      Future<void> request(String name) async {
        await tester.tap(find.widgetWithText(TextButton, name));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '卸载'));
        await tester.pumpAndSettle();
      }

      await request('first');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await request('second');
      inventory = inventory.where((b) => b['name'] != 'first').toList();
      reply.complete({'stage': 'remove', 'target': 'first', 'changed': true, 'application': 'applied'});
      await tester.pumpAndSettle();
      expect(carrier.argsOf('pluginManager/removeBundle'), hasLength(1));
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      if (next == 'third') {
        final oldUndo = tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;
        await request('third');
        final text = (tester.widget<SnackBar>(find.byType(SnackBar)).content as Text).data!;
        expect(text, '已卸载「third」');
        expect(snackBarOnTop(tester, text), isTrue);
        oldUndo(); // second was sent when third took the window.
        await tester.pump();
        expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
        await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        expect(carrier.argsOf('pluginManager/removeBundle').map((a) => a['name']), ['first', 'second']);
      } else {
        if (next == 'host') {
          final other = FakePluginCarrier();
          other.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
          final otherClient = DshClient.withCarrier(other);
          addTearDown(otherClient.close);
          container.read(switchConnectionProvider.notifier).set(fakeHost(otherClient));
        } else if (next == 'route') {
          unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('new route')))));
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        if (next == 'host') {
          // Same Host, new connection: second was dropped before sending and
          // its row is back, so the page says it was not uninstalled. A's
          // result is not shown on the new connection.
          expect(find.text('没能卸载'), findsOneWidget);
          expect(find.widgetWithText(SnackBarAction, '撤销'), findsNothing);
        } else {
          expect(find.byType(SnackBar), findsNothing, reason: 'retired results are never published to a new owner');
        }
        if (next == 'route') expect(find.text('new route'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
