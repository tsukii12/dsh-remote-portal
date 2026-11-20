// Golden screenshots of the drawer's folders, filters, multi-select and the
// 已归档 undo notice, light and dark.
//
//   flutter test --update-goldens test/drawer/drawer_golden_test.dart

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/folder_sheets.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/english_preview.dart';
import '../workspace/support.dart';
import 'support.dart';

class _FakeChat extends StatelessWidget {
  const _FakeChat();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Widget _shell() => HomeShell(chatBuilder: (_) => const _FakeChat(), initiallyOpen: true);

/// The golden harness' sample conversations on a connected in-memory host,
/// so the workspace row (「全部对话」 and the list's options) shows as on a
/// phone.
List<Override> _drawer({
  bool empty = false,
  Map<String, Object> prefs = const {},
  Map<String, PendingKind> pending = const {},
  Set<String> unread = const {},
}) {
  SharedPreferences.setMockInitialValues(prefs);
  final host = FakeWorkspaceHost();
  if (!empty) {
    for (final s in sampleSessions()) {
      host.seedSession(s.sessionId, s.title!, s.updatedAt, running: s.running);
    }
  }
  host.seedWorkspace('/root/workspace', title: 'default-workspace');
  return [
    ...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: 's2'),
    pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
    unreadSessionIdsProvider.overrideWithValue(unread),
  ];
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Closes the host's client after the test, then runs [then].
Future<void> Function(WidgetTester) _before([Future<void> Function(WidgetTester tester)? then]) => (tester) async {
  addTearDown(_container(tester).read(activeConnectionProvider).value!.client.close);
  await _settle(tester);
  await then?.call(tester);
};

void main() {
  setUpAll(loadEmojiFont);

  // No conversations yet: no filters, the quiet empty view.
  goldenBoth('drawer_g9_empty', _shell, overrides: () => _drawer(empty: true), before: _before());

  // Two folders (one closed), markers: s5 waits for approval, s6 is unread,
  // s1 runs.
  goldenBoth(
    'drawer_g9_folders',
    _shell,
    overrides: () => _drawer(prefs: storedView(sampleFolders), pending: {'s5': PendingKind.approval}, unread: {'s6'}),
    before: _before(),
  );

  // English smoke golden (i18n): folders, markers and filters, light.
  testWidgets('drawer_g9_folders (en)', (tester) async {
    useEnglish();
    await tester.runAsync(loadGoldenFonts);
    usePhoneSurface(tester);
    final overrides = _drawer(prefs: storedView(sampleFolders), pending: {'s5': PendingKind.approval}, unread: {'s6'});
    await tester.pumpWidget(goldenApp(home: inEnglish(_shell()), brightness: Brightness.light, overrides: overrides));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await _before()(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_drawer_g9_folders_light.png'));
  });

  // 待确认: the flat list of what waits.
  goldenBoth(
    'drawer_g9_filter',
    _shell,
    overrides: () =>
        _drawer(prefs: storedView(sampleFolders), pending: {'s5': PendingKind.approval, 's3': PendingKind.question}),
    before: _before((tester) async {
      _container(tester).read(drawerFilterProvider.notifier).set(DrawerFilter.pending);
      await _settle(tester);
    }),
  );

  // Multi-select: two chosen, one of them in a folder.
  goldenBoth(
    'drawer_g9_select',
    _shell,
    overrides: () => _drawer(prefs: storedView(sampleFolders)),
    before: _before((tester) async {
      _container(tester).read(drawerSelectionProvider.notifier)
        ..start('s2')
        ..toggle('s4');
      await _settle(tester);
    }),
  );

  // 新建文件夹 over the drawer, a hue chosen.
  goldenBoth(
    'drawer_g9_folder_editor',
    _shell,
    overrides: () => _drawer(prefs: storedView(sampleFolders)),
    before: _before((tester) async {
      final context = tester.element(find.byType(HomeShell));
      showFolderEditor(context, initial: sampleFolders.folders.first);
      await _settle(tester);
    }),
  );

  // 归档 from a conversation's menu: the row leaves at once and 已归档「…」
  // with 撤销 stands for the undo window (nothing has reached the Host yet).
  goldenBoth(
    'drawer_archive_undo',
    _shell,
    overrides: () => _drawer(),
    before: _before((tester) async {
      await tester.longPress(find.widgetWithText(SessionTile, '给设置页加深色模式'));
      await _settle(tester);
      await tester.tap(find.text('归档'));
      await _settle(tester);
    }),
  );

  // Two chosen, 归档 in the selection bar: 已归档 2 个对话 with 撤销.
  goldenBoth(
    'drawer_archive_undo_bulk',
    _shell,
    overrides: () => _drawer(),
    before: _before((tester) async {
      _container(tester).read(drawerSelectionProvider.notifier)
        ..start('s2')
        ..toggle('s4');
      await _settle(tester);
      await tester.tap(find.text('归档'));
      await _settle(tester);
    }),
  );
}
