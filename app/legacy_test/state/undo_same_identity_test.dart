import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/undo_notice_window.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';

class _ArchiveHost extends FakeWorkspaceHost {
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspace/archiveSession') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    final request = args['request']! as Map;
    archived = [...archived, request['sessionId']! as String];
    push({'type': 'archived', 'archivedSessionIds': archived});
    return RpcOk({'archivedSessionIds': archived});
  }
}

void main() {
  for (final same in [true, false]) {
    testWidgets('stale outer claim respects current identity: same=$same', (tester) async {
      final key = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(MaterialApp(scaffoldMessengerKey: key, home: const Scaffold()));
      final root = key.currentState!;
      final bIntent = reserveUndoNotice(root);
      final identity = Object();
      final bEnd = Completer<void>();
      final cEnd = same ? bEnd : Completer<void>();
      var bCancelled = 0;
      final cLease = reserveUndoNotice(root).claim(
        identity: same ? identity : Object(),
        canUndo: () => !cEnd.isCompleted,
        cancel: () {
          if (cEnd.isCompleted) return false;
          cEnd.complete();
          return true;
        },
        commit: () {
          if (cEnd.isCompleted) return false;
          cEnd.complete();
          return true;
        },
        windowClosed: cEnd.future,
      )!;
      addTearDown(() {
        if (!bEnd.isCompleted) bEnd.complete();
        if (!cEnd.isCompleted) cEnd.complete();
      });
      final result = bIntent.claim(
        identity: identity,
        canUndo: () => !bEnd.isCompleted,
        cancel: () {
          bCancelled++;
          bEnd.complete();
          return true;
        },
        commit: () {
          bCancelled++;
          bEnd.complete();
          return true;
        },
        windowClosed: bEnd.future,
      );
      if (same) {
        expect(identical(result, cLease), isTrue);
        expect(bCancelled, 0);
        expect(cEnd.isCompleted, isFalse);
      } else {
        expect(result, isNull);
        expect(bCancelled, 1);
        expect(cEnd.isCompleted, isFalse);
      }
      await tester.pump();
      expect(cLease.isCurrent, isTrue);
    });
  }

  testWidgets('real archive same ids reentry keeps the inner winner pending', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final host = _ArchiveHost();
    host.seedSession('s1', 'Same identity', DateTime.utc(2026, 10, 28));
    host.seedWorkspace('/root/code', title: 'Project', sessionIds: ['s1']);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        overrides: workspaceOverrides(
          host,
          current: 's1',
          prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final context = tester.element(find.byType(HomeShell));
    final root = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context);
    final client = container.read(activeConnectionProvider).value!.client;
    addTearDown(client.close);
    final controller = container.read(sessionsProvider.notifier);
    PendingSessionArchive? inner;
    UndoNoticeLease? innerLease;
    var entered = false;
    final sub = container.listen(currentSessionProvider, (_, next) {
      if (next != null || entered) return;
      entered = true;
      final intent = reserveUndoNotice(root);
      final pending = controller.scheduleArchive(['s1']);
      inner = pending;
      innerLease = intent.claim(
        identity: pending,
        canUndo: () => pending.canUndo,
        cancel: pending.cancel,
        commit: pending.commitNow,
        windowClosed: pending.windowClosed,
      );
    });
    addTearDown(sub.close);
    final outerIntent = reserveUndoNotice(root);
    final outer = controller.scheduleArchive(['s1']);
    addTearDown(() {
      if (outer.canUndo) outer.cancel();
      outer.release();
    });
    expect(entered, isTrue);
    expect(identical(outer, inner), isTrue, reason: 'production same-ids early return shares pending');
    expect(innerLease!.isCurrent, isTrue);
    expect(identical(innerLease!.identity, inner), isTrue);
    final outerLease = outerIntent.claim(
      identity: outer,
      canUndo: () => outer.canUndo,
      cancel: outer.cancel,
      commit: outer.commitNow,
      windowClosed: outer.windowClosed,
    );
    // The actual archive UI recognizes this as non-owning duplicate and returns
    // without cancel or release; null would take its release branch instead.
    expect(identical(outerLease, innerLease), isTrue);
    expect(outer.canUndo, isTrue);
    expect(outer.owned, isTrue);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect((await outer.done)!.archived, ['s1']);
    expect(outer.owned, isTrue);
    // While the inner owner still holds its result lease, a Host round trip
    // must retire it. Premature outer release would remove this tracking.
    final originalHost = container.read(activeHostProvider);
    container.read(activeHostProvider.notifier).select(const HostRef.portal('fixture-other'));
    container.read(activeHostProvider.notifier).select(originalHost);
    expect(outer.owned, isFalse);
  });
}
