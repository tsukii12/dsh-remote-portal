import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';

class _ArchiveHost extends FakeWorkspaceHost {
  bool failUndo = false;
  bool failArchive = false;
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
      if (failArchive) return const RpcError(DshRemoteException('fixture/denied', 'denied'));
      archived = [...archived, id];
      pinned = pinned.where((value) => value != id).toList();
      push({'type': 'pinned', 'pinnedSessionIds': pinned});
    } else {
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

  testWidgets('undo restores group, pin and current selection', (tester) async {
    final (host, container) = await start(tester);
    await archive(tester);
    expect(find.widgetWithText(SessionTile, '归档测试'), findsNothing);
    expect(container.read(currentSessionProvider), isNull);
    expect(find.text('已归档「归档测试」'), findsOneWidget);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    await tester.tap(find.text('撤销'));
    await _settle(tester);
    expect(find.widgetWithText(SessionTile, '归档测试'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(container.read(currentSessionProvider), 's1');
    expect(container.read(workspacePrefsProvider).selected, 'ws-1');
    expect(container.read(workspacesProvider).byId('ws-1')!.sessionIds, contains('s1'));
    expect(host.pinned, ['s1']);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
  });

  testWidgets('a running chat says it was stopped; the notice ends with its window and says nothing more', (
    tester,
  ) async {
    await start(tester, running: true);
    await archive(tester);
    expect(find.text('已停止并归档「归档测试」'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('commit failure restores the hidden session and reports the archive error', (tester) async {
    final (host, container) = await start(tester);
    await archive(tester);
    host.failArchive = true;
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    expect(find.text(appL10n.shellArchiveFailed), findsOneWidget);
    expect(container.read(currentSessionProvider), 's1');
    expect(host.archived, isEmpty);
  });

  testWidgets('drawer owned buttons expose their actions and headings', (tester) async {
    final semantics = tester.ensureSemantics();
    await start(tester);
    for (final finder in [
      find.byType(NewChatButton),
      find.widgetWithText(SessionTile, '归档测试'),
      find.bySemanticsLabel('全部功能'),
      find.bySemanticsLabel('设置'),
      find.bySemanticsLabel(RegExp('当前主机：.*')),
    ]) {
      final data = tester.getSemantics(finder).getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
    }
    expect(
      tester
          .getSemantics(find.widgetWithText(SessionTile, '归档测试'))
          .getSemanticsData()
          .hasAction(SemanticsAction.longPress),
      isTrue,
    );
    expect(tester.getSemantics(find.text('置顶')).getSemanticsData().flagsCollection.isHeader, isTrue);
    semantics.dispose();
  });
}
