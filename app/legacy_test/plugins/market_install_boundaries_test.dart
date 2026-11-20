import 'dart:async';

import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

class _Host extends Notifier<PluginHost?> {
  _Host(this.initial);
  final PluginHost? initial;
  @override
  PluginHost? build() => initial;
  void set(PluginHost? host) => state = host;
}

final _hostProvider = NotifierProvider<_Host, PluginHost?>(() => _Host(null));

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;
  late Completer<String?> integrity;
  final entry = officialFixtureMarket().byName['@dsh-go/media']!;

  setUp(() async {
    integrity = Completer<String?>();
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    carrier.handlers['pluginManager/installBundle'] = (_) => installResult(target: entry.name);
    carrier.handlers['pluginManager/removeBundle'] = (_) => installResult(target: entry.name);
    container = ProviderContainer(
      overrides: [
        ...pluginOverrides(fakeHost(client), npmIntegrity: (_, _) => integrity.future),
        _hostProvider.overrideWith(() => _Host(PluginHost.of(fakeHost(client)))),
        pluginHostProvider.overrideWith((ref) => ref.watch(_hostProvider)),
      ],
    );
    container.listen(pluginInstallsProvider, (_, _) {});
    await container.read(installedPluginsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await client.close();
  });

  test('a host switch during verification cancels without touching either host', () async {
    final result = container.read(pluginInstallsProvider.notifier).install(marketInstallRequest(entry));
    await pumpEventQueue();
    expect(container.read(pluginInstallsProvider)[entry.name]!.phase, PluginInstallPhase.verifying);
    container.read(_hostProvider.notifier).set(null);
    container.read(pluginInstallsProvider);
    integrity.complete(entry.listing!.integrity);
    expect((await result).phase, PluginInstallPhase.cancelled);
    expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
    expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  test('cancel during verification leaves the installed version untouched', () async {
    final controller = container.read(pluginInstallsProvider.notifier);
    final result = controller.install(marketInstallRequest(entry, replace: true));
    await pumpEventQueue();
    await controller.cancel(entry.name);
    integrity.complete(entry.listing!.integrity);
    expect((await result).phase, PluginInstallPhase.cancelled);
    expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
    expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
  });

  for (final reported in <String?>[null, 'sha512-different']) {
    test('verification $reported fails before removing an installed version', () async {
      final result = container
          .read(pluginInstallsProvider.notifier)
          .install(marketInstallRequest(entry, replace: true));
      integrity.complete(reported);
      expect((await result).phase, PluginInstallPhase.failed);
      expect(carrier.argsOf('pluginManager/installBundle'), isEmpty);
      expect(carrier.argsOf('pluginManager/removeBundle'), isEmpty);
    });
  }

  test('a verified update removes then installs the pinned version', () async {
    final result = container.read(pluginInstallsProvider.notifier).install(marketInstallRequest(entry, replace: true));
    integrity.complete(entry.listing!.integrity);
    expect((await result).phase, PluginInstallPhase.succeeded);
    expect(
      carrier.calls.where((call) => call.$1.contains('Bundle') && !call.$1.contains('list')).map((call) => call.$1),
      ['pluginManager/removeBundle', 'pluginManager/installBundle'],
    );
    expect(carrier.argsOf('pluginManager/installBundle').single['spec'], '@dsh-go/media@0.2.0');
  });
}
