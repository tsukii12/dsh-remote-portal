import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/session_sync_host.dart';

// Real HTTP/WS transport and production controller. Each peer has a distinct
// client and a same-named S session, so an old action must retain its owner.
class _Peer {
  _Peer(this.label, this.host, this.client, this.hold);
  final String label;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  bool failPage = false;
  bool failFork = false;

  static Future<_Peer> start(String label, {required bool truncated, bool withReply = false}) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    final peer = _Peer(label, host, client, hold);
    host.handlers['session/page'] = (_) => peer.failPage
        ? _failure('old-$label-page')
        : {
            'ok': true,
            'value': {
              'records': [syncEvent('turn/end', 1, 0)],
              'hasMore': false,
            },
          };
    host.handlers['session/fork'] = (_) => peer.failFork
        ? _failure('old-$label-fork')
        : {
            'ok': true,
            'value': {'sessionId': 'fork-$label'},
          };
    host.handlers['session/projections'] = (_) => {'ok': true, 'value': null};
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      final snapshot = syncSnapshot(1);
      snapshot['cursor'] = withReply ? 4 : 2;
      snapshot['records'] = [
        if (!truncated) syncEvent('turn/end', 1, 0),
        {
          'type': 'event',
          'event': {
            'type': 'user/message',
            'seq': 2,
            'time': 1792700000002,
            'data': {
              'id': 'user-$label',
              'role': 'user',
              'source': {'kind': 'user', 'rpcId': 'request-$label'},
              'content': [
                {'type': 'text', 'text': 'prompt-$label'},
              ],
            },
          },
        },
        if (withReply) ...[
          {
            'type': 'event',
            'event': {
              'type': 'assistant/message',
              'seq': 3,
              'time': 1792700000003,
              'data': {
                'turn': 1,
                'step': 1,
                'message': {
                  'id': 'reply-$label',
                  'role': 'assistant',
                  'content': [
                    {'type': 'text', 'text': 'answer-$label'},
                  ],
                  'source': {'kind': 'assistant'},
                },
              },
            },
          },
          syncEvent('turn/end', 4, 1),
        ],
      ];
      snapshot['hasMore'] = truncated;
      snapshot['projections'] = {'asOfSeq': withReply ? 4 : 2, 'values': <String, Object?>{}};
      socket.item(id, snapshot);
    };
    await client.mux.ready();
    return peer;
  }

  static Map<String, Object?> _failure(String message) => {
    'ok': false,
    'error': {'code': 'session/fork-unavailable', 'message': message, 'details': <String, Object?>{}},
  };

  List<Map<String, Object?>> get forks => host.rpcCalls.where((r) => r['method'] == 'session/fork').toList();

  Future<void> close() async {
    hold.finish();
    await client.close();
    await host.close();
  }
}

class _Pair {
  _Pair(this.a, this.b, this.container);
  final _Peer a;
  final _Peer b;
  final ProviderContainer container;
  ChatController get chat => container.read(chatProvider('S').notifier);
  ChatState get state => container.read(chatProvider('S'));
  UserChatItem get prompt => state.items.whereType<UserChatItem>().single;

  static Future<_Pair> start({bool truncated = true, bool withReply = false}) async {
    final a = await _Peer.start('A', truncated: truncated, withReply: withReply);
    final b = await _Peer.start('B', truncated: truncated, withReply: withReply);
    final container = ProviderContainer(overrides: [_connection(a)]);
    container.listen(chatProvider('S'), (_, _) {});
    final pair = _Pair(a, b, container);
    await pair.ready(a);
    return pair;
  }

  static Override _connection(_Peer? peer) => activeConnectionProvider.overrideWithValue(
    AsyncData<HostConnection?>(
      peer == null ? null : HostConnection(hostId: '', client: peer.client, label: peer.label, isLocal: false),
    ),
  );

  Future<void> ready(_Peer peer) async {
    try {
      await waitSync(
        () => state.controlReady && state.items.whereType<UserChatItem>().any((p) => p.text == 'prompt-${peer.label}'),
        'production follow snapshot for ${peer.label}',
      );
    } catch (_) {
      // A failed fixture must be diagnosed before treating it as a product red.
      // ignore: avoid_print
      print(
        'FORK FIXTURE ${peer.label}: ready=${state.controlReady} loading=${state.loading} error=${state.error} '
        'items=${state.items.map((e) => e is UserChatItem ? e.text : e.runtimeType)} '
        'events=${chat.events.map((e) => '${e.type}/${e.seq}')}',
      );
      rethrow;
    }
  }

  Future<void> select(_Peer? peer) async {
    final previous = chat;
    container.updateOverrides([_connection(peer)]);
    await container.pump();
    if (peer != null) await ready(peer);
    expect(chat, same(previous), reason: 'the production Notifier survives a connection dependency rebuild');
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
  Future<void> scenario(Future<void> Function(_Pair pair) run, {bool truncated = true, bool withReply = false}) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final pair = await _Pair.start(truncated: truncated, withReply: withReply);
        try {
          await run(pair);
        } finally {
          await pair.close();
        }
      }, RealSyncHttp());

  for (final truncated in [true, false]) {
    test(
      'the current owner can fork, prior history needed=$truncated',
      () => scenario((p) async {
        final outcome = await p.chat.forkBeforePrompt(p.prompt);
        expect(outcome?.sessionId, 'fork-A');
        expect(p.a.forks, hasLength(1));
        expect(p.b.forks, isEmpty);
      }, truncated: truncated),
    );
  }

  for (final changeOwner in [false, true]) {
    test(
      'branchAfter keeps the original result owner, change owner=$changeOwner',
      () => scenario(
        (p) async {
          final reply = p.state.items.whereType<AssistantChatItem>().single;
          expect(p.chat.branchPointAfter(reply), 4);
          p.a.hold.arm('session/fork');
          final result = p.chat.branchAfter(reply);
          await p.a.hold.received!.future;
          if (changeOwner) await p.select(p.b);
          p.a.hold.finish();
          expect((await result)?.sessionId, changeOwner ? isNull : 'fork-A');
          expect(p.a.forks, hasLength(1));
          expect(p.b.forks, isEmpty);
          expect(p.state.error, isNull);
        },
        truncated: false,
        withReply: true,
      ),
    );
  }

  for (final destination in ['B', 'ABA', 'offline']) {
    test(
      'a held prior-history page cannot continue a fork after $destination',
      () => scenario((p) async {
        p.a.hold.arm('session/page');
        final result = p.chat.forkBeforePrompt(p.prompt);
        await p.a.hold.received!.future;
        await p.select(destination == 'offline' ? null : p.b);
        if (destination == 'ABA') await p.select(p.a);
        p.a.hold.finish();
        final outcome = await result;
        syncTrace('fork-history-$destination', {'outcome': outcome?.sessionId, 'A': p.a.forks, 'B': p.b.forks});
        expect(p.a.forks, isEmpty);
        expect(p.b.forks, isEmpty);
        expect(outcome, isNull);
        expect(p.state.error, isNull);
      }),
    );
  }

  test(
    'an old successful fork cannot return a navigation outcome to the new connection',
    () => scenario((p) async {
      p.a.hold.arm('session/fork');
      final result = p.chat.forkBeforePrompt(p.prompt);
      await p.a.hold.received!.future;
      await p.select(p.b);
      p.a.hold.finish();
      expect(await result, isNull);
      expect(p.a.forks, hasLength(1), reason: 'already dispatched on A; this does not roll back server work');
      expect(p.b.forks, isEmpty);
      expect(p.state.error, isNull);
    }, truncated: false),
  );

  for (final endpoint in ['session/page', 'session/fork']) {
    test(
      'a current $endpoint failure remains visible',
      () => scenario((p) async {
        p.a.failPage = endpoint == 'session/page';
        p.a.failFork = endpoint == 'session/fork';
        expect(await p.chat.forkBeforePrompt(p.prompt), isNull);
        expect(p.state.error, isNotNull);
        expect(p.b.forks, isEmpty);
      }, truncated: endpoint == 'session/page'),
    );

    test(
      'a failed old $endpoint cannot put its error into the new connection state',
      () => scenario((p) async {
        p.a.failPage = endpoint == 'session/page';
        p.a.failFork = endpoint == 'session/fork';
        p.a.hold.arm(endpoint);
        final result = p.chat.forkBeforePrompt(p.prompt);
        await p.a.hold.received!.future;
        await p.select(p.b);
        p.a.hold.finish();
        expect(await result, isNull);
        expect(p.state.error, isNull);
        expect(p.b.forks, isEmpty);
      }, truncated: endpoint == 'session/page'),
    );
  }

  test(
    'a new mux generation retires the held history even after a fresh snapshot',
    () => scenario((p) async {
      p.a.hold.arm('session/page');
      final result = p.chat.forkBeforePrompt(p.prompt);
      await p.a.hold.received!.future;
      final generation = p.a.client.mux.generation;
      await p.a.host.sockets.last.ws.close(1001, 'fork ownership reconnect');
      await waitSync(
        () =>
            p.a.client.mux.generation != null &&
            !identical(p.a.client.mux.generation, generation) &&
            p.state.controlReady,
        'new ready mux and followed snapshot',
      );
      p.a.hold.finish();
      final outcome = await result;
      syncTrace('fork-history-new-mux', {'outcome': outcome?.sessionId, 'A': p.a.forks});
      expect(p.a.forks, isEmpty);
      expect(outcome, isNull);
    }),
  );
}
