import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../chat/support/session_sync_host.dart' show HeldReplyCarrier, ReplyHold;

const _id = 'panels-team-probe';

enum _Kind { panels, team }

// Production controllers and SDK over loopback HTTP/WS. The fixture contains
// actual upstream module snapshots; response delivery is deliberately held.
class _Probe {
  _Probe(this.kind, this.raw, this.host, this.client, this.hold);
  final _Kind kind;
  final Map raw;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  late final ProviderContainer container;
  var baseline = 'latestResident';
  var query = 'latestResident';
  var failQuery = false;
  var nullQuery = false;
  var opens = 0;
  var reads = 0;
  late FakeMuxSocket socket;
  late String stream;

  int? get value => switch (kind) {
    _Kind.panels => container.read(sessionPanelsProvider(_id)).planActive ? 1 : 0,
    _Kind.team => container.read(teamProvider(_id)).value?.members.length,
  };
  int get low => kind == _Kind.panels ? 0 : 1;
  int get high => kind == _Kind.panels ? 1 : 2;

  static Future<_Probe> start(
    _Kind kind, {
    bool lowInitial = false,
    bool delayFirst = false,
    bool rejectWebSocket = false,
    bool failInitial = false,
  }) async {
    final raw = jsonDecode(File('test/state/fixtures/panels-team-real-module.json').readAsStringSync()) as Map;
    final host = await FakeDsh.start();
    host.rejectWebSocket = rejectWebSocket;
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    if (!rejectWebSocket) await client.mux.ready();
    final p = _Probe(kind, raw, host, client, hold);
    if (lowInitial) p.baseline = p.query = 'before';
    p.failQuery = failInitial;
    if (delayFirst) hold.arm('session/projections');
    host.handlers['session/projections'] = (_) {
      p.reads++;
      if (p.failQuery) {
        return {
          'ok': false,
          'error': {'code': 'probe/failed', 'message': 'controlled query failure'},
        };
      }
      return {
        'ok': true,
        'value': p.nullQuery
            ? null
            : {'kind': 'sequenced', ...(raw[p.query]['projections'][_id] as Map).cast<String, Object?>()},
      };
    };
    host.onOpen = (socket, stream, endpoint, _) {
      if (endpoint != 'session/control') throw StateError(endpoint);
      p.socket = socket;
      p.stream = stream;
      p.opens++;
      if (!delayFirst || p.opens > 1) {
        socket.item(stream, {'type': 'baseline', 'value': raw[p.baseline]});
      }
    };
    p.container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true))),
        hostSessionsProvider.overrideWithValue(const {}),
        agentTeamBundleProvider.overrideWithValue(
          AsyncData(PluginBundle.fromJson({'name': agentTeamBundle, 'enabled': true, 'installed': true})),
        ),
      ],
    );
    final sub = kind == _Kind.panels
        ? p.container.listen(sessionPanelsProvider(_id), (_, _) {})
        : p.container.listen(teamProvider(_id), (_, _) {});
    addTearDown(() async {
      hold.finish();
      sub.close();
      p.container.dispose();
      await client.close();
      await host.close();
    });
    await p.until(
      () =>
          p.reads == 1 && (rejectWebSocket || p.opens == 1) && (delayFirst || p.value == (lowInitial ? p.low : p.high)),
    );
    return p;
  }

  Future<void> tick() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await container.pump();
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200; i++) {
      if (condition()) return;
      await tick();
    }
    fail('condition timed out kind=$kind opens=$opens reads=$reads value=$value');
  }

  Future<void> settleReply() async {
    for (var i = 0; i < 10; i++) {
      await tick();
    }
  }

  Future<void> reconnect(String nextBaseline) async {
    baseline = nextBaseline;
    final prior = opens;
    await host.sockets.last.ws.close(1001, 'controlled reconnect');
    await until(() => opens == prior + 1);
  }

  void latestFrame() {
    final snapshot = raw['querySnapshot'] as Map;
    final key = kind == _Kind.panels ? 'plan' : 'agentTeam';
    socket.item(stream, {
      'type': 'projection',
      'sessionId': _id,
      'seq': snapshot['asOfSeq'],
      'key': key,
      'value': snapshot['values'][key],
    });
  }
}

void main() {
  for (final kind in _Kind.values) {
    test('$kind cold query keeps the cache until a newer live frame arrives', () async {
      final p = await _Probe.start(kind, lowInitial: true);
      p.hold.arm('session/projections');
      await p.reconnect('coldBaseline');
      await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
      expect(p.value, p.low);
      p.latestFrame();
      await p.until(() => p.value == p.high);
      p.hold.finish();
      await p.settleReply();
      expect(p.value, p.high, reason: 'An older HTTP snapshot cannot undo the newer live key');
    });

    test('$kind later resident baseline retires a held cold query', () async {
      final p = await _Probe.start(kind);
      p.hold.arm('session/projections');
      await p.reconnect('coldBaseline');
      await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
      expect(p.value, p.high, reason: 'Missing whole-session baseline is not deletion');
      await p.reconnect('before');
      await p.until(() => p.value == p.low);
      p.hold.finish();
      await p.settleReply();
      expect(p.value, p.low);
      expect(p.reads, 2, reason: 'A resident baseline needs no additional query');
    });

    test('$kind failed cold query retains the successful visible cache', () async {
      final p = await _Probe.start(kind);
      p.failQuery = true;
      await p.reconnect('coldBaseline');
      await p.until(() => p.reads == 2);
      await p.settleReply();
      expect(p.value, p.high);
      if (kind == _Kind.team) expect(p.container.read(teamProvider(_id)).hasError, isFalse);
    });

    test('$kind newest absent cut wins when two query replies arrive backwards', () async {
      final p = await _Probe.start(kind);
      p.hold.arm('session/projections');
      await p.reconnect('coldBaseline');
      await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
      final oldRelease = p.hold.release!;
      addTearDown(() {
        if (!oldRelease.isCompleted) oldRelease.complete();
      });
      p.hold.arm('session/projections');
      p.query = 'before';
      await p.reconnect('coldBaseline');
      await p.until(() => p.reads == 3 && p.hold.received!.isCompleted);
      p.hold.finish();
      await p.until(() => p.value == p.low);
      oldRelease.complete();
      await p.settleReply();
      expect(p.value, p.low, reason: 'A valid asOfSeq=-1 snapshot is accepted under the new cut');
    });

    test('$kind first resident baseline rejects an initial query from an older ready generation', () async {
      final p = await _Probe.start(kind, delayFirst: true);
      await p.hold.received!.future;
      final generation = p.client.mux.lastReadyGenerationNumber;
      await p.reconnect('before');
      await p.until(() => p.value == p.low);
      expect(p.client.mux.lastReadyGenerationNumber, greaterThan(generation));
      p.hold.finish();
      await p.settleReply();
      expect(p.value, p.low);
      expect(p.reads, 1);
    });

    test('$kind HTTP query remains usable while WebSocket is unavailable', () async {
      final p = await _Probe.start(kind, rejectWebSocket: true);
      expect(p.value, p.high);
      expect(p.client.mux.lastReadyGenerationNumber, 0);
      expect(p.host.sockets, isEmpty);
      expect(p.reads, 1);
    });
  }

  test('team keeps a known empty result after a failed cold refresh', () async {
    final p = await _Probe.start(_Kind.team);
    p.nullQuery = true;
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2 && p.value == null);
    expect(p.container.read(teamProvider(_id)).hasValue, isTrue);
    p.failQuery = true;
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 3);
    await p.settleReply();
    final state = p.container.read(teamProvider(_id));
    expect(state.hasValue, isTrue);
    expect(state.hasError, isFalse);
    expect(state.value, isNull);
  });

  test('team an old failed initial query cannot overwrite a new empty successful cut', () async {
    final p = await _Probe.start(_Kind.team, delayFirst: true, failInitial: true);
    await p.hold.received!.future;
    final oldRelease = p.hold.release!;
    addTearDown(() {
      if (!oldRelease.isCompleted) oldRelease.complete();
    });
    p.hold.arm('session/projections');
    p.failQuery = false;
    p.nullQuery = true;
    await p.reconnect('coldBaseline');
    await p.until(() => p.reads == 2 && p.hold.received!.isCompleted);
    p.hold.finish();
    await p.until(() => p.container.read(teamProvider(_id)).hasValue);
    oldRelease.complete();
    await p.settleReply();
    final state = p.container.read(teamProvider(_id));
    expect(state.hasError, isFalse);
    expect(state.hasValue, isTrue);
    expect(state.value, isNull);
  });
}
