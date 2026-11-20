import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/session_sync_host.dart';

const _remote = HostRef.portal('controlled-B');
final _peers = Provider<Map<HostRef, _Peer?>>((ref) => const {});
final _routing = activeConnectionProvider.overrideWith((ref) {
  final host = ref.watch(activeHostProvider);
  final peer = ref.watch(_peers)[host];
  return AsyncData<HostConnection?>(
    peer == null ? null : HostConnection(hostId: '', client: peer.client, label: peer.label, isLocal: host.isLocal),
  );
});

class _Peer {
  _Peer(this.label, this.host, this.client, this.hold);
  final String label;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  final answers = <Map<String, Object?>>[];
  int follows = 0;

  static Future<_Peer> start(String label) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(HeldReplyCarrier(DshHttpCarrier(connection), hold));
    final peer = _Peer(label, host, client, hold);
    host.handlers[r'$events/result'] = (args) {
      peer.answers.add(args);
      return {'ok': true};
    };
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      peer.follows++;
      final snapshot = syncSnapshot(1);
      socket.item(id, {
        ...snapshot,
        'header': {...snapshot['header']! as Map, 'cwd': '/peer-$label'},
      });
    };
    await client.mux.ready();
    return peer;
  }

  void ask(String id) => host.sockets.last.event({
    'type': 'waterfall',
    'event': 'approval/request',
    'eventId': id,
    'agentId': 'S',
    'request': {'toolName': 'bash', 'callId': '$label-call-$id', 'reason': 'controlled $label test request'},
  });

  Future<void> close() async {
    hold.finish();
    await client.close();
    await host.close();
  }
}

class _Harness {
  _Harness(this.a, this.b, this.container);
  final _Peer a;
  final _Peer b;
  final ProviderContainer container;
  final extras = <_Peer>[];
  ChatController get chat => container.read(chatProvider('S').notifier);
  ChatState get state => container.read(chatProvider('S'));

  static Future<_Harness> start() async {
    final a = await _Peer.start('A');
    final b = await _Peer.start('B');
    final c = ProviderContainer(overrides: [
      _peers.overrideWithValue({HostRef.none: a, _remote: b}),
      _routing,
    ]);
    final h = _Harness(a, b, c);
    c.read(activeHostProvider.notifier).select(HostRef.none);
    c.read(currentSessionProvider.notifier).select('S');
    c.listen(chatProvider('S'), (_, _) {});
    await h.ready(a);
    return h;
  }

  Future<void> ready(_Peer peer) => waitSync(
    () => peer.follows > 0 && state.controlReady && chat.header?.cwd == '/peer-${peer.label}',
    '${peer.label} follow applied',
  );

  Future<void> select(HostRef host, _Peer peer) async {
    container.read(activeHostProvider.notifier).select(host);
    expect(container.read(currentSessionProvider), isNull, reason: 'The actual host selector leaves the old conversation');
    container.read(currentSessionProvider.notifier).select('S');
    await container.pump();
    await ready(peer);
  }

  Future<void> enable() async {
    a.ask('ask-A-initial');
    await waitSync(() => state.openApproval?.eventId == 'ask-A-initial', 'initial A approval');
    await chat.allowAll(state.openApproval!);
    // setAutoApprove already starts the pending request; allowAll's second
    // deduplicated call need not wait for that first request's HTTP response.
    await waitSync(() => a.answers.length == 1, 'initial A approval HTTP');
    expect(a.answers.single['eventId'], 'ask-A-initial');
    expect(a.answers.single['outcome'], {'kind': 'result', 'value': 'allowed-once'});
    expect(state.autoApprove, isTrue);
  }

  Future<void> close() async {
    container.dispose();
    await a.close();
    await b.close();
    for (final peer in extras) {
      await peer.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> scenario(Future<void> Function(_Harness) body) => HttpOverrides.runWithHttpOverrides(() async {
    final h = await _Harness.start();
    try {
      await body(h);
    } finally {
      await h.close();
    }
  }, RealSyncHttp());

  test('current host conversation keeps explicit auto approval', () => scenario((h) async {
    await h.enable();
    h.a.ask('ask-A-next');
    await waitSync(() => h.a.answers.length == 2, 'next explicit A auto approval');
    expect(h.a.answers.last['eventId'], 'ask-A-next');
    expect(h.b.answers, isEmpty);
  }));

  test('host selection must not grant the same named B session auto approval', () => scenario((h) async {
    await h.enable();
    await h.select(_remote, h.b);
    h.b.ask('ask-B');
    await waitSync(
      () => h.b.answers.isNotEmpty || h.state.openApproval?.eventId == 'ask-B',
      'B approval reaches the current controller',
    );
    expect(h.b.answers, isEmpty, reason: 'A consent did not authorize B');
    expect(h.state.autoApprove, isFalse);
    expect(h.state.openApproval?.eventId, 'ask-B');
  }));

  for (final copiedId in [false, true]) {
    test('held A success ACK cannot hide B or cancel its request (copied id: $copiedId)', () => scenario((h) async {
      h.a.hold.arm(r'$events/result');
      await h.enable();
      await h.a.hold.received!.future;
      final bId = copiedId ? 'ask-A-initial' : 'ask-B-after-held-A';
      await h.select(_remote, h.b);
      h.b.ask(bId);
      await waitSync(
        () => h.state.approvals.any((request) => request.callId == 'B-call-$bId'),
        'B approval delivered while A success ACK is held',
      );
      syncTrace('held A ACK / B before release', {
        'ids': h.state.approvals.map((request) => request.eventId).toList(),
        'calls': h.state.approvals.map((request) => request.callId).toList(),
        'open': h.state.openApproval?.eventId,
        'autoApprove': h.state.autoApprove,
        'BAnswers': h.b.answers,
      });
      expect(h.state.approvals.map((request) => request.callId), ['B-call-$bId']);
      expect(h.state.openApproval?.eventId, bId);
      expect(h.state.autoApprove, isFalse);
      expect(h.b.answers, isEmpty);

      final aCancelled = h.a.client.mux.hostEvents.firstWhere(
        (event) => event is HostRequestCancelledEvent && event.eventId == 'ask-A-initial',
      );
      h.a.hold.finish();
      await aCancelled.timeout(const Duration(seconds: 4));
      await h.container.pump();
      expect(h.state.approvals.map((request) => request.callId), ['B-call-$bId']);
      expect(h.state.openApproval?.eventId, bId);
      expect(h.b.answers, isEmpty, reason: 'A completion did not authorize B');
    }));
  }

  test('host switch retires old questions and replays each current host pending request', () => scenario((h) async {
    void question(_Peer peer, String id) => peer.host.sockets.last.event({
      'type': 'waterfall',
      'event': 'user-questions/request',
      'eventId': id,
      'agentId': 'S',
      'request': {
        'questions': [{'id': 'choice', 'question': 'Choose on ${peer.label}', 'options': <Object?>[]}],
      },
    });
    h.a.ask('pending-A');
    question(h.a, 'question-A');
    await waitSync(() => h.state.questions.any((q) => q.eventId == 'question-A'), 'A question');
    h.b.ask('pending-B');
    question(h.b, 'question-B');
    await waitSync(() => h.b.client.mux.pendingRequests.length == 2, 'B requests cached before follow');
    await h.select(_remote, h.b);
    await waitSync(() => h.state.questions.any((q) => q.eventId == 'question-B'), 'B question replayed');
    expect(h.state.approvals.map((request) => request.eventId), ['pending-B']);
    expect(h.state.questions.map((request) => request.eventId), ['question-B']);
    expect(h.a.client.mux.pendingRequests, hasLength(2), reason: 'Retirement does not cancel the old Host request');
    await h.select(HostRef.none, h.a);
    await waitSync(() => h.state.questions.any((q) => q.eventId == 'question-A'), 'returning A replayed');
    expect(h.state.approvals.map((request) => request.eventId), ['pending-A']);
    expect(h.state.questions.map((request) => request.eventId), ['question-A']);
    expect(h.a.answers, isEmpty);
    expect(h.b.answers, isEmpty);
  }));

  test('same host follow replacement keeps unanswered requests', () => scenario((h) async {
    h.a.ask('pending-same-host');
    await waitSync(() => h.state.openApproval?.eventId == 'pending-same-host', 'pending same Host approval');
    expect(await h.chat.resync(), isTrue);
    expect(h.state.approvals.map((request) => request.eventId), ['pending-same-host']);
    expect(h.state.openApproval?.eventId, 'pending-same-host');
    expect(h.a.answers, isEmpty);
  }));

  test('a new connection to the same selected host keeps conversation consent', () => scenario((h) async {
    await h.enable();
    final replacement = await _Peer.start('A-reconnected');
    h.extras.add(replacement);
    h.container.updateOverrides([
      _peers.overrideWithValue({HostRef.none: replacement, _remote: h.b}),
      _routing,
    ]);
    await h.container.pump();
    await h.ready(replacement);
    expect(h.container.read(activeHostProvider), HostRef.none);
    replacement.ask('ask-A-reconnected');
    await waitSync(() => replacement.answers.isNotEmpty, 'same-host approval');
    expect(replacement.answers.single['eventId'], 'ask-A-reconnected');
    expect(h.state.autoApprove, isTrue);
  }));

  test('returning after an observed different host does not restore old consent', () => scenario((h) async {
    await h.enable();
    await h.select(_remote, h.b);
    await h.select(HostRef.none, h.a);
    h.a.ask('ask-A-returned');
    await waitSync(
      () => h.a.answers.length > 1 || h.state.openApproval?.eventId == 'ask-A-returned',
      'A request after the host round trip',
    );
    expect(h.a.answers, hasLength(1));
    expect(h.state.autoApprove, isFalse);
    expect(h.state.openApproval?.eventId, 'ask-A-returned');
  }));

  test('an answered A id must not hide the copied request id on B', () => scenario((h) async {
    h.a.hold.arm(r'$events/result');
    await h.enable();
    await h.a.hold.received!.future;
    expect(h.state.autoAnswered, contains('ask-A-initial'));
    await h.select(_remote, h.b);
    h.b.ask('ask-A-initial');
    await waitSync(
      () => h.state.approvals.any((request) => request.callId == 'B-call-ask-A-initial'),
      'B request with a copied event id',
    );
    expect(h.b.answers, isEmpty);
    expect(h.state.openApproval?.eventId, 'ask-A-initial');
    expect(h.state.autoAnswered, isEmpty);
  }));

  test('renaming a relay display name preserves the same host consent', () => scenario((h) async {
    await h.select(_remote, h.b);
    h.b.ask('ask-B-initial');
    await waitSync(() => h.state.openApproval?.eventId == 'ask-B-initial', 'initial B request');
    await h.chat.allowAll(h.state.openApproval!);
    await waitSync(() => h.b.answers.length == 1, 'initial B approval');
    h.container.read(activeHostProvider.notifier).select(const HostRef.portal('controlled-B', name: 'Renamed'));
    await h.container.pump();
    await h.ready(h.b);
    expect(h.container.read(currentSessionProvider), 'S');
    h.b.ask('ask-B-renamed');
    await waitSync(() => h.b.answers.length == 2, 'same relay identity approval');
    expect(h.state.autoApprove, isTrue);
  }));

  test('same client WebSocket reconnect preserves conversation consent', () => scenario((h) async {
    await h.enable();
    final generation = h.a.client.mux.generation!.number;
    final follows = h.a.follows;
    await h.a.host.sockets.last.ws.close();
    await waitSync(
      () => (h.a.client.mux.generation?.number ?? generation) > generation && h.a.follows > follows,
      'new WebSocket generation and follow',
    );
    await h.ready(h.a);
    h.a.ask('ask-A-new-generation');
    await waitSync(() => h.a.answers.length == 2, 'same client reconnected approval');
    expect(h.state.autoApprove, isTrue);
  }));

  for (final operation in ['approval', 'answer', 'reject']) {
    for (final transition in ['stay', 'same-host-reconnect', 'different-host', 'host-round-trip']) {
      test('manual $operation failure belongs to its original host ($transition)', () => scenario((h) async {
        h.a.host.handlers[r'$events/result'] = (args) {
          h.a.answers.add(args);
          return {
            'ok': false,
            'error': {'code': 'test/previous-host-failure', 'message': 'Controlled old-host response'},
          };
        };
        h.a.host.sockets.last.event({
          'type': 'waterfall',
          'event': operation == 'approval' ? 'approval/request' : 'user-questions/request',
          'eventId': 'manual-A',
          'agentId': 'S',
          'request': operation == 'approval'
              ? {'toolName': 'bash', 'callId': 'A-manual', 'reason': 'controlled request'}
              : {
                  'questions': [{'id': 'choice', 'question': 'Choose on A', 'options': <Object?>[]}],
                },
        });
        await waitSync(
          () => operation == 'approval'
              ? h.state.openApproval?.eventId == 'manual-A'
              : h.state.questions.any((q) => q.eventId == 'manual-A'),
          'original request reaches the actual controller',
        );
        final controller = h.chat;
        final approval = h.state.openApproval;
        final question = h.state.questions.firstOrNull;
        h.a.hold.arm(r'$events/result');
        Future<void> reply() async {
          if (operation == 'approval') {
            await controller.respond(approval!, ApprovalDecision.allowOnce);
          } else if (operation == 'answer') {
            expect(await controller.answer(question!, const [QuestionAnswer('choice', custom: 'answer A')]), isFalse);
          } else {
            expect(await controller.rejectQuestion(question!), isFalse);
          }
        }
        final pending = reply();
        await h.a.hold.received!.future.timeout(const Duration(seconds: 4));
        expect(h.a.answers, hasLength(1));
        if (transition == 'same-host-reconnect') {
          final replacement = await _Peer.start('A-reconnected');
          h.extras.add(replacement);
          h.container.updateOverrides([
            _peers.overrideWithValue({HostRef.none: replacement, _remote: h.b}),
            _routing,
          ]);
          await h.container.pump();
          await h.ready(replacement);
        } else if (transition == 'different-host') {
          await h.select(_remote, h.b);
          h.b.ask('current-B');
          await waitSync(() => h.state.openApproval?.eventId == 'current-B', 'current B approval');
        } else if (transition == 'host-round-trip') {
          await h.select(_remote, h.b);
          await h.select(HostRef.none, h.a);
          expect(h.container.read(activeHostProvider), HostRef.none);
        }
        expect(h.state.error, isNull);
        h.a.hold.finish();
        await pending;
        await h.container.pump();
        if (transition == 'different-host' || transition == 'host-round-trip') {
          expect(h.state.error, isNull, reason: 'A response from retired consent must not report an error on the current conversation.');
          if (transition == 'different-host') expect(h.state.openApproval?.eventId, 'current-B');
          expect(h.b.answers, isEmpty);
        } else {
          expect(h.state.error, isNotNull, reason: 'A current failure must still be reported.');
        }
      }));
    }
  }
}
