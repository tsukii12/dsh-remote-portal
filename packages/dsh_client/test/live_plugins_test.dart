/// Live plugin management against a running `dsh web`: lists bundles, then
/// installs and removes one small real plugin from npm.
///
/// Skipped unless `DSH_LIVE_URL` holds the launch URL (with `?token=`). It
/// changes the Host's `web` profile, so point it at a throwaway `DSH_HOME`:
/// ```sh
/// env -i PATH=... HOME=/tmp/x/home DSH_HOME=/tmp/x/home/.dsh dsh web --port 0 --no-open
/// DSH_LIVE_URL='http://127.0.0.1:41629/?token=...' dart test test/live_plugins_test.dart
/// ```
/// `DSH_LIVE_PLUGIN` overrides the spec (default `novel-writer@1.0.2`: 37 KB,
/// no dependencies, no build scripts). Needs pnpm on the Host and npm access.
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final spec = Platform.environment['DSH_LIVE_PLUGIN'] ?? 'novel-writer@1.0.2';
  final name = spec.substring(0, spec.lastIndexOf('@') > 0 ? spec.lastIndexOf('@') : spec.length);
  final skip = url == null ? 'set DSH_LIVE_URL to run live plugin tests' : null;

  group('live pluginManager', skip: skip, () {
    late DshClient client;

    setUpAll(() async {
      client = await DshClient.connect(launchUrl: url);
      final existing = await client.listBundles();
      if (existing.any((b) => b.name == name && b.installed)) {
        await client.removeBundle(name);
      }
    });

    tearDownAll(() async {
      try {
        final left = await client.listBundles();
        if (left.any((b) => b.name == name && b.installed)) await client.removeBundle(name);
      } finally {
        await client.close();
      }
    });

    test('listBundles: the base layer and DSH optional bundles', () async {
      final bundles = await client.listBundles();
      expect(bundles, isNotEmpty);
      final base = bundles.firstWhere((b) => b.name == '@deepseek-ai/dsh-base');
      expect(base.enabled, isTrue);
      expect(base.removable, isFalse);
      expect(base.rows, isNotEmpty);
      expect(bundles.where((b) => b.optional && b.official), isNotEmpty);
      expect(bundles.any((b) => b.name == name && b.installed), isFalse);
      final plugins = await client.listPlugins();
      expect(plugins.any((p) => p.entryId == 'include:plugin-manager'), isTrue);
    });

    test('inspect, unknown request ids', () async {
      final inspection = await client.inspectPlugin(spec);
      expect(inspection, isA<PluginInspectionAccepted>());
      final accepted = inspection as PluginInspectionAccepted;
      expect(accepted.name, name);
      expect(accepted.bundle, isTrue);
      expect(await client.cancelInstall('dsh-app-live-none'), PluginCancelStatus.notRunning);
      expect(await client.waitForInstall('dsh-app-live-none'), isNull);
    });

    test('install with progress events, switch off/on, remove', () async {
      final requestId = 'dsh-app-live-${DateTime.now().microsecondsSinceEpoch}';
      final events = <PluginManagerEvent>[];
      final sub = client.pluginManagerEvents.listen(events.add);
      addTearDown(sub.cancel);

      final installed = await client.installBundle(spec, requestId: requestId, enabled: true, saveExact: true);
      expect(installed.application, anyOf(PluginApplication.applied, PluginApplication.restartRequired));
      expect(installed.bundle, name);
      expect(installed.error, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final states = events.whereType<PluginInstallStateEvent>().where((e) => e.requestId == requestId);
      expect(states.map((e) => e.phase), containsAllInOrder(['installing', 'applying']));
      final logs = events.whereType<PluginInstallLogEvent>().where((e) => e.requestId == requestId);
      expect(logs.any((e) => e.finished && e.exitCode == 0), isTrue);
      expect(events.whereType<PluginManagerChangedEvent>().map((e) => e.reason), contains('install'));

      var bundle = (await client.listBundles()).firstWhere((b) => b.name == name);
      expect(bundle.installed, isTrue);
      expect(bundle.enabled, isTrue);
      expect(bundle.removable, isTrue);
      expect(bundle.source, isNotNull);

      final again = await client.installBundle(spec);
      expect(again.application, PluginApplication.failed);
      expect(again.error?.code, 'already-installed');

      final off = await client.setBundleEnabled(name, false);
      expect(off.succeeded, isTrue);
      bundle = (await client.listBundles()).firstWhere((b) => b.name == name);
      expect(bundle.enabled, isFalse);
      expect((await client.setBundleEnabled(name, true)).succeeded, isTrue);

      final removed = await client.removeBundle(name);
      expect(removed.succeeded, isTrue);
      expect((await client.listBundles()).any((b) => b.name == name && b.installed), isFalse);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a missing package fails as not-found and leaves the profile alone', () async {
      final result = await client.installBundle('dsh-app-definitely-missing-zz9@1.0.0');
      expect(result.application, PluginApplication.failed);
      expect(result.failureKind, 'not-found');
      expect(result.registries, isNotEmpty);
      expect((await client.listBundles()).any((b) => b.name == 'dsh-app-definitely-missing-zz9'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
