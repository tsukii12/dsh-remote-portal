// Original independent R1 counterexample by reviewer W1; replayed here unchanged in behavior.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../chat/support/session_sync_host.dart' show HeldReplyCarrier, ReplyHold;

const _id = 'cold-projection-probe';

// Actual module snapshots, with controlled network ordering. This does not
// claim a full Host persistence/restart integration.
class _Probe {
  _Probe(this.raw, this.host, this.client, this.hold);
  final Map raw;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  late final ProviderContainer container;
  var baseline = 'latestResident';
  var query = 'detachedQuerySnapshot';
  var failQuery = false;
  var opens = 0;
  var reads = 0;
  late FakeMuxSocket socket;
  late String stream;
  int? get turns => container.read(sessionUsageProvider(_id)).turns;

  static Future<_Probe> start({bool emptyInitial = false, bool delayFirst = false}) async {
    final raw = jsonDecode(File('test/state/fixtures/control-baseline-real-module.json').readAsStringSync()) as Map;
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
      muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 20)]),
    );
    final p = _Probe(raw, host, client, hold);
    if (delayFirst) hold.arm('session/projections');
    if (emptyInitial) {
      p.baseline = 'before';
      p.query = 'emptyColdSnapshot';
    }
    host.handlers['session/projections'] = (_) {
      p.reads++;
      if (p.failQuery) {
        return {
          'ok': false,
          'error': {'code': 'probe/failed', 'message': 'controlled read failure'},
        };
      }
      return {
        'ok': true,
        'value': {'kind': 'sequenced', ...(raw[p.query] as Map).cast<String, Object?>()},
      };
    };
    host.onOpen = (socket, stream, endpoint, _) {
      if (endpoint != 'session/control') throw StateError(endpoint);
      p.socket = socket;
      p.stream = stream;
      p.opens++;
      if (!delayFirst || p.opens > 1) socket.item(stream, {'type': 'baseline', 'value': raw[p.baseline]});
    };
    p.container = ProviderContainer(
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true)))],
    );
    final sub = p.container.listen(sessionUsageProvider(_id), (_, _) {});
    addTearDown(() async {
      hold.finish();
      sub.close();
      p.container.dispose();
      await client.close();
      await host.close();
    });
    await p.until(() => p.opens == 1 && p.reads == 1 && (delayFirst || p.turns == (emptyInitial ? 0 : 1)));
    return p;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200; i++) {
      await tick();
      if (condition()) return;
    }
    fail('condition timed out: opens=$opens reads=$reads turns=$turns');
  }

  Future<void> tick() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await container.pump();
  }

  Future<void> reconnect(String nextBaseline) async {
    baseline = nextBaseline;
    final prior = opens;
    await host.sockets.last.ws.close(1001, 'controlled real reconnect');
    await until(() => opens == prior + 1);
  }

  void latestFrame() {
    final snapshot = raw['detachedQuerySnapshot'] as Map;
    socket.item(stream, {
      'type': 'projection',
      'sessionId': _id,
      'seq': snapshot['asOfSeq'],
      'key': 'sessionStats',
      'value': snapshot['values']['sessionStats'],
    });
  }
}

void main() {
  test('HTTP initial projection remains available when WebSocket cannot connect', () async {
    final raw = jsonDecode(File('test/state/fixtures/control-baseline-real-module.json').readAsStringSync()) as Map;
    final host = await FakeDsh.start();
    host.rejectWebSocket = true;
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final client = DshClient.withCarrier(
      DshHttpCarrier(connection),
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    var reads = 0;
    host.handlers['session/projections'] = (_) {
      reads++;
      return {
        'ok': true,
        'value': {'kind': 'sequenced', ...(raw['detachedQuerySnapshot'] as Map).cast<String, Object?>()},
      };
    };
    final c = ProviderContainer(
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true)))],
    );
    final sub = c.listen(sessionUsageProvider(_id), (_, _) {});
    addTearDown(() async {
      sub.close();
      c.dispose();
      await client.close();
      await host.close();
    });
    for (var i = 0; i < 100 && c.read(sessionUsageProvider(_id)).turns != 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await c.pump();
    }
    expect(c.read(sessionUsageProvider(_id)).turns, 1);
    expect(reads, 1);
    expect(client.mux.lastReadyGenerationNumber, 0);
    expect(host.sockets, isEmpty);
  });

  test('first received resident baseline retires initial seed from old mux', () async {
    final p = await _Probe.start(delayFirst: true);
    await p.hold.received!.future;
    final previous = p.client.mux.lastReadyGenerationNumber;
    await p.reconnect('before');
    await p.until(() => p.turns == 0);
    expect(p.client.mux.lastReadyGenerationNumber, greaterThan(previous));
    p.hold.finish();
    for (var i = 0; i < 10; i++) {
      await p.tick();
    }
    expect(
      p.turns,
      0,
      reason: 'initial read was physically completed before the reconnect but delivered after new generation baseline',
    );
    expect(p.reads, 1);
  });
}
