import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/session_sync_host.dart';

Map<String, Object?> _user(int seq, String text) => {
  'type': 'event',
  'event': {
    'type': 'user/message',
    'seq': seq,
    'time': 1792700000000 + seq,
    'data': {
      'id': text,
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user', 'rpcId': text},
    },
  },
};

class _Peer {
  _Peer(this.label, this.host, this.client, this.hold);
  final String label;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  var pages = 0;
  var failPage = false;

  static Future<_Peer> start(String label) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    final client = DshClient.withCarrier(
      HeldReplyCarrier(DshHttpCarrier(connection), hold),
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    final peer = _Peer(label, host, client, hold);
    host.handlers['session/projections'] = (_) => {'ok': true, 'value': null};
    host.handlers['session/page'] = (args) {
      peer.pages++;
      if (peer.failPage) {
        return {
          'ok': false,
          'error': {'code': 'session/page-failed', 'message': 'page-$label-failed'},
        };
      }
      return {
        'ok': true,
        'value': {
          'records': [_user(5, 'older-$label-${peer.pages}')],
          'hasMore': false,
        },
      };
    };
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      final snapshot = syncSnapshot(1);
      snapshot['cursor'] = 10;
      snapshot['hasMore'] = true;
      snapshot['records'] = [syncEvent('turn/start', 9, 1), _user(10, 'current-$label')];
      snapshot['projections'] = {'asOfSeq': 10, 'values': <String, Object?>{}};
      socket.item(id, snapshot);
    };
    await client.mux.ready();
    return peer;
  }

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
  List<String> get texts => state.items.whereType<UserChatItem>().map((i) => i.text).toList();
  static Override connection(_Peer peer) => activeConnectionProvider.overrideWithValue(
    AsyncData<HostConnection?>(HostConnection(hostId: '', client: peer.client, label: peer.label, isLocal: false)),
  );

  static Future<_Pair> start() async {
    final a = await _Peer.start('A');
    final b = await _Peer.start('B');
    final container = ProviderContainer(overrides: [connection(a)]);
    container.listen(chatProvider('S'), (_, _) {});
    final pair = _Pair(a, b, container);
    await pair.ready(a);
    return pair;
  }

  Future<void> ready(_Peer peer) =>
      waitSync(() => state.controlReady && texts.contains('current-${peer.label}'), 'ready ${peer.label}');
  Future<void> select(_Peer peer) async {
    final previous = chat;
    container.updateOverrides([connection(peer)]);
    await container.pump();
    await ready(peer);
    expect(chat, same(previous));
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
  Future<void> scenario(Future<void> Function(_Pair p) run) => HttpOverrides.runWithHttpOverrides(() async {
    final pair = await _Pair.start();
    try {
      await run(pair);
    } finally {
      await pair.close();
    }
  }, RealSyncHttp());

  test(
    'current history appends older rows and applies its hasMore',
    () => scenario((p) async {
      await p.chat.loadOlder();
      final wire = p.a.host.rpcCalls.singleWhere((r) => r['method'] == 'session/page');
      final request = ((wire['payload'] as Map)['args'] as Map)['request'] as Map;
      expect(request['address'], {'kind': 'session', 'sessionId': 'S'});
      expect(request['beforeSeq'], 9);
      expect(p.texts, ['older-A-1', 'current-A']);
      expect(p.state.hasMoreHistory, isFalse);
      expect(p.state.loadingOlder, isFalse);
    }),
  );

  test(
    'current history failure clears busy and can retry',
    () => scenario((p) async {
      p.a.failPage = true;
      await p.chat.loadOlder();
      expect(p.state.error, isNotNull);
      expect(p.state.loadingOlder, isFalse);
      p.a.failPage = false;
      await p.chat.loadOlder();
      expect(p.texts, ['older-A-2', 'current-A']);
    }),
  );

  test(
    'current history remains single flight',
    () => scenario((p) async {
      p.a.hold.arm('session/page');
      final first = p.chat.loadOlder();
      await p.a.hold.received!.future;
      await p.chat.loadOlder();
      expect(p.a.pages, 1);
      expect(p.state.loadingOlder, isTrue);
      p.a.hold.finish();
      await first;
      expect(p.texts, ['older-A-1', 'current-A']);
    }),
  );

  for (final aba in [false, true]) {
    test(
      'old history cannot merge into a replacement snapshot, ABA=$aba',
      () => scenario((p) async {
        p.a.hold.arm('session/page');
        final old = p.chat.loadOlder();
        await p.a.hold.received!.future;
        await p.select(p.b);
        if (aba) await p.select(p.a);
        p.a.hold.finish();
        await old;
        syncTrace('history-owner-$aba', {'texts': p.texts, 'hasMore': p.state.hasMoreHistory});
        expect(p.texts, [aba ? 'current-A' : 'current-B']);
        expect(p.state.hasMoreHistory, isTrue);
      }),
    );
  }

  test(
    'old history error cannot publish into the new connection',
    () => scenario((p) async {
      p.a.failPage = true;
      p.a.hold.arm('session/page');
      final old = p.chat.loadOlder();
      await p.a.hold.received!.future;
      await p.select(p.b);
      p.a.hold.finish();
      await old;
      expect(p.state.error, isNull);
      expect(p.texts, ['current-B']);
    }),
  );

  test(
    'old history cannot clear a newer connection page busy mark',
    () => scenario((p) async {
      p.a.hold.arm('session/page');
      final old = p.chat.loadOlder();
      await p.a.hold.received!.future;
      await p.select(p.b);
      p.b.hold.arm('session/page');
      final current = p.chat.loadOlder();
      await p.b.hold.received!.future;
      p.a.hold.finish();
      await old;
      expect(p.state.loadingOlder, isTrue);
      expect(p.texts, ['current-B']);
      p.b.hold.finish();
      await current;
      expect(p.state.loadingOlder, isFalse);
      expect(p.texts, ['older-B-1', 'current-B']);
    }),
  );

  test(
    'reconnect retires old page busy and permits a fresh page first',
    () => scenario((p) async {
      p.a.hold.arm('session/page');
      final old = p.chat.loadOlder();
      await p.a.hold.received!.future;
      final generation = p.a.client.mux.generation;
      await p.a.host.sockets.last.ws.close(1001, 'history reconnect');
      await waitSync(
        () =>
            p.a.client.mux.generation != null &&
            !identical(p.a.client.mux.generation, generation) &&
            p.state.controlReady,
        'fresh generation and snapshot',
      );
      expect(p.state.loadingOlder, isFalse);
      p.a.hold.endpoint = null; // The first response remains held; a new read is independent.
      await p.chat.loadOlder();
      expect(p.a.pages, 2);
      expect(p.texts, ['older-A-2', 'current-A']);
      p.a.hold.finish();
      await old;
      expect(p.texts, ['older-A-2', 'current-A']);
    }),
  );
}
