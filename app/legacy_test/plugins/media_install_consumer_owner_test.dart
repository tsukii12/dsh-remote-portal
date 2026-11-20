import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/ui/settings/media_settings_page.dart';
import 'package:dsh_app/update/version.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../state/read_list_refresh_test.dart' show FixedHost, SwitchConnection, switchConnectionProvider;
import 'support/fake_plugin_host.dart';

// Gate only reconnection establishment; preserve the real DshMux state machine.
class _RecoveryCarrier extends FakePluginCarrier {
  Completer<void>? reopen;

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    await reopen?.future;
    return super.openLink(options);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scenario in ['success', 'failure', 'covered', 'host', 'roundtrip', 'closed', 'recover', 'first-ready', 'client']) {
    testWidgets('real media sheet owns its completion: $scenario', (tester) async {
      final a = _RecoveryCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      final ah = fakeHost(ac, label: 'A');
      final bh = fakeHost(bc, kind: HostKind.portal, label: 'B');
      final reply = Completer<Object?>();
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
      }
      a.handlers['pluginManager/installBundle'] = (_) => reply.future;
      if (scenario != 'first-ready') await ac.mux.ready();
      usePhoneView(tester);
      late BuildContext origin;
      var sheetCompleted = false;
      await tester.pumpWidget(testApp(
        Scaffold(body: Builder(builder: (context) {
          origin = context;
          return TextButton(
            onPressed: () async {
              await showMediaInstallSheet(context);
              sheetCompleted = true;
            },
            child: const Text('Open media'),
          );
        })),
        overrides: [
          activeHostProvider.overrideWith(FixedHost.new),
          switchConnectionProvider.overrideWith(() => SwitchConnection(ah)),
          activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
          readListIdentityProvider.overrideWithValue(null),
          localSafeModeProvider.overrideWithValue(false),
          marketIndexFetcherProvider.overrideWithValue((url) async => parseMarketIndex(sampleIndex, url)),
          officialMarketFetcherProvider.overrideWithValue(() async => officialFixtureMarket()),
          npmIntegrityProvider.overrideWithValue((name, _) async => officialFixtureMarket().byName[name]?.listing?.integrity),
          appVersionProvider.overrideWithValue(AppVersion.tryParse('1.0.11')!),
        ],
      ));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(origin);
      await tester.tap(find.text('Open media'));
      await tester.pumpAndSettle();
      final sheetContext = tester.element(find.byType(MediaInstallPrompt));
      final sheetRoute = ModalRoute.of(sheetContext)!;
      final navigator = Navigator.of(sheetContext);
      await tester.tap(find.text('在此主机上安装'));
      await tester.pump();
      await tester.pump();
      expect(a.argsOf('pluginManager/installBundle'), hasLength(1));
      expect(sheetRoute.isCurrent, isTrue);
      if (scenario == 'first-ready') {
        // HTTP/plugin RPCs can be pending before the first mux is started.
        // Cross that boundary while the real install is still unresolved.
        expect(ac.mux.generation, isNull);
        expect(ac.mux.lastReadyGenerationNumber, 0);
        expect(reply.isCompleted, isFalse);
        final hostBeforeReady = container.read(activeHostProvider);
        expect(container.read(activeConnectionProvider).value?.client, same(ac));
        final ready = ac.mux.ready();
        await tester.pump();
        final firstGeneration = await ready;
        await tester.pump();
        expect(ac.mux.generation, same(firstGeneration));
        expect(ac.mux.lastReadyGenerationNumber, 1);
        expect(container.read(activeHostProvider), hostBeforeReady);
        expect(container.read(activeConnectionProvider).value?.client, same(ac));
        expect(reply.isCompleted, isFalse);
        expect(sheetRoute.isCurrent, isTrue);
      }
      var destinationCompleted = false;
      if (scenario == 'covered') {
        unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New destination')),
        )).then((_) => destinationCompleted = true));
        await tester.pumpAndSettle();
        expect(sheetContext.mounted, isTrue, reason: 'the old sheet remains mounted under the new route');
        expect(sheetRoute.isCurrent, isFalse);
      }
      if (scenario == 'host' || scenario == 'roundtrip') {
        container.read(activeHostProvider.notifier).select(const HostRef.portal('fake-host'));
        container.read(switchConnectionProvider.notifier).set(bh);
        if (scenario == 'roundtrip') {
          // No frame between A -> B -> A: final equality cannot prove ownership.
          container.read(activeHostProvider.notifier).select(HostRef.none);
          container.read(switchConnectionProvider.notifier).set(ah);
        }
        await tester.pump();
        expect(sheetContext.mounted, isTrue);
      }
      if (scenario == 'client') {
        // Same selected Host, but a different underlying client owns the screen.
        container.read(switchConnectionProvider.notifier).set(fakeHost(bc, label: 'Replacement A'));
        await tester.pump();
      }
      Future<PluginInstallJob>? recoveredJob;
      final recoveredReply = Completer<Object?>();
      if (scenario == 'recover') {
        final originalHost = container.read(pluginHostProvider)!;
        final originalGeneration = ac.mux.generation;
        final running = container.read(pluginInstallsProvider).values.single;
        // Observe the actual controller result via its existing duplicate waiter.
        // This does not submit another RPC.
        recoveredJob = container.read(pluginInstallsProvider.notifier).install(running.request);
        a.handlers['pluginManager/waitForInstall'] = (_) => recoveredReply.future;
        a.reopen = Completer<void>();
        ac.mux.reconnect();
        await tester.pump();
        expect(ac.mux.state, DshConnectionState.reconnecting);
        expect(container.read(readListLiveConnectionProvider), isNull);
        expect(container.read(pluginHostProvider), isNull);
        expect(container.read(activeConnectionProvider).value?.client, same(ac));
        expect(sheetRoute.isCurrent, isTrue);
        reply.completeError(const DshTransportException('controlled lost install response'));
        await tester.pump();
        await tester.pump();
        expect(a.argsOf('pluginManager/waitForInstall'), hasLength(1));
        expect(a.argsOf('pluginManager/waitForInstall').single['requestId'], running.requestId);
        // The reconnect backoff advances in the widget clock; openLink stays gated.
        await tester.pump(const Duration(seconds: 1));
        a.reopen!.complete();
        await tester.pump();
        await ac.mux.ready();
        await tester.pump();
        final restoredHost = container.read(pluginHostProvider)!;
        expect(restoredHost, isNot(same(originalHost)));
        expect(restoredHost.client, same(ac));
        expect(ac.mux.generation, isNot(same(originalGeneration)));
        expect(container.read(activeHostProvider), HostRef.none);
        recoveredReply.complete(installResult(target: '@dsh-go/media', application: 'applied'));
      }
      if (scenario == 'closed') {
        navigator.pop();
        await tester.pumpAndSettle();
        unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('New destination')),
        )).then((_) => destinationCompleted = true));
        await tester.pumpAndSettle();
      }
      if (scenario == 'failure') {
        reply.completeError(const DshRemoteException('DENIED', 'controlled installation failure'));
      } else if (scenario != 'recover') {
        reply.complete(installResult(target: '@dsh-go/media', application: 'applied'));
      }
      await tester.pumpAndSettle();
      expect(b.argsOf('pluginManager/installBundle'), isEmpty);
      if (scenario == 'recover') {
        expect((await recoveredJob!).phase, PluginInstallPhase.succeeded);
        expect(a.argsOf('pluginManager/installBundle'), hasLength(1));
        expect(b.argsOf('pluginManager/waitForInstall'), isEmpty);
      }
      if (scenario == 'success' || scenario == 'recover' || scenario == 'first-ready') {
        expect(sheetCompleted, isTrue);
        expect(sheetRoute.isActive, isFalse);
      } else if (scenario == 'covered' || scenario == 'closed') {
        expect(destinationCompleted, isFalse, reason: 'old installation must not pop the new route');
        expect(find.text('New destination'), findsOneWidget);
        if (scenario == 'covered') expect(sheetCompleted, isFalse);
      } else {
        expect(sheetCompleted, isFalse, reason: 'failure or retired Host cannot close this sheet');
        expect(sheetRoute.isCurrent, isTrue);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
