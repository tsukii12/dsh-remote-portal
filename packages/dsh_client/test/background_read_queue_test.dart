// The list-read queue on fake time: a fake worker stands in for the isolate
// and its HTTP read, so the admission limits and stage budgets are measured
// in seconds that do not pass.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshTransportException;
import 'package:dsh_client/src/background_session_read.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// Workers whose HTTP read takes [read]; a granted parse finishes at once.
final class SlowWorkers {
  SlowWorkers(this.read);

  final Duration read;
  int active = 0;
  int peak = 0;

  BackgroundReadWorker spawn(BackgroundListRequest request, BackgroundReadEvents events) =>
      _SlowWorker(this, request, events);
}

final class _SlowWorker implements BackgroundReadWorker {
  _SlowWorker(this.workers, this.request, this.events) {
    workers.active++;
    if (workers.active > workers.peak) workers.peak = workers.active;
    _reading = Timer(workers.read, events.bodyReady);
  }

  final SlowWorkers workers;
  final BackgroundListRequest request;
  final BackgroundReadEvents events;
  late final Timer _reading;
  bool _gone = false;

  void _exit() {
    if (_gone) return;
    _gone = true;
    workers.active--;
    events.exited();
  }

  @override
  void parse() => Timer.run(() {
    events.result(request.rpcId);
    _exit();
  });

  @override
  void kill() {
    _reading.cancel();
    Timer.run(_exit);
  }
}

BackgroundListRequest listRead(int index, {Duration timeout = const Duration(seconds: 120)}) => BackgroundListRequest(
  uri: Uri.parse('http://127.0.0.1:1/api/session/list'),
  kind: BackgroundListKind.sessions,
  rpcId: 'read-$index',
  connectTimeout: const Duration(seconds: 5),
  requestTimeout: timeout,
);

void main() {
  test('2 slots, 9 reads of 5 s each: all complete, none times out waiting for a slot', () {
    fakeAsync((async) {
      final workers = SlowWorkers(const Duration(seconds: 5));
      final reads = BackgroundListReads(scheduler: BackgroundReadScheduler(spawn: workers.spawn));
      final done = <Object?>[];
      final failed = <Object>[];
      for (var i = 0; i < 9; i++) {
        reads.read(listRead(i)).then(done.add, onError: failed.add);
      }
      async.elapse(const Duration(seconds: 15));
      expect(done, hasLength(6), reason: 'three rounds of two in 15 s');
      expect(failed, isEmpty, reason: 'reads 4-8 waited 10-20 s for a slot, past the old 10 s queue budget');
      async.elapse(const Duration(seconds: 10));
      expect(failed, isEmpty);
      expect(done, unorderedEquals([for (var i = 0; i < 9; i++) 'read-$i']));
      expect(workers.peak, 2, reason: 'never more than two active');
      expect(workers.active, 0);
    });
  });

  test('waiting for a slot gets the request\'s own budget, then times out', () {
    fakeAsync((async) {
      final workers = SlowWorkers(const Duration(seconds: 3));
      final reads = BackgroundListReads(scheduler: BackgroundReadScheduler(spawn: workers.spawn));
      final outcomes = <String, Object?>{};
      for (var i = 0; i < 5; i++) {
        reads
            .read(listRead(i, timeout: const Duration(seconds: 4)))
            .then((value) => outcomes['read-$i'] = value, onError: (Object error) => outcomes['read-$i'] = error);
      }
      async.elapse(const Duration(seconds: 3, milliseconds: 999));
      expect(outcomes.keys, unorderedEquals(['read-0', 'read-1']));
      async.elapse(const Duration(milliseconds: 1));
      // Reads 2 and 3 started at 3 s; read 4 has waited its 4 s.
      expect(
        outcomes['read-4'],
        isA<DshTransportException>().having((e) => e.message, 'message', contains('background queue timed out')),
      );
      async.elapse(const Duration(seconds: 3));
      expect(outcomes['read-2'], 'read-2');
      expect(outcomes['read-3'], 'read-3');
    });
  });

  test('two active and eight waiting: the next read is refused at once', () {
    fakeAsync((async) {
      final workers = SlowWorkers(const Duration(seconds: 5));
      final reads = BackgroundListReads(scheduler: BackgroundReadScheduler(spawn: workers.spawn));
      final failed = <Object>[];
      for (var i = 0; i < 10; i++) {
        reads.read(listRead(i)).ignore();
      }
      reads.read(listRead(10)).then((_) {}, onError: failed.add);
      async.flushMicrotasks();
      expect(
        failed.single,
        isA<DshTransportException>().having((e) => e.message, 'message', contains('queue is full')),
      );
      expect(workers.active, 2);
      reads.close();
      async.elapse(const Duration(seconds: 1));
      expect(workers.active, 0, reason: 'closing retires the active workers too');
    });
  });
}
