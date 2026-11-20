import 'dart:io';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../chat/support/session_sync_host.dart';

enum _Kind { panels, usage, team }

Map<String, Object?> _values(String label, int score) => {
  'goal': {
    'goal': {'objective': label, 'phase': 'active'},
  },
  'plan': {'active': score > 50, 'pending': false},
  'todos': [
    {'content': label, 'status': 'pending'},
  ],
  'tokenUsage': {'outputTokens': score},
  'contextPressure': {'pressureTokens': score, 'contextWindow': 1000},
  'sessionStats': {'turns': score},
  'agentTeam': {'failure': label},
};

class _Peer {
  _Peer(this.label, this.host, this.client, this.hold);
  final String label;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  final streams = <({FakeMuxSocket socket, String id})>[];
  var seedCalls = 0;
  var seedFails = false;
  var emitBaseline = true;
  var seedSeq = 100;
  var baselineSeq = 99;
  String get seedLabel => label == 'A' ? 'seed-A' : 'current-B';
  String get baselineLabel => label == 'A' ? 'baseline-A' : 'current-B';

  static Future<_Peer> start(String label) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
      muxOptions: const MuxOptions(
        readyTimeout: Duration(seconds: 2),
        retryCaps: [Duration(milliseconds: 20)],
      ),
    );
    final peer = _Peer(label, host, client, hold);
    if (label == 'B') peer.seedSeq = peer.baselineSeq = 10;
    host.handlers['session/projections'] = (_) {
      peer.seedCalls++;
      if (peer.seedFails) {
        return {
          'ok': false,
          'error': {
            'code': 'probe/seed-failed',
            'message': 'seed-$label-failed',
          },
        };
      }
      return {
        'ok': true,
        'value': {
          'asOfSeq': peer.seedSeq,
          'values': _values(peer.seedLabel, peer.seedSeq),
        },
      };
    };
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/control') throw StateError(endpoint);
      peer.streams.add((socket: socket, id: id));
      if (peer.emitBaseline) {
        socket.item(id, {
          'type': 'baseline',
          'value': {
            'projections': {
              'S': {
                'asOfSeq': peer.baselineSeq,
                'values': _values(peer.baselineLabel, peer.baselineSeq),
              },
            },
          },
        });
      }
    };
    await client.mux.ready();
    return peer;
  }

  void update(String label, int seq) {
    for (final stream in streams) {
      for (final entry in _values(label, seq).entries) {
        stream.socket.item(stream.id, {
          'type': 'projection',
          'sessionId': 'S',
          'key': entry.key,
          'value': entry.value,
          'seq': seq,
        });
      }
    }
  }

  Future<void> close() async {
    hold.finish();
    await client.close();
    await host.close();
  }
}

class _Probe {
  _Probe(this.kind, this.a, this.b, this.container);
  final _Kind kind;
  final _Peer a;
  final _Peer b;
  final ProviderContainer container;

  static Override connection(_Peer? peer) =>
      activeConnectionProvider.overrideWithValue(
        AsyncData<HostConnection?>(
          peer == null
              ? null
              : HostConnection(hostId: '', 
                  client: peer.client,
                  label: peer.label,
                  isLocal: false,
                ),
        ),
      );

  List<Override> overrides(_Peer? peer) => [
    connection(peer),
    hostSessionsProvider.overrideWithValue(const {}),
    agentTeamBundleProvider.overrideWithValue(const AsyncData(null)),
  ];

  Object get notifier => switch (kind) {
    _Kind.panels => container.read(sessionPanelsProvider('S').notifier),
    _Kind.usage => container.read(sessionUsageProvider('S').notifier),
    _Kind.team => container.read(teamProvider('S').notifier),
  };

  Map<String, Object?> get state {
    switch (kind) {
      case _Kind.panels:
        final s = container.read(sessionPanelsProvider('S'));
        return {
          'label': s.goal?.objective,
          'todo': s.todos?.firstOrNull?.content,
          'plan': s.planActive,
        };
      case _Kind.usage:
        final s = container.read(sessionUsageProvider('S'));
        return {
          'output': s.output,
          'pressure': s.pressureTokens,
          'turns': s.turns,
        };
      case _Kind.team:
        final s = container.read(teamProvider('S'));
        return {
          'label': s.value?.failure,
          'loading': s.isLoading,
          'error': s.hasError,
        };
    }
  }

  Map<String, Object?> expected(String label, int score) => switch (kind) {
    _Kind.panels => {'label': label, 'todo': label, 'plan': score > 50},
    _Kind.usage => {'output': score, 'pressure': score, 'turns': score},
    _Kind.team => {'label': label, 'loading': false, 'error': false},
  };

  static Future<_Probe> start(
    _Kind kind, {
    bool seedFails = false,
    bool baseline = true,
  }) async {
    final a = await _Peer.start('A');
    final b = await _Peer.start('B');
    a.seedFails = seedFails;
    a.emitBaseline = baseline;
    a.hold.arm('session/projections');
    final container = ProviderContainer(
      overrides: [
        connection(a),
        hostSessionsProvider.overrideWithValue(const {}),
        agentTeamBundleProvider.overrideWithValue(const AsyncData(null)),
      ],
    );
    final p = _Probe(kind, a, b, container);
    switch (kind) {
      case _Kind.panels:
        container.listen(sessionPanelsProvider('S'), (_, _) {});
      case _Kind.usage:
        container.listen(sessionUsageProvider('S'), (_, _) {});
      case _Kind.team:
        container.listen(teamProvider('S'), (_, _) {});
    }
    await a.hold.received!.future;
    await waitSync(() => a.streams.isNotEmpty, 'initial real control stream');
    if (baseline) {
      await p.waitFor('baseline-A', 99);
    }
    final wire = a.host.rpcCalls.singleWhere(
      (r) => r['method'] == 'session/projections',
    );
    final request = ((wire['payload'] as Map)['args'] as Map)['request'];
    expect(request, {'sessionId': 'S'});
    return p;
  }

  Future<void> waitFor(String label, int score) => waitSync(
    () => switch (kind) {
      _Kind.panels || _Kind.team => state['label'] == label,
      _Kind.usage => state['output'] == score,
    },
    '$kind $label',
  );

  Future<void> select(_Peer? peer, {bool ready = true}) async {
    final old = notifier;
    container.updateOverrides(overrides(peer));
    await container.pump();
    expect(notifier, same(old));
    if (peer != null && ready) {
      await waitFor(peer.baselineLabel, peer.baselineSeq);
    }
  }

  Future<void> releaseA() async {
    a.hold.finish();
    // Flush the held RPC and the controller continuation before asserting
    // absence of a stale publication; server response was received earlier.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await container.pump();
    }
  }

  Future<void> close() async {
    a.hold.finish();
    b.hold.finish();
    container.dispose();
    await a.close();
    await b.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> scenario(
    _Kind kind,
    Future<void> Function(_Probe) body, {
    bool seedFails = false,
    bool baseline = true,
  }) => HttpOverrides.runWithHttpOverrides(() async {
    final p = await _Probe.start(
      kind,
      seedFails: seedFails,
      baseline: baseline,
    );
    try {
      await body(p);
    } finally {
      await p.close();
    }
  }, RealSyncHttp());

  for (final kind in _Kind.values) {
    test(
      '$kind current seed fills the state after an older baseline',
      () => scenario(kind, (p) async {
        await p.releaseA();
        expect(p.state, p.expected('seed-A', 100));
      }),
    );

    test(
      '$kind newer control keys survive the current older seed',
      () => scenario(kind, (p) async {
        p.a.update('live-A', 101);
        await p.waitFor('live-A', 101);
        await p.releaseA();
        expect(p.state, p.expected('live-A', 101));
      }),
    );

    test(
      '$kind old high-sequence A seed cannot overwrite lower-sequence B',
      () => scenario(kind, (p) async {
        await p.select(p.b);
        expect(p.state, p.expected('current-B', 10));
        await p.releaseA();
        syncTrace('projection-seed-$kind', p.state);
        expect(p.state, p.expected('current-B', 10));
      }),
    );

    test(
      '$kind a disconnected state is not filled by the old seed',
      () => scenario(kind, (p) async {
        await p.select(null);
        final empty = p.state;
        await p.releaseA();
        expect(p.state, empty);
      }),
    );
  }

  test(
    'team current seed failure remains visible without any live data',
    () => scenario(
      _Kind.team,
      (p) async {
        await p.releaseA();
        expect(p.state['error'], isTrue);
      },
      seedFails: true,
      baseline: false,
    ),
  );

  test(
    'team old seed failure cannot replace the new connection loading state',
    () => scenario(
      _Kind.team,
      (p) async {
        p.b.emitBaseline = false;
        p.b.hold.arm('session/projections');
        await p.select(p.b, ready: false);
        await p.b.hold.received!.future;
        expect(p.state, {'label': null, 'loading': true, 'error': false});
        await p.releaseA();
        expect(p.state, {'label': null, 'loading': true, 'error': false});
        p.b.hold.finish();
        await p.waitFor('current-B', 10);
        expect(p.state, p.expected('current-B', 10));
      },
      seedFails: true,
      baseline: false,
    ),
  );
}
