import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/session_sync_host.dart';

// Two real loopback connections with distinct same-named sessions. Equal
// oldest/newest sequence numbers do not mean that the transcript is the same.
class _Peer {
  _Peer(this.label, this.host, this.client, this.cut);
  String label;
  final FakeDsh host;
  final DshClient client;
  int? cut;

  Map<String, Object?> event(String type, int seq, Map<String, Object?> data) => {
    'type': 'event',
    'event': {'type': type, 'seq': seq, 'time': 1792700000000 + seq, 'data': data},
  };

  Map<String, Object?> snapshot() {
    final value = syncSnapshot(1);
    value['cursor'] = 5;
    value['records'] = [
      syncEvent('turn/start', 0, 1),
      event('user/message', 1, {
        'id': 'user-$label',
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'question-$label'},
        ],
        'source': {'kind': 'user', 'rpcId': 'prompt-$label'},
      }),
      event('assistant/message', 2, {
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
      }),
      if (cut == 3) syncEvent('turn/end', 3, 1) else event('step/end', 3, {'turn': 1, 'step': 1}),
      if (cut == 3)
        event('session/title', 4, {'title': 'title-$label'})
      else
        event('turn/end', 4, {
          'turn': 1,
          'reason': {'kind': cut == null ? 'error' : 'completed'},
        }),
      event('sandbox/mode', 5, {'mode': 'off'}),
    ];
    value['projections'] = {'asOfSeq': 5, 'values': <String, Object?>{}};
    return value;
  }

  static Future<_Peer> start(String label, {int? cut = 3}) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    final client = DshClient.withCarrier(
      DshHttpCarrier(connection),
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    final peer = _Peer(label, host, client, cut);
    host.handlers['session/projections'] = (_) => {'ok': true, 'value': null};
    host.handlers['session/fork'] = (_) => {
      'ok': true,
      'value': {'sessionId': 'fork-$label'},
    };
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      socket.item(id, peer.snapshot());
    };
    await client.mux.ready();
    return peer;
  }

  Future<void> close() async {
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
  AssistantChatItem get reply => state.items.whereType<AssistantChatItem>().single;

  static Override connection(_Peer peer) => activeConnectionProvider.overrideWithValue(
    AsyncData<HostConnection?>(HostConnection(hostId: '', client: peer.client, label: peer.label, isLocal: false)),
  );

  static Future<_Pair> start({int? bCut = 4}) async {
    final a = await _Peer.start('A');
    final b = await _Peer.start('B', cut: bCut);
    final container = ProviderContainer(overrides: [connection(a)]);
    container.listen(chatProvider('S'), (_, _) {});
    final pair = _Pair(a, b, container);
    await pair.ready(a);
    return pair;
  }

  Future<void> ready(_Peer peer) => waitSync(
    () => state.controlReady && state.items.whereType<AssistantChatItem>().any((r) => r.text == 'answer-${peer.label}'),
    'snapshot ${peer.label}',
  );

  void warm() {
    expect(chat.branchPointAfter(reply), 3);
    expect(chat.replyMessageId(reply), 'reply-A');
    expect(chat.events.first.seq, 0);
    expect(chat.events.last.seq, 5);
  }

  Future<void> selectB() async {
    final old = chat;
    container.updateOverrides([connection(b)]);
    await container.pump();
    await ready(b);
    expect(chat, same(old));
    expect(chat.events.first.seq, 0);
    expect(chat.events.last.seq, 5);
  }

  Future<void> close() async {
    container.dispose();
    await a.close();
    await b.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> scenario(Future<void> Function(_Pair pair) run, {int? bCut = 4}) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final pair = await _Pair.start(bCut: bCut);
        try {
          await run(pair);
        } finally {
          await pair.close();
        }
      }, RealSyncHttp());

  test(
    'same-owner unchanged snapshot preserves valid reply lookups',
    () => scenario((p) async {
      p.warm();
      expect(await p.chat.resync(), isTrue);
      p.warm();
    }),
  );

  test(
    'a new connection without an old cached lookup uses its own fork cut',
    () => scenario((p) async {
      await p.selectB();
      expect(p.chat.replyMessageId(p.reply), 'reply-B');
      expect(p.chat.branchPointAfter(p.reply), 4);
      expect((await p.chat.branchAfter(p.reply))?.sessionId, 'fork-B');
      final call = p.b.host.rpcCalls.singleWhere((r) => r['method'] == 'session/fork');
      expect(((call['payload'] as Map)['args'] as Map)['request'], containsPair('atSeq', 4));
    }),
  );

  test(
    'same sequence range on a new connection gets that reply message id',
    () => scenario((p) async {
      p.warm();
      await p.selectB();
      expect(p.chat.replyMessageId(p.reply), 'reply-B');
    }),
  );

  test(
    'same sequence range on a new connection gets that finished turn cut',
    () => scenario((p) async {
      p.warm();
      await p.selectB();
      final outcome = await p.chat.branchAfter(p.reply);
      expect(outcome?.sessionId, 'fork-B');
      final call = p.b.host.rpcCalls.singleWhere((r) => r['method'] == 'session/fork');
      syncTrace('replacement-reply-fork-cut', call);
      expect(((call['payload'] as Map)['args'] as Map)['request'], containsPair('atSeq', 4));
    }),
  );

  test(
    'an error-ended replacement does not inherit the old branch permission',
    () => scenario((p) async {
      p.warm();
      await p.selectB();
      expect(p.chat.branchPointAfter(p.reply), isNull);
    }, bCut: null),
  );
}
