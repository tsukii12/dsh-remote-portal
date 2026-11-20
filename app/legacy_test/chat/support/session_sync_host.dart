// Real loopback HTTP/WS support for G54 admission/recovery tests. Product
// client/watch/controller are used without overriding their implementations.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../../packages/dsh_client/test/support/fake_dsh.dart';

class RealSyncHttp extends HttpOverrides {}

const _muxOptions = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Future<void> waitSync(bool Function() ready, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Map<String, Object?> syncItem(String id) => {
  'id': id,
  'role': 'user',
  'content': [
    {'type': 'text', 'text': id},
  ],
  'source': {'kind': 'user', 'rpcId': 'request-$id'},
};

Map<String, Object?> syncEvent(String type, int seq, int turn) => {
  'type': 'event',
  'event': {
    'type': type,
    'seq': seq,
    'time': 1792700000000 + seq,
    'data': {'turn': turn, if (type == 'turn/end') 'reason': 'completed'},
  },
};

Map<String, Object?> syncSnapshot(int turn) => {
  'type': 'snapshot',
  'header': {
    'version': 4,
    'id': 'S',
    'createdAt': 1792700000000,
    'cwd': '/probe',
    'isSeeded': false,
    'agentPreset': 'standard',
  },
  'cursor': turn == 1 ? 0 : 2,
  'records': [
    syncEvent('turn/start', 0, 1),
    if (turn == 2) ...[syncEvent('turn/end', 1, 1), syncEvent('turn/start', 2, 2)],
  ],
  'hasMore': false,
  'projections': {
    'asOfSeq': turn == 1 ? 0 : 2,
    'values': {
      'inbox': {
        'next-turn': [syncItem('queue-run-$turn')],
        'next-step': <Object?>[],
      },
    },
  },
  'assistantStream': {'revision': 0},
};

class SyncHarness {
  SyncHarness(this.host, this.client);
  final FakeDsh host;
  final DshClient client;
  late final ProviderContainer container;
  final follows = <({FakeMuxSocket socket, String id})>[];
  final cancelledBackendRuns = <int>[];
  final boundary = <Map<String, Object?>>[];
  int backendRun = 1;
  String followMode = 'snapshot';

  ChatController get chat => container.read(chatProvider('S').notifier);
  ChatState get state => container.read(chatProvider('S'));
  List<String> get methods => [for (final call in host.rpcCalls) call['method']! as String];
  List<int> get observedTurns => chat.events.whereType<TurnStartedEvent>().map((e) => e.turn).toList();

  static Future<SyncHarness> start({
    List<Override> overrides = const [],
    bool initialSnapshot = true,
    ReplyHold? hold,
    void Function(DshEvent)? observe,
  }) async {
    final host = await FakeDsh.start();
    DshClient? openedClient;
    SyncHarness? openedHarness;
    var hasContainer = false;
    try {
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      final carrier = DshHttpCarrier(connection);
      final transport = hold == null ? carrier : HeldReplyCarrier(carrier, hold);
      final client = observe == null
          ? DshClient.withCarrier(transport, muxOptions: _muxOptions)
          : ObservedSyncClient(transport, observe);
      openedClient = client;
      await client.mux.ready();
      final h = SyncHarness(host, client);
      openedHarness = h;
      if (!initialSnapshot) h.followMode = 'hold';
      host.handlers['session/cancel'] = (args) {
        h.cancelledBackendRuns.add(h.backendRun);
        h.boundary.add({'endpoint': 'session/cancel', 'backendRun': h.backendRun, 'request': args['request']});
        return {'ok': true};
      };
      for (final endpoint in ['session/updateQueue', 'session/prompt']) {
        host.handlers[endpoint] = (args) {
          h.boundary.add({'endpoint': endpoint, 'backendRun': h.backendRun, 'request': args['request']});
          return {'ok': true};
        };
      }
      host.handlers['session/page'] = (args) => {
        'ok': true,
        'value': {'records': <Object?>[], 'hasMore': false},
      };
      host.onOpen = (socket, id, endpoint, payload) {
        if (endpoint != 'session/follow') throw StateError('Unexpected stream $endpoint');
        h.follows.add((socket: socket, id: id));
        switch (h.followMode) {
          case 'snapshot':
            socket.item(id, syncSnapshot(h.backendRun));
          case 'error':
            h.failFollow(socket, id);
          case 'hold':
            break;
          default:
            throw StateError(h.followMode);
        }
      };
      h.container = ProviderContainer(
        overrides: [
          ...overrides,
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(hostId: '', client: client, label: 'G54 loopback', isLocal: true)),
          ),
        ],
      );
      hasContainer = true;
      final initialReady = Completer<void>();
      h.container.listen(chatProvider('S'), (_, state) {
        if (state.running && state.pending.length == 1 && state.controlReady && !initialReady.isCompleted) {
          initialReady.complete();
        }
      }, fireImmediately: true);
      if (initialSnapshot) {
        await initialReady.future.timeout(const Duration(seconds: 4));
        expect(h.observedTurns, [1]);
        expect(h.state.streamLost, isFalse);
      } else {
        await waitSync(() => h.follows.isNotEmpty, 'first follow opened');
      }
      return h;
    } catch (_) {
      try {
        if (hasContainer) openedHarness!.container.dispose();
      } finally {
        try { await openedClient?.close(); } finally { await host.close(); }
      }
      rethrow;
    }
  }

  void failFollow(FakeMuxSocket socket, String id) => socket.send({
    'type': 'error',
    'streamId': id,
    'error': {
      'code': 'gateway/internal',
      'message': 'G54 controlled follow failure',
      'details': {'retryable': true},
    },
  });

  Future<void> enter(String phase, {bool unchangedInbox = true}) async {
    backendRun = 2; // Backend advances independently; its new snapshot is held.
    switch (phase) {
      case 'terminal-follow-error':
        followMode = 'error';
        failFollow(follows.last.socket, follows.last.id);
        await waitSync(() => state.streamLost, 'six follow failures');
        expect(follows.length, 6);
        expect(client.mux.state, DshConnectionState.connected);
        expect(client.mux.generation!.number, 1);
      case 'same-generation-follow-retry':
        followMode = 'hold';
        failFollow(follows.last.socket, follows.last.id);
        await waitSync(() => follows.length == 2, 'same-generation reopened follow, snapshot held');
        expect(state.streamLost, isFalse);
        expect(client.mux.state, DshConnectionState.connected);
        expect(client.mux.generation!.number, 1);
      case 'new-mux-ready-snapshot-held':
        followMode = 'hold';
        await follows.last.socket.ws.close(1001, 'G54 loss');
        await waitSync(
          () => client.mux.generation?.number == 2 && follows.length >= 2,
          'new mux ready before snapshot',
        );
        expect(state.streamLost, isFalse);
        expect(client.mux.state, DshConnectionState.connected);
      case 'websocket-refused-http-live':
        host.rejectWebSocket = true;
        await follows.last.socket.ws.close(1001, 'G54 loss');
        await waitSync(() => client.mux.state == DshConnectionState.unauthorized, 'WS-only refusal');
        expect(client.mux.generation, isNull);
      default:
        throw StateError(phase);
    }
    expect(state.running, isTrue, reason: 'The previously observed run remains visible');
    expect(observedTurns, [1]);
    if (unchangedInbox) expect(state.pending.single.inboxId, 'queue-run-1');
  }

  Map<String, Object?> fact() => {
    'mux': client.mux.state.name,
    'generation': client.mux.generation?.number,
    'streamLost': state.streamLost,
    'running': state.running,
    'stopping': state.stopping,
    'controlReady': state.controlReady,
    'followOpens': follows.length,
    'observedTurns': observedTurns,
    'observedInbox': [for (final p in state.pending) p.inboxId],
    'backendRun': backendRun,
    'httpMethods': methods,
    'cancelledBackendRuns': List<int>.of(cancelledBackendRuns),
    'rpcBoundary': List<Map<String, Object?>>.of(boundary),
  };

  Future<void> close() async {
    container.dispose();
    try {
      await client.close();
    } finally {
      await host.close();
    }
  }
}

void syncTrace(String name, Object data) => debugPrint('G54 ${jsonEncode({'case': name, 'data': data})}');

/// Hold a real HTTP result at the await boundary, after the server received it.
class ReplyHold {
  String? endpoint;
  Completer<void>? release;
  Completer<void>? received;
  void arm(String value) {
    endpoint = value;
    release = Completer<void>();
    received = Completer<void>();
  }

  void finish() {
    endpoint = null;
    if (release case final done? when !done.isCompleted) done.complete();
  }
}

class HeldReplyCarrier extends DshCarrier {
  HeldReplyCarrier(this.inner, this.hold);
  final DshCarrier inner;
  final ReplyHold hold;
  @override
  String get kind => inner.kind;
  @override
  DshTracer? get tracer => inner.tracer;
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => inner.openLink(options);
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final release = hold.endpoint == endpoint ? hold.release : null;
    final received = hold.endpoint == endpoint ? hold.received : null;
    final result = await inner.call(endpoint, args, timeout: timeout);
    if (release != null) {
      if (!received!.isCompleted) received.complete();
      await release.future;
    }
    return result;
  }

  @override
  Future<void> close() async {
    hold.finish();
    await inner.close();
  }
}

// A passive tap only: all watch frames still come from the real implementation.
class ObservedSyncClient extends DshClient {
  ObservedSyncClient(super.carrier, this.observe) : super.withCarrier(muxOptions: _muxOptions);
  final void Function(DshEvent) observe;
  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) =>
      super.watch(sessionId, options: options).map((event) {
        observe(event);
        return event;
      });
}
