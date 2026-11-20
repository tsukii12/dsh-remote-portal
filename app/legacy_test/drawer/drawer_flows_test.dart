// The drawer's folder and multi-select flows against an in-memory host:
// create a folder, file a conversation in it (and undo), delete a folder
// (and undo), filter, and bulk archive with undo.
//
//   flutter test test/drawer/drawer_flows_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/drawer/folder_header.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

Future<(DrawerHost, ProviderContainer)> _start(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  Map<String, PendingKind> pending = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final host = DrawerHost();
  final midnight = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  host.seedSession('s1', '修复登录按钮', midnight.add(const Duration(seconds: 3)), running: true);
  host.seedSession('s2', '深色模式', midnight.add(const Duration(seconds: 2)));
  host.seedSession('s3', 'proot 入门', midnight.add(const Duration(seconds: 1)));
  host.pinned = ['s3'];
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        ...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: 's2'),
        pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
      ],
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  final client = container.read(activeConnectionProvider).value!.client;
  addTearDown(client.close);
  return (host, container);
}

Finder _tile(String title) => find.widgetWithText(SessionTile, title);

void main() {
  testWidgets('a folder can start a new chat without creating an empty engine session', (tester) async {
    final (host, container) = await _start(
      tester,
      prefs: storedView(
        const DrawerView(
          loaded: true,
          folders: [DrawerFolder(id: 'f1', name: '工作')],
        ),
      ),
    );
    await tester.longPress(find.widgetWithText(DrawerFolderHeader, '工作'));
    await _settle(tester);
    await tester.tap(find.text('新对话').last);
    await _settle(tester);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(pendingSessionFolderProvider), 'f1');
    expect(host.argsOf('session/create'), isEmpty);

    container.read(currentSessionProvider.notifier).select('s2');
    expect(container.read(pendingSessionFolderProvider), isNull);
  });

  testWidgets('新建文件夹 from the options sheet, then file a conversation in it and undo', (tester) async {
    final (_, container) = await _start(tester);
    await tester.tap(find.byType(DrawerViewButton));
    await _settle(tester);
    await tester.tap(find.text('新建文件夹'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), '工作');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await _settle(tester);
    expect(find.widgetWithText(DrawerFolderHeader, '工作'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('drawer.view.local.local'), contains('工作'));

    await tester.longPress(_tile('深色模式'));
    await _settle(tester);
    await tester.tap(find.text('移到文件夹'));
    await _settle(tester);
    await tester.tap(find.text('工作').last);
    await _settle(tester);
    final folderId = container.read(drawerViewProvider).folders.single.id;
    expect(container.read(drawerViewProvider).folderOf, {'s2': folderId});
    expect(find.text('已移到「工作」'), findsOneWidget);
    // Inside the folder: one indent in.
    final header = tester.getRect(find.widgetWithText(DrawerFolderHeader, '工作'));
    final title = tester.getRect(find.descendant(of: _tile('深色模式'), matching: find.text('深色模式')));
    expect(title.top, greaterThan(header.top));

    await tester.tap(find.text('撤销'));
    await _settle(tester);
    expect(container.read(drawerViewProvider).folderOf, isEmpty);
  });

  testWidgets('deleting a folder keeps its conversations; undo brings it back', (tester) async {
    final (_, container) = await _start(
      tester,
      prefs: storedView(
        const DrawerView(
          loaded: true,
          folders: [
            DrawerFolder(id: 'f1', name: '工作', sessionIds: ['s1']),
          ],
        ),
      ),
    );
    await tester.longPress(find.widgetWithText(DrawerFolderHeader, '工作'));
    await _settle(tester);
    await tester.tap(find.text('删除文件夹'));
    await _settle(tester);
    expect(find.byType(DrawerFolderHeader), findsNothing);
    expect(_tile('修复登录按钮'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await _settle(tester);
    expect(find.widgetWithText(DrawerFolderHeader, '工作'), findsOneWidget);
    expect(container.read(drawerViewProvider).folderOf, {'s1': 'f1'});
  });

  testWidgets('filters: 运行中 and 待确认 show only their matches, or say there are none', (tester) async {
    await _start(tester, pending: {'s3': PendingKind.approval});
    expect(find.descendant(of: _tile('proot 入门'), matching: find.text('待确认')), findsOneWidget);
    await tester.tap(find.widgetWithText(CapsuleChoiceChip, '运行中'));
    await _settle(tester);
    expect(_tile('修复登录按钮'), findsOneWidget);
    expect(_tile('深色模式'), findsNothing);
    await tester.tap(find.widgetWithText(CapsuleChoiceChip, '待确认 1'));
    await _settle(tester);
    expect(_tile('proot 入门'), findsOneWidget);
    expect(_tile('修复登录按钮'), findsNothing);
    await tester.tap(find.widgetWithText(CapsuleChoiceChip, '未读'));
    await _settle(tester);
    expect(find.text('没有未读对话'), findsOneWidget);
  });

  testWidgets('multi-select: delayed archive undo keeps folders, pin and the open one without Host writes', (
    tester,
  ) async {
    final (host, container) = await _start(
      tester,
      prefs: storedView(
        const DrawerView(
          loaded: true,
          folders: [
            DrawerFolder(id: 'f1', name: '工作', sessionIds: ['s2', 's3']),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(DrawerViewButton));
    await _settle(tester);
    await tester.tap(find.text('多选'));
    await _settle(tester);
    expect(find.byType(SelectionActionBar), findsOneWidget);
    await tester.tap(_tile('深色模式'));
    await tester.tap(_tile('proot 入门'));
    await tester.pump();
    expect(find.text('已选 2 个'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SelectionActionBar), matching: find.text('归档')));
    await _settle(tester);
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    expect(find.text('已归档 2 个对话'), findsOneWidget);
    expect(host.pinned, ['s3']);
    expect(container.read(drawerViewProvider).folderOf, {'s2': 'f1', 's3': 'f1'});
    expect(container.read(drawerSelectionProvider), isNull);
    expect(container.read(currentSessionProvider), isNull);
    expect(_tile('深色模式'), findsNothing);

    await tester.tap(find.text('撤销'));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(host.argsOf('workspace/archiveSession'), isEmpty);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    expect(host.argsOf('workspace/pinSession'), isEmpty);
    expect(host.archived, isEmpty);
    expect(host.pinned, ['s3']);
    expect(container.read(drawerViewProvider).folderOf, {'s2': 'f1', 's3': 'f1'});
    expect(find.widgetWithText(DrawerFolderHeader, '工作'), findsOneWidget);
    expect(container.read(currentSessionProvider), 's2');
    expect(_tile('深色模式'), findsOneWidget);
  });

  testWidgets('long press 多选 starts with that row; 完成 ends it', (tester) async {
    final (_, container) = await _start(tester);
    await tester.longPress(_tile('深色模式'));
    await _settle(tester);
    await tester.tap(find.text('多选'));
    await _settle(tester);
    expect(container.read(drawerSelectionProvider), {'s2'});
    await tester.tap(find.byType(DoneButton));
    await _settle(tester);
    expect(container.read(drawerSelectionProvider), isNull);
  });
}
