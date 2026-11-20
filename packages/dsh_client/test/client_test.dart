import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';
import 'support/fixtures.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

class _HistoryFailsOnce extends DshClient {
  _HistoryFailsOnce(super.connection, {this.statusCode = 500}) : super(muxOptions: fastMux);
  final int statusCode;
  int pages = 0;
  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) {
    if (++pages == 1) return Future.error(DshHttpException(statusCode, 'temporary'));
    return super.history(
      sessionId,
      throughSeq: throughSeq,
      beforeSeq: beforeSeq,
      maxMessages: maxMessages,
      turnWindow: turnWindow,
    );
  }
}

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect({bool startMux = true}) =>
      DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux, startMux: startMux);

  group('connection + rpc', () {
    test('login mints the cookie; requests carry it with Host and no Origin', () async {
      host.handlers['session/list'] = (args) {
        expect(args, {'_request': <String, Object?>{}});
        return {
          'ok': true,
          'value': {'items': <Object?>[]},
        };
      };
      final client = await connect(startMux: false);
      addTearDown(client.close);
      final cookie = client.connection.cookie!;
      expect(cookie.name, FakeDsh.cookieName);
      expect(cookie.value, FakeDsh.cookieValue);
      expect(cookie.authority, '127.0.0.1:${host.port}');
      expect(cookie.expiresAt!.isAfter(DateTime.now().add(const Duration(days: 29))), isTrue);
      expect(DshCookie.fromJson(cookie.toJson()).header, cookie.header);

      expect(await client.listSessions(), isEmpty);
      final envelope = host.rpcCalls.single;
      expect(envelope['type'], 'client-request');
      expect(envelope['method'], 'session/list');
      expect(envelope['rpcId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      final request = host.requests.last;
      expect(request['path'], '/api/session/list');
      expect(request['host'], '127.0.0.1:${host.port}');
      expect(request['origin'], isNull);
      expect(request['cookie'], cookie.header);
      expect(await client.connection.checkHealth(), DshHealth.ok);
    });

    test('bad launch token is a 401', () async {
      final connection = DshConnection(host.baseUri);
      addTearDown(connection.close);
      await expectLater(
        connection.login('wrong'),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 401)),
      );
    });

    test('remote failures, void results and carrier refusals are typed', () async {
      host.handlers['session/selectModel'] = (_) => {
        'ok': false,
        'error': {
          'code': 'session/model-unavailable',
          'message': 'Select an available model before sending a message.',
          'details': {'provider': 'p', 'model': 'm'},
        },
      };
      host.handlers['credentials/set'] = (args) {
        expect(args, {'ref': 'DEEPSEEK_API_KEY', 'value': 'sk-test'});
        return {'ok': true};
      };
      final client = await connect(startMux: false);
      addTearDown(client.close);
      await expectLater(
        client.setModel('s', provider: 'p', model: 'm'),
        throwsA(
          isA<DshRemoteException>()
              .having((e) => e.code, 'code', 'session/model-unavailable')
              .having((e) => e.details['model'], 'details', 'm'),
        ),
      );
      await client.setProviderKey('sk-test');
      expect(() => client.setProviderKey('x', ref: 'not a ref'), throwsArgumentError);
      await expectLater(
        client.rpc.call('nope/missing'),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 404)),
      );
      final anonymous = DshClient(DshConnection(host.baseUri));
      addTearDown(anonymous.close);
      await expectLater(
        anonymous.listSessions(),
        throwsA(isA<DshHttpException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)),
      );
    });

    test(r'$events/result keeps a literal $ in the path and uses the current clientId', () async {
      Map<String, Object?>? seen;
      host.handlers[r'$events/result'] = (args) {
        seen = args;
        return {'ok': true};
      };
      final client = await connect();
      addTearDown(client.close);
      final request = ApprovalRequest(eventId: 'evt-9', sessionId: 's', toolName: 'bash');
      expect(client.mux.pendingRequests, isEmpty);
      final cancelled = client.hostEvents.where((event) => event is HostRequestCancelledEvent).first;
      await client.respondApproval(request, ApprovalDecision.allowOnce);
      expect(await cancelled, isA<HostRequestCancelledEvent>().having((event) => event.eventId, 'eventId', 'evt-9'));
      expect(host.requests.last['rawPath'], r'/api/$events/result');
      expect(seen, {
        'clientId': 'client-1',
        'eventId': 'evt-9',
        'outcome': {'kind': 'result', 'value': 'allowed-once'},
      });
      await client.respondApproval(request, ApprovalDecision.pass);
      expect(seen!['outcome'], {'kind': 'next'});
    });
  });

  group('mux', () {
    test('ready generation and host events', () async {
      final client = await connect();
      addTearDown(client.close);
      expect(client.mux.state, DshConnectionState.connected);
      expect(client.mux.generation!.clientId, 'client-1');
      expect(client.mux.generation!.home, '/home/user');
      final next = client.hostEvents.first;
      host.sockets.single.event({
        'type': 'emit',
        'event': 'api-session/status',
        'args': ['s1', true],
      });
      expect(await next, isA<SessionStatusEvent>().having((e) => e.running, 'running', isTrue));
      final upgrade = host.requests.firstWhere((r) => r['path'] == '/api/remote.mux');
      expect(upgrade['origin'], isNull);
      expect(upgrade['cookie'], client.connection.cookie!.header);
    });

    test('a refused upgrade parks the mux in unauthorized', () async {
      final client = await connect(startMux: false);
      addTearDown(client.close);
      host.rejectWebSocket = true;
      await expectLater(client.mux.ready(), throwsA(isA<DshHttpException>()));
      expect(client.mux.state, DshConnectionState.unauthorized);
    });

    test('logical stream error frames surface as DshRemoteException', () async {
      host.onOpen = (socket, streamId, endpoint, payload) => socket.send({
        'type': 'error',
        'streamId': streamId,
        'error': {
          'code': 'session/not-found',
          'message': 'session "x" not found',
          'details': {'sessionId': 'x'},
        },
      });
      final client = await connect();
      addTearDown(client.close);
      final events = <DshEvent>[];
      Object? failure;
      final done = Completer<void>();
      client
          .watch('x', options: const WatchOptions(includeConnectionEvents: false))
          .listen(events.add, onError: (Object e) => failure = e, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 5));
      expect(failure, isA<DshRemoteException>().having((e) => e.code, 'code', 'session/not-found'));
    });
  });

  group('watch', () {
    final frames = loadJsonl('follow_reply_ok.jsonl').cast<Map<String, Object?>>();
    final snapshot = frames.first;
    final eventFrames = frames.where((f) => f['type'] == 'event').toList();
    Map<String, Object?> eventFrame(int seq) => eventFrames.firstWhere((f) => (f['event'] as Map)['seq'] == seq);

    test('a transient history 500 is repaired by the next follow without exposing an error', () async {
      final sessionId = (snapshot['header'] as Map)['id'] as String;
      var opens = 0;
      host.onOpen = (socket, id, endpoint, payload) {
        opens++;
        if (opens == 1) {
          socket.item(id, snapshot);
          socket.item(id, eventFrame(8));
        } else {
          socket.item(id, {
            ...snapshot,
            'cursor': 10,
            'records': [eventFrame(9), eventFrame(10)],
          });
        }
      };
      host.handlers['session/page'] = (args) {
        final before = ((args['request'] as Map)['beforeSeq'] as int);
        return {
          'ok': true,
          'value': {
            'records': [for (var i = 5; i < before; i++) eventFrame(i)],
            'hasMore': false,
          },
        };
      };
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      final client = _HistoryFailsOnce(connection);
      addTearDown(client.close);
      final events = <DshEvent>[];
      final errors = <Object>[];
      final sub = client.watch(sessionId).listen(events.add, onError: errors.add);
      addTearDown(sub.cancel);
      await _until(() => events.whereType<SessionSnapshotEvent>().length == 2);
      expect(errors, isEmpty);
      expect(client.pages, 2);
      expect(events.whereType<SessionSnapshotEvent>().last.events.map((e) => e.seq), [5, 6, 7, 8, 9, 10]);
    });

    test('a page auth failure waits for a new mux generation, even while connected', () async {
      final sessionId = (snapshot['header'] as Map)['id'] as String;
      var opens = 0;
      host.onOpen = (socket, id, endpoint, payload) {
        opens++;
        socket.item(id, snapshot);
        if (opens == 1) socket.item(id, eventFrame(8));
      };
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      final client = _HistoryFailsOnce(connection, statusCode: 401);
      addTearDown(client.close);
      final errors = <Object>[];
      final events = <DshEvent>[];
      final sub = client.watch(sessionId).listen(events.add, onError: errors.add);
      addTearDown(sub.cancel);
      await _until(() => client.pages == 1);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(client.mux.state, DshConnectionState.connected);
      expect(opens, 1, reason: 'the same authenticated generation must not spin');
      expect(errors, isEmpty);
      client.mux.reconnect();
      await _until(() => opens == 2);
      expect(errors, isEmpty);
    });

    test('repeated invalid first frames back off before the third follow', () async {
      final times = <DateTime>[];
      host.onOpen = (socket, id, endpoint, payload) {
        times.add(DateTime.now());
        socket.item(id, times.length < 3 ? eventFrame(5) : snapshot);
      };
      final client = await connect();
      addTearDown(client.close);
      final events = <DshEvent>[];
      final sub = client.watch('s').listen(events.add);
      addTearDown(sub.cancel);
      await _until(() => events.whereType<SessionSnapshotEvent>().isNotEmpty);
      expect(times, hasLength(3));
      expect(times[2].difference(times[1]), greaterThanOrEqualTo(fastMux.retryCaps.first * 0.5));
    });

    test('authentication refusal waits for connected without reporting an error', () async {
      host.rejectWebSocket = true;
      host.onOpen = (socket, id, endpoint, payload) => socket.item(id, snapshot);
      final client = await connect(startMux: false);
      addTearDown(client.close);
      final events = <DshEvent>[];
      final errors = <Object>[];
      final sub = client.watch('s').listen(events.add, onError: errors.add);
      addTearDown(sub.cancel);
      await _until(() => client.mux.state == DshConnectionState.unauthorized);
      expect(errors, isEmpty);
      host.rejectWebSocket = false;
      client.mux.reconnect();
      await _until(() => events.whereType<SessionSnapshotEvent>().isNotEmpty);
      expect(errors, isEmpty);
    });

    for (final replay in [false, true]) {
      test('Host ready reconciles approvals (redelivered: $replay)', () async {
        final sessionId = (snapshot['header'] as Map)['id'] as String;
        host.pendingWaterfalls.add({
          'type': 'waterfall',
          'event': 'approval/request',
          'eventId': 'stale',
          'agentId': sessionId,
          'request': {'toolName': 'bash'},
        });
        host.onOpen = (socket, id, endpoint, payload) => socket.item(id, snapshot);
        final client = await connect();
        addTearDown(client.close);
        final transcript = ChatTranscript();
        final events = <DshEvent>[];
        const options = WatchOptions(hostRequestGrace: Duration(milliseconds: 40));
        final sub = client.watch(sessionId, options: options).listen((event) {
          events.add(event);
          transcript.apply(event);
        });
        addTearDown(sub.cancel);
        await _until(() => transcript.pendingApprovals.isNotEmpty);
        if (!replay) host.pendingWaterfalls.clear();
        await host.sockets.single.ws.close();
        await _until(() => client.mux.generation?.number == 2);
        if (replay) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(events.whereType<HostRequestCancelledEvent>(), isEmpty);
          expect(transcript.pendingApprovals, hasLength(1));
        } else {
          await _until(() => events.whereType<HostRequestCancelledEvent>().isNotEmpty);
          expect(transcript.pendingApprovals, isEmpty);
        }
      });
    }

    test('reconnect resyncs, fills the gap from history and replays pending approvals', () async {
      final sessionId = (snapshot['header'] as Map)['id'] as String;
      host.pendingWaterfalls.add({
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'evt-1',
        'agentId': sessionId,
        'request': {'toolName': 'bash', 'callId': 'call-1', 'reason': 'escalate'},
      });
      var opens = 0;
      host.onOpen = (socket, streamId, endpoint, payload) {
        expect(endpoint, 'session/follow');
        final request = payload['args'] as Map;
        expect((request['request'] as Map)['assistantStream'], isTrue);
        opens++;
        if (opens == 1) {
          socket.item(streamId, snapshot);
          for (var seq = 5; seq <= 10; seq++) {
            socket.item(streamId, eventFrame(seq));
          }
        } else {
          socket.item(streamId, {
            ...snapshot,
            'cursor': 18,
            'hasMore': true,
            'records': [for (var seq = 15; seq <= 18; seq++) eventFrame(seq)],
          });
        }
      };
      Map<String, Object?>? pageArgs;
      host.handlers['session/page'] = (args) {
        pageArgs = args;
        final request = args['request'] as Map;
        final before = request['beforeSeq'] as int;
        return {
          'ok': true,
          'value': {
            'records': [for (var seq = 5; seq < before; seq++) eventFrame(seq)],
            'hasMore': true,
          },
        };
      };
      Map<String, Object?>? answer;
      host.handlers[r'$events/result'] = (args) {
        answer = args;
        return {'ok': true};
      };

      final client = await connect();
      addTearDown(client.close);
      final events = <DshEvent>[];
      final resynced = Completer<void>();
      final sub = client.watch(sessionId).listen((event) {
        events.add(event);
        if (event is SessionSnapshotEvent && event.isResync) resynced.complete();
      });
      addTearDown(sub.cancel);

      await _until(() => events.whereType<SessionLogEvent>().any((e) => e.seq == 10));
      await host.sockets.single.ws.close();
      await resynced.future.timeout(const Duration(seconds: 5));

      final snapshots = events.whereType<SessionSnapshotEvent>().toList();
      expect(snapshots.first.events.map((e) => e.seq), [0, 1, 2, 3, 4]);
      expect(events.whereType<SessionLogEvent>().map((e) => e.seq), [5, 6, 7, 8, 9, 10]);
      expect(snapshots.last.events.map((e) => e.seq), [11, 12, 13, 14, 15, 16, 17, 18]);
      expect((pageArgs!['request'] as Map)['beforeSeq'], 15);
      expect((pageArgs!['request'] as Map)['throughSeq'], 18);
      expect(
        events.whereType<ConnectionStateEvent>().map((e) => e.state),
        containsAllInOrder([DshConnectionState.reconnecting, DshConnectionState.connected]),
      );

      final approvals = events.whereType<ApprovalRequestedEvent>().toList();
      expect(approvals.map((e) => e.request.eventId), ['evt-1', 'evt-1']);
      await client.respondApproval(approvals.last.request, ApprovalDecision.reject);
      expect(answer!['clientId'], 'client-2');
      expect(answer!['outcome'], {'kind': 'result', 'value': 'rejected'});
      await _until(() => events.whereType<HostRequestCancelledEvent>().isNotEmpty);
    });

    test('a skipped assistant-stream revision forces a resync', () async {
      final sessionId = (snapshot['header'] as Map)['id'] as String;
      var opens = 0;
      host.onOpen = (socket, streamId, endpoint, payload) {
        opens++;
        socket.item(streamId, snapshot);
        if (opens == 1) {
          socket.item(streamId, {
            'type': 'assistant-stream',
            'frame': {'type': 'start', 'attemptId': 'a1', 'revision': 1, 'turn': 1, 'step': 1, 'startedAfterSeq': 4},
          });
          socket.item(streamId, {
            'type': 'assistant-stream',
            'frame': {
              'type': 'chunk',
              'attemptId': 'a1',
              'revision': 3,
              'index': 1,
              'time': 1,
              'chunk': {'type': 'text-delta', 'index': 0, 'text': 'x'},
            },
          });
        }
      };
      final client = await connect();
      addTearDown(client.close);
      final events = <DshEvent>[];
      final sub = client.watch(sessionId).listen(events.add);
      addTearDown(sub.cancel);
      await _until(() => events.whereType<SessionSnapshotEvent>().length == 2);
      expect(events.whereType<AssistantChunkEvent>(), isEmpty);
      expect(events.whereType<SessionSnapshotEvent>().last.isResync, isTrue);
      final cancels = host.sockets.single.received.where((f) => f['type'] == 'cancel');
      expect(cancels, hasLength(1));
    });
  });
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
