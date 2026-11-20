import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// In-memory carrier: a scripted Host behind [DshClient.withCarrier].
class _MemoryCarrier extends DshCarrier {
  final Map<String, RpcResult Function(Map<String, Object?> args)> handlers = {};
  final List<_MemoryLink> links = [];
  final List<(String, Map<String, Object?>)> calls = [];
  Object? refuseWith;
  bool uplink = true;
  Set<String>? allowed;
  int clientIds = 0;
  void Function(_MemoryLink link, String streamId, String endpoint, Map<String, Object?> payload)? onOpen;

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => uplink;

  @override
  bool allowsEndpoint(String endpoint) => allowed?.contains(endpoint) ?? true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (!allowsEndpoint(endpoint)) {
      return const RpcError(DshRemoteException('METHOD_NOT_ALLOWED', 'not on the allow-list'));
    }
    return handlers[endpoint]?.call(args) ?? const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final refusal = refuseWith;
    if (refusal != null) throw refusal;
    final link = _MemoryLink(this);
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _MemoryLink implements DshMuxLink {
  _MemoryLink(this.carrier);

  final _MemoryCarrier carrier;
  late DshMuxFrameHandler onFrame;
  late DshMuxLossHandler onLost;
  final List<String> cancelled = [];
  final List<Object?> uplinked = [];
  bool closed = false;

  void item(String streamId, Object? value) => onFrame({'type': 'item', 'streamId': streamId, 'value': value});

  void lose() => onLost(const DshCarrierLostException('memory link dropped'), null);

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    this.onFrame = onFrame;
    this.onLost = onLost;
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => item(streamId, {
          'type': 'ready',
          'clientId': 'memory-${++carrier.clientIds}',
          'host': {'home': '/h'},
        }),
      );
      return;
    }
    carrier.onOpen?.call(this, streamId, endpoint, payload);
  }

  @override
  void sendItem(String streamId, Object? value) => uplinked.add(value);

  @override
  void endUplink(String streamId) => uplinked.add(#end);

  @override
  void cancel(String streamId) => cancelled.add(streamId);

  @override
  Future<void> close(int code, String reason) async => closed = true;
}

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 10)]);

void main() {
  test('DshClient.withCarrier runs the same API over a custom carrier', () async {
    final carrier = _MemoryCarrier();
    carrier.handlers['session/list'] = (args) {
      expect(args, {'_request': <String, Object?>{}});
      return const RpcOk({
        'items': [
          {'sessionId': 's1'},
        ],
      });
    };
    final client = await DshClient.connectCarrier(carrier, muxOptions: fastMux);
    addTearDown(client.close);
    expect(client.mux.generation!.clientId, 'memory-1');
    expect((await client.listSessions()).single.sessionId, 's1');
    expect(() => client.connection, throwsStateError);
    await expectLater(client.rpc.call('bad endpoint'), throwsArgumentError);
  });

  test('link loss reconnects, a new generation reopens streams', () async {
    final carrier = _MemoryCarrier();
    final opened = <String>[];
    carrier.onOpen = (link, streamId, endpoint, payload) {
      opened.add(endpoint);
      link.item(streamId, {
        'type': 'baseline',
        'items': <Object?>[],
        'archivedSessionIds': <Object?>[],
        'pinnedSessionIds': <Object?>[],
      });
    };
    final client = await DshClient.connectCarrier(carrier, muxOptions: fastMux);
    addTearDown(client.close);
    final updates = <WorkspaceUpdate>[];
    final sub = client.watchWorkspaces().listen(updates.add);
    await _eventually(() => updates.length == 1);
    carrier.links.single.lose();
    await _eventually(() => updates.length == 2);
    expect(client.mux.generation!.clientId, 'memory-2');
    expect(opened, ['workspace/follow', 'workspace/follow']);
    await sub.cancel();
    expect(carrier.links.last.cancelled, hasLength(1));
  });

  test('a refused link parks the mux in unauthorized with the carrier reason', () async {
    final carrier = _MemoryCarrier()
      ..refuseWith = const DshCarrierRefusedException('PEER_IDENTITY_MISMATCH', 'key changed');
    final client = DshClient.withCarrier(carrier, muxOptions: fastMux);
    addTearDown(client.close);
    await expectLater(
      client.mux.ready(),
      throwsA(isA<DshCarrierRefusedException>().having((e) => e.code, 'code', 'PEER_IDENTITY_MISMATCH')),
    );
    expect(client.mux.state, DshConnectionState.unauthorized);
    expect(carrier.links, isEmpty);
    carrier.refuseWith = null;
    client.mux.reconnect();
    await client.mux.ready(timeout: const Duration(seconds: 2));
    expect(client.mux.state, DshConnectionState.connected);
  });

  test('an explicit reconnect opens a new link now, not after the backoff', () async {
    final carrier = _MemoryCarrier();
    const slowRetry = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(seconds: 30)]);
    final client = await DshClient.connectCarrier(carrier, muxOptions: slowRetry);
    addTearDown(client.close);
    client.mux.reconnect();
    await client.mux.ready(timeout: const Duration(seconds: 2));
    expect(carrier.links, hasLength(2));
    expect(carrier.links.first.closed, isTrue);
    expect(client.mux.generation!.clientId, 'memory-2');
  });

  test('uplink and allow-list follow the carrier', () async {
    final carrier = _MemoryCarrier()
      ..uplink = false
      ..allowed = {r'$events', 'userQuestions/attachWait'};
    carrier.onOpen = (link, streamId, endpoint, payload) {};
    final client = await DshClient.connectCarrier(carrier, muxOptions: fastMux);
    addTearDown(client.close);
    expect(client.supportsEndpoint('fileUploads/upload'), isFalse);
    await expectLater(
      client.uploadFile('s', [1]),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'METHOD_NOT_ALLOWED')),
    );
    final stream = client.claimQuestionWait('s', 'c');
    expect(stream.supportsUplink, isFalse);
    expect(() => stream.send(1), throwsUnsupportedError);
    stream.endUplink(); // no-op
    expect(carrier.links.single.uplinked, isEmpty);
    await stream.cancel();

    carrier.uplink = true;
    final duplex = client.mux.open('userQuestions/attachWait', const {});
    duplex.send({'n': 1});
    duplex.endUplink();
    await _eventually(() => carrier.links.single.uplinked.length == 2);
    await duplex.cancel();
  });
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
