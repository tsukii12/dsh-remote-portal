import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

// Only transport is controlled. Watch, mux ready/generations, RPC and history
// parsing are the real SDK, driven on fake time without a live Host.
class _Carrier extends DshCarrier {
  final links = <_Link>[];
  final pages = <Completer<RpcResult>>[];
  final follows = <_Link>[];

  @override
  String get kind => 'controlled-watch-recovery';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    expect(endpoint, 'session/page');
    final reply = Completer<RpcResult>();
    pages.add(reply);
    return reply.future;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link(this);
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.carrier);
  final _Carrier carrier;
  late DshMuxFrameHandler frame;
  String? eventsId;
  String? followId;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      eventsId = streamId;
    } else {
      expect(endpoint, 'session/follow');
      followId = streamId;
      carrier.follows.add(this);
    }
  }

  void ready() => frame({
    'type': 'item',
    'streamId': eventsId!,
    'value': {
      'type': 'ready',
      'clientId': 'same-client-id',
      'host': {'home': '/synthetic'},
    },
  });
  void item(Object? value) => frame({'type': 'item', 'streamId': followId!, 'value': value});
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

// Broadcast subscription cancellation can return an SDK-cached Future from
// the outer zone. Drain that zone too; do not mistake it for a product wait.
Future<void> pump(FakeAsync clock) async {
  for (var turn = 0; turn < 32; turn++) {
    clock.elapse(Duration.zero);
    await Future<void>.value();
  }
}

void main() {
  final frames = loadJsonl('follow_reply_ok.jsonl').cast<Map<String, Object?>>();
  final initial = frames.first;
  final sessionId = (initial['header']! as Map)['id']! as String;
  Map<String, Object?> event(int seq) =>
      frames.firstWhere((f) => f['type'] == 'event' && (f['event']! as Map)['seq'] == seq);
  final recovered = {
    ...initial,
    'cursor': 8,
    'records': [for (var seq = 5; seq <= 8; seq++) event(seq)],
  };
  final errors = <Object>[
    const DshHttpException(401, 'old request unauthorized'),
    const DshHttpException(403, 'old request forbidden'),
    const DshCarrierRefusedException('unauthorized', 'old request refused'),
  ];

  for (final snapshotGap in [false, true]) {
    for (final error in errors) {
      test(
        'uses already-ready successor after ${snapshotGap ? 'snapshot' : 'live'} history rejects with $error',
        () async {
          final async = FakeAsync();
          final carrier = _Carrier();
          final client = async.run(
            (_) => DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration.zero])),
          );
          final received = <DshEvent>[];
          final failures = <Object>[];
          var done = false;
          final sub = async.run(
            (_) => client
                .watch(sessionId, options: WatchOptions(includeSyncEvents: snapshotGap, includeHostEvents: false))
                .listen(received.add, onError: failures.add, onDone: () => done = true),
          );
          try {
            await pump(async);
            carrier.links.single.ready();
            await pump(async);
            carrier.links.single.item(initial);
            await pump(async);
            expect(received.whereType<SessionSnapshotEvent>(), hasLength(1));
            if (snapshotGap) {
              async.run((_) => client.mux.reconnect());
              await pump(async);
              carrier.links.last.ready();
              await pump(async);
              carrier.links.last.item({
                ...recovered,
                'records': [event(8)],
              });
            } else {
              carrier.links.single.item(event(8));
            }
            await pump(async);
            expect(carrier.pages, hasLength(1), reason: 'real history RPC is pending');
            final oldGeneration = client.mux.generation;
            final opensBefore = carrier.follows.length;
            async.run((_) => client.mux.reconnect());
            await pump(async);
            expect(carrier.links, hasLength(snapshotGap ? 3 : 2));
            final successor = carrier.links.last;
            successor.ready();
            await pump(async); // The non-replay generation event has been delivered.
            expect(client.mux.generation, isNotNull);
            expect(client.mux.generation, isNot(same(oldGeneration)));
            expect(client.mux.state, DshConnectionState.connected);
            expect(carrier.follows, hasLength(opensBefore), reason: 'watch is still awaiting the old page');
            expect(done, isFalse);
            carrier.pages.single.completeError(error);
            await pump(async);
            expect(
              carrier.follows,
              hasLength(opensBefore + 1),
              reason: 'reuse ready successor, do not wait for another login',
            );
            expect(carrier.follows.last, same(successor));
            successor.item(recovered);
            await pump(async);
            expect(received.whereType<SessionSnapshotEvent>(), hasLength(2));
            expect(failures, isEmpty);
          } finally {
            unawaited(sub.cancel());
            unawaited(client.close());
            await pump(async);
          }
        },
      );
    }
  }

  for (final ending in ['reconnect', 'stop', 'close']) {
    test('same-generation refusal waits without spinning, then $ending settles it', () async {
      final async = FakeAsync();
      final carrier = _Carrier();
      final client = async.run(
        (_) => DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration.zero])),
      );
      final failures = <Object>[];
      var done = false;
      final sub = async.run(
        (_) => client
            .watch(sessionId, options: const WatchOptions(includeHostEvents: false))
            .listen((_) {}, onError: failures.add, onDone: () => done = true),
      );
      try {
        await pump(async);
        carrier.links.single.ready();
        await pump(async);
        carrier.links.single.item(initial);
        carrier.links.single.item(event(8));
        await pump(async);
        expect(carrier.pages, hasLength(1));
        carrier.pages.single.completeError(errors.first);
        await pump(async);
        async.elapse(const Duration(minutes: 1));
        expect(carrier.follows, hasLength(1));
        expect(carrier.pages, hasLength(1));
        expect(failures, isEmpty);
        expect(done, isFalse);
        if (ending == 'reconnect') {
          async.run((_) => client.mux.reconnect());
          await pump(async);
          carrier.links.last.ready();
          await pump(async);
          expect(carrier.follows, hasLength(2));
        } else if (ending == 'stop') {
          var cancelled = false;
          unawaited(sub.cancel().then((_) => cancelled = true));
          await pump(async);
          expect(cancelled, isTrue);
          async.run((_) => client.mux.reconnect());
          await pump(async);
          carrier.links.last.ready();
          await pump(async);
          expect(carrier.follows, hasLength(1));
        } else {
          unawaited(client.close());
          await pump(async);
          expect(done, isTrue);
          expect(carrier.follows, hasLength(1));
        }
      } finally {
        unawaited(sub.cancel());
        unawaited(client.close());
        await pump(async);
      }
    });
  }
  for (final closeClient in [false, true]) {
    test(
      'late refusal after successor ready cannot revive ${closeClient ? 'closed client' : 'stopped watch'}',
      () async {
        final clock = FakeAsync();
        final carrier = _Carrier();
        final client = clock.run(
          (_) => DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration.zero])),
        );
        final failures = <Object>[];
        final sub = clock.run(
          (_) => client
              .watch(sessionId, options: const WatchOptions(includeHostEvents: false))
              .listen((_) {}, onError: failures.add),
        );
        try {
          await pump(clock);
          carrier.links.single.ready();
          await pump(clock);
          carrier.links.single.item(initial);
          carrier.links.single.item(event(8));
          await pump(clock);
          expect(carrier.pages, hasLength(1));
          clock.run((_) => client.mux.reconnect());
          await pump(clock);
          carrier.links.last.ready();
          await pump(clock);
          expect(client.mux.generation!.number, 2);
          if (closeClient) {
            unawaited(client.close());
          } else {
            unawaited(sub.cancel());
          }
          await pump(clock);
          carrier.pages.single.completeError(errors.first);
          await pump(clock);
          expect(carrier.follows, hasLength(1));
          expect(failures, closeClient ? [errors.first] : isEmpty);
        } finally {
          unawaited(sub.cancel());
          unawaited(client.close());
          await pump(clock);
        }
      },
    );
  }
}
