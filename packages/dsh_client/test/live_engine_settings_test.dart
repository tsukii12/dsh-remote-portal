/// Live settings forms against a running `dsh web`: describe, a write and its
/// undo, a stale revision, a refused value and the plugin inventory.
///
/// Skipped unless `DSH_LIVE_URL` holds the launch URL (with `?token=`). It
/// writes `subagent.maxDepth` (and puts it back), so point it at a throwaway
/// `HOME`:
/// ```sh
/// env -i PATH=... HOME=/tmp/x/home dsh web --port 0 --no-open
/// DSH_LIVE_URL='http://127.0.0.1:41629/?token=...' dart test test/live_engine_settings_test.dart
/// ```
@Tags(['live'])
library;

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final skip = url == null ? 'set DSH_LIVE_URL to run live settings tests' : null;

  group('live settings', skip: skip, () {
    late DshClient client;

    setUpAll(() async => client = await DshClient.connect(launchUrl: url));
    tearDownAll(() async => client.close());

    test('describe carries schemas, layers and secret slots', () async {
      final described = await client.describeSettings();
      final subagent = described.namespaces['subagent']!;
      expect(subagent.schema.fields!['maxDepth']!.meta.min, 0);
      expect(subagent.base?['maxDepth'], isA<int>());
      final search = described.namespaces['web-search-deepseek'];
      if (search != null) expect(search.secrets.map((s) => s.path.join('.')), contains('apiKey'));
    });

    test('set, conflict, rejection and unset', () async {
      final before = (await client.describeSettings()).namespaces['subagent']!;
      final target = (before.value['maxDepth']! as int) + 2;
      final after = await client.mutateSettingsView('subagent', [
        SettingsOp.set(['maxDepth'], target),
      ], expectedRevision: before.revision);
      expect(after.value['maxDepth'], target);
      expect(after.user?['maxDepth'], target);
      expect(after.revision, greaterThan(before.revision));

      await expectLater(
        client.mutateSettingsView('subagent', [
          const SettingsOp.set(['maxDepth'], 0),
        ], expectedRevision: before.revision),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'settings/conflict')),
      );
      await expectLater(
        client.mutateSettingsView('subagent', [
          const SettingsOp.set(['maxDepth'], -1),
        ]),
        throwsA(
          isA<DshRemoteException>()
              .having((e) => e.code, 'code', 'settings/rejected')
              .having((e) => e.message, 'message', contains('>= 0')),
        ),
      );

      final reset = await client.mutateSettingsView('subagent', [
        const SettingsOp.unset(['maxDepth']),
      ], expectedRevision: after.revision);
      expect(reset.value['maxDepth'], before.base?['maxDepth']);
      expect(reset.user?.containsKey('maxDepth') ?? false, isFalse);
    });

    test('plugin inventory lists the Loader entries', () async {
      final inventory = await client.pluginInventory();
      expect(inventory.entries, isNotEmpty);
      expect(inventory.entries.where((e) => e.enabled && e.fiberPhase == 'active'), isNotEmpty);
    });
  });
}
