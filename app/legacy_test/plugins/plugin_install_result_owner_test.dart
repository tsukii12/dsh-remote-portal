import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/read_list_refresh_test.dart' show FixedHost, SwitchConnection, switchConnectionProvider;
import 'support/fake_plugin_host.dart';

Future<void> flush(ProviderContainer c) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await c.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const request = PluginInstallRequest(name: 'owner-plugin', spec: 'owner-plugin@1.0.0');

  for (final mode in ['old-first', 'new-first', 'same']) {
    test('installation caller keeps request identity: $mode', () async {
      final a = FakePluginCarrier();
      final b = FakePluginCarrier();
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      addTearDown(ac.close);
      addTearDown(bc.close);
      final ar = Completer<Object?>();
      final br = Completer<Object?>();
      a.handlers['pluginManager/installBundle'] = (_) => ar.future;
      b.handlers['pluginManager/installBundle'] = (_) => br.future;
      for (final carrier in [a, b]) {
        carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
      }
      final c = ProviderContainer(
        overrides: [
          activeHostProvider.overrideWith(FixedHost.new),
          switchConnectionProvider.overrideWith(() => SwitchConnection(fakeHost(ac))),
          activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
          readListIdentityProvider.overrideWithValue(null),
          localSafeModeProvider.overrideWithValue(false),
        ],
      );
      addTearDown(c.dispose);
      c.listen(pluginInstallsProvider, (_, _) {});
      final controller = c.read(pluginInstallsProvider.notifier);
      final first = controller.install(request);
      await flush(c);
      final original = c.read(pluginInstallsProvider)[request.name]!;
      expect(a.argsOf('pluginManager/installBundle'), hasLength(1));
      final duplicate = controller.install(request);
      if (mode == 'same') {
        ar.complete(installResult(target: request.name));
        final results = await Future.wait([first, duplicate]);
        expect(results.map((j) => j.requestId), everyElement(original.requestId));
        expect(results.map((j) => j.phase), everyElement(PluginInstallPhase.succeeded));
        expect(a.argsOf('pluginManager/installBundle'), hasLength(1));
        expect(b.argsOf('pluginManager/installBundle'), isEmpty);
        return;
      }
      c.read(switchConnectionProvider.notifier).set(fakeHost(bc));
      await flush(c);
      final second = c.read(pluginInstallsProvider.notifier).install(request);
      await flush(c);
      final newer = c.read(pluginInstallsProvider)[request.name]!;
      expect(newer.requestId, isNot(original.requestId));
      expect(b.argsOf('pluginManager/installBundle'), hasLength(1));
      PluginInstallJob? oldResult;
      if (mode == 'old-first') {
        ar.complete(installResult(target: request.name));
        oldResult = await first;
        expect(c.read(pluginInstallsProvider)[request.name]!.requestId, newer.requestId);
        expect(c.read(pluginInstallsProvider)[request.name]!.isActive, isTrue);
      }
      br.complete(installResult(target: request.name));
      final newResult = await second;
      if (mode == 'new-first') {
        ar.complete(installResult(target: request.name));
        oldResult = await first;
      }
      final duplicateResult = await duplicate.timeout(const Duration(seconds: 2));
      expect(newResult.requestId, newer.requestId);
      expect(
        [oldResult!.requestId, duplicateResult.requestId],
        [original.requestId, original.requestId],
        reason: 'both original caller and duplicate waiter belong to A request',
      );
      expect(oldResult.isActive, isFalse, reason: 'completed future must contain a terminal result');
      expect(duplicateResult.isActive, isFalse);
    });
  }

  test('retired queued request and duplicate resolve their own cancellation', () async {
    final a = FakePluginCarrier();
    final b = FakePluginCarrier();
    final ac = DshClient.withCarrier(a);
    final bc = DshClient.withCarrier(b);
    addTearDown(ac.close);
    addTearDown(bc.close);
    final ar = Completer<Object?>();
    final br = Completer<Object?>();
    a.handlers['pluginManager/installBundle'] = (_) => ar.future;
    b.handlers['pluginManager/installBundle'] = (_) => br.future;
    for (final carrier in [a, b]) {
      carrier.handlers['pluginManager/listBundles'] = (_) => <Object?>[];
    }
    final c = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(FixedHost.new),
        switchConnectionProvider.overrideWith(() => SwitchConnection(fakeHost(ac))),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        readListIdentityProvider.overrideWithValue(null),
        localSafeModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);
    c.listen(pluginInstallsProvider, (_, _) {});
    final controller = c.read(pluginInstallsProvider.notifier);
    final blocker = controller.install(const PluginInstallRequest(name: 'blocker', spec: 'blocker@1.0.0'));
    await flush(c);
    final queued = controller.install(request);
    final duplicate = controller.install(request);
    final original = c.read(pluginInstallsProvider)[request.name]!;
    expect(original.phase, PluginInstallPhase.queued);
    c.read(switchConnectionProvider.notifier).set(fakeHost(bc));
    await flush(c);
    final next = c.read(pluginInstallsProvider.notifier).install(request);
    await flush(c);
    ar.complete(installResult(target: 'blocker'));
    await blocker;
    final oldResult = await queued;
    br.complete(installResult(target: request.name));
    await next;
    final duplicateResult = await duplicate.timeout(const Duration(seconds: 2));
    expect(a.argsOf('pluginManager/installBundle'), hasLength(1), reason: 'retired queued request never dispatches');
    expect([oldResult.requestId, duplicateResult.requestId], [original.requestId, original.requestId]);
    expect([oldResult.phase, duplicateResult.phase], everyElement(PluginInstallPhase.cancelled));
  });
}
