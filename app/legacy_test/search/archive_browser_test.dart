import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/session_deletion_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drawer/support.dart';
import '../shell/golden_harness.dart';
import '../workspace/support.dart';

class _DeletionBackend implements SessionDeletionBackend {
  late DrawerHost host;
  final calls = <String>[];
  bool available = true;
  String? failure;
  Completer<void>? reply;

  @override
  Future<bool> supported(DshClient client) async => available;

  @override
  Future<void> delete(DshClient client, String sessionId) async {
    calls.add(sessionId);
    if (reply case final pending?) await pending.future;
    if (failure case final code?) throw DshRemoteException(code, 'controlled fake rejection');
    host.sessions.removeWhere((row) => row['sessionId'] == sessionId);
    host.archived.remove(sessionId);
    host.push({'type': 'archived', 'archivedSessionIds': host.archived});
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

Future<(DrawerHost, ProviderContainer)> _openArchive(
  WidgetTester tester, {
  _DeletionBackend? backend,
  bool archivedOnly = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final host = DrawerHost();
  host.seedSession('a1', '归档的旧对话', DateTime(2026, 10, 1));
  host.archived = ['a1'];
  if (backend != null) backend.host = host;
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        ...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: null),
        if (backend != null) sessionDeletionBackendProvider.overrideWithValue(backend),
      ],
    ),
  );
  await settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  expect(container.read(sessionsProvider).value, isEmpty);
  expect(find.byType(DrawerViewButton), findsOneWidget);
  if (archivedOnly) {
    await tester.tap(find.byType(DrawerViewButton));
    await settle(tester);
    await tester.tap(find.text('已归档'));
    await settle(tester);
  } else {
    await tester.tap(find.bySemanticsLabel('搜索对话'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '归档');
    await settle(tester);
  }
  expect(find.byType(SessionSearchPage), findsOneWidget);
  expect(find.byType(SearchResultTile), findsOneWidget);
  return (host, container);
}

Finder get _deleteAction => find.byKey(const ValueKey('session-delete-action'));
Finder get _confirmation => find.byKey(const ValueKey('session-delete-confirmation'));
Finder get _confirm => find.byKey(const ValueKey('session-delete-confirm'));

Future<void> _openActions(WidgetTester tester) async {
  await tester.tap(find.byType(SearchResultTile));
  await settle(tester);
  expect(_deleteAction, findsOneWidget);
  expect(find.text('恢复并打开'), findsOneWidget);
}

Future<void> _askDelete(WidgetTester tester) async {
  await _openActions(tester);
  expect(tester.widget<ListTile>(_deleteAction).enabled, isTrue);
  await tester.tap(_deleteAction);
  await settle(tester);
  expect(_confirmation, findsOneWidget);
  expect(find.text('永久删除「归档的旧对话」？'), findsOneWidget);
}

void main() {
  testWidgets('all-archived drawer remains browsable and restores before opening', (tester) async {
    final (host, container) = await _openArchive(tester);
    await tester.tap(find.byType(SearchResultTile));
    await settle(tester);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    await tester.tap(find.text('恢复并打开'));
    await settle(tester);
    expect(host.argsOf('workspace/unarchiveSession'), hasLength(1));
    expect(host.archived, isEmpty);
    expect(container.read(currentSessionProvider), 'a1');
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final roundTrip in [false, true]) {
    testWidgets('restore confirmation retires across host switch (return: $roundTrip)', (tester) async {
      final (host, container) = await _openArchive(tester);
      await tester.tap(find.byType(SearchResultTile));
      await settle(tester);
      container.read(activeHostProvider.notifier).select(const HostRef.portal('other'));
      if (roundTrip) container.read(activeHostProvider.notifier).select(HostRef.none);
      await settle(tester);
      await tester.tap(find.text('恢复并打开'));
      await settle(tester);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      expect(host.archived, ['a1']);
      expect(container.read(currentSessionProvider), isNull);
      expect(find.byType(SessionSearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final archivedOnly in [false, true]) {
    testWidgets('archived deletion waits for confirmation and Host acknowledgement (browser: $archivedOnly)', (
      tester,
    ) async {
      final reply = Completer<void>();
      final backend = _DeletionBackend()..reply = reply;
      final (host, container) = await _openArchive(tester, backend: backend, archivedOnly: archivedOnly);
      await _askDelete(tester);
      expect(find.textContaining('无法撤销'), findsOneWidget);
      expect(backend.calls, isEmpty);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      await tester.tap(_confirm);
      await settle(tester);
      expect(backend.calls, ['a1']);
      expect(container.read(sessionsProvider.notifier).archivedSessions.single.sessionId, 'a1');
      expect(find.byKey(const ValueKey('session-delete-progress')), findsOneWidget);
      reply.complete();
      await settle(tester);
      expect(container.read(sessionsProvider.notifier).archivedSessions, isEmpty);
      expect(find.byType(SearchResultTile), findsNothing);
      expect(find.byType(SessionSearchPage), findsOneWidget);
      expect(container.read(currentSessionProvider), isNull);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      expect(host.argsOf('workspace/archiveSession'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled archived deletion keeps the archived chat without restoring it', (tester) async {
    final backend = _DeletionBackend();
    final (host, container) = await _openArchive(tester, backend: backend);
    await _askDelete(tester);
    await tester.tap(find.descendant(of: _confirmation, matching: find.text('取消')));
    await settle(tester);
    expect(backend.calls, isEmpty);
    expect(host.archived, ['a1']);
    expect(find.byType(SearchResultTile), findsOneWidget);
    expect(container.read(currentSessionProvider), isNull);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
  });

  testWidgets('unsupported deletion leaves restore available for an archived chat', (tester) async {
    final backend = _DeletionBackend()..available = false;
    final (host, _) = await _openArchive(tester, backend: backend);
    await _openActions(tester);
    expect(tester.widget<ListTile>(_deleteAction).enabled, isFalse);
    expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
    expect(find.text('此主机不支持安全永久删除，仍可使用归档。'), findsOneWidget);
    await tester.tap(find.text('恢复并打开'));
    await settle(tester);
    expect(host.argsOf('workspace/unarchiveSession'), hasLength(1));
    expect(backend.calls, isEmpty);
  });

  testWidgets('Host deletion refusal keeps the archived result and reports its stable reason', (tester) async {
    final backend = _DeletionBackend()..failure = 'writer-held';
    final (host, container) = await _openArchive(tester, backend: backend);
    await _askDelete(tester);
    await tester.tap(_confirm);
    await settle(tester);
    expect(backend.calls, ['a1']);
    expect(find.textContaining('(writer-held)'), findsOneWidget);
    expect(container.read(sessionsProvider.notifier).archivedSessions.single.sessionId, 'a1');
    expect(host.archived, ['a1']);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(find.byType(SearchResultTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final confirmed in [false, true]) {
    testWidgets('archived deletion intent retires on A to B to A (confirmation: $confirmed)', (tester) async {
      final backend = _DeletionBackend();
      final (host, container) = await _openArchive(tester, backend: backend);
      if (confirmed) {
        await _askDelete(tester);
      } else {
        await _openActions(tester);
      }
      container.read(activeHostProvider.notifier).select(const HostRef.portal('other'));
      container.read(activeHostProvider.notifier).select(HostRef.none);
      await settle(tester);
      if (confirmed) {
        expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
      } else {
        expect(tester.widget<ListTile>(_deleteAction).onTap, isNull);
      }
      expect(backend.calls, isEmpty);
      expect(host.archived, ['a1']);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an archived chat restored elsewhere no longer satisfies the pending deletion intent', (tester) async {
    final backend = _DeletionBackend();
    final (host, _) = await _openArchive(tester, backend: backend);
    await _askDelete(tester);
    host.archived = [];
    host.push({'type': 'archived', 'archivedSessionIds': host.archived});
    await settle(tester);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(backend.calls, isEmpty);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
  });
}
