import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Controls incoming socket events, including delivery during the same turn.
/// The public carrier still owns parsing, validation, ordering and retirement.
class _Socket extends StreamView<dynamic> implements WebSocket {
  _Socket() : this._(StreamController<dynamic>(sync: true));
  _Socket._(this.incoming) : super(incoming.stream);

  final StreamController<dynamic> incoming;
  final closeRequests = <(int?, String?)>[];
  Future<void>? _closing;

  @override
  Duration? pingInterval;
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Future<void> close([int? code, String? reason]) {
    closeRequests.add((code, reason));
    closeCode = code;
    closeReason = reason;
    return _closing ??= Future<void>.microtask(() => incoming.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends DshConnection {
  _Connection(this.socket) : super(Uri.parse('http://127.0.0.1'));

  final _Socket socket;

  @override
  Future<WebSocket> connectWebSocket(String path, {Duration? timeout}) async {
    expect(path, remoteMuxPath);
    return socket;
  }
}

void main() {
  final rows = List.generate(
    14000,
    (i) => {'seq': i, 'text': 'Synthetic 合成 $i 😀\n'.padRight(84, '.'), 'done': i.isEven},
  );
  final large = jsonEncode({'type': 'item', 'streamId': 'history', 'value': rows});
  final small = jsonEncode({'type': 'item', 'streamId': 'other', 'value': 'after snapshot'});
  final end = jsonEncode({'type': 'end', 'streamId': 'history'});

  late _Socket socket;
  late _Connection connection;
  late DshMuxLink link;

  setUp(() async {
    socket = _Socket();
    connection = _Connection(socket);
    link = await DshHttpCarrier(connection).openLink(const MuxOptions());
  });
  tearDown(() async {
    await link.close(WebSocketStatus.normalClosure, 'test finished');
    connection.close(force: true);
  });

  test('small control frames retain immediate delivery', () {
    final frames = <Map<String, Object?>>[];
    link.start(onFrame: frames.add, onLost: (_, _) => fail('unexpected link loss'));
    socket.incoming.add(small);
    expect(frames.single['value'], 'after snapshot');
  });

  test('large JSON yields before delivery without reordering later frames', () async {
    final frames = <Map<String, Object?>>[];
    final ended = Completer<void>();
    link.start(
      onFrame: (frame) {
        frames.add(frame);
        if (frame['type'] == 'end') ended.complete();
      },
      onLost: (_, _) => fail('unexpected link loss'),
    );
    socket.incoming.add(large);
    // This asserts a scheduling boundary, not a machine-dependent time budget.
    expect(frames.length, 0);
    socket.incoming.add(small);
    socket.incoming.add(end);
    await ended.future;
    expect(frames.map((f) => (f['type'], f['streamId'])), [('item', 'history'), ('item', 'other'), ('end', 'history')]);
    expect(frames.first['value'], rows);
    expect(frames[1]['value'], 'after snapshot');
  });

  test('local close retires a decoding frame and its queued successor', () async {
    final frames = <Map<String, Object?>>[];
    final losses = <DshCarrierLostException>[];
    link.start(onFrame: frames.add, onLost: (failure, _) => losses.add(failure));
    socket.incoming.add(large);
    socket.incoming.add(small);
    await link.close(WebSocketStatus.normalClosure, 'owner replaced');
    // The controlled stream has drained, including the outstanding decode.
    expect(frames.length, 0);
    expect(losses, isEmpty);
    expect(socket.closeRequests.single, (WebSocketStatus.normalClosure, 'owner replaced'));
  });

  for (final (name, data, reason) in <(String, Object, String)>[
    ('binary', <int>[1, 2], 'binary WebSocket message'),
    ('invalid JSON', '{', 'invalid Remote stream frame'),
    ('large invalid JSON', '$large trailing', 'invalid Remote stream frame'),
    ('non-object JSON', '[]', 'invalid Remote stream frame'),
    ('missing stream ID', '{"type":"end"}', 'invalid Remote stream frame'),
    ('invalid frame type', '{"type":"open","streamId":"history"}', 'invalid Remote stream frame'),
  ]) {
    test('$name preserves protocol failure and stops later delivery', () async {
      final lost = Completer<void>();
      final failures = <(DshCarrierLostException, Object?)>[];
      final frames = <Map<String, Object?>>[];
      link.start(
        onFrame: frames.add,
        onLost: (failure, cause) {
          failures.add((failure, cause));
          if (!lost.isCompleted) lost.complete();
        },
      );
      socket.incoming.add(data);
      socket.incoming.add(small);
      await lost.future;
      await socket.incoming.done;
      expect(frames, isEmpty);
      expect(failures, hasLength(1));
      expect(failures.single.$1.message, 'protocol failure: $reason');
      expect(failures.single.$2, isA<DshProtocolException>().having((e) => e.message, 'message', reason));
      expect(socket.closeRequests.single, (4002, 'invalid Remote stream frame'));
    });
  }

  test('transport error stays behind a pending frame and reports loss once', () async {
    final order = <String>[];
    final lost = Completer<void>();
    link.start(
      onFrame: (frame) {
        expect(frame['value'], rows);
        order.add('item');
      },
      onLost: (failure, cause) {
        expect(failure.message, contains('wire failed'));
        expect(cause, isNull);
        order.add('lost');
        lost.complete();
      },
    );
    socket.incoming.add(large);
    socket.incoming.addError(StateError('wire failed'));
    socket.incoming.add(small);
    await lost.future;
    await socket.incoming.close();
    expect(order, ['item', 'lost']);
  });

  test('peer EOF stays behind a pending frame', () async {
    final order = <String>[];
    final lost = Completer<void>();
    link.start(
      onFrame: (frame) {
        expect(frame['value'], rows);
        order.add('item');
      },
      onLost: (failure, cause) {
        expect(failure.message, startsWith('WebSocket closed'));
        expect(cause, isNull);
        order.add('lost');
        lost.complete();
      },
    );
    socket.incoming.add(large);
    await socket.incoming.close();
    await lost.future;
    expect(order, ['item', 'lost']);
  });
}
