// Where a notice stands while the drawer is pulled over: inside it, the
// content's own 10 in from either side, and composerToastGap above the
// identity bar (or the multi-select action bar over it), at any text size and
// with a cutout on the left. With the drawer closed it keeps the theme's
// placement, and it follows the drawer when it opens or closes under it.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/composer_toast.dart' show composerToastGap;
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';

const _edge = SessionsDrawer.contentEdge;

List<Override> _overrides() {
  SharedPreferences.setMockInitialValues({});
  final host = FakeWorkspaceHost();
  for (final s in sampleSessions()) {
    host.seedSession(s.sessionId, s.title!, s.updatedAt, running: s.running);
  }
  host.seedWorkspace('/root/workspace', title: 'default-workspace');
  return workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: 's2');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

VoidCallback? _openDrawer;

Future<ProviderContainer> _pump(WidgetTester tester, {bool open = true}) async {
  _openDrawer = null;
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(
        initiallyOpen: open,
        chatBuilder: (openDrawer) {
          _openDrawer = openDrawer;
          return const SizedBox.expand();
        },
      ),
      overrides: _overrides(),
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  return container;
}

/// The notice's card (the SnackBar's own box includes its margin).
Rect _notice(WidgetTester tester) =>
    tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);

Rect _drawer(WidgetTester tester) => tester.getRect(find.byType(SessionsDrawer));

Future<void> _archiveFromMenu(WidgetTester tester) async {
  await tester.longPress(find.widgetWithText(SessionTile, '给设置页加深色模式'));
  await _settle(tester);
  await tester.tap(find.text('归档'));
  await _settle(tester);
  expect(find.text('已归档「给设置页加深色模式」'), findsOneWidget);
}

/// A notice with 撤销, as the drawer's own flows show one.
ScaffoldMessengerState _showNotice(WidgetTester tester) {
  final messenger = ScaffoldMessenger.of(tester.element(find.byType(HomeShell)));
  messenger.showSnackBar(
    SnackBar(
      content: const Text('已删除文件夹「工作」'),
      duration: const Duration(seconds: 30),
      persist: false,
      action: SnackBarAction(label: '撤销', onPressed: () {}),
    ),
  );
  return messenger;
}

/// Inside the drawer with equal margins, its content's; [bar]'s top
/// [composerToastGap] below it; nothing of [bar] under it.
void _expectInDrawer(WidgetTester tester, Rect bar, {double inset = 0}) {
  final notice = _notice(tester);
  final drawer = _drawer(tester);
  final left = notice.left - (drawer.left + inset);
  final right = drawer.right - notice.right;
  expect(left, moreOrLessEquals(_edge, epsilon: 0.5), reason: 'left margin $left');
  expect(right, moreOrLessEquals(left, epsilon: 0.5), reason: 'margins $left / $right');
  expect(notice.right, lessThanOrEqualTo(drawer.right));
  // The identity bar's own content (its host pill and keys) sits the same 10 in.
  expect(bar.left + _edge, moreOrLessEquals(notice.left, epsilon: 0.5));
  expect(bar.right - _edge, moreOrLessEquals(notice.right, epsilon: 0.5));
  expect(bar.top - notice.bottom, moreOrLessEquals(composerToastGap, epsilon: 0.5));
  expect(notice.overlaps(bar), isFalse);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('open drawer: 已归档 stands inside it, above the identity bar', (tester) async {
    usePhoneSurface(tester);
    await _pump(tester);
    await _archiveFromMenu(tester);
    _expectInDrawer(tester, tester.getRect(find.byType(IdentityBar)));
  });

  testWidgets('multi-select: above the action bar that lies over the identity bar', (tester) async {
    usePhoneSurface(tester);
    final container = await _pump(tester);
    container.read(drawerSelectionProvider.notifier)
      ..start('s2')
      ..toggle('s4');
    await _settle(tester);
    final bar = tester.getRect(find.byType(SelectionActionBar));
    expect(bar, tester.getRect(find.byType(IdentityBar)));
    await tester.tap(find.text('归档'));
    await _settle(tester);
    expect(find.text('已归档 2 个对话'), findsOneWidget);
    _expectInDrawer(tester, bar);
  });

  testWidgets('large text: still above the taller identity bar', (tester) async {
    usePhoneSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester);
    final bar = tester.getRect(find.byType(IdentityBar));
    expect(bar.height, greaterThan(66));
    await _archiveFromMenu(tester);
    _expectInDrawer(tester, bar);
  });

  testWidgets('on its side with a cutout: the margins count from the content, not the cutout', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800 * 2, 380 * 2);
    tester.view.padding = const FakeViewPadding(left: 32 * 2, bottom: 16 * 2);
    tester.view.viewPadding = const FakeViewPadding(left: 32 * 2, bottom: 16 * 2);
    addTearDown(tester.view.reset);
    await _pump(tester);
    expect(_drawer(tester).width, 320 + 32);
    // Few rows show on a phone on its side: any notice, not one row's.
    final messenger = _showNotice(tester);
    await _settle(tester);
    _expectInDrawer(tester, tester.getRect(find.byType(IdentityBar)), inset: 32);
    messenger.clearSnackBars();
    await _settle(tester);
  });

  testWidgets('closed drawer keeps the theme placement; the notice follows the drawer', (tester) async {
    usePhoneSurface(tester);
    await _pump(tester, open: false);
    final messenger = _showNotice(tester);
    await _settle(tester);
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final bottomInset = tester.view.padding.bottom / tester.view.devicePixelRatio;
    Rect closed() {
      final notice = _notice(tester);
      expect(notice.left, moreOrLessEquals(16, epsilon: 0.5));
      expect(view.width - notice.right, moreOrLessEquals(16, epsilon: 0.5));
      expect(view.height - bottomInset - notice.bottom, moreOrLessEquals(16, epsilon: 0.5));
      return notice;
    }

    final before = closed();
    _openDrawer!();
    await _settle(tester);
    _expectInDrawer(tester, tester.getRect(find.byType(IdentityBar)));
    // A tap on the scrim pushes the drawer back.
    await tester.tapAt(Offset(view.width - 20, view.height / 2));
    await _settle(tester);
    expect(closed(), before);
    messenger.clearSnackBars();
    await _settle(tester);
  });
}
