import 'dart:async';

import 'package:dsh_app/ui/common/brief_notice.dart';
import 'package:dsh_app/ui/common/undo_notice_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Plan {
  final end = Completer<void>();
  bool get canUndo => !end.isCompleted;
  int cancels = 0;
  int commits = 0;

  /// Runs synchronously whenever the window ends (undo restoring a selection,
  /// or an early send), as the real archive plan's listeners can.
  VoidCallback? onEnd;
  bool cancel() {
    if (!canUndo) return false;
    cancels++;
    end.complete();
    onEnd?.call();
    return true;
  }

  bool commit() {
    if (!canUndo) return false;
    commits++;
    end.complete();
    onEnd?.call();
    return true;
  }

  /// Claims and, as the real flows do right after a valid claim, puts its
  /// notice up.
  UndoNoticeLease? claim(UndoNoticeIntent intent) {
    final lease = intent.claim(
      identity: this,
      canUndo: () => canUndo,
      cancel: cancel,
      commit: commit,
      windowClosed: end.future,
    );
    lease?.attach(
      _root,
      _root.showUndoNotice('plan $hashCode', undoLabel: '撤销', onUndo: cancel, window: const Duration(seconds: 4)),
    );
    return lease;
  }
}

late ScaffoldMessengerState _root;

Future<ScaffoldMessengerState> _messenger(WidgetTester tester) async {
  final key = GlobalKey<ScaffoldMessengerState>();
  await tester.pumpWidget(
    MaterialApp(
      scaffoldMessengerKey: key,
      home: const Scaffold(body: Text('home')),
    ),
  );
  return _root = key.currentState!;
}

void main() {
  testWidgets('reserve invalid B keeps A cancellable and delays error until A closes', (tester) async {
    final messenger = await _messenger(tester);
    final a = _Plan();
    a.claim(reserveUndoNotice(messenger));
    reserveUndoNotice(messenger); // validation fails; no claim.
    var shown = false;
    final result = publishAfterUndoNotice(messenger, () => messenger.mounted, () => shown = true);
    await tester.pump();
    expect(a.canUndo, isTrue);
    expect(a.cancels, 0);
    expect(shown, isFalse);
    a.cancel();
    await result;
    expect(shown, isTrue);
  });

  testWidgets('reserve before schedule retires B if synchronous schedule creates C', (tester) async {
    final messenger = await _messenger(tester);
    final a = _Plan();
    a.claim(reserveUndoNotice(messenger));
    final bIntent = reserveUndoNotice(messenger);
    final c = _Plan();
    UndoNoticeLease? cLease;
    // Models existing archive schedule cancelling A and restoring selection.
    a.onEnd = () => cLease = c.claim(reserveUndoNotice(messenger));
    a.cancel();
    final b = _Plan();
    expect(b.claim(bIntent), isNull);
    expect(b.canUndo, isFalse);
    expect(cLease!.isCurrent, isTrue);
    expect(c.canUndo, isTrue);
    c.cancel();
    await tester.pump();
  });

  testWidgets('claim publishes B identity before ending A; reentrant C wins', (tester) async {
    final messenger = await _messenger(tester);
    final a = _Plan();
    a.claim(reserveUndoNotice(messenger));
    final b = _Plan();
    final c = _Plan();
    UndoNoticeLease? cLease;
    a.onEnd = () => cLease = c.claim(reserveUndoNotice(messenger));
    expect(b.claim(reserveUndoNotice(messenger)), isNull);
    expect(a.commits, 1, reason: 'A loses its notice, so it is sent rather than dropped');
    expect(a.cancels, 0);
    expect(b.cancels, 1);
    expect(c.cancels, 0);
    await tester.pump(); // old window callbacks must not release C.
    expect(cLease!.isCurrent, isTrue);
    c.cancel();
    await tester.pump();
  });

  testWidgets('A result waits through B to C and retires when owner changes', (tester) async {
    final messenger = await _messenger(tester);
    final b = _Plan();
    b.claim(reserveUndoNotice(messenger));
    var owned = true;
    var publications = 0;
    final result = publishAfterUndoNotice(messenger, () => owned && messenger.mounted, () => publications++);
    final c = _Plan();
    c.claim(reserveUndoNotice(messenger));
    await tester.pump();
    expect(publications, 0);
    owned = false;
    c.cancel();
    await result;
    expect(publications, 0);
  });

  testWidgets('completed old window cannot release replacement or cause busy loop', (tester) async {
    final messenger = await _messenger(tester);
    final a = _Plan();
    a.claim(reserveUndoNotice(messenger));
    final b = _Plan();
    final lease = b.claim(reserveUndoNotice(messenger))!;
    expect(lease.replacedPrevious, isTrue);
    expect(a.commits, 1);
    expect(a.cancels, 0);
    await tester.pump();
    expect(lease.isCurrent, isTrue);
    var shown = 0;
    final done = publishAfterUndoNotice(messenger, () => true, () => shown++);
    await tester.pump();
    expect(shown, 0);
    b.cancel();
    await done;
    expect(shown, 1);
  });
  testWidgets('invalid C reservation while A ends does not retire valid B', (tester) async {
    final messenger = await _messenger(tester);
    final a = _Plan();
    a.claim(reserveUndoNotice(messenger));
    final b = _Plan();
    a.onEnd = () {
      reserveUndoNotice(messenger); // C validation fails synchronously, never claims.
    };
    final bLease = b.claim(reserveUndoNotice(messenger));
    expect(bLease, isNotNull);
    expect(a.commits, 1);
    expect(b.canUndo, isTrue);
    expect(b.cancels, 0);
    await tester.pump();
    expect(bLease!.isCurrent, isTrue);
    b.cancel();
    await tester.pump();
  });
}
