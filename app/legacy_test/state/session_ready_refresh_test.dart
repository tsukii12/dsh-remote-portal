import 'dart:async';

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'read_list_refresh_test.dart' show ListHost, listOverrides;

Future<T> _finish<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then<void>(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  for (var i = 0; !done && i < 20; i++) {
    await tester.pump(Duration.zero);
  }
  expect(done, isTrue, reason: 'all controlled completions must drain');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return future;
}

class _Harness {
  _Harness(this.host, this.container, this.first);
  final ListHost host;
  final ProviderContainer container;
  final Future<List<SessionSummary>> first;
  List<Completer<Object?>> get reads => host.requests['sessions']!;
  SessionsController get sessions => container.read(sessionsProvider.notifier);

  static Future<_Harness> start(WidgetTester tester) async {
    final host = ListHost('host')..paused.add('sessions');
    final container = ProviderContainer(overrides: listOverrides(host));
    container.listen(sessionsProvider, (_, _) {});
    final h = _Harness(host, container, container.read(sessionsProvider.future));
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(h.reads, hasLength(1));
    expect(host.client.mux.generation, isNotNull);
    expect(container.read(sessionsProvider).isLoading, isTrue);
    addTearDown(() async {
      container.dispose();
      for (final read in h.reads) {
        if (!read.isCompleted) read.complete(ListHost.sessions('cleanup'));
      }
      await host.client.close();
    });
    return h;
  }

  void reply(int index, String label) => reads[index].complete(ListHost.sessions(label));

  Future<void> firstCompletes(WidgetTester tester) async {
    reply(0, 'initial');
    await _finish(tester, first);
  }

  Future<void> freshCompletes(WidgetTester tester) async {
    final fresh = sessions.refresh();
    expect(reads, hasLength(2));
    reply(1, 'fresh');
    await _finish(tester, fresh);
    expect(container.read(sessionsProvider).requireValue.single.sessionId, 'fresh-0');
  }

  Future<void> deadline(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pump(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('post-ready successful refresh covers the earlier ready-only debounce', (tester) async {
    final h = await _Harness.start(tester);
    await h.firstCompletes(tester);
    // This request is explicitly started after ready, not merely completed
    // after it. It has also been successfully adopted before the timer fires.
    await h.freshCompletes(tester);
    await h.deadline(tester);
    expect(h.reads, hasLength(2));
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'fresh-0');
  });

  testWidgets('a pre-ready request finishing early does not cover ready', (tester) async {
    final h = await _Harness.start(tester);
    await h.firstCompletes(tester);
    await h.deadline(tester);
    expect(h.reads, hasLength(2));
    h.reply(1, 'after-ready');
    await tester.pump(Duration.zero);
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'after-ready-0');
  });

  testWidgets('a failed post-ready refresh does not suppress the ready retry', (tester) async {
    final h = await _Harness.start(tester);
    await h.firstCompletes(tester);
    final failed = h.sessions.refresh();
    h.reads[1].completeError(const DshRemoteException('test/failed', 'controlled failure'));
    await _finish(tester, failed);
    await h.deadline(tester);
    expect(h.reads, hasLength(3));
    h.reply(2, 'recovered');
    await tester.pump(Duration.zero);
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'recovered-0');
  });

  testWidgets('a still-pending post-ready refresh does not suppress ready', (tester) async {
    final h = await _Harness.start(tester);
    await h.firstCompletes(tester);
    final pending = h.sessions.refresh();
    expect(h.reads, hasLength(2));
    await h.deadline(tester);
    expect(h.reads, hasLength(3));
    h.reply(2, 'newest');
    h.reply(1, 'older');
    await _finish(tester, pending);
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'newest-0');
  });

  testWidgets('non-ready changes still request a list after an earlier fresh read', (tester) async {
    final h = await _Harness.start(tester);
    await h.firstCompletes(tester);
    await h.freshCompletes(tester);
    h.host.carrier.link!.push({
      'type': 'emit',
      'event': 'api-session/status',
      'args': ['not-listed-yet', true],
    });
    await tester.pump(Duration.zero);
    await h.deadline(tester);
    expect(h.reads, hasLength(3));
    h.reply(2, 'after-change');
    await tester.pump(Duration.zero);
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'after-change-0');
  });

  for (final failed in [false, true]) {
    testWidgets('an earlier success does not cover a later ${failed ? 'failed' : 'pending'} read', (tester) async {
      final h = await _Harness.start(tester);
      await h.firstCompletes(tester);
      await h.freshCompletes(tester);
      final latest = h.sessions.refresh();
      expect(h.reads, hasLength(3));
      if (failed) {
        h.reads[2].completeError(const DshRemoteException('test/failed', 'controlled latest failure'));
        await _finish(tester, latest);
      }
      await h.deadline(tester);
      expect(h.reads, hasLength(4));
      h.reply(3, 'after-latest');
      if (!failed) h.reply(2, 'stale');
      await _finish(tester, latest);
      await tester.pump(Duration.zero);
      expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'after-latest-0');
    });
  }

  testWidgets('a later mux generation ready is not covered by the earlier fresh read', (tester) async {
    final h = await _Harness.start(tester);
    // Retire the first ready timer while its initial list is still pending,
    // preserving the baseline's existing slow-read behavior in this control.
    await h.deadline(tester);
    await h.firstCompletes(tester);
    await h.freshCompletes(tester);
    final previous = h.host.client.mux.generation;
    h.host.client.mux.reconnect();
    final ready = h.host.client.mux.ready();
    await tester.pump(const MuxOptions().retryCaps.first);
    await _finish(tester, ready);
    expect(h.host.client.mux.generation, isNot(same(previous)));
    await h.deadline(tester);
    expect(h.reads, hasLength(3));
    h.reply(2, 'new-generation');
    await tester.pump(Duration.zero);
    expect(h.container.read(sessionsProvider).requireValue.single.sessionId, 'new-generation-0');
  });
}
