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

  static Future<_Probe> start({bool emptyInitial = false}) async {
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
      socket.item(stream, {'type': 'baseline', 'value': raw[p.baseline]});
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
    await p.until(() => p.opens == 1 && p.reads == 1 && p.turns == (emptyInitial ? 0 : 1));
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
  test('new live frame beats a held cold-session refresh snapshot', () async {
    final p = await _Probe.start(emptyInitial: true);
    p.query = 'emptyColdSnapshot';
    p.hold.arm('session/projections');
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
    p.latestFrame();
    await p.until(() => p.turns == 1);
    p.hold.finish();
    for (var i = 0; i < 10; i++) {
      await p.tick();
    }
    expect(p.turns, 1);
  });

  test('later resident baseline retires an older held cold refresh', () async {
    final p = await _Probe.start();
    p.hold.arm('session/projections');
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
    await p.reconnect('before');
    await p.until(() => p.turns == 0);
    p.hold.finish();
    for (var i = 0; i < 10; i++) {
      await p.tick();
    }
    expect(p.turns, 0);
    expect(p.reads, 2, reason: 'present baseline does not need an extra query');
  });

  test('failed cold refresh retains the visible cache', () async {
    final p = await _Probe.start();
    p.failQuery = true;
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2);
    for (var i = 0; i < 10; i++) {
      await p.tick();
    }
    expect(p.turns, 1);
  });

  test('latest absent cut wins when two refresh replies arrive backwards', () async {
    final p = await _Probe.start();
    p.hold.arm('session/projections');
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
    final olderRelease = p.hold.release!;
    addTearDown(() {
      if (!olderRelease.isCompleted) olderRelease.complete();
    });
    p.hold.arm('session/projections');
    p.query = 'emptyColdSnapshot';
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 3 && p.hold.received!.isCompleted);
    p.hold.finish();
    await p.until(() => p.turns == 0);
    olderRelease.complete();
    for (var i = 0; i < 10; i++) {
      await p.tick();
    }
    expect(p.turns, 0);
  });
}
