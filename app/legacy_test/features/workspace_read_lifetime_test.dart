import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Only the transport boundary is controlled. The provider, resilient workspace
// stream, ready handshake, frame parsing and cancellation all run unchanged.
class _Carrier extends DshCarrier {
  final link = _Link();
  int closes = 0;

  @override
  String get kind => 'workspace-read-lifetime';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      const RpcOk(<Object?>[]);
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link;
  @override
  Future<void> close() async => closes++;
}

class _Link implements DshMuxLink {
  late DshMuxFrameHandler _frame;
  final opened = <String>[];
  final cancelled = <String>[];
  int closes = 0;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => _frame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => item(streamId, {
          'type': 'ready',
          'clientId': 'workspace-reader',
          'host': {'home': '/home/test'},
        }),
      );
    } else {
      if (endpoint != 'workspace/follow') throw StateError('Unexpected endpoint: $endpoint');
      opened.add(streamId);
    }
  }

  void item(String id, Object? value) => _frame({'type': 'item', 'streamId': id, 'value': value});

  void baseline(String id, {bool empty = false}) => item(id, {
    'type': 'baseline',
    'value': {
      'items': [
        if (!empty)
          {
            'workspaceId': 'w',
            'path': '/work',
            'title': 'Work',
            'sessionIds': ['s'],
          },
      ],
      'archivedSessionIds': <String>[],
      'pinnedSessionIds': <String>[],
    },
  });

  void fail(String id) => _frame({
    'type': 'error',
    'streamId': id,
    'error': {'code': 'gateway/internal', 'message': 'controlled workspace read failure'},
  });

  @override
  void cancel(String streamId) => cancelled.add(streamId);
  @override
  Future<void> close(int code, String reason) async => closes++;
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
}

HostConnection _host(DshClient client) => HostConnection(hostId: '', client: client, isLocal: true);

class _Harness {
  _Harness({bool connected = true}) {
    client = DshClient.withCarrier(carrier);
    container = ProviderContainer(
      overrides: [activeConnectionProvider.overrideWithValue(AsyncData(connected ? _host(client) : null))],
    );
    listener = container.listen(hostWorkspacesProvider, (_, _) {});
  }

  final carrier = _Carrier();
  late final DshClient client;
  late final ProviderContainer container;
  late final ProviderSubscription<AsyncValue<List<Workspace>>> listener;
  _Link get link => carrier.link;

  Future<void> close() async {
    container.dispose();
    await client.close();
  }
}

// SDK cancellation can return a cached Future owned by the root Zone.
// Drain both queues, including Riverpod's zero-time disposal task, without
// advancing a nonzero timer or waiting for wall-clock time.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(Duration.zero);
  await tester.runAsync(() => Future<void>.value());
  await tester.pump(Duration.zero);
}

void main() {
  testWidgets('six-second fallback cancels its still-open workspace stream', (tester) async {
    final h = _Harness();
    addTearDown(h.close);
    await _drain(tester);
    final id = h.link.opened.single;
    expect(h.container.read(hostWorkspacesProvider).isLoading, isTrue);

    await tester.pump(const Duration(seconds: 6));
    expect(h.container.read(hostWorkspacesProvider).requireValue, isEmpty);
    expect(h.link.cancelled, [id]);
    expect(h.client.mux.state, DshConnectionState.connected);
    expect(h.carrier.closes, 0);
  });

  testWidgets('leaving the editor cancels only its read while the shared client stays live', (tester) async {
    final h = _Harness();
    addTearDown(h.close);
    await _drain(tester);
    final owned = h.link.opened.single;
    final peer = h.client.watchWorkspaces().listen((_) {});
    addTearDown(peer.cancel);
    await _drain(tester);
    final other = h.link.opened.last;
    expect(other, isNot(owned));

    h.listener.close();
    await _drain(tester);
    expect(h.link.cancelled, [owned]);
    expect(h.link.cancelled, isNot(contains(other)));
    expect(h.link.closes, 0);
    expect(h.client.mux.state, DshConnectionState.connected);
  });

  testWidgets('a replacement connection releases the old pending read and adopts the new baseline', (tester) async {
    final h = _Harness();
    final nextCarrier = _Carrier();
    final next = DshClient.withCarrier(nextCarrier);
    addTearDown(() async {
      await h.close();
      await next.close();
    });
    await _drain(tester);
    final oldId = h.link.opened.single;
    h.container.updateOverrides([activeConnectionProvider.overrideWithValue(AsyncData(_host(next)))]);
    h.container.read(hostWorkspacesProvider); // The editor rebuild reads its changed dependency.
    await _drain(tester);
    final newId = nextCarrier.link.opened.single;
    nextCarrier.link.baseline(newId);
    await _drain(tester);
    expect(h.container.read(hostWorkspacesProvider).requireValue.single.workspaceId, 'w');
    expect(h.link.cancelled, [oldId]);
    expect(nextCarrier.link.cancelled, [newId]);
    expect(h.carrier.closes, 0);
    expect(nextCarrier.closes, 0);
  });

  for (final empty in [false, true]) {
    testWidgets('${empty ? "an empty" : "a nonempty"} baseline completes and cancels once', (tester) async {
      final h = _Harness();
      addTearDown(h.close);
      await _drain(tester);
      final id = h.link.opened.single;
      h.link.baseline(id, empty: empty);
      await _drain(tester);
      final result = h.container.read(hostWorkspacesProvider).requireValue;
      if (empty) {
        expect(result, isEmpty);
      } else {
        expect(result.single.workspaceId, 'w');
        expect(result.single.path, '/work');
        expect(result.single.title, 'Work');
        expect(result.single.sessionIds, ['s']);
      }
      expect(h.link.cancelled, [id]);
      await tester.pump(const Duration(seconds: 6));
      expect(h.link.cancelled, [id], reason: 'the completed read has no second timeout cancellation');
      expect(h.carrier.closes, 0);
    });
  }

  testWidgets('a terminal workspace error still falls back without closing the client', (tester) async {
    final h = _Harness();
    addTearDown(h.close);
    await _drain(tester);
    h.link.fail(h.link.opened.single);
    await _drain(tester);
    expect(h.container.read(hostWorkspacesProvider).requireValue, isEmpty);
    expect(h.link.cancelled, isEmpty, reason: 'the Host already terminated this stream');
    expect(h.client.mux.state, DshConnectionState.connected);
    expect(h.carrier.closes, 0);
  });

  testWidgets('no connection returns an empty list without starting a mux', (tester) async {
    final h = _Harness(connected: false);
    addTearDown(h.close);
    await _drain(tester);
    expect(h.container.read(hostWorkspacesProvider).requireValue, isEmpty);
    expect(h.link.opened, isEmpty);
    expect(h.link.cancelled, isEmpty);
  });
}
