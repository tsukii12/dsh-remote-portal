// The home screen on a tablet (1280 × 800) and an open foldable (720 × 900):
// the rail, the sidebar, 对话详情 as a column and as a sheet, measured
// against the chat header and the composer; the keys that fold the panel
// sharing one spot; insets; and goldens in light and dark. Regenerate with
//
//   flutter test --update-goldens test/shell/adaptive/adaptive_home_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/shell/adaptive/detail_sheet.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _eps = 0.01;
Matcher _near(double v) => closeTo(v, _eps);

const _wide = Size(1280, 800);
const _medium = Size(720, 900);

Rect _key(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

Rect _pill(WidgetTester tester) => _key(tester, 'chat-title-pill');

Future<void> _pumpHome(
  WidgetTester tester, {
  Size size = _wide,
  double right = 0,
  double left = 0,
  Brightness brightness = Brightness.light,
  LayoutPrefs prefs = const LayoutPrefs(loaded: true),
  String? session = 's1',
}) async {
  useWindow(tester, size, left: left, right: right);
  mockClipboard(tester);
  await tester.pumpWidget(homeApp(brightness: brightness, prefs: prefs, session: session));
  // Keep the initial 800 ms, coalescing only its later frames. The gesture,
  // route and panel-transition pumps below remain unchanged.
  await pumpFrames(tester, 2);
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _openSheet(WidgetTester tester, {bool full = false}) async {
  SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1');
  await pumpFrames(tester, 8);
  if (full) {
    await tester.tap(find.bySemanticsLabel('展开'));
    await pumpFrames(tester, 8);
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  group('1280 × 800, 对话详情 beside the chat', () {
    testWidgets('rail keys on the header line and the composer line', (tester) async {
      await _pumpHome(tester);
      expect(tester.takeException(), isNull);
      final menu = _key(tester, 'rail-menu');
      final search = _key(tester, 'rail-search');
      final settings = _key(tester, 'rail-settings');
      final pill = _pill(tester);
      final composer = tester.getRect(find.byType(Composer));

      expect(menu.size, const Size.square(44));
      expect(menu.left, _near(12));
      expect(menu.center.dy, _near(pill.center.dy));
      expect(search.left, _near(menu.left));
      expect(search.top - menu.bottom, _near(8));
      expect(settings.left, _near(menu.left));
      expect(settings.bottom, _near(composer.bottom));
      // The rail owns ≡: the header has none, its pill starts on the chat
      // column's 12.
      expect(find.byKey(const ValueKey('chat-menu')), findsNothing);
      expect(pill.left, _near(68 + 12));
    });

    testWidgets('panel: edges, bar on the header line, tabs on 16', (tester) async {
      await _pumpHome(tester);
      final panel = tester.getRect(find.byType(SessionDetailPage));
      expect(panel, const Rect.fromLTWH(896, 0, 384, 800));
      final line = _key(tester, 'adaptive-panel-hairline');
      expect(line.left, _near(896));
      expect(line.width, _near(0.5));

      final collapse = _key(tester, 'panel-collapse');
      final pill = _pill(tester);
      expect(collapse.size, const Size.square(44));
      expect(1280 - collapse.right, _near(12));
      expect(collapse.center.dy, _near(pill.center.dy));
      // The label starts where the figures under it do.
      final label = tester.getRect(find.text('对话详情'));
      expect(label.left, _near(896 + 24));
      expect(label.center.dy, _near(collapse.center.dy));
      final segments = tester.getRect(find.byType(GlassSegments));
      expect(segments.left, _near(896 + 16));
      expect(1280 - segments.right, _near(16));

      // The chat: the composer centred in its column, the column ending on
      // the hairline; the header's new-chat key 12 in from it.
      final composer = tester.getRect(find.byType(Composer));
      expect(composer.center.dx, _near((68 + 896) / 2));
      expect(896 - _key(tester, 'chat-new-chat').right, _near(12));
      expect(find.byKey(const ValueKey('chat-panel-key')), findsNothing);
    });

    testWidgets('fold and unfold: the key stays on one spot', (tester) async {
      await _pumpHome(tester);
      final open = _key(tester, 'panel-collapse');
      await tester.tap(find.byKey(const ValueKey('panel-collapse')));
      await pumpFrames(tester, 8);
      expect(find.byType(SessionDetailPage), findsNothing);
      final folded = _key(tester, 'chat-panel-key');
      expect(folded, open);
      // The sidebar fits again; the header's ≡ folds it.
      expect(find.byType(SessionsDrawer), findsOneWidget);
      expect(tester.getRect(find.byType(SessionsDrawer)).width, _near(320));
      expect(_key(tester, 'chat-menu').left, _near(320 + 12));

      await tester.tap(find.byKey(const ValueKey('chat-panel-key')));
      await pumpFrames(tester, 8);
      expect(find.byType(SessionDetailPage), findsOneWidget);
      expect(_key(tester, 'panel-collapse'), open);
    });

    testWidgets('the title pill folds and unfolds the panel', (tester) async {
      await _pumpHome(tester);
      final context = tester.element(find.byType(ChatScreen));
      SessionDetailPage.open(context, 's1', toggle: true);
      await pumpFrames(tester, 8);
      expect(find.byType(SessionDetailPage), findsNothing);
      SessionDetailPage.open(context, 's1', toggle: true);
      await pumpFrames(tester, 8);
      expect(find.byType(SessionDetailPage), findsOneWidget);
      // A tab from elsewhere (the progress strip): opens on it.
      SessionDetailPage.open(context, 's1', tab: SessionTab.progress);
      await pumpFrames(tester, 8);
      final tabs = tester.widget<GlassSegments>(find.byType(GlassSegments));
      expect(tabs.labels[tabs.controller.index], '进度');
    });

    testWidgets('swiping the panel turns its tabs, never pulls the drawer', (tester) async {
      await _pumpHome(tester);
      final view = find.descendant(of: find.byType(SessionDetailPage), matching: find.byType(TabBarView));
      await tester.fling(view, const Offset(-300, 0), 1200);
      await pumpFrames(tester, 8);
      GlassSegments tabs() => tester.widget<GlassSegments>(find.byType(GlassSegments));
      expect(tabs().labels[tabs().controller.index], '改动');
      await tester.fling(view, const Offset(300, 0), 1200);
      await pumpFrames(tester, 8);
      expect(tabs().labels[tabs().controller.index], '轨迹');
      expect(find.byType(SessionsDrawer), findsNothing);
    });

    testWidgets('no room for the sidebar: ≡ on the rail pulls the drawer', (tester) async {
      await _pumpHome(tester);
      await tester.tap(find.byKey(const ValueKey('rail-menu')));
      await pumpFrames(tester, 8);
      expect(find.byType(SessionsDrawer), findsOneWidget);
      expect(tester.getRect(find.byType(SessionsDrawer)).left, _near(0));
    });

    testWidgets('a navigation bar on the right: the panel keeps clear', (tester) async {
      await _pumpHome(tester, right: 48);
      final collapse = _key(tester, 'panel-collapse');
      expect(1280 - 48 - collapse.right, _near(12));
      final panel = tester.getRect(find.byType(SessionDetailPage));
      expect(panel.right, _near(1280 - 48));
      expect(panel.width, 384);
    });

    testWidgets('no conversation: sidebar and chat, no panel or its key', (tester) async {
      await _pumpHome(tester, session: null);
      expect(find.byType(SessionDetailPage), findsNothing);
      expect(find.byKey(const ValueKey('chat-panel-key')), findsNothing);
      expect(tester.getRect(find.byType(SessionsDrawer)).width, _near(320));
    });
  });

  group('720 × 900, the wide sheet', () {
    testWidgets('no rail, no panel: the phone layout', (tester) async {
      await _pumpHome(tester, size: _medium);
      expect(find.byKey(const ValueKey('rail-menu')), findsNothing);
      expect(find.byType(SessionDetailPage), findsNothing);
      expect(_key(tester, 'chat-menu').left, _near(12));
    });

    testWidgets('half the window, title and tabs on the sheet\'s 20', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpHome(tester, size: _medium);
      await _openSheet(tester);
      final sheet = _key(tester, 'detail-sheet');
      expect(sheet, const Rect.fromLTWH(0, 450, 720, 450));
      final title = tester.getRect(find.text('对话详情'));
      expect(title.left - sheet.left, _near(20));
      final segments = tester.getRect(find.byType(GlassSegments));
      expect(segments.left - sheet.left, _near(20));
      expect(sheet.right - segments.right, _near(20));
      await tester.tap(find.bySemanticsLabel('展开'));
      await pumpFrames(tester, 8);
      expect(_key(tester, 'detail-sheet').top, _near(statusBar + 12));
      semantics.dispose();
    });

    testWidgets('turned wide, the sheet becomes the panel, same tab', (tester) async {
      await _pumpHome(tester, size: _medium, prefs: const LayoutPrefs(loaded: true, panelOpen: false));
      SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1', tab: SessionTab.changes);
      await pumpFrames(tester, 8);
      expect(find.byType(DetailSheetScope), findsOneWidget);
      useWindow(tester, _wide);
      await pumpFrames(tester, 8);
      expect(find.byType(DetailSheetScope), findsNothing);
      final tabs = tester.widget<GlassSegments>(find.byType(GlassSegments));
      expect(tabs.labels[tabs.controller.index], '改动');
      expect(tester.getRect(find.byType(SessionDetailPage)).right, _near(1280));
    });
  });

  testWidgets('widening the window keeps the docked sidebar and chat state', (tester) async {
    await _pumpHome(tester, size: const Size(1312, 800));
    final chat = tester.state(find.byType(ChatScreen));
    for (final width in [1313.0, 1314.0, 1315.0, 1316.0]) {
      useWindow(tester, Size(width, 800));
      await tester.pump();
      expect(find.byKey(const ValueKey('persistent-sidebar')), findsOneWidget, reason: '$width');
      expect(find.byKey(const ValueKey('rail-menu')), findsNothing, reason: '$width');
      expect(find.byKey(const ValueKey('chat-menu')), findsOneWidget, reason: '$width');
      expect(tester.state(find.byType(ChatScreen)), same(chat));
      final rect = tester.getRect(find.byType(ChatScreen));
      expect(rect.left, _near(320));
      expect(rect.width, greaterThanOrEqualTo(600));
      expect(rect.right, _near(tester.getRect(find.byType(SessionDetailPage)).left));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the rail unfolds the persistent sidebar at the panel grid step', (tester) async {
    await _pumpHome(tester, size: const Size(1314, 800), prefs: const LayoutPrefs(loaded: true, sidebarOpen: false));
    final panelWidth = tester.getRect(find.byType(SessionDetailPage)).width;
    await tester.tap(find.byKey(const ValueKey('rail-menu')));
    await pumpFrames(tester, 8);
    expect(find.byKey(const ValueKey('persistent-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-menu')), findsNothing);
    expect(tester.getRect(find.byType(ChatScreen)).width, greaterThanOrEqualTo(600));
    expect(tester.getRect(find.byType(SessionDetailPage)).width, panelWidth);
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await pumpFrames(tester, 8);
    expect(find.byKey(const ValueKey('persistent-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('rail-menu')), findsOneWidget);
    expect(find.byType(SessionDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('wide_panel', (tester) async {
        await _pumpHome(tester, brightness: brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/wide_panel_$mode.png'));
      });

      testWidgets('wide_sidebar', (tester) async {
        await _pumpHome(tester, brightness: brightness, prefs: const LayoutPrefs(loaded: true, panelOpen: false));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/wide_sidebar_$mode.png'));
      });

      testWidgets('medium_sheet', (tester) async {
        await _pumpHome(tester, size: _medium, brightness: brightness);
        await _openSheet(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/medium_sheet_$mode.png'));
      });

      testWidgets('medium_sheet_full', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpHome(tester, size: _medium, brightness: brightness);
        await _openSheet(tester, full: true);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/medium_sheet_full_$mode.png'));
        semantics.dispose();
      });
    });
  }
}
