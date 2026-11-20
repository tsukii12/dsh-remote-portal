import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// One Host survives replacement client objects. Only still-pending waterfalls
// are replayed to each ready connection, as on the production mux protocol.
class _Host {
  final pending = <String, Map<String, Object?>>{};
  final links = <_Link>[];
  final answers = <Map<String, Object?>>[];
  int follows = 0;

  void ask(String kind, String id) {
    final frame = {
      'type': 'waterfall',
      'event': kind == 'question' ? 'user-questions/request' : 'approval/request',
      'eventId': id,
      'agentId': 's',
      'request': kind == 'question'
          ? {
              'questions': [
                {'id': 'choice', 'question': 'Choose', 'options': <Object?>[]},
              ],
            }
          : {'toolName': 'read', 'callId': 'call-$id'},
    };
    pending[id] = frame;
    for (final link in links.where((link) => !link.closed)) {
      link.event(frame);
    }
  }

  void settle(String id) {
    pending.remove(id);
    for (final link in links.where((link) => !link.closed)) {
      link.event({'type': 'cancel', 'eventId': id});
    }
  }

  DshClient client() => DshClient.withCarrier(_Carrier(this));
}

class _Carrier extends DshCarrier {
  _Carrier(this.host);
  final _Host host;
  @override
  String get kind => 'controlled';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == r'$events/result') {
      host.answers.add(args);
      host.settle(args['eventId']! as String);
      return const RpcOk(null);
    }
    if (endpoint == 'session/projections') return const RpcOk(null);
    throw StateError('unexpected RPC $endpoint');
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link(host, 'client-${host.links.length + 1}');
    host.links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.host, this.clientId);
  final _Host host;
  final String clientId;
  late DshMuxFrameHandler onFrame;
  String? eventsId;
  bool closed = false;

  void item(String stream, Object? value) {
    if (!closed) onFrame({'type': 'item', 'streamId': stream, 'value': value});
  }

  void event(Object? value) => item(eventsId!, value);

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    this.onFrame = onFrame;
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      eventsId = streamId;
      scheduleMicrotask(() {
        event({
          'type': 'ready',
          'clientId': clientId,
          'host': {'home': '/home'},
        });
        for (final request in host.pending.values) {
          event(request);
        }
      });
      return;
    }
    if (endpoint != 'session/follow') throw StateError('unexpected stream $endpoint');
    host.follows++;
    scheduleMicrotask(
      () => item(streamId, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 's', 'createdAt': 1800000000000, 'cwd': '/$clientId'},
        'cursor': -1,
        'records': <Object?>[],
        'hasMore': false,
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
  }

  @override
  void cancel(String streamId) {}
  @override
  void sendItem(String streamId, Object? value) => throw StateError('no uplink');
  @override
  void endUplink(String streamId) => throw StateError('no uplink');
  @override
  Future<void> close(int code, String reason) async => closed = true;
}

class _Harness {
  _Harness(this.host, this.clients, this.container);
  final _Host host;
  final List<DshClient> clients;
  final ProviderContainer container;
  ChatController get chat => container.read(chatProvider('s').notifier);
  ChatState get state => container.read(chatProvider('s'));

  static Future<_Harness> start(WidgetTester tester) async {
    final host = _Host();
    final first = host.client();
    await first.mux.ready();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(hostId: '', client: first, label: 'same host', isLocal: true)),
        ),
      ],
    );
    container.listen(chatProvider('s'), (_, _) {});
    final h = _Harness(host, [first], container);
    addTearDown(() async {
      container.dispose();
      for (final client in h.clients) {
        await client.close();
      }
    });
    await h.flush(tester);
    expect(h.state.controlReady, isTrue);
    return h;
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  }

  Future<DshClient> replace(WidgetTester tester, {required bool alreadyReady}) async {
    final next = host.client();
    clients.add(next);
    if (alreadyReady) await next.mux.ready();
    final before = chat;
    container.updateOverrides([
      activeConnectionProvider.overrideWithValue(
        AsyncData(HostConnection(hostId: '', client: next, label: 'same host', isLocal: true)),
      ),
    ]);
    // A standalone container schedules rebuilds on Timer.zero. Drive that
    // virtual timer before awaiting anything that depends on the rebuild.
    await flush(tester);
    // This must also hold after the watch's existing reconnect grace period:
    // a later reconciliation must not be mistaken for a permanently stale card.
    await tester.pump(const WatchOptions().hostRequestGrace);
    await flush(tester);
    expect(chat, same(before), reason: 'dependency rebuild retains the real controller');
    expect(state.controlReady, isTrue);
    return next;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final kind in ['question', 'approval']) {
    for (final alreadyReady in [false, true]) {
      testWidgets('replacement client drops settled $kind; already ready=$alreadyReady', (tester) async {
        final h = await _Harness.start(tester);
        h.host.ask(kind, 'old');
        await h.flush(tester);
        expect(kind == 'question' ? h.state.questions.single.eventId : h.state.approvals.single.eventId, 'old');
        await h.clients.single.close();
        h.host.settle('old'); // Resolved on the computer while this client was away.
        final next = await h.replace(tester, alreadyReady: alreadyReady);
        expect(next.mux.pendingRequests, isEmpty);
        expect(h.state.questions, isEmpty);
        expect(h.state.approvals, isEmpty);
        expect(h.host.answers, isEmpty, reason: 'retiring a local card must not answer the Host');
      });
    }
  }

  testWidgets('replacement replays only its current pending requests', (tester) async {
    final h = await _Harness.start(tester);
    h.host.ask('question', 'settled');
    h.host.ask('question', 'still-open');
    await h.flush(tester);
    expect(h.state.questions, hasLength(2));
    await h.clients.single.close();
    h.host.settle('settled');
    final next = await h.replace(tester, alreadyReady: true);
    expect(next.mux.pendingRequests, hasLength(1));
    expect(h.state.questions.map((q) => q.eventId), ['still-open']);
    expect(h.host.answers, isEmpty);
  });

  testWidgets('same client follow replacement preserves a currently pending question', (tester) async {
    final h = await _Harness.start(tester);
    h.host.ask('question', 'still-open');
    await h.flush(tester);
    final resync = h.chat.resync();
    await h.flush(tester);
    expect(await resync, isTrue);
    expect(h.state.questions.single.eventId, 'still-open');
    expect(h.host.answers, isEmpty);
  });

  testWidgets('same Host replacement preserves explicit conversation auto approval', (tester) async {
    final h = await _Harness.start(tester);
    h.chat.setAutoApprove(true);
    await h.clients.single.close();
    await h.replace(tester, alreadyReady: true);
    expect(h.state.autoApprove, isTrue);
    h.host.ask('approval', 'current');
    await h.flush(tester);
    expect(h.host.answers.single['eventId'], 'current');
    expect(h.host.answers.single['outcome'], {'kind': 'result', 'value': 'allowed-once'});
  });
}
