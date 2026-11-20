import 'dart:async';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_plugin_host.dart';

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;
  late Completer<Object?> first;
  late int reads;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() async {
    container.dispose();
    await client.close();
  });

  Future<void> begin(WidgetTester tester) async {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    await client.mux.ready();
    first = Completer<Object?>();
    reads = 0;
    carrier.handlers['pluginManager/listBundles'] = (_) => ++reads == 1 ? first.future : [bundleJson('new-plugin')];
    container = ProviderContainer(overrides: pluginOverrides(fakeHost(client)));
    container.listen(installedPluginsProvider, (_, _) {});
    await tester.pump();
    expect(reads, 1);
  }

  Future<void> changed(WidgetTester tester, {bool ready = false}) async {
    if (ready) {
      carrier.link!.push({
        'type': 'ready',
        'clientId': 'client-reconnected',
        'host': {'home': '/home/u'},
      });
    } else {
      carrier.emit('plugin-manager/changed', {'reason': 'install'});
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(reads, 1, reason: 'the initial request still owns its pending reply');
  }

  for (final event in ['changed', 'ready', 'burst']) {
    testWidgets('$event during the initial plugin read refreshes after that read', (tester) async {
      await begin(tester);
      await changed(tester, ready: event == 'ready');
      if (event == 'burst') await changed(tester);
      first.complete([bundleJson('old-plugin')]);
      await tester.pump();
      await tester.pump();

      expect(container.read(installedPluginsProvider).value?.map((bundle) => bundle.name), ['new-plugin']);
      expect(reads, 2, reason: 'later Host changes require one follow-up to the earlier reply');
    });
  }

  testWidgets('a later Host change can refresh after the initial read fails', (tester) async {
    await begin(tester);
    final initialFailure = expectLater(
      container.read(installedPluginsProvider.future),
      throwsA(isA<DshRemoteException>()),
    );
    await changed(tester);
    first.completeError(const DshRemoteException('test/initial-read-failed', 'Synthetic read failure'));
    await tester.pump();
    await initialFailure;
    await tester.pump();

    expect(container.read(installedPluginsProvider).value?.map((bundle) => bundle.name), ['new-plugin']);
    expect(reads, 2);
  });

  testWidgets('a queued change cannot refresh either Host after its owner is replaced', (tester) async {
    await begin(tester);
    await changed(tester);
    final other = FakePluginCarrier();
    final otherClient = DshClient.withCarrier(other);
    addTearDown(otherClient.close);
    other.handlers['pluginManager/listBundles'] = (_) => [bundleJson('other-host-plugin')];
    container.updateOverrides(pluginOverrides(fakeHost(otherClient)));
    await tester.pump(Duration.zero);
    expect(container.read(installedPluginsProvider).value?.map((bundle) => bundle.name), ['other-host-plugin']);
    first.complete([bundleJson('old-plugin')]);
    await tester.pump();
    await tester.pump();

    expect(container.read(installedPluginsProvider).value?.map((bundle) => bundle.name), ['other-host-plugin']);
    expect(reads, 1);
    expect(other.argsOf('pluginManager/listBundles'), hasLength(1));
  });
}
