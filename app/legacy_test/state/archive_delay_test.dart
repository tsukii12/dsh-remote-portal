import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _ArchiveHost extends FakeWorkspaceHost {
  bool failUndo = false;
  final failArchiveIds = <String>{};
  Completer<void>? archiveGate;
  Completer<void>? undoGate;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspace/archiveSession' && endpoint != 'workspace/unarchiveSession') {
      return super.call(endpoint, args, timeout: timeout);
    }
    calls.add((endpoint, args));
    if (endpoint == 'workspace/unarchiveSession' && failUndo) {
      return const RpcError(DshRemoteException('foo/bar', 'private failure'));
    }
    final request = args['request']! as Map;
    final id = request['sessionId']! as String;
    if (endpoint == 'workspace/archiveSession') {
      if (archiveGate case final gate?) await gate.future;
      if (failArchiveIds.contains(id)) return const RpcError(DshRemoteException('fixture/denied', 'denied'));
      archived = [...archived, id];
      pinned = pinned.where((value) => value != id).toList();
      push({'type': 'pinned', 'pinnedSessionIds': pinned});
    } else {
      if (undoGate case final gate?) await gate.future;
      archived = archived.where((value) => value != id).toList();
    }
    push({'type': 'archived', 'archivedSessionIds': archived});
    return RpcOk({'archivedSessionIds': archived});
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<(_ArchiveHost, ProviderContainer)> start(WidgetTester tester, {bool running = false}) async {
    final host = _ArchiveHost();
    host.seedSession('s1', '归档测试', DateTime.now(), running: running);
    host.seedWorkspace('/root/code', title: '项目', sessionIds: ['s1']);
    host.pinned = ['s1'];
    final initialConnection = workspaceHost(host);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        overrides: [
          ...workspaceOverrides(
            host,
            current: 's1',
            prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
          ).skip(1),
          switchConnectionProvider.overrideWith(() => SwitchConnection(initialConnection)),
          activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        ],
      ),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    final client = container.read(activeConnectionProvider).value!.client;
    addTearDown(client.close);
    return (host, container);
  }

  Future<void> archive(WidgetTester tester) async {
    await tester.longPress(find.widgetWithText(SessionTile, '归档测试'));
    await _settle(tester);
    await tester.tap(find.text('归档'));
    await _settle(tester);
  }

  Future<void> addSecond(WidgetTester tester, _ArchiveHost host, ProviderContainer container) async {
    host.seedSession('s2', 'Second', DateTime.now());
    host.workspaces.first['sessionIds'] = ['s1', 's2'];
    host.push({'type': 'upsert', 'workspace': host.workspaces.first});
    await container.read(sessionsProvider.notifier).refresh();
    await _settle(tester);
  }

  PendingSessionArchive plan(ProviderContainer c, List<String> ids) {
    final p = c.read(sessionsProvider.notifier).scheduleArchive(ids);
    addTearDown(p.release);
    return p;
  }

  for (final bulk in [false, true]) {
    testWidgets('real drawer delays archive and undo sends zero requests: bulk=$bulk', (tester) async {
      final (host, container) = await start(tester);
      if (bulk) {
        container.read(drawerSelectionProvider.notifier).start('s1');
        await _settle(tester);
        await tester.tap(find.text('归档'));
        await _settle(tester);
      } else {
        await archive(tester);
      }
      expect(host.argsOf('workspace/archiveSession'), isEmpty);
      expect(find.widgetWithText(SessionTile, '归档测试'), findsNothing);
      expect(find.text(bulk ? '已归档 1 个对话' : '已归档「归档测试」'), findsOneWidget);
      expect(container.read(currentSessionProvider), isNull);
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(host.argsOf('workspace/archiveSession'), isEmpty);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      expect(container.read(currentSessionProvider), 's1');
      expect(host.pinned, ['s1']);
      expect(find.widgetWithText(SessionTile, '归档测试'), findsOneWidget);
    });
  }

  testWidgets('four seconds is the pre-dispatch boundary, not unarchive compensation', (tester) async {
    final (host, container) = await start(tester);
    final p = plan(container, ['s1']);
    await tester.pump(const Duration(milliseconds: 3999));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect((await p.done)!.archived, ['s1']);
    expect(p.canUndo, isFalse);
    expect(p.cancel(), isFalse);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
  });

  testWidgets('refresh preserves waiting mask and undo uses the latest rows', (tester) async {
    final (host, container) = await start(tester);
    final p = plan(container, ['s1']);
    await container.read(sessionsProvider.notifier).refresh();
    expect(container.read(sessionsProvider).value, isEmpty);
    expect(p.cancel(), isTrue);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), contains('s1'));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('replacement sends the old plan at once; duplicate and stale handles cannot dispatch again', (
    tester,
  ) async {
    final (host, container) = await start(tester);
    await addSecond(tester, host, container);
    final first = plan(container, ['s1']);
    expect(identical(plan(container, ['s1']), first), isTrue);
    final second = plan(container, ['s2']);
    expect(second.replacedPrevious, isTrue);
    expect(first.sent, isTrue, reason: 'its notice is replaced, so it is sent rather than dropped');
    expect((await first.done)!.archived, ['s1']);
    expect(first.cancel(), isFalse);
    expect(first.undo(), isFalse);
    expect(second.canUndo, isTrue);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), isEmpty);
    expect(second.undo(), isTrue);
    expect(second.undone, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession').map((call) => (call['request'] as Map)['sessionId']), ['s1']);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
  });

  testWidgets('invalid replacement leaves the valid old timer and undo intact', (tester) async {
    final (host, container) = await start(tester);
    final first = plan(container, ['s1']);
    expect(() => plan(container, ['missing']), throwsA(isA<DshClosedException>()));
    expect(first.canUndo, isTrue);
    first.cancel();
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('undo does not steal a newer selection even if it returns to null', (tester) async {
    final (_, container) = await start(tester);
    final p = plan(container, ['s1']);
    container.read(currentSessionProvider.notifier).select('other');
    container.read(currentSessionProvider.notifier).select(null);
    p.cancel();
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('explicit new chat while already null prevents undo selection restore', (tester) async {
    final (_, container) = await start(tester);
    final p = plan(container, ['s1']);
    container.read(currentSessionProvider.notifier).select(null);
    p.cancel();
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('synchronous selection listener choice is not adopted as the plan revision', (tester) async {
    final (_, container) = await start(tester);
    var changed = false;
    final sub = container.listen(currentSessionProvider, (previous, next) {
      if (next == null && !changed) {
        changed = true;
        container.read(currentSessionProvider.notifier).select('listener-choice');
        container.read(currentSessionProvider.notifier).select(null);
      }
    });
    addTearDown(sub.close);
    final p = plan(container, ['s1']);
    p.cancel();
    expect(container.read(currentSessionProvider), isNull);
  });

  testWidgets('synchronous owner change while clearing selection does not arm a retired timer', (tester) async {
    final (host, container) = await start(tester);
    var changed = false;
    final sub = container.listen(currentSessionProvider, (previous, next) {
      if (next == null && !changed) {
        changed = true;
        container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
      }
    });
    addTearDown(sub.close);
    final p = plan(container, ['s1']);
    await tester.pump(const Duration(seconds: 5));
    expect(await p.done, isNull);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('replacement sends the older plan without restoring its selection, so no listener reenters', (
    tester,
  ) async {
    final (host, container) = await start(tester);
    await addSecond(tester, host, container);
    host.seedSession('s3', 'Third', DateTime.now());
    await container.read(sessionsProvider.notifier).refresh();
    final first = plan(container, ['s1']);
    PendingSessionArchive? third;
    final sub = container.listen(currentSessionProvider, (previous, next) {
      if (next == 's1' && third == null) third = plan(container, ['s3']);
    });
    addTearDown(sub.close);
    final outer = plan(container, ['s2']);
    expect(outer.replacedPrevious, isTrue);
    expect((await first.done)!.archived, ['s1']);
    expect(third, isNull, reason: 'a sent plan gives the selection back only if it fails');
    expect(container.read(currentSessionProvider), isNull);
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession').map((call) => (call['request'] as Map)['sessionId']), [
      's1',
      's2',
    ]);
    expect((await outer.done)!.archived, ['s2']);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s3']);
  });

  for (final boundary in ['host', 'round-trip', 'reconnect', 'dispose']) {
    testWidgets('waiting plan retires without dispatch: $boundary', (tester) async {
      final (host, container) = await start(tester);
      final connectionA = container.read(activeConnectionProvider).value!;
      final p = plan(container, ['s1']);
      if (boundary == 'host' || boundary == 'round-trip') {
        final b = _ArchiveHost();
        b.seedSession('s1', 'Other owner', DateTime.now());
        final connectionB = workspaceHost(b, local: false);
        addTearDown(connectionB.client.close);
        container.read(switchConnectionProvider.notifier).set(connectionB);
        container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
        if (boundary == 'round-trip') {
          container.read(switchConnectionProvider.notifier).set(connectionA);
          container.read(activeHostProvider.notifier).select(HostRef.none);
        }
      } else if (boundary == 'reconnect') {
        connectionA.client.mux.reconnect();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump(const Duration(seconds: 5));
      expect(await p.done, isNull);
      expect(host.argsOf('workspace/archiveSession'), isEmpty);
    });
  }

  testWidgets('leaving the screen sends a waiting plan at once, and only once', (tester) async {
    // The notice said 已归档 and its 撤销 leaves with the screen; the process
    // may be killed from recents before the window would have ended.
    final (host, container) = await start(tester);
    final p = plan(container, ['s1']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(p.sent, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect((await p.done)!.archived, ['s1']);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
  });

  testWidgets('a plan dropped by a reconnect says it was not archived and brings the row back', (tester) async {
    final (host, container) = await start(tester);
    await archive(tester);
    expect(find.text('已归档「归档测试」'), findsOneWidget);
    container.read(activeConnectionProvider).value!.client.mux.reconnect();
    await _settle(tester);
    expect(find.text('没能归档，稍后再试'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '撤销'), findsNothing);
    expect(find.widgetWithText(SessionTile, '归档测试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('撤销 says nothing more', (tester) async {
    final (host, _) = await start(tester);
    await archive(tester);
    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('partial failure restores only failed rows and leaves success archived', (tester) async {
    final (host, container) = await start(tester);
    await addSecond(tester, host, container);
    host.failArchiveIds.add('s1');
    final p = plan(container, ['s1', 's2']);
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    final result = (await p.done)!;
    expect(result.failed, ['s1']);
    expect(result.archived, ['s2']);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s1']);
    expect(container.read(currentSessionProvider), 's1');
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
  });

  testWidgets('committing batch cannot undo; host change retires its unsent remainder', (tester) async {
    final (host, container) = await start(tester);
    await addSecond(tester, host, container);
    final gate = host.archiveGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final p = plan(container, ['s1', 's2']);
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(p.canUndo, isFalse);
    expect(p.cancel(), isFalse);
    final b = _ArchiveHost();
    b.seedSession('s1', 'B', DateTime.now());
    final connectionB = workspaceHost(b, local: false);
    addTearDown(connectionB.client.close);
    container.read(switchConnectionProvider.notifier).set(connectionB);
    container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
    await _settle(tester);
    container.read(currentSessionProvider.notifier).select('new-owner-selection');
    gate.complete();
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession'), hasLength(1));
    expect(b.argsOf('workspace/archiveSession'), isEmpty);
    expect(container.read(currentSessionProvider), 'new-owner-selection');
    expect(await p.done, isNull);
  });
  for (final outcome in ['success', 'failure', 'third', 'host', 'route']) {
    testWidgets('late committing result preserves newer undo: $outcome', (tester) async {
      final (host, container) = await start(tester);
      await addSecond(tester, host, container);
      host.seedSession('s3', 'Third', DateTime.now());
      host.workspaces.first['sessionIds'] = ['s1', 's2', 's3'];
      host.push({'type': 'upsert', 'workspace': host.workspaces.first});
      await container.read(sessionsProvider.notifier).refresh();
      await _settle(tester);
      final gate = host.archiveGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await archive(tester);
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(host.argsOf('workspace/archiveSession'), hasLength(1));
      await tester.longPress(find.widgetWithText(SessionTile, 'Second'));
      await _settle(tester);
      await tester.tap(find.text('归档'));
      await _settle(tester);
      final oldUndo = tester.widget<SnackBarAction>(find.widgetWithText(SnackBarAction, '撤销')).onPressed;
      if (outcome == 'failure') host.failArchiveIds.add('s1');
      gate.complete();
      await _settle(tester);
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      if (outcome == 'third') {
        await tester.longPress(find.widgetWithText(SessionTile, 'Third'));
        await _settle(tester);
        await tester.tap(find.text('归档'));
        await _settle(tester);
        expect(find.text('已归档「Third」'), findsOneWidget);
        oldUndo(); // Second was sent when Third took the window.
        await tester.pump();
        expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      } else if (outcome == 'route') {
        final navigator = Navigator.of(tester.element(find.byType(HomeShell)));
        unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('new route')))));
        await tester.pump(const Duration(seconds: 5));
        await _settle(tester);
        expect(find.text('new route'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
        return;
      } else if (outcome == 'host') {
        final b = _ArchiveHost();
        b.seedSession('s1', 'B', DateTime.now());
        final connectionB = workspaceHost(b, local: false);
        addTearDown(connectionB.client.close);
        container.read(switchConnectionProvider.notifier).set(connectionB);
        container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
        await tester.pump(const Duration(seconds: 5));
        await _settle(tester);
        expect(find.byType(SnackBar), findsNothing);
        expect(b.argsOf('workspace/archiveSession'), isEmpty);
        return;
      }
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pump(const Duration(seconds: 5));
      await _settle(tester);
      expect(host.argsOf('workspace/archiveSession'), hasLength(outcome == 'third' ? 2 : 1));
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      if (outcome == 'failure') expect(find.text('没能归档，稍后再试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
