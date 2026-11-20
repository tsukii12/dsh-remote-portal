// Landscape and tablet geometry, measured: a phone on its
// side (camera left, or turned the other way with the navigation bar on the
// left), 600, 840 and 1280. One centred column on the phone, side insets
// mirrored, the composer and the dock on the messages' reading column, the
// header and dock stepping aside for the keyboard, sheets and dialogs centred
// on the glass, and the state kept across turning.
//
//   flutter test test/landscape/landscape_geometry_test.dart

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/bots/bot_sheets.dart' show confirmDelete;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart' show ModelChip;
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/common/app_sheet.dart' show SheetDragHandle;
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/terminal/terminal_keys.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' hide fakeConnection;
import '../chat/support/sample_chat.dart';
import '../search/support.dart';
import '../shell/adaptive/support.dart' hide useWindow;
import '../shell/golden_harness.dart' show FakeCurrentSession, FakeRuntime, FakeSettings, goldenApp, runningStatus;
import '../terminal/support.dart';
import 'support.dart';

const _eps = 0.01;
Matcher _near(double v) => closeTo(v, _eps);

Rect _key(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

Future<void> _home(WidgetTester tester, Win win, {ChatState Function(String id)? chat, double keyboard = 0}) async {
  useWin(tester, win, keyboard: keyboard);
  mockClipboard(tester);
  await tester.pumpWidget(homeApp(chat: chat));
  await pumpFrames(tester, 8);
}

/// The dialog's card (the AlertDialog widget itself spans the window).
Finder _dialog() => find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first;

ChatState _approval(String id) => id == 's1' ? conversationState() : const ChatState(loading: false);

List<Override> _shell() => [
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
];

/// A page with one button that runs [open].
class _Launcher extends StatelessWidget {
  const _Launcher(this.open);

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open')),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  for (final win in [phoneLeft, phoneRight]) {
    final side = win.left > win.right ? win.left : win.right;
    final centre = win.size.width / 2;

    group('${win.name}: a phone on its side', () {
      testWidgets('one column: no rail, no panel; the header keys mirror each other', (tester) async {
        await _home(tester, win);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('rail-menu')), findsNothing);
        expect(find.byKey(const ValueKey('adaptive-panel-hairline')), findsNothing);
        final menu = _key(tester, 'chat-menu');
        final newChat = _key(tester, 'chat-new-chat');
        expect(menu.left, _near(side + 12));
        expect(win.size.width - newChat.right, _near(side + 12));
        expect(menu.size, const Size.square(44));
        expect(newChat.center.dy, _near(menu.center.dy));
      });

      testWidgets('the composer and the dock sit on the messages\' reading column', (tester) async {
        await _home(tester, win, chat: _approval);
        final composer = tester.getRect(find.byType(Composer));
        expect(composer.center.dx, _near(centre));
        expect(composer.width, _near(AppSpace.floatingWidth));
        // Cards span the text column (720 less 16 a side): 4 inside the
        // composer's edges, as on an upright phone.
        final card = tester.getRect(find.byType(ApprovalCard));
        expect(card.left - composer.left, _near(4));
        expect(composer.right - card.right, _near(4));
      });

      testWidgets('keyboard up: header and dock step aside, the latest message stays in sight', (tester) async {
        await _home(tester, win);
        expect(find.byType(DockStack), findsOneWidget);
        await tester.showKeyboard(find.byType(EditableText).first);
        setKeyboard(tester, win, 200);
        await pumpFrames(tester, 8);

        final composer = tester.getRect(find.byType(Composer));
        // 8 above the keyboard plus the composer's own 8.
        expect(composer.bottom, _near(win.size.height - 200 - 16));
        // Folded to nothing toward the composer (still mounted, unseen).
        final fold = tester.widget<Align>(find.ancestor(of: find.byType(DockStack), matching: find.byType(Align)).first);
        expect(fold.heightFactor, 0);
        final fade = tester.widget<Opacity>(
          find.ancestor(of: find.byType(DockStack), matching: find.byType(Opacity)).first,
        );
        expect(fade.opacity, 0);
        expect(find.byType(DockStack).hitTestable(), findsNothing);
        expect(find.byKey(const ValueKey('chat-title-pill')).hitTestable(), findsNothing);
        // The last row of the run, whole, between the status bar and the
        // composer.
        final last = tester.getRect(find.text('运行').last);
        expect(last.bottom, lessThanOrEqualTo(composer.top));
        expect(last.top, greaterThanOrEqualTo(win.top));
        // Not just the last row: the header's 64 is the chat's now, about
        // three rows of it.
        expect(composer.top - win.top, greaterThan(100));

        setKeyboard(tester, win, 0);
        await pumpFrames(tester, 8);
        expect(find.byType(DockStack).hitTestable(), findsWidgets);
        expect(find.byKey(const ValueKey('chat-title-pill')).hitTestable(), findsOneWidget);
      });

      testWidgets('the drawer: 320 of list beside the cutout', (tester) async {
        await _home(tester, win);
        await tester.tap(find.byKey(const ValueKey('chat-menu')));
        await pumpFrames(tester, 8);
        final search = tester.getRect(find.text('搜索对话').first);
        expect(search.left, greaterThan(side + 10));
        // Scrolling the list takes the brand, search and filters with it.
        final before = tester.getRect(find.text('给设置页加深色模式').last).top;
        await tester.drag(find.text('给设置页加深色模式').last, const Offset(0, -200));
        await pumpFrames(tester, 8);
        expect(tester.getRect(find.text('给设置页加深色模式').last).top, lessThan(before - 150));
      });

      testWidgets('对话详情 opens as a page; hero and tabs on the reading column', (tester) async {
        await _home(tester, win);
        SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1');
        await pumpFrames(tester, 10);
        final tabs = tester.getRect(find.byType(GlassSegments));
        expect(tabs.center.dx, _near(centre));
        // The column's side is floored to whole points.
        expect(tabs.width, closeTo(AppSpace.readingWidth - 32, 1));
        final back = tester.getRect(find.byTooltip('返回').last);
        expect(back.left, _near(side + 12));
      });

      testWidgets('a sheet is centred on the glass', (tester) async {
        await _home(tester, win);
        await tester.tap(find.byType(ModelChip));
        await pumpFrames(tester, 8);
        final sheet = tester.getRect(
          find.ancestor(of: find.byType(SheetDragHandle), matching: find.byType(GlassSurface)).first,
        );
        expect(sheet.center.dx, _near(centre));
        expect(sheet.width, _near(640));
      });

      testWidgets('a dialog is centred on the glass', (tester) async {
        useWin(tester, win);
        await tester.pumpWidget(
          testApp(_Launcher((context) => confirmDelete(context, title: '删除这个任务？', body: '删除后不能恢复。'))),
        );
        await tester.tap(find.text('open'));
        await pumpFrames(tester, 6);
        expect(tester.getRect(_dialog()).center.dx, _near(centre));
      });

      testWidgets('a page: back key clear of the inset, content centred', (tester) async {
        useWin(tester, win);
        await tester.pumpWidget(
          goldenApp(home: const SettingsScreen(), brightness: Brightness.light, overrides: _shell()),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.getRect(find.byTooltip('返回')).left, _near(side + 12));
        final title = tester.getRect(find.text('设置').first);
        // The column: 720 centred (24 in for the large title).
        expect(title.left, _near(((win.size.width - AppSpace.readingWidth) / 2).floorToDouble() + 24));
      });
    });
  }

  testWidgets('turning a phone keeps the draft and the conversation', (tester) async {
    const upright = Win('upright', Size(412, 915));
    await _home(tester, upright);
    await tester.enterText(find.byType(EditableText).first, '先别动草稿');
    await pumpFrames(tester, 2);
    final state = tester.state(find.byType(ChatScreen));

    useWin(tester, phoneLeft);
    await pumpFrames(tester, 6);
    expect(tester.state(find.byType(ChatScreen)), same(state));
    expect(find.text('先别动草稿'), findsOneWidget);
    expect(tester.getRect(find.byType(Composer)).center.dx, _near(915 / 2));

    useWin(tester, upright);
    await pumpFrames(tester, 6);
    expect(tester.state(find.byType(ChatScreen)), same(state));
    expect(find.text('先别动草稿'), findsOneWidget);
  });

  group('600 × 900', () {
    testWidgets('one column; the composer 12 from the edges', (tester) async {
      await _home(tester, w600);
      final composer = tester.getRect(find.byType(Composer));
      expect(composer.left, _near(12));
      expect(composer.right, _near(600 - 12));
      expect(find.byKey(const ValueKey('rail-menu')), findsNothing);
    });
  });

  for (final win in [w840, w1280]) {
    group('${win.name}: rail · chat · panel', () {
      testWidgets('the composer centred on the chat column, on its reading column', (tester) async {
        await _home(tester, win, chat: _approval);
        final rail = _key(tester, 'rail-menu');
        final hairline = tester.getRect(find.byKey(const ValueKey('adaptive-panel-hairline')));
        final chatLeft = rail.right + 12;
        final chatRight = hairline.left;
        final composer = tester.getRect(find.byType(Composer));
        expect(composer.center.dx, _near((chatLeft + chatRight) / 2));
        final column = (chatRight - chatLeft).clamp(0.0, AppSpace.readingWidth);
        expect(composer.width, _near(column - 24));
        final card = tester.getRect(find.byType(ApprovalCard));
        expect(card.left - composer.left, _near(4));
        expect(composer.right - card.right, _near(4));
      });
    });
  }

  group('1280 × 800', () {
    testWidgets('the jump key keeps to the reading column', (tester) async {
      await _home(tester, w1280);
      await tester.dragFrom(const Offset(500, 400), const Offset(0, 300));
      await pumpFrames(tester, 8);
      final jump = tester.getRect(find.byKey(const ValueKey('jump')));
      final composer = tester.getRect(find.byType(Composer));
      // Over the composer's right end: 12 in from the reading column.
      expect(jump.right, _near(composer.right));
    });

    testWidgets('search: the field over the results, both centred', (tester) async {
      useWin(tester, w1280);
      await tester.pumpWidget(
        goldenApp(
          home: SessionSearchPage(now: searchNow),
          brightness: Brightness.light,
          overrides: [
            sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
            sessionContentSearchProvider.overrideWithValue(
              FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)}),
            ),
            currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
          ],
        ),
      );
      await tester.pump();
      final field = tester.getRect(find.byType(TextField));
      expect(field.center.dx, _near(640));
      expect(field.width, lessThanOrEqualTo(AppSpace.floatingWidth));
      expect(tester.getRect(find.byTooltip('返回')).left, _near(12));
      await tester.enterText(find.byType(TextField), '登录');
      await tester.pump(SessionSearchController.debounce);
      await pumpFrames(tester, 4);
      final tile = tester.getRect(find.byType(SearchResultTile).first);
      expect(tile.left, _near((1280 - AppSpace.readingWidth) / 2 + 12));
      expect(tile.right, _near(1280 - (1280 - AppSpace.readingWidth) / 2 - 12));
    });

    testWidgets('terminal: the key row keeps its spacing, centred', (tester) async {
      useWin(tester, w1280);
      await tester.pumpWidget(
        goldenApp(
          home: const TerminalPage(sessionId: 's1'),
          brightness: Brightness.light,
          overrides: terminalOverrides(FakeTerminalBackend()..createdScreen = sampleScreen),
        ),
      );
      await settleTerminal(tester);
      final esc = tester.getRect(find.byKey(const ValueKey('terminal-key-esc')));
      final last = tester.getRect(find.byKey(ValueKey('terminal-key-${TerminalExtraKey.values.last.name}')));
      expect(esc.width, _near(TerminalBar.maxCell));
      expect((esc.left + last.right) / 2, _near(640));
    });

    testWidgets('a dialog keeps Material\'s 560', (tester) async {
      useWin(tester, w1280);
      await tester.pumpWidget(
        testApp(_Launcher((context) => confirmDelete(context, title: '删除这个任务？', body: '很长的说明' * 40))),
      );
      await tester.tap(find.text('open'));
      await pumpFrames(tester, 6);
      final dialog = tester.getRect(_dialog());
      expect(dialog.width, lessThanOrEqualTo(560));
      expect(dialog.center.dx, _near(640));
    });
  });
}
