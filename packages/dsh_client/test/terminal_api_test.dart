import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> fail(String code, [Map<String, Object?> details = const {}]) => {
  'ok': false,
  'error': {'code': code, 'message': code, 'details': details},
};

/// `WebTerminalInfo` as DSH 0.2.1-rc.2 returns it (recorded from a throwaway
/// `dsh web`).
Map<String, Object?> infoJson({
  String id = 't1',
  String title = 'bash',
  int cols = 80,
  int rows = 24,
  String state = 'running',
  int? exitCode,
}) => {
  'id': id,
  'shell': {
    'path': '/bin/bash',
    'name': 'bash',
    'args': ['-i'],
  },
  'title': title,
  'cwd': '/root/work',
  'cols': cols,
  'rows': rows,
  'state': state,
  'exitCode': exitCode,
};

Map<String, Object?> snapshotJson({
  int sequence = 1,
  bool writable = true,
  Map<String, Object?>? info,
  Object? window,
}) => {
  'type': 'snapshot',
  'sequence': sequence,
  'screen': r'[root@phone work]$ ',
  'info': info ?? infoJson(),
  'writable': writable,
  'inputWindow': window ?? {'maxBytes': 262144, 'frameOverheadBytes': 74},
};

/// An attachment over in-memory pipes: [down] plays the Host, [sent] records
/// the uplink.
class Pipe {
  Pipe({TerminalEnvironment environment = TerminalEnvironment.defaults}) {
    attachment = TerminalAttachment.over(
      items: down.stream,
      send: sent.add,
      cancel: () async => cancelled++,
      environment: environment,
    );
    sub = attachment.frames.listen(frames.add, onError: errors.add, onDone: () => done = true);
  }

  final down = StreamController<Object?>();
  final sent = <Object?>[];
  final frames = <TerminalFrame>[];
  final errors = <Object>[];
  late final TerminalAttachment attachment;
  late final StreamSubscription<TerminalFrame> sub;
  var cancelled = 0;
  var done = false;

  Future<void> host(Object? frame) async {
    down.add(frame);
    await pumpEventQueue();
  }

  List<Map<String, Object?>> get commands => [for (final c in sent) (c! as Map).cast<String, Object?>()];
}

void main() {
  group('models', () {
    test('parse recorded Host values tolerantly', () {
      final info = TerminalInfo.fromJson(infoJson(title: '  ', state: 'exited', exitCode: 3))!;
      expect(info.title, 'bash', reason: 'a blank title falls back to the shell name');
      expect(info.shell.args, ['-i']);
      expect(info.state, TerminalProcessState.exited);
      expect(info.exitCode, 3);
      expect(info.running, isFalse);
      expect(TerminalInfo.fromJson({'title': 'x'}), isNull);

      final env = TerminalEnvironment.fromJson({
        'cwd': '/root/work',
        'maxInputBytes': 65536,
        'maxBufferedBytes': 2097152,
        'maxCols': 500,
        'maxRows': 200,
        'scrollback': 1000,
      });
      expect((env.cwd, env.maxCols, env.maxRows, env.scrollback), ('/root/work', 500, 200, 1000));
      expect(TerminalEnvironment.fromJson({'maxCols': -1}).maxCols, 500);

      expect(TerminalFrame.fromJson({'type': 'mystery'}), isNull);
      final snapshot = TerminalFrame.fromJson(snapshotJson())! as TerminalSnapshot;
      expect(snapshot.window!.frameOverheadBytes, 74);
      expect(TerminalFrame.fromJson({'type': 'ack', 'sequence': 2, 'refusal': 'read-only'}), isA<TerminalAck>());
      expect(newTerminalId(), matches(RegExp(r'^[\w-]{1,128}$')));
    });
  });

  group('remote calls', () {
    late FakeDsh host;

    setUp(() async => host = await FakeDsh.start());
    tearDown(() async => host.close());

    Future<DshClient> connect() async {
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
      addTearDown(client.close);
      return client;
    }

    test('unary methods use the wire names of 0.2.1-rc.2', () async {
      final seen = <String, Map<String, Object?>>{};
      Map<String, Object?> Function(Map<String, Object?>) record(String endpoint, Object? value) => (args) {
        seen[endpoint] = args;
        return ok(value);
      };
      host.handlers
        ..['terminal/environment'] = record('terminal/environment', {'cwd': '/root/work', 'maxCols': 300})
        ..['terminal/shells'] = record('terminal/shells', [
          {
            'path': '/bin/bash',
            'name': 'bash',
            'args': ['-i'],
          },
          {'name': 'broken'},
        ])
        ..['terminal/list'] = record('terminal/list', [infoJson(), infoJson(id: 't2', state: 'exited', exitCode: 0)])
        ..['terminal/create'] = record('terminal/create', infoJson(id: 't3', cols: 60, rows: 20))
        ..['terminal/rename'] = record('terminal/rename', null)
        ..['terminal/close'] = record('terminal/close', null);
      final client = await connect();
      expect(client.supportsTerminals, isTrue);

      expect((await client.terminalEnvironment('s1')).maxCols, 300);
      expect((await client.terminalShells('s1')).map((s) => s.path), ['/bin/bash']);
      final list = await client.listTerminals('s1');
      expect(list.map((t) => (t.id, t.state)), [
        ('t1', TerminalProcessState.running),
        ('t2', TerminalProcessState.exited),
      ]);
      final created = await client.createTerminal('s1', id: 't3', cols: 60, rows: 20, shellPath: '/bin/bash');
      expect((created.id, created.cols, created.rows), ('t3', 60, 20));
      await client.renameTerminal('s1', 't3', '构建');
      await client.closeTerminal('s1', 't3');

      expect(seen['terminal/environment'], {'agentId': 's1'});
      expect(seen['terminal/shells'], {'agentId': 's1'});
      expect(seen['terminal/list'], {'sessionId': 's1'});
      expect(seen['terminal/create'], {
        'agentId': 's1',
        'request': {'id': 't3', 'cols': 60, 'rows': 20, 'shellPath': '/bin/bash'},
      });
      expect(seen['terminal/rename'], {'agentId': 's1', 'id': 't3', 'title': '构建'});
      expect(seen['terminal/close'], {'agentId': 's1', 'id': 't3'});
    });

    test('create without a shell omits shellPath; Host refusals keep their code', () async {
      Map<String, Object?>? args;
      host.handlers['terminal/create'] = (a) {
        args = a;
        return fail('terminal/limit-reached', {'limit': 8});
      };
      final client = await connect();
      await expectLater(
        client.createTerminal('s1', id: 't9', cols: 80, rows: 24),
        throwsA(
          isA<DshRemoteException>()
              .having((e) => e.code, 'code', 'terminal/limit-reached')
              .having((e) => e.details['limit'], 'limit', 8),
        ),
      );
      expect(args!['request'], {'id': 't9', 'cols': 80, 'rows': 24});
    });

    test('retain and attach open streams; input goes up as numbered items', () async {
      final opened = <String, Map<String, Object?>>{};
      final ids = <String, String>{};
      late FakeMuxSocket socket;
      host.onOpen = (s, streamId, endpoint, payload) {
        socket = s;
        opened[endpoint] = (payload['args']! as Map).cast<String, Object?>();
        ids[endpoint] = streamId;
        if (endpoint == 'terminal/retain') s.item(streamId, {'type': 'retained'});
        if (endpoint == 'terminal/attach') s.item(streamId, snapshotJson());
      };
      final client = await connect();

      final holds = <void>[];
      final retain = client.retainTerminal('s1', 't1').listen(holds.add);
      addTearDown(retain.cancel);
      final attachment = client.attachTerminal('s1', 't1');
      final frames = <TerminalFrame>[];
      attachment.frames.listen(frames.add);
      await _until(() => holds.isNotEmpty && frames.isNotEmpty);
      expect(opened['terminal/retain'], {'sessionId': 's1', 'id': 't1'});
      expect(opened['terminal/attach'], {'agentId': 's1', 'id': 't1'});
      expect(attachment.writable, isTrue);

      expect(attachment.write('ls\r'), isTrue);
      expect(attachment.resize(100, 30), isTrue);
      bool uplinked() => socket.received.where((f) => f['type'] == 'item').length == 2;
      await _until(uplinked);
      final items = [
        for (final f in socket.received)
          if (f['type'] == 'item') f,
      ];
      expect(items.map((f) => f['streamId']).toSet(), {ids['terminal/attach']});
      expect(items.map((f) => f['value']), [
        {'type': 'write', 'sequence': 1, 'data': 'ls\r'},
        {'type': 'resize', 'sequence': 2, 'cols': 100, 'rows': 30},
      ]);

      // Detaching cancels the stream; the terminal is untouched.
      await attachment.close();
      await _until(() => socket.received.any((f) => f['type'] == 'cancel' && f['streamId'] == ids['terminal/attach']));
      expect(host.rpcCalls.where((c) => c['method'] == 'terminal/close'), isEmpty);
    });

    test('attach to a missing terminal fails with terminal/unavailable', () async {
      host.onOpen = (s, streamId, endpoint, payload) => s.send({
        'type': 'error',
        'streamId': streamId,
        'error': {
          'code': 'terminal/unavailable',
          'message': 'Terminal no longer exists in this Session',
          'details': {},
        },
      });
      final client = await connect();
      final attachment = client.attachTerminal('s1', 'gone');
      await expectLater(
        attachment.frames,
        emitsError(isA<DshRemoteException>().having((e) => e.code, 'code', 'terminal/unavailable')),
      );
      expect(attachment.isClosed, isTrue);
    });

    test('the Host ending the stream (terminal closed) completes frames', () async {
      host.onOpen = (s, streamId, endpoint, payload) {
        s.item(streamId, snapshotJson());
        s.item(streamId, {'type': 'state', 'info': infoJson(state: 'exited', exitCode: 0), 'writable': false});
        s.send({'type': 'end', 'streamId': streamId});
      };
      final client = await connect();
      final attachment = client.attachTerminal('s1', 't1');
      final frames = await attachment.frames.toList();
      expect(frames.last, isA<TerminalStatus>().having((f) => f.info.exitCode, 'exit', 0));
      expect(attachment.writable, isFalse);
    });

    test('carriers without uplink take the follow route (terminal_follow_test.dart)', () async {
      final client = await connect();
      expect(client.supportsTerminals, isTrue);
      final relayLike = DshClient.withCarrier(_NoUplink(client.carrier));
      addTearDown(relayLike.close);
      expect(relayLike.supportsTerminals, isTrue);
    });
  });

  group('attachment protocol', () {
    test('frames must start with a snapshot', () async {
      final pipe = Pipe();
      await pipe.host({'type': 'output', 'sequence': 2, 'data': 'x'});
      expect(pipe.errors.single, isA<TerminalStreamException>().having((e) => e.issue, 'issue', 'invalidOutput'));
      expect(pipe.cancelled, 1);
      expect(pipe.done, isTrue);
    });

    test('output sequences continue the snapshot without gaps', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson(sequence: 5));
      await pipe.host({'type': 'output', 'sequence': 6, 'data': 'a'});
      await pipe.host({'type': 'output', 'sequence': 7, 'data': 'b'});
      expect(pipe.errors, isEmpty);
      await pipe.host({'type': 'output', 'sequence': 9, 'data': 'c'});
      expect(pipe.frames.whereType<TerminalOutput>().map((f) => f.data), ['a', 'b']);
      expect(pipe.errors.single, isA<TerminalStreamException>());
    });

    test('a second snapshot is a protocol error', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson());
      await pipe.host(snapshotJson());
      expect(pipe.errors.single, isA<TerminalStreamException>());
    });

    test('nothing is written before the snapshot or without control', () async {
      final pipe = Pipe();
      expect(pipe.attachment.write('x'), isFalse);
      await pipe.host(snapshotJson(writable: false));
      expect(pipe.attachment.writable, isFalse);
      expect(pipe.attachment.write('x'), isFalse);
      expect(pipe.attachment.resize(90, 30), isFalse);
      expect(pipe.sent, isEmpty);
      // Taking control back arrives as a state frame.
      await pipe.host({'type': 'state', 'info': infoJson(), 'writable': true});
      expect(pipe.attachment.write('x'), isTrue);
      expect(pipe.commands.single, {'type': 'write', 'sequence': 1, 'data': 'x'});
    });

    test('an exited process is never writable', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson(info: infoJson(state: 'exited', exitCode: 1)));
      expect(pipe.attachment.writable, isFalse);
    });

    test('acks release commands in order; a refusal ends input', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson());
      pipe.attachment
        ..write('a')
        ..write('b');
      expect(pipe.commands.map((c) => c['sequence']), [1, 2]);
      await pipe.host({'type': 'ack', 'sequence': 1});
      await pipe.host({'type': 'ack', 'sequence': 2, 'refusal': 'read-only'});
      expect(pipe.errors, isEmpty);
      expect(pipe.attachment.writable, isFalse);
      expect(pipe.attachment.write('c'), isFalse);
      expect(pipe.frames.whereType<TerminalAck>().last.refusal, 'read-only');
    });

    test('an out-of-order ack fails the attachment', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson());
      pipe.attachment.write('a');
      await pipe.host({'type': 'ack', 'sequence': 2});
      expect(pipe.errors.single, isA<TerminalStreamException>().having((e) => e.issue, 'issue', 'invalidOutput'));
    });

    test('input waits for the carrier window and flows on each ack', () async {
      final pipe = Pipe();
      // Room for about two small frames.
      await pipe.host(snapshotJson(window: {'maxBytes': 120, 'frameOverheadBytes': 10}));
      for (final key in ['a', 'b', 'c', 'd']) {
        pipe.attachment.write(key);
      }
      expect(pipe.commands.map((c) => c['data']), ['a', 'b']);
      await pipe.host({'type': 'ack', 'sequence': 1});
      expect(pipe.commands.map((c) => c['data']), ['a', 'b', 'c']);
      await pipe.host({'type': 'ack', 'sequence': 2});
      await pipe.host({'type': 'ack', 'sequence': 3});
      expect(pipe.commands.map((c) => c['data']), ['a', 'b', 'c', 'd']);
      expect(pipe.commands.map((c) => c['sequence']), [1, 2, 3, 4]);
    });

    test('a big paste goes out in chunks within maxInputBytes, code points intact', () async {
      final pipe = Pipe(environment: const TerminalEnvironment(maxInputBytes: 1000));
      await pipe.host(snapshotJson());
      final text = '${'é' * 700}末尾😀';
      expect(pipe.attachment.write(text), isTrue);
      final chunks = [for (final c in pipe.commands) c['data']! as String];
      expect(chunks.length, greaterThan(1));
      expect(chunks.join(), text);
      for (final chunk in chunks) {
        expect(utf8.encode(chunk).length, lessThanOrEqualTo(1000));
      }
      expect(pipe.commands.map((c) => c['sequence']), [for (var i = 1; i <= chunks.length; i++) i]);
    });

    test('overflowing the client buffer fails with inputFull', () async {
      final pipe = Pipe(environment: const TerminalEnvironment(maxBufferedBytes: 300));
      await pipe.host(snapshotJson(window: {'maxBytes': 100, 'frameOverheadBytes': 0}));
      for (var i = 0; i < 6; i++) {
        pipe.attachment.write('x' * 20);
      }
      await pumpEventQueue();
      expect(pipe.errors.single, isA<TerminalStreamException>().having((e) => e.issue, 'issue', 'inputFull'));
      expect(pipe.cancelled, 1);
    });

    test('resize clamps to the Host limits and skips the current size', () async {
      final pipe = Pipe(environment: const TerminalEnvironment(maxCols: 120, maxRows: 40));
      await pipe.host(snapshotJson(info: infoJson(cols: 80, rows: 24)));
      expect(pipe.attachment.resize(80, 24), isFalse);
      expect(pipe.attachment.resize(999, 0), isTrue);
      expect(pipe.attachment.resize(999, 0), isFalse);
      expect(pipe.commands.single, {'type': 'resize', 'sequence': 1, 'cols': 120, 'rows': 1});
      await pipe.host({'type': 'ack', 'sequence': 1});
      await pipe.host({'type': 'state', 'info': infoJson(cols: 120, rows: 1), 'writable': true});
      expect(pipe.attachment.info!.cols, 120);
      expect(pipe.attachment.resize(120, 1), isFalse);
    });

    test('carrier loss surfaces as the error and detaches', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson());
      pipe.down.addError(const DshCarrierLostException('socket closed'));
      await pumpEventQueue();
      expect(pipe.errors.single, isA<DshCarrierLostException>());
      expect(pipe.attachment.isClosed, isTrue);
      expect(pipe.attachment.write('x'), isFalse);
    });

    test('cancelling the frames subscription detaches', () async {
      final pipe = Pipe();
      await pipe.host(snapshotJson());
      await pipe.sub.cancel();
      await pumpEventQueue();
      expect(pipe.cancelled, 1);
      expect(pipe.attachment.isClosed, isTrue);
    });
  });
}

/// The local carrier with uplink switched off (as on the relay tunnel).
class _NoUplink extends DshCarrier {
  _NoUplink(this.inner);

  final DshCarrier inner;

  @override
  String get kind => 'no-uplink';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      inner.call(endpoint, args, timeout: timeout);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => inner.openLink(options);

  @override
  Future<void> close() async {}
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
