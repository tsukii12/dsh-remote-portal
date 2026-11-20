import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _Carrier extends DshCarrier {
  Completer<_Link> nextLink = Completer<_Link>();

  @override
  String get kind => 'controlled-history';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async => const RpcOk(null);
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link();
    nextLink.complete(link);
    nextLink = Completer<_Link>();
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  late DshMuxFrameHandler frame;
  String? eventsId;
  final eventsOpened = Completer<void>();

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;
  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      eventsId = streamId;
      eventsOpened.complete();
    }
  }

  void event(Map<String, Object?> value) => frame({'type': 'item', 'streamId': eventsId!, 'value': value});
  void ready() => event({
    'type': 'ready',
    'clientId': 'same-wire-client-id',
    'host': {'home': '/home/u'},
  });
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

const _options = MuxOptions(retryCaps: [Duration.zero]);

void main() {
  for (final (name, stream) in <(String, Stream<Object?> Function(DshMux))>[
    ('receipts', (mux) => mux.hostEventReceipts),
    ('events', (mux) => mux.hostEvents),
    ('states', (mux) => mux.states),
    ('generations', (mux) => mux.generations),
  ]) {
    test('C907 close does not await a paused $name listener', () async {
      final carrier = _Carrier();
      final client = DshClient.withCarrier(carrier, muxOptions: _options);
      addTearDown(client.close);
      final next = carrier.nextLink.future;
      final receipt = client.mux.hostEventReceipts.first;
      final ready = client.mux.ready();
      final link = await next;
      await link.eventsOpened.future;
      link.ready();
      await ready;
      final proof = (await receipt).provenance;
      final sub = stream(client.mux).listen((_) {})..pause();
      final closing = client.close();
      expect(proof.current, isFalse, reason: 'revocation is synchronous');
      try {
        await closing.timeout(const Duration(milliseconds: 200));
        expect(client.mux.state, DshConnectionState.closed);
        expect(client.mux.generation, isNull);
      } finally {
        // The pre-fix failure must still release the paused stream in teardown.
        await sub.cancel();
        await closing;
      }
    });
  }

  test('accepted ready history is synchronous and survives close without granting a live generation', () async {
    final carrier = _Carrier();
    final client = DshClient.withCarrier(carrier, muxOptions: _options);
    addTearDown(client.close);
    expect(client.mux.lastReadyGenerationNumber, 0);
    expect(client.mux.generation, isNull);
    final states = <DshConnectionState>[];
    final sub = client.mux.states.listen(states.add);
    addTearDown(sub.cancel);
    final next = carrier.nextLink.future;
    final started = client.mux.ready();
    final link = await next;
    await link.eventsOpened.future;
    final deliveredStates = states.length;
    link.ready();
    expect(client.mux.lastReadyGenerationNumber, 1);
    expect(client.mux.generation!.number, 1);
    expect(states.length, deliveredStates, reason: 'the async connected callback has not run');
    final closing = client.close();
    expect(client.mux.generation, isNull);
    expect(client.mux.lastReadyGenerationNumber, 1, reason: 'a teardown can still inspect accepted ready history');
    expect((await started).number, 1);
    await closing;
    expect(client.mux.state, DshConnectionState.closed);
    expect(client.mux.lastReadyGenerationNumber, 1);
    await expectLater(client.mux.ready(), throwsA(isA<DshClosedException>()));

    final other = DshClient.withCarrier(_Carrier(), muxOptions: _options);
    addTearDown(other.close);
    expect(other.mux.lastReadyGenerationNumber, 0, reason: 'history belongs to this mux instance only');
  });

  test('ready history advances on accepted reconnects but ignores retired-link frames', () async {
    final carrier = _Carrier();
    final client = DshClient.withCarrier(carrier, muxOptions: _options);
    addTearDown(client.close);
    final firstLink = carrier.nextLink.future;
    final started = client.mux.ready();
    final first = await firstLink;
    await first.eventsOpened.future;
    first.ready();
    await started;
    final next = carrier.nextLink.future;
    client.mux.reconnect();
    expect(client.mux.generation, isNull);
    expect(client.mux.lastReadyGenerationNumber, 1);
    final second = await next;
    await second.eventsOpened.future;
    first.ready();
    expect(client.mux.lastReadyGenerationNumber, 1, reason: 'the old link cannot mint a generation');
    second.ready();
    expect(client.mux.lastReadyGenerationNumber, 2);
    expect(client.mux.generation!.number, 2);
    expect(client.mux.generation!.clientId, 'same-wire-client-id');
    await client.close();
    second.ready();
    expect(client.mux.generation, isNull);
    expect(client.mux.lastReadyGenerationNumber, 2);
  });

  test('an invalid first frame does not mint ready history', () async {
    final carrier = _Carrier();
    final client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(autoReconnect: false));
    addTearDown(client.close);
    final next = carrier.nextLink.future;
    final failed = expectLater(client.mux.ready(), throwsA(isA<DshCarrierLostException>()));
    final link = await next;
    await link.eventsOpened.future;
    link.event({'type': 'emit', 'event': 'before-ready', 'args': <Object?>[]});
    expect(client.mux.lastReadyGenerationNumber, 0);
    expect(client.mux.generation, isNull);
    await failed;
    await client.close();
    expect(client.mux.lastReadyGenerationNumber, 0);
  });
}
