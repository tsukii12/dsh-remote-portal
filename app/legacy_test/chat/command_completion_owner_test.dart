import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/session_sync_host.dart';

enum _Outcome { success, syntax, rpcError }

const _commandRequest = {'agentId': 'S', 'line': '/probe', 'submittedAttachments': <Object?>[]};

Map<String, Object?> _commandEvent(String label, int seq, bool done) => {
  'type': 'event',
  'event': {
    'type': done ? 'command/done' : 'command/run',
    'seq': seq,
    'time': 1792700000000 + seq,
    'data': {
      'commandId': 'present-$label',
      'name': 'probe',
      if (done) 'kind': 'success',
      if (done) 'text': '$label-visible',
    },
  },
};

class _Peer {
  _Peer(this.label, this.host, this.client, this.hold);
  final String label;
  final FakeDsh host;
  final DshClient client;
  final ReplyHold hold;
  final follows = <({FakeMuxSocket socket, String id})>[];
  _Outcome outcome = _Outcome.success;
  bool snapshots = true;
  int executions = 0;
  final requests = <Map<String, Object?>>[];

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
    host.handlers['commands/execute'] = (args) {
      peer.requests.add(args);
      peer.executions++;
      if (peer.outcome == _Outcome.rpcError) {
        return {
          'ok': false,
          'error': {'code': 'probe/failed', 'message': '$label-transport-error'},
        };
      }
      return {
        'ok': true,
        'value': {
          'commandId': peer.outcome == _Outcome.syntax ? null : 'reply-$label',
          'result': {'kind': peer.outcome == _Outcome.success ? 'success' : 'error', 'text': '$label-result'},
        },
      };
    };
    host.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      peer.follows.add((socket: socket, id: id));
      if (peer.snapshots) {
        socket.item(id, {
          ...syncSnapshot(1),
          'cursor': 2,
          'records': [syncEvent('turn/start', 0, 1), _commandEvent(label, 1, false), _commandEvent(label, 2, true)],
        });
      }
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

class _Probe {
  _Probe(this.a, this.b, this.container);
  final _Peer a;
  final _Peer b;
  final ProviderContainer container;
  bool disposed = false;

  ChatController get chat => container.read(chatProvider('S').notifier);
  ChatState get state => container.read(chatProvider('S'));
  List<Map<String, Object?>> get notices => [
    for (final c in state.commands)
      {'id': c.id, 'name': c.name, 'args': c.args, 'seq': c.seq, 'done': c.done, 'success': c.success, 'text': c.text},
  ];
  static Override connection(_Peer? p) => activeConnectionProvider.overrideWithValue(
    AsyncData<HostConnection?>(p == null ? null : HostConnection(hostId: '', client: p.client, label: p.label, isLocal: false)),
  );

  static Future<_Probe> start({bool snapshots = true}) async {
    final a = await _Peer.start('A');
    final b = await _Peer.start('B');
    a.snapshots = snapshots;
    final container = ProviderContainer(overrides: [connection(a)]);
    final p = _Probe(a, b, container);
    container.listen(chatProvider('S'), (_, _) {});
    if (snapshots) {
      await p.waitFor(a);
    } else {
      await waitSync(() => a.follows.isNotEmpty, 'held initial follow');
    }
    return p;
  }

  Future<void> waitFor(_Peer p) =>
      waitSync(() => state.commands.any((c) => c.text == '${p.label}-visible'), '${p.label} real command snapshot');

  Future<void> select(_Peer? p) async {
    final controller = chat;
    container.updateOverrides([connection(p)]);
    await container.pump();
    expect(chat, same(controller), reason: 'The Notifier survives its dependency rebuild');
    if (p != null) await waitFor(p);
  }

  Future<Future<bool> Function()> startHeld(_Outcome outcome) async {
    a.outcome = outcome;
    a.hold.arm('commands/execute');
    final completion = chat.runCommand('/probe');
    await a.hold.received!.future.timeout(const Duration(seconds: 4));
    expect(a.executions, 1);
    expect(a.requests.single, _commandRequest);
    // Return a thunk rather than an async Future<bool>: do not flatten the
    // held command's result while preparing the scenario.
    return () => completion;
  }

  Future<void> close() async {
    a.hold.finish();
    b.hold.finish();
    if (!disposed) container.dispose();
    await a.close();
    await b.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  syncTrace('command-owner-fixture', {'version': 'flat-args-v2'});
  Future<void> scenario(Future<void> Function(_Probe) body, {bool snapshots = true}) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final p = await _Probe.start(snapshots: snapshots);
        try {
          await body(p);
        } finally {
          await p.close();
        }
      }, RealSyncHttp());

  for (final outcome in _Outcome.values) {
    test(
      'current command retains its $outcome completion',
      () => scenario((p) async {
        p.a.outcome = outcome;
        final result = await p.chat.runCommand('/probe');
        expect(result, outcome == _Outcome.success);
        expect(p.state.commands, hasLength(2));
        expect(p.state.commands.last.done, isTrue);
        expect(p.state.commands.last.success, outcome == _Outcome.success);
        expect(p.a.executions, 1);
        expect(p.a.requests.single, _commandRequest);
        expect(p.b.executions, 0);
      }),
    );

    test(
      'old A $outcome cannot publish into current B',
      () => scenario((p) async {
        final completion = await p.startHeld(outcome);
        await p.select(p.b);
        final before = p.notices;
        expect(before.map((c) => c['text']), ['B-visible']);
        p.a.hold.finish();
        final result = await completion();
        expect(p.notices, before);
        expect(result, isFalse);
        expect(p.b.executions, 0, reason: 'The old command was sent only to A');
      }),
    );
  }

  for (final outcome in [_Outcome.success, _Outcome.rpcError]) {
    test(
      'disconnect retires the $outcome command completion',
      () => scenario((p) async {
        final completion = await p.startHeld(outcome);
        await p.select(null);
        final before = p.notices;
        p.a.hold.finish();
        final result = await completion();
        expect(p.notices, before);
        expect(result, isFalse);
      }),
    );
  }

  test(
    'A to B to A does not revive a retired command result',
    () => scenario((p) async {
      final completion = await p.startHeld(_Outcome.success);
      await p.select(p.b);
      await p.select(p.a);
      final before = p.notices;
      expect(before.map((c) => c['text']), ['A-visible']);
      p.a.hold.finish();
      final result = await completion();
      expect(p.notices, before);
      expect(result, isFalse);
    }),
  );

  test(
    'disposed provider ignores a late successful command',
    () => scenario((p) async {
      final completion = await p.startHeld(_Outcome.success);
      p.container.dispose();
      p.disposed = true;
      p.a.hold.finish();
      expect(await completion(), isFalse);
    }),
  );

  test(
    'current syntax result remains available before the first follow snapshot',
    () => scenario((p) async {
      expect(p.state.syncing, isTrue);
      p.a.outcome = _Outcome.syntax;
      expect(await p.chat.runCommand('/probe'), isFalse);
      expect(p.state.commands.single.text, 'A-result');
      expect(p.a.executions, 1);
    }, snapshots: false),
  );
}
