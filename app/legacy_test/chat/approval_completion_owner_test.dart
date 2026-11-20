import 'dart:async';
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
    peer == null
        ? null
        : HostConnection(hostId: '', 
            client: peer.client,
            label: peer.label,
            isLocal: host.isLocal,
          ),
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
  bool failApproval = false;

  static Future<_Peer> start(String label) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
    );
    final peer = _Peer(label, host, client, hold);
    host.handlers[r'$events/result'] = (args) {
      peer.answers.add(args);
      return peer.failApproval
          ? {
              'ok': false,
              'error': {
                'code': 'approval/test-failure',
                'message': 'controlled approval failure',
                'details': {},
              },
            }
          : {'ok': true};
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

  void ask(String id, {String suffix = ''}) => host.sockets.last.event({
    'type': 'waterfall',
    'event': 'approval/request',
    'eventId': id,
    'agentId': 'S',
    'request': {
      'toolName': 'bash',
      'callId': '$label-call-$id$suffix',
      'reason': 'controlled $label test request',
    },
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
    final c = ProviderContainer(
      overrides: [
        _peers.overrideWithValue({HostRef.none: a, _remote: b}),
        _routing,
      ],
    );
    final h = _Harness(a, b, c);
    c.read(activeHostProvider.notifier).select(HostRef.none);
    c.read(currentSessionProvider.notifier).select('S');
    c.listen(chatProvider('S'), (_, _) {});
    await h.ready(a);
    return h;
  }

  Future<void> ready(_Peer peer) => waitSync(
    () =>
        peer.follows > 0 &&
        state.controlReady &&
        chat.header?.cwd == '/peer-${peer.label}',
    '${peer.label} follow applied',
  );

  Future<void> select(HostRef host, _Peer peer) async {
    container.read(activeHostProvider.notifier).select(host);
    expect(
      container.read(currentSessionProvider),
      isNull,
      reason: 'The actual host selector leaves the old conversation',
    );
    container.read(currentSessionProvider.notifier).select('S');
    await container.pump();
    await ready(peer);
  }

  bool disposed = false;

  void disposeContainer() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  Future<void> close() async {
    disposeContainer();
    await a.close();
    await b.close();
    for (final peer in extras) {
      await peer.close();
    }
  }
}

Future<Completer<void>> _holdAnswer(
  _Harness h,
  _Peer peer,
  String id, {
  required bool fail,
}) async {
  peer.failApproval = fail;
  peer.hold.arm(r'$events/result');
  peer.ask(id);
  await waitSync(
    () => h.state.openApproval?.eventId == id,
    'visible $id before explicit approval',
  );
  await h.chat.allowAll(h.state.openApproval!);
  await peer.hold.received!.future;
  expect(peer.answers.last['eventId'], id);
  expect(h.state.autoAnswered, contains(id));
  return peer.hold.release!;
}

Future<void> _releaseAnswer(Completer<void> release) async {
  release.complete();
  // The real HTTP result is already captured; drain its async continuations
  // before the next event. No fabricated network timing or UI deadline.
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> scenario(Future<void> Function(_Harness) body) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final h = await _Harness.start();
        try {
          await body(h);
        } finally {
          await h.close();
        }
      }, RealSyncHttp());

  test(
    'current host failed approval restores the card and reports its error',
    () => scenario((h) async {
      final release = await _holdAnswer(h, h.a, 'current-failure', fail: true);
      await _releaseAnswer(release);
      expect(h.state.error, isNotNull);
      expect(h.state.openApproval?.eventId, 'current-failure');
      expect(h.state.autoAnswered, isEmpty);
      expect(h.a.answers, hasLength(1));
    }),
  );

  test(
    'late A approval failure must not write an error into host B',
    () => scenario((h) async {
      final release = await _holdAnswer(h, h.a, 'old-A', fail: true);
      await h.select(_remote, h.b);
      h.b.ask('pending-B');
      await waitSync(
        () => h.state.approvals.any(
          (request) => request.callId == 'B-call-pending-B',
        ),
        'B request delivered',
      );
      expect(h.state.error, isNull);
      await _releaseAnswer(release);
      expect(h.state.error, isNull, reason: 'A failure is not a B operation');
      expect(
        h.state.approvals.any(
          (request) => request.callId == 'B-call-pending-B',
        ),
        isTrue,
      );
      expect(h.b.answers, isEmpty);
    }),
  );

  test(
    'late A failure must not remove a B approval marker with the same id',
    () => scenario((h) async {
      const id = 'copied-id';
      final release = await _holdAnswer(h, h.a, id, fail: true);
      await h.select(_remote, h.b);
      await _holdAnswer(h, h.b, id, fail: false);
      expect(h.state.openApproval, isNull);
      await _releaseAnswer(release);
      expect(
        h.state.autoAnswered,
        contains(id),
        reason: 'The outstanding B answer owns its marker',
      );
      expect(h.state.openApproval, isNull);
      expect(h.state.error, isNull);
      expect(h.b.answers, hasLength(1));
    }),
  );

  test(
    'observed host round trip retires the old failure even after returning to A',
    () => scenario((h) async {
      const id = 'A-round-trip';
      final release = await _holdAnswer(h, h.a, id, fail: true);
      await h.select(_remote, h.b);
      await h.select(HostRef.none, h.a);
      await _holdAnswer(h, h.a, id, fail: false);
      expect(h.a.answers, hasLength(2));
      await _releaseAnswer(release);
      expect(h.state.autoAnswered, contains(id));
      expect(h.state.openApproval, isNull);
      expect(h.state.error, isNull);
    }),
  );

  test(
    'same host new client still restores its pending card after the old failure',
    () => scenario((h) async {
      const id = 'same-host-pending';
      final release = await _holdAnswer(h, h.a, id, fail: true);
      final replacement = await _Peer.start('A-new-client');
      h.extras.add(replacement);
      h.container.updateOverrides([
        _peers.overrideWithValue({HostRef.none: replacement, _remote: h.b}),
        _routing,
      ]);
      await h.container.pump();
      await h.ready(replacement);
      replacement.ask(id);
      await waitSync(
        () => h.state.approvals.any(
          (request) => request.callId == 'A-new-client-call-$id',
        ),
        'redelivered same-host request',
      );
      expect(h.state.autoAnswered, contains(id));
      expect(h.state.openApproval, isNull);
      expect(
        replacement.answers,
        isEmpty,
        reason: 'The earlier request is still in flight',
      );
      await _releaseAnswer(release);
      expect(h.state.autoAnswered, isNot(contains(id)));
      expect(h.state.openApproval?.eventId, id);
      expect(h.state.error, isNotNull);
      expect(replacement.answers, isEmpty);
    }),
  );

  test(
    'same client reconnect keeps ownership of a failed in-flight answer',
    () => scenario((h) async {
      const id = 'same-client-pending';
      final release = await _holdAnswer(h, h.a, id, fail: true);
      final generation = h.a.client.mux.generation!.number;
      final follows = h.a.follows;
      await h.a.host.sockets.last.ws.close();
      await waitSync(
        () =>
            (h.a.client.mux.generation?.number ?? generation) > generation &&
            h.a.follows > follows,
        'same-client new mux',
      );
      await h.ready(h.a);
      h.a.ask(id, suffix: '-redelivered');
      await waitSync(
        () => h.state.approvals.any(
          (request) => request.callId == 'A-call-$id-redelivered',
        ),
        'redelivered same-client request was applied',
      );
      expect(h.state.autoAnswered, contains(id));
      await _releaseAnswer(release);
      expect(h.state.autoAnswered, isNot(contains(id)));
      expect(h.state.openApproval?.eventId, id);
      expect(h.state.error, isNotNull);
    }),
  );

  test(
    'relay display-name change keeps the current failed approval recoverable',
    () => scenario((h) async {
      await h.select(_remote, h.b);
      final release = await _holdAnswer(h, h.b, 'relay-failure', fail: true);
      h.container
          .read(activeHostProvider.notifier)
          .select(const HostRef.portal('controlled-B', name: 'Renamed'));
      await h.container.pump();
      expect(h.container.read(currentSessionProvider), 'S');
      await _releaseAnswer(release);
      expect(h.state.openApproval?.eventId, 'relay-failure');
      expect(h.state.autoAnswered, isEmpty);
      expect(h.state.error, isNotNull);
    }),
  );

  test(
    'disposed controller ignores a late real HTTP approval failure',
    () => scenario((h) async {
      final release = await _holdAnswer(h, h.a, 'disposed-failure', fail: true);
      h.disposeContainer();
      await _releaseAnswer(release);
      expect(h.a.answers, hasLength(1));
      expect(h.b.answers, isEmpty);
    }),
  );
}
