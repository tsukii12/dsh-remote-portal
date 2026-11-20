import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> fail(String code, String message) => {
  'ok': false,
  'error': {'code': code, 'message': message, 'details': <String, Object?>{}},
};

/// An inventory row as `dynamicCordisRunner/inventory` returns it
/// (`DynamicCordisInventoryRow`, DSH 0.2.1-rc.2).
const _clock = {
  'pluginId': 'clock-a1b2',
  'agentId': 'session-1',
  'packages': [
    {'packageId': 'pkg-1', 'name': '桌面时钟', 'purpose': '在侧边栏显示时间', 'hasHostHalf': true, 'hasClientHalf': true},
    {'packageId': 'pkg-2', 'name': '桌面时钟', 'purpose': '在侧边栏显示时间和日期', 'hasHostHalf': true, 'hasClientHalf': true},
  ],
  'currentPackageId': 'pkg-1',
  'activeRun': {'pluginRunId': 'run-7', 'packageId': 'pkg-1'},
  'latestRun': {
    'pluginRunId': 'run-7',
    'packageId': 'pkg-1',
    'mode': 'run',
    'status': 'running',
    'host': {'status': 'running', 'waitingFor': <String>[]},
    'client': {'status': 'running', 'waitingFor': <String>[]},
  },
};

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(client.close);
    return client;
  }

  group('inventory', () {
    test('parses rows; drops rows without their identities', () async {
      host.handlers['dynamicCordisRunner/inventory'] = (args) {
        expect(args, isEmpty);
        return ok([
          _clock,
          {'pluginId': 'no-agent'},
          {'agentId': 'session-2'},
        ]);
      };
      final rows = await (await connect()).cordisInventory();
      expect(rows, hasLength(1));
      final clock = rows.single;
      expect(clock.pluginId, 'clock-a1b2');
      expect(clock.agentId, 'session-1');
      expect(clock.packages.map((p) => p.packageId), ['pkg-1', 'pkg-2']);
      expect(clock.shown!.packageId, 'pkg-1');
      expect(clock.name, '桌面时钟');
      expect(clock.purpose, '在侧边栏显示时间');
      expect(clock.running, isTrue);
      expect(clock.active!.packageId, 'pkg-1');
      expect(clock.hasInterface, isTrue);
      expect(clock.status, CordisPluginStatus.running);
      expect(clock.latestRun!.hostStatus, 'running');
    });

    test('a fresh Host answers an empty list', () async {
      host.handlers['dynamicCordisRunner/inventory'] = (_) => ok(<Object?>[]);
      expect(await (await connect()).cordisInventory(), isEmpty);
    });

    test('Host errors surface as DshRemoteException', () async {
      host.handlers['dynamicCordisRunner/inventory'] = (_) => fail('gateway/unknown-endpoint', 'no such endpoint');
      await expectLater(
        (await connect()).cordisInventory(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'gateway/unknown-endpoint')),
      );
    });
  });

  group('status', () {
    CordisPlugin row(Map<String, Object?> patch) => CordisPlugin.fromJson({..._clock, ...patch})!;

    test('a pending switch is the version shown; its failure reads failed', () {
      final failed = row({
        'nextPackageId': 'pkg-2',
        'activeRun': null,
        'latestRun': {
          'pluginRunId': 'run-8',
          'packageId': 'pkg-2',
          'mode': 'update',
          'status': 'failed',
          'host': {'status': 'failed', 'waitingFor': <String>[]},
          'client': {'status': 'absent', 'waitingFor': <String>[]},
          'error': {
            'phase': 'host-apply',
            'message': 'ctx.fs is not a function',
            'stack': 'at apply (vm:3:7)',
            'pluginId': 'clock-a1b2',
            'packageId': 'pkg-2',
            'pluginRunId': 'run-8',
          },
        },
      });
      expect(failed.shown!.packageId, 'pkg-2');
      expect(failed.purpose, '在侧边栏显示时间和日期');
      expect(failed.status, CordisPluginStatus.failed);
      expect(failed.failure!.phase, 'host-apply');
      expect(failed.failure!.message, 'ctx.fs is not a function');
    });

    test('a failure of another version does not mark the row', () {
      final plugin = row({
        'latestRun': {'pluginRunId': 'run-6', 'packageId': 'pkg-0', 'status': 'failed'},
      });
      expect(plugin.status, CordisPluginStatus.running);
      expect(plugin.failure, isNull);
    });

    test('awaiting approval wins over everything', () {
      final plugin = row({
        'latestRun': {
          'pluginRunId': 'run-9',
          'packageId': 'pkg-1',
          'status': 'awaiting-approval',
          'requiresApproval': true,
          'approvalRequestId': 'req-1',
        },
      });
      expect(plugin.status, CordisPluginStatus.awaitingApproval);
      expect(plugin.latestRun!.requiresApproval, isTrue);
    });

    test('stopped reads idle; a Host half coming up reads starting', () {
      expect(row({'activeRun': null, 'latestRun': null}).status, CordisPluginStatus.idle);
      expect(
        row({
          'activeRun': null,
          'latestRun': {'pluginRunId': 'run-9', 'packageId': 'pkg-1', 'status': 'starting-host'},
        }).status,
        CordisPluginStatus.starting,
      );
    });

    test('a nameless version falls back to the plugin id', () {
      final plugin = row({
        'packages': [
          {'packageId': 'pkg-1', 'name': '  '},
        ],
      });
      expect(plugin.name, 'clock-a1b2');
      expect(plugin.purpose, '');
      expect(plugin.hasInterface, isFalse);
    });
  });

  group('panel verbs', () {
    final plugin = CordisPlugin.fromJson(_clock)!;

    test('stopFromPanel sends the owner and the plugin', () async {
      host.handlers['dynamicCordisRunner/stopFromPanel'] = (args) {
        expect(args, {'agentId': 'session-1', 'pluginId': 'clock-a1b2'});
        return ok({'ok': true});
      };
      expect(await (await connect()).stopCordisPlugin(plugin), CordisStopOutcome.stopped);
    });

    test('stopFromPanel refusals map to outcomes', () async {
      final client = await connect();
      host.handlers['dynamicCordisRunner/stopFromPanel'] = (_) =>
          ok({'ok': false, 'reason': 'not-running', 'message': 'plugin is not running'});
      expect(await client.stopCordisPlugin(plugin), CordisStopOutcome.notRunning);
      host.handlers['dynamicCordisRunner/stopFromPanel'] = (_) =>
          ok({'ok': false, 'reason': 'plugin-missing', 'message': 'no such plugin'});
      expect(await client.stopCordisPlugin(plugin), CordisStopOutcome.missing);
    });

    test('undefineFromPanel: true when removed, false when already gone', () async {
      final client = await connect();
      host.handlers['dynamicCordisRunner/undefineFromPanel'] = (args) {
        expect(args, {'agentId': 'session-1', 'pluginId': 'clock-a1b2'});
        return ok({'ok': true, 'wasRunning': true});
      };
      expect(await client.removeCordisPlugin(plugin), isTrue);
      host.handlers['dynamicCordisRunner/undefineFromPanel'] = (_) =>
          ok({'ok': false, 'reason': 'plugin-missing', 'message': 'no such plugin'});
      expect(await client.removeCordisPlugin(plugin), isFalse);
    });

    test('an unknown conversation throws session/not-found', () async {
      host.handlers['dynamicCordisRunner/undefineFromPanel'] = (_) =>
          fail('session/not-found', 'session "nope" not found');
      await expectLater(
        (await connect()).removeCordisPlugin(plugin),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/not-found')),
      );
    });
  });

  test('the HTTP carrier reaches the inventory', () async {
    expect((await connect()).canReadCordis, isTrue);
  });
}
