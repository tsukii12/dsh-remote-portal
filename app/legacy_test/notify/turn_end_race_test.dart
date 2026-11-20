import 'dart:async';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _DeferredSource extends FakeAlertSource {
  final pendingTurns = <Completer<TurnOutcome?>>[];
  Completer<List<SessionSummary>>? pendingList;

  @override
  Future<TurnOutcome?> lastTurn(String sessionId) {
    lastTurnCalls.add(sessionId);
    final pending = Completer<TurnOutcome?>();
    pendingTurns.add(pending);
    return pending.future;
  }

  @override
  Future<List<SessionSummary>> listSessions() => pendingList?.future ?? super.listSessions();
}

void main() {
  late _DeferredSource source;
  late List<ChatAlert> alerts;
  late HostAlertTracker tracker;

  setUp(() {
    source = _DeferredSource()..sessions = [session('s1', running: true)];
    alerts = [];
    tracker = HostAlertTracker(
      host: HostRef.none,
      source: source,
      onAlert: alerts.add,
      onWithdraw: (_, _, _) {},
      onSessionGone: (_, _) {},
    )..start();
  });
  tearDown(() => tracker.dispose());

  test('an old idle read cannot end a turn that has started since', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.emit(const SessionStatusEvent('s1', true));
    source.pendingTurns.single.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
  });

  test('idle running idle invalidates the first read even when idle again', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.emit(const SessionStatusEvent('s1', true));
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    expect(source.pendingTurns, hasLength(2));
    source.pendingTurns.first.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
    source.pendingTurns.last.complete(outcome(18, 'completed'));
    await settle();
    expect(alerts, hasLength(1));
  });

  test('a removed session cannot finish a phone task through a pending read', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.emit(const SessionRemovedEvent('s1'));
    source.pendingTurns.single.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
  });

  test('a delayed reconnect snapshot cannot overwrite a newer running edge', () async {
    await settle();
    source.pendingList = Completer<List<SessionSummary>>();
    source.emit(const HostReadyEvent('new-generation', '/root'));
    source.emit(const SessionStatusEvent('s1', true));
    source.pendingList!.complete([session('s1')]);
    await settle();
    for (final pending in source.pendingTurns) {
      pending.complete(outcome(8, 'completed'));
    }
    await settle();
    expect(alerts, isEmpty);
  });

  test('a prior generation read cannot finish after reconnect', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.emit(const HostReadyEvent('new-generation', '/root'));
    await settle();
    source.pendingTurns.first.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
  });

  test('reconnect rereads a pending idle outcome when the session remains idle', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.sessions = [session('s1')];
    source.emit(const HostReadyEvent('new-generation', '/root'));
    await settle();
    expect(source.pendingTurns, hasLength(2));
    source.pendingTurns.first.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
    source.pendingTurns.last.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, hasLength(1));
  });

  test('a duplicate idle push does not invalidate the only pending outcome', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    source.pendingTurns.single.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, hasLength(1));
  });

  test('a transient tail failure retries without reconnect and alerts once', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.pendingTurns.single.completeError(const DshTransportException('link interrupted'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(source.pendingTurns, hasLength(2));
    source.pendingTurns.last.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts.single.endSeq, 8);
    source.sessions = [session('s1')];
    source.emit(const HostReadyEvent('next-generation', '/root'));
    await settle();
    expect(source.pendingTurns, hasLength(2), reason: 'successful recovery clears pending idle');
    expect(alerts, hasLength(1));
  });

  test('two failed reads stop retrying but ready recovers the pending idle', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.pendingTurns.single.completeError(const DshTransportException('first failure'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(source.pendingTurns, hasLength(2));
    source.pendingTurns.last.completeError(const DshTransportException('second failure'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(source.pendingTurns, hasLength(2), reason: 'no unbounded retry loop');
    expect(alerts, isEmpty, reason: 'an unreadable outcome must not invent a notification');
    source.sessions = [session('s1')];
    source.emit(const HostReadyEvent('next-generation', '/root'));
    await settle();
    expect(source.pendingTurns, hasLength(3));
    source.pendingTurns.last.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts.single.endSeq, 8);
  });

  for (final error in [
    const DshHttpException(401, 'login required'),
    const DshHttpException(403, 'forbidden'),
    const DshHttpException(404, 'not found'),
    const DshRemoteException('session/not-found', 'gone'),
  ]) {
    test('a permanent tail refusal is not retried: $error', () async {
      await settle();
      source.emit(const SessionStatusEvent('s1', false));
      await settle();
      source.pendingTurns.single.completeError(error);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(source.pendingTurns, hasLength(1));
      expect(alerts, isEmpty);
    });
  }

  test('a reliable null tail is neither retried nor recovered on ready', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.pendingTurns.single.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    source.sessions = [session('s1')];
    source.emit(const HostReadyEvent('next-generation', '/root'));
    await settle();
    expect(source.pendingTurns, hasLength(1));
    expect(alerts, isEmpty);
  });

  for (final invalidation in ['running', 'removed', 'disposed', 'ready']) {
    test('$invalidation during retry delay retires the old read', () async {
      await settle();
      source.emit(const SessionStatusEvent('s1', false));
      await settle();
      source.pendingTurns.single.completeError(const DshTransportException('interrupted'));
      await settle();
      switch (invalidation) {
        case 'running':
          source.emit(const SessionStatusEvent('s1', true));
        case 'removed':
          source.emit(const SessionRemovedEvent('s1'));
        case 'disposed':
          await tracker.dispose();
        case 'ready':
          source.sessions = [session('s1')];
          source.emit(const HostReadyEvent('next-generation', '/root'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(source.pendingTurns, hasLength(invalidation == 'ready' ? 2 : 1));
      expect(alerts, isEmpty);
      if (invalidation == 'ready') {
        source.pendingTurns.last.complete(outcome(8, 'completed'));
        await settle();
        expect(alerts.single.endSeq, 8);
      }
    });
  }

  test('a retry already in flight cannot finish a newer turn', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    source.pendingTurns.single.completeError(const DshTransportException('interrupted'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(source.pendingTurns, hasLength(2));
    source.emit(const SessionStatusEvent('s1', true));
    source.emit(const SessionStatusEvent('s1', false));
    await settle();
    expect(source.pendingTurns, hasLength(3));
    source.pendingTurns[1].complete(outcome(8, 'completed'));
    await settle();
    expect(alerts, isEmpty);
    source.pendingTurns.last.complete(outcome(18, 'completed'));
    await settle();
    expect(alerts.single.endSeq, 18);
  });

  test('a timed-out tail cannot alert later than its successful retry', () async {
    await settle();
    source.emit(const SessionStatusEvent('s1', false));
    await Future<void>.delayed(const Duration(milliseconds: 3350));
    expect(source.pendingTurns, hasLength(2));
    source.pendingTurns.first.complete(outcome(7, 'aborted'));
    await settle();
    expect(alerts, isEmpty);
    source.pendingTurns.last.complete(outcome(8, 'completed'));
    await settle();
    expect(alerts.single.endSeq, 8);
    expect(alerts.single.kind, AlertKind.done);
  });

  test('a new turn start in the history tail invalidates the old end', () {
    SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
        SessionLogEvent.fromJson({'seq': seq, 'time': 1792712155483, 'type': type, 'data': data});
    expect(
      outcomeFromEvents([
        event(8, 'turn/end', {
          'turn': 1,
          'reason': {'kind': 'completed'},
        }),
        event(9, 'turn/start', {'turn': 2}),
      ]),
      isNull,
    );
  });
}
