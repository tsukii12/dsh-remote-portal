import 'dart:async';
import 'dart:collection';

import 'package:dsh_client/dsh_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

class _Carrier extends DshCarrier {
  final links = <_Link>[];
  final follows = <(_Link, String)>[];

  @override
  String get kind => 'controlled-history';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      throw StateError('unexpected RPC: $endpoint');

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link(this);
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.carrier);
  final _Carrier carrier;
  late DshMuxFrameHandler frame;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => frame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => item(streamId, {
          'type': 'ready',
          'clientId': 'same-wire-id',
          'host': {'home': '/home/test'},
        }),
      );
    } else if (endpoint == 'session/follow') {
      carrier.follows.add((this, streamId));
    }
  }

  void item(String streamId, Object? value) => frame({'type': 'item', 'streamId': streamId, 'value': value});
  @override
  void cancel(String streamId) {}
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
}

class _Read {
  _Read(this.through, this.before);
  final int through;
  final int? before;
  final reply = Completer<HistoryPage>();
}

class _Client extends DshClient {
  _Client(super.carrier) : super.withCarrier(muxOptions: const MuxOptions(retryCaps: [Duration.zero]));
  final reads = <_Read>[];
  Completer<List<SessionSummary>>? sessionsReply;
  int sessionsReads = 0;

  @override
  Future<List<SessionSummary>> listSessions() {
    sessionsReads++;
    return sessionsReply!.future;
  }

  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) {
    final read = _Read(throughSeq, beforeSeq);
    reads.add(read);
    return read.reply.future;
  }
}

// Observe whether the watcher scans a page after its owner is already gone.
// The page remains valid; a late read must be rejected before using its rows.
class _ObservedEvents extends ListBase<SessionLogEvent> {
  _ObservedEvents(this.events);
  final List<SessionLogEvent> events;
  int reads = 0;
  @override
  int get length => events.length;
  @override
  set length(int value) => throw UnsupportedError('immutable fixture');
  @override
  SessionLogEvent operator [](int index) {
    reads++;
    return events[index];
  }

  @override
  void operator []=(int index, SessionLogEvent value) => throw UnsupportedError('immutable fixture');
}

Map<String, Object?> _event(int seq) => {
  'seq': seq,
  'time': seq,
  'type': 'session/title',
  'data': {'title': 'title-$seq'},
};

List<SessionLogEvent> _events(Iterable<int> seqs) => seqs.map((seq) => SessionLogEvent.fromJson(_event(seq))).toList();

class _Harness {
  _Harness(this.clock, {bool connectionEvents = true, bool syncEvents = false}) {
    client = _Client(carrier);
    subscription = client
        .watch(
          'session',
          options: WatchOptions(includeConnectionEvents: connectionEvents, includeSyncEvents: syncEvents),
        )
        .listen(seen.add, onError: errors.add, onDone: () => done = true);
    clock.flushMicrotasks();
    snapshot(0, [0]);
  }

  final FakeAsync clock;
  final carrier = _Carrier();
  late final _Client client;
  late final StreamSubscription<DshEvent> subscription;
  final seen = <DshEvent>[];
  final errors = <Object>[];
  bool done = false;

  void snapshot(int cursor, List<int> seqs) {
    final (link, id) = carrier.follows.last;
    link.item(id, {
      'type': 'snapshot',
      'header': {'version': 4, 'id': 'session', 'createdAt': 0, 'isSeeded': false},
      'cursor': cursor,
      'records': [
        for (final seq in seqs) {'event': _event(seq)},
      ],
      'hasMore': false,
      'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
    });
    clock.flushMicrotasks();
  }

  void event(int seq) {
    final (link, id) = carrier.follows.last;
    link.item(id, {'type': 'event', 'event': _event(seq)});
    clock.flushMicrotasks();
  }

  void reconnect() => clock.run((_) => client.mux.reconnect());

  // Cancellation can return a cached Future owned by the outer Zone. Drain
  // both queues without advancing a nonzero timer or waiting on real time.
  Future<void> flush() async {
    for (var i = 0; i < 16; i++) {
      clock.flushMicrotasks();
      clock.elapse(Duration.zero);
      await Future<void>.value();
    }
    clock.flushMicrotasks();
  }

  void dispose() {
    unawaited(subscription.cancel());
    for (final read in client.reads) {
      if (!read.reply.isCompleted) read.reply.complete(const HistoryPage([], false));
    }
    final sessions = client.sessionsReply;
    if (sessions != null && !sessions.isCompleted) sessions.complete([]);
    unawaited(client.close());
    clock.flushMicrotasks();
  }
}

Future<void> _scenario(
  Future<void> Function(_Harness h) body, {
  bool connectionEvents = true,
  bool syncEvents = false,
}) async {
  final clock = FakeAsync();
  final h = clock.run((_) => _Harness(clock, connectionEvents: connectionEvents, syncEvents: syncEvents));
  try {
    await h.flush();
    await body(h);
  } finally {
    h.dispose();
    await h.flush();
  }
}

void main() {
  for (final connectionEvents in [true, false]) {
    test(
      'late gap repair cannot publish events from a retired generation (connectionEvents=$connectionEvents)',
      () => _scenario((h) async {
        h.event(3);
        await h.flush();
        expect(h.client.reads, hasLength(1));
        h.reconnect();
        await h.flush();
        expect(h.client.mux.generation!.number, 2);
        final page = _ObservedEvents(_events([1, 2]));
        h.client.reads.single.reply.complete(HistoryPage(page, false));
        await h.flush();

        expect(h.seen.whereType<SessionLogEvent>(), isEmpty, reason: 'old rows and the old gap event stay retired');
        expect(page.reads, 0, reason: 'a stale page must be rejected before scanning');
        expect(h.carrier.follows, hasLength(2));
        h.snapshot(3, [1, 2, 3]);
        await h.flush();
        final snapshots = h.seen.whereType<SessionSnapshotEvent>().toList();
        expect(snapshots.map((s) => s.cursor), [0, 3]);
        expect(snapshots.last.events.map((e) => e.seq), [1, 2, 3]);
        expect(h.errors, isEmpty);
      }, connectionEvents: connectionEvents),
    );
  }

  test(
    'retired snapshot repair does not request another page on the replacement connection',
    () => _scenario((h) async {
      h.reconnect();
      await h.flush();
      expect(h.carrier.follows, hasLength(2));
      h.snapshot(5, [5]);
      await h.flush();
      expect(h.client.reads, hasLength(1));
      expect(h.client.reads.single.before, 5);
      h.reconnect();
      await h.flush();
      expect(h.client.mux.generation!.number, 3);
      final page = _ObservedEvents(_events([3, 4]));
      h.client.reads.single.reply.complete(HistoryPage(page, true));
      await h.flush();

      expect(h.client.reads, hasLength(1), reason: 'old repair cannot use the new HTTP generation for more pages');
      expect(page.reads, 0);
      expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0]);
      expect(h.carrier.follows, hasLength(3));
      h.snapshot(5, [1, 2, 3, 4, 5]);
      await h.flush();
      expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 5]);
      expect(h.errors, isEmpty);
    }, syncEvents: true),
  );

  test(
    'cancelled watcher does not scan its late history page',
    () => _scenario((h) async {
      h.event(3);
      await h.flush();
      expect(h.client.reads, hasLength(1));
      unawaited(h.subscription.cancel());
      await h.flush();
      final page = _ObservedEvents(_events([1, 2]));
      h.client.reads.single.reply.complete(HistoryPage(page, true));
      await h.flush();

      expect(page.reads, 0);
      expect(h.client.reads, hasLength(1));
      expect(h.seen.whereType<SessionLogEvent>(), isEmpty);
    }),
  );

  for (final failure in [
    const DshHttpException(401, 'old request lost its cookie'),
    const DshRemoteException('session/not-found', 'old request no longer finds the session'),
  ]) {
    test(
      'late history failure cannot park or end a replacement generation ($failure)',
      () => _scenario((h) async {
        h.event(3);
        await h.flush();
        expect(h.client.reads, hasLength(1));
        h.reconnect();
        await h.flush();
        expect(h.client.mux.generation!.number, 2);
        h.client.reads.single.reply.completeError(failure);
        await h.flush();

        expect(h.errors, isEmpty, reason: 'the retired request cannot report a failure for the new follow');
        expect(h.carrier.follows, hasLength(2), reason: 'the already ready successor must be followed');
        h.snapshot(3, [1, 2, 3]);
        await h.flush();
        expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 3]);
      }),
    );

    test(
      'history error settling before retirement is checked again at recovery ($failure)',
      () => _scenario((h) async {
        h.event(3);
        await h.flush();
        h.client.reads.single.reply.completeError(failure);
        h.clock.run((_) => scheduleMicrotask(h.client.mux.reconnect));
        await h.flush();

        expect(h.client.mux.generation!.number, 2);
        expect(h.errors, isEmpty);
        expect(h.carrier.follows, hasLength(2));
        h.snapshot(3, [1, 2, 3]);
        await h.flush();
        expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 3]);
      }, connectionEvents: false),
    );
  }

  test(
    'retirement during route lookup cannot turn the old history failure into a new terminal error',
    () => _scenario((h) async {
      h.client.sessionsReply = Completer<List<SessionSummary>>();
      h.event(3);
      await h.flush();
      h.client.reads.single.reply.completeError(const DshRemoteException('session/agent-busy', 'find parent'));
      await h.flush();
      expect(h.client.sessionsReads, 1);
      expect(h.errors, isEmpty);
      h.reconnect();
      await h.flush();
      h.client.sessionsReply!.complete([]);
      await h.flush();

      expect(h.errors, isEmpty);
      expect(h.carrier.follows, hasLength(2));
      h.snapshot(3, [1, 2, 3]);
      await h.flush();
      expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 3]);
    }, connectionEvents: false),
  );

  test(
    'current HTTP 401 still waits for a genuinely new ready rather than busy retrying',
    () => _scenario((h) async {
      h.event(3);
      await h.flush();
      h.client.reads.single.reply.completeError(const DshHttpException(401, 'current cookie rejected'));
      await h.flush();
      expect(h.client.mux.generation!.number, 1);
      expect(h.carrier.follows, hasLength(1));
      expect(h.errors, isEmpty);
      expect(h.done, isFalse);
      h.reconnect();
      await h.flush();
      expect(h.carrier.follows, hasLength(2));
      h.snapshot(3, [1, 2, 3]);
      await h.flush();
      expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 3]);
    }),
  );

  test(
    'retired incomplete snapshot repairs cannot exhaust a successor retry budget',
    () => _scenario((h) async {
      h.reconnect();
      await h.flush();
      for (var attempt = 0; attempt < 6; attempt++) {
        h.snapshot(5, [5]);
        await h.flush();
        h.client.reads.last.reply.complete(HistoryPage(_events([3, 4]), false));
        h.clock.run((_) => scheduleMicrotask(() => scheduleMicrotask(h.client.mux.reconnect)));
        await h.flush();
        expect(h.errors, isEmpty, reason: 'retired repair $attempt');
        expect(h.carrier.follows, hasLength(attempt + 3));
      }
      h.snapshot(5, [1, 2, 3, 4, 5]);
      await h.flush();
      expect(h.seen.whereType<SessionSnapshotEvent>().map((s) => s.cursor), [0, 5]);
    }, syncEvents: true),
  );

  test(
    'current incomplete snapshot repairs still exhaust the bounded retry budget',
    () => _scenario((h) async {
      h.reconnect();
      await h.flush();
      for (var attempt = 0; attempt < 6; attempt++) {
        h.snapshot(5, [5]);
        await h.flush();
        h.client.reads.last.reply.complete(HistoryPage(_events([3, 4]), false));
        await h.flush();
        if (attempt < 5) expect(h.errors, isEmpty);
      }
      expect(h.errors.single, isA<DshProtocolException>());
      expect(h.done, isTrue);
      expect(h.client.mux.generation!.number, 2);
      expect(h.carrier.follows, hasLength(7));
    }, syncEvents: true),
  );

  test(
    'current terminal history error keeps its original code and ends the watch',
    () => _scenario((h) async {
      const failure = DshRemoteException('session/not-found', 'current session is gone');
      h.event(3);
      await h.flush();
      h.client.reads.single.reply.completeError(failure);
      await h.flush();
      expect(h.errors, [same(failure)]);
      expect(h.done, isTrue);
      expect(h.carrier.follows, hasLength(1));
    }),
  );

  test(
    'closing the client while history is pending still terminates without reopening',
    () => _scenario((h) async {
      h.event(3);
      await h.flush();
      unawaited(h.client.close());
      await h.flush();
      h.client.reads.single.reply.completeError(const DshClosedException('client closed'));
      await h.flush();
      expect(h.done, isTrue);
      expect(h.carrier.follows, hasLength(1));
      expect(h.errors, isEmpty);
    }),
  );

  test(
    'current repair keeps page boundaries and publishes the complete gap in sequence order',
    () => _scenario((h) async {
      h.event(5);
      await h.flush();
      expect(h.client.reads.single.through, 4);
      expect(h.client.reads.single.before, 5);
      h.client.reads.single.reply.complete(HistoryPage(_events([3, 4, 5]), true));
      await h.flush();
      expect(h.client.reads, hasLength(2));
      expect(h.client.reads.last.before, 3);
      expect(h.client.reads.last.through, 4);
      h.client.reads.last.reply.complete(HistoryPage(_events([0, 1, 2, 3]), false));
      await h.flush();

      expect(h.seen.whereType<SessionLogEvent>().map((e) => e.seq), [1, 2, 3, 4, 5]);
      expect(h.carrier.follows, hasLength(1));
      expect(h.errors, isEmpty);
    }),
  );
}
