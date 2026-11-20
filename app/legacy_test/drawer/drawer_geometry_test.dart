// Measured alignment of the drawer's folders, filters and multi-select:
// the 10 / 20 grid, equal row heights, folder members on the folder name's
// line, 完成 exactly where 新对话 was, the action bar as tall as the identity
// bar. Numbers, not eyeballing.
//
//   flutter test test/drawer/drawer_geometry_test.dart

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/drawer/folder_header.dart';
import 'package:dsh_app/ui/shell/drawer/folder_mark.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workspace/workspace_switcher.dart';
import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'support.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<SessionSummary>? sessions,
  DrawerView view = sampleFolders,
  Map<String, PendingKind> pending = const {},
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues(storedView(view));
  usePhoneSurface(tester);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        sessionsProvider.overrideWith(() => FakeSessions(sessions ?? sampleSessions())),
        currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
        pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
        unreadSessionIdsProvider.overrideWithValue(const {}),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
}

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void main() {
  group('folders', () {
    testWidgets('header on the row grid; members line up with the folder name', (tester) async {
      await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final header = find.widgetWithText(DrawerFolderHeader, '工作');
      final headerRect = _rect(tester, header);
      final mark = _rect(tester, find.descendant(of: header, matching: find.byType(FolderMarkGlyph)));
      final name = _rect(tester, find.descendant(of: header, matching: find.text('工作')));
      final member = find.widgetWithText(SessionTile, '解释 proot 的 link2symlink');
      final memberTitle = _rect(tester, find.descendant(of: member, matching: find.text('解释 proot 的 link2symlink')));
      final loose = find.widgetWithText(SessionTile, '修复登录按钮重复提交');
      final looseTitle = _rect(tester, find.descendant(of: loose, matching: find.text('修复登录按钮重复提交')));

      // Equal heights, same 10 edges as a conversation row.
      expect(headerRect.height, _near(SessionTile.height));
      expect(_rect(tester, member).height, _near(SessionTile.height));
      expect(headerRect.left - drawer.left, _near(10));
      expect(drawer.right - headerRect.right, _near(10));
      expect(_rect(tester, member).left - drawer.left, _near(10));
      expect(drawer.right - _rect(tester, member).right, _near(10));
      // Mark on the 20 line, centred in the row; members on the name's line.
      expect(mark.left - drawer.left, _near(20));
      expect(mark.center.dy, _near(headerRect.center.dy));
      expect(name.left - drawer.left, _near(20 + SessionTile.folderIndent));
      expect(memberTitle.left, _near(name.left));
      expect(looseTitle.left - drawer.left, _near(20));
    });

    testWidgets('a closed folder hides its members; opening reveals them', (tester) async {
      final container = await _pump(tester);
      expect(find.text('把 README 翻译成英文'), findsNothing);
      await tester.tap(find.widgetWithText(DrawerFolderHeader, '学习'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('把 README 翻译成英文'), findsOneWidget);
      expect(container.read(drawerViewProvider).byId('f2')!.collapsed, isFalse);
    });
  });

  group('filters', () {
    testWidgets('capsules start on the 10 line, equal height, 8 apart, one centre line', (tester) async {
      await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final chips = [
        for (final f in DrawerFilter.values) _rect(tester, find.widgetWithText(CapsuleChoiceChip, f.label)),
      ];
      expect(chips.first.left - drawer.left, _near(10));
      for (var i = 1; i < chips.length; i++) {
        expect(chips[i].height, _near(chips.first.height));
        expect(chips[i].center.dy, _near(chips.first.center.dy));
        expect(chips[i].left - chips[i - 1].right, _near(DrawerFilterBar.gap));
      }
    });

    testWidgets('the options key ends on the 10 line and is a 36 circle', (tester) async {
      await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final key = _rect(tester, find.byType(DrawerViewButton));
      expect(key.size, const Size(DrawerViewButton.size, DrawerViewButton.size));
      expect(drawer.right - key.right, _near(10));
    });

    testWidgets('on a connected host the options key shares the workspace row’s centre line', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = FakeWorkspaceHost();
      for (final session in sampleSessions()) {
        host.seedSession(session.sessionId, session.title!, session.updatedAt, running: session.running);
      }
      host.seedWorkspace('/root/workspace', title: 'default-workspace');
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          overrides: workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      addTearDown(container.read(activeConnectionProvider).value!.client.close);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final key = _rect(tester, find.byType(DrawerViewButton));
      final row = _rect(tester, find.byType(WorkspaceSwitcher));
      expect(row.height, _near(WorkspaceSwitcher.height));
      expect(key.center.dy, _near(row.center.dy));
      expect(drawer.right - key.right, _near(10));
      // The first capsule's edge sits under the switcher's highlight edge.
      final first = _rect(tester, find.widgetWithText(CapsuleChoiceChip, DrawerFilter.all.label));
      expect(first.left - drawer.left, _near(10));
    });

    testWidgets('360 wide at 1.3× text: nothing overflows', (tester) async {
      tester.view.physicalSize = const Size(360 * 2, 780 * 2);
      await _pump(tester, textScale: 1.3);
      expect(tester.takeException(), isNull);
    });
  });

  group('multi-select', () {
    testWidgets('完成 takes 新对话’s place; 全选 on the 20 line; count centred', (tester) async {
      final container = await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final newChat = _rect(tester, find.byType(NewChatButton));
      container.read(drawerSelectionProvider.notifier).start('s2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final done = _rect(tester, find.byType(DoneButton));
      expect(done.height, _near(newChat.height));
      expect(done.right, _near(newChat.right));
      expect(done.center.dy, _near(newChat.center.dy));
      final all = _rect(tester, find.descendant(of: find.byType(DrawerSelectionHeader), matching: find.text('全选')));
      expect(all.left - drawer.left, _near(20));
      final count = _rect(tester, find.text('已选 1 个'));
      expect(count.center.dx, _near(drawer.center.dx));
    });

    testWidgets('the check slides in on the 20 line; titles move one slot right', (tester) async {
      final container = await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      container.read(drawerSelectionProvider.notifier).start('s2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final loose = find.widgetWithText(SessionTile, '给设置页加深色模式');
      final title = _rect(tester, find.descendant(of: loose, matching: find.text('给设置页加深色模式')));
      expect(title.left - drawer.left, _near(20 + SessionTile.checkSlot));
      final member = find.widgetWithText(SessionTile, '解释 proot 的 link2symlink');
      final memberTitle = _rect(tester, find.descendant(of: member, matching: find.text('解释 proot 的 link2symlink')));
      expect(memberTitle.left - drawer.left, _near(20 + SessionTile.folderIndent + SessionTile.checkSlot));
    });

    testWidgets('the action bar is as tall as the identity bar; four equal keys on the 10 lines', (tester) async {
      final container = await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final identity = _rect(tester, find.byType(IdentityBar));
      container.read(drawerSelectionProvider.notifier).start('s2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final bar = _rect(tester, find.byType(SelectionActionBar));
      expect(bar.height, _near(identity.height));
      expect(bar.bottom, _near(identity.bottom));
      final keys = [
        for (final label in ['移到文件夹', '置顶', '归档', '删除'])
          _rect(tester, find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first),
      ];
      expect(keys.first.left - drawer.left, _near(10));
      expect(drawer.right - keys.last.right, _near(10));
      for (var i = 1; i < keys.length; i++) {
        expect(keys[i].width, _near(keys[0].width));
        expect(keys[i].left - keys[i - 1].right, _near(8));
      }
    });
  });

  group('identity bar', () {
    testWidgets('全部功能 and 设置: equal keys, 8 apart, as tall as the host pill, 10 from the edge', (tester) async {
      await _pump(tester);
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      final bar = find.byType(IdentityBar);
      // The two glass circles, left to right; their icons say which is which.
      Rect key(IconData icon) =>
          _rect(tester, find.ancestor(of: find.byIcon(icon), matching: find.byType(GlassSurface)).first);
      final features = key(AppIcons.allFeatures);
      final settings = key(AppIcons.settings);
      final pill = _rect(
        tester,
        find.descendant(of: bar, matching: find.byKey(const ValueKey('identity-host-controls'))),
      );
      expect(features.size, settings.size);
      expect(features.width, _near(44));
      expect(features.height, _near(44));
      expect(settings.left - features.right, _near(8));
      expect(features.left - pill.right, _near(8));
      expect(drawer.right - settings.right, _near(10));
      expect(pill.left - drawer.left, _near(10));
      expect(pill.height, _near(features.height));
      expect(pill.center.dy, _near(features.center.dy));
      expect(settings.center.dy, _near(features.center.dy));
    });
  });

  group('empty', () {
    // No folders either: since #230 a folder keeps the list (its long press
    // starts a chat in it) even with no conversations.
    testWidgets('no conversations: no filters, the empty view centred in the drawer', (tester) async {
      await _pump(tester, sessions: const [], view: const DrawerView(loaded: true));
      final drawer = _rect(tester, find.byType(SessionsDrawer));
      expect(find.byType(CapsuleChoiceChip), findsNothing);
      final empty = _rect(tester, find.byType(EmptyView));
      expect(empty.center.dx, _near(drawer.center.dx));
    });
  });
}
