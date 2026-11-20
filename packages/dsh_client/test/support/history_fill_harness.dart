import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'fake_dsh.dart';

Map<String, Object?> historyFrame(int seq) => {
  'type': 'event',
  'event': {
    'type': 'session/title',
    'seq': seq,
    'time': seq,
    'data': {'title': 'record-$seq'},
  },
};

Map<String, Object?> historySnapshot(int cursor, List<Map<String, Object?>> records) => {
  'type': 'snapshot',
  'header': {'version': 4, 'id': 's', 'createdAt': 0, 'isSeeded': false},
  'cursor': cursor,
  'records': records,
  'hasMore': true,
  'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
};

/// Holds the *decoded result after the real RPC returned*, not network traffic.
class HeldHistoryClient extends DshClient {
  HeldHistoryClient(super.connection);

  final entered = Completer<void>();
  final release = Completer<void>();
  final returned = Completer<void>();
  bool holdNext = false;
  final attempts = <({int through, int? before})>[];

  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) async {
    attempts.add((through: throughSeq, before: beforeSeq));
    final page = await super.history(
      sessionId,
      throughSeq: throughSeq,
      beforeSeq: beforeSeq,
      maxMessages: maxMessages,
      turnWindow: turnWindow,
    );
    if (holdNext) {
      holdNext = false;
      entered.complete();
      try {
        await release.future;
      } finally {
        returned.complete();
      }
    }
    return page;
  }
}

/// Fixed server pages keyed by the exact requested beforeSeq. No fill algorithm
/// is implemented here: product watch decides which request to issue next.
class HistoryFillHarness {
  HistoryFillHarness._(this.host, this.client, this.cursor, this.pages);

  final FakeDsh host;
  final HeldHistoryClient client;
  final int cursor;
  final Map<int, List<Map<String, Object?>>> pages;
  final requests = <Map<String, Object?>>[];
  final snapshots = <SessionSnapshotEvent>[];
  final errors = <Object>[];
  final failure = Completer<void>();
  final logs = <SessionLogEvent>[];
  final liveLast = Completer<SessionLogEvent>();
  FakeMuxSocket? followSocket;
  String? followId;
  bool closing = false;

  Future<T> guard<T>(Future<T> future) =>
      Future.any([future, failure.future.then<T>((_) => throw StateError('Unexpected failure signal success'))]);

  void emitLiveGap() => followSocket!.item(followId!, historyFrame(cursor));
  final first = Completer<SessionSnapshotEvent>();
  final recovered = Completer<SessionSnapshotEvent>();
  StreamSubscription<DshEvent>? subscription;
  int opens = 0;
  bool replacementComplete = false;

  static Future<HistoryFillHarness> start({
    required int cursor,
    required Map<int, List<Map<String, Object?>>> pages,
    bool includeSyncEvents = true,
    Set<int> lastPages = const {},
  }) async {
    final host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    try {
      await connection.login(FakeDsh.token);
    } catch (_) {
      connection.close();
      await host.close();
      rethrow;
    }
    final harness = HistoryFillHarness._(host, HeldHistoryClient(connection), cursor, pages);
    host.handlers['session/page'] = (args) {
      final request = Map<String, Object?>.from(args['request']! as Map);
      harness.requests.add(request);
      final before = request['beforeSeq']! as int;
      final records = pages[before];
      if (records == null) throw StateError('Unexpected page cursor $before');
      return {
        'ok': true,
        'value': {'records': records, 'hasMore': !lastPages.contains(before)},
      };
    };
    host.onOpen = (socket, id, endpoint, payload) {
      if (endpoint != 'session/follow') return;
      harness.followSocket = socket;
      harness.followId = id;
      harness.opens++;
      final records = harness.opens == 1
          ? [historyFrame(0)]
          : harness.replacementComplete
          ? [for (var seq = 1; seq <= cursor; seq++) historyFrame(seq)]
          : [historyFrame(cursor)];
      socket.item(id, historySnapshot(harness.opens == 1 ? 0 : cursor, records));
    };
    harness.subscription = harness.client
        .watch('s', options: WatchOptions(includeSyncEvents: includeSyncEvents, includeHostEvents: false))
        .listen(
          (event) {
            if (event is SessionLogEvent) {
              harness.logs.add(event);
              if (event.seq == cursor && !harness.liveLast.isCompleted) harness.liveLast.complete(event);
            }
            if (event is! SessionSnapshotEvent) return;
            harness.snapshots.add(event);
            final target = event.cursor == 0 ? harness.first : harness.recovered;
            if (!target.isCompleted) target.complete(event);
          },
          onError: (Object error, StackTrace stack) {
            harness.errors.add(error);
            if (!harness.failure.isCompleted) harness.failure.completeError(error, stack);
          },
          onDone: () {
            if (!harness.closing && !harness.failure.isCompleted) {
              harness.failure.completeError(StateError('watch ended before fixture cleanup'));
            }
          },
        );
    try {
      await harness.guard(harness.first.future);
      return harness;
    } catch (_) {
      await harness.close();
      rethrow;
    }
  }

  void reconnect() => client.mux.reconnect();

  Future<void> close() async {
    closing = true;
    if (!client.release.isCompleted) client.release.complete();
    await subscription?.cancel();
    if (client.entered.isCompleted) await client.returned.future;
    await client.close();
    await host.close();
  }
}
