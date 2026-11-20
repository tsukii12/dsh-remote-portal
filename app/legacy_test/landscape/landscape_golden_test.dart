// Goldens of the landscape / tablet layouts: a phone on its
// side (chat, keyboard up, drawer, 对话详情 page, a page, the share panel and its
// image page),
// the chat at 600 and 840, and search and the terminal at 1280. The 1280
// chat is test/shell/adaptive/adaptive_home_test.dart's. Regenerate with
//
//   flutter test --update-goldens test/landscape/landscape_golden_test.dart

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/share/share_image_page.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' hide fakeConnection;
import '../search/support.dart';
import '../share/support.dart' show firstReply, shareChatState;
import '../shell/adaptive/support.dart' hide useWindow;
import '../shell/golden_harness.dart' show FakeCurrentSession, FakeRuntime, FakeSettings, goldenApp, runningStatus;
import '../terminal/support.dart';
import 'support.dart';

List<Override> _shell() => [
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: testKey))),
];

/// [name]_light / _dark (or only [only]) of [build] on [win].
void _golden(
  String name,
  Win win,
  Widget Function(Brightness brightness) build, {
  Future<void> Function(WidgetTester tester)? before,
  double keyboard = 0,
  List<Brightness> only = Brightness.values,
}) {
  for (final brightness in only) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      useWin(tester, win, keyboard: keyboard);
      mockClipboard(tester);
      await tester.pumpWidget(build(brightness));
      await pumpFrames(tester, 8);
      if (before != null) await before(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

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
    ShareCardStyle.lastTemplate = null;
    freezeClocks();
  });
  tearDown(thawClocks);

  // ── A phone on its side ────────────────────────────────────────────────
  _golden('phone_chat', phoneLeft, (b) => homeApp(brightness: b));
  _golden(
    'phone_chat_keyboard',
    phoneLeft,
    (b) => homeApp(brightness: b),
    keyboard: 200,
    only: const [Brightness.light],
    before: (tester) async {
      await tester.showKeyboard(find.byType(EditableText).first);
      await pumpFrames(tester, 8);
    },
  );
  // A six-line draft with the keyboard up: the editor keeps to what fits
  // above the keyboard and scrolls inside, the chat keeps its strip.
  _golden(
    'phone_chat_keyboard_draft',
    phoneLeft,
    (b) => homeApp(brightness: b),
    keyboard: 200,
    before: (tester) async {
      await tester.showKeyboard(find.byType(EditableText).first);
      await tester.enterText(find.byType(EditableText).first, '第一行\n第二行\n第三行\n第四行\n第五行\n第六行');
      await pumpFrames(tester, 8);
    },
  );
  _golden(
    'phone_drawer',
    phoneLeft,
    (b) => homeApp(brightness: b),
    only: const [Brightness.light],
    before: (tester) async {
      await tester.tap(find.byKey(const ValueKey('chat-menu')));
      await pumpFrames(tester, 8);
    },
  );
  _golden(
    'phone_detail_page',
    phoneLeft,
    (b) => homeApp(brightness: b),
    only: const [Brightness.light],
    before: (tester) async {
      SessionDetailPage.open(tester.element(find.byType(ChatScreen)), 's1');
      await pumpFrames(tester, 10);
    },
  );
  _golden(
    'phone_settings',
    phoneLeft,
    (b) => goldenApp(home: const SettingsScreen(), brightness: b, overrides: _shell()),
  );
  Widget sharePanel(Brightness brightness) {
    final state = shareChatState();
    return testApp(
      _Launcher(
        (context) => showSharePanel(context, ConversationSubject(sessionId: 's1', reply: firstReply(state))),
      ),
      brightness: brightness,
      overrides: [chatProvider.overrideWith2((id) => FakeChatController(id, state))],
    );
  }

  _golden(
    'phone_share_panel',
    phoneLeft,
    sharePanel,
    only: const [Brightness.light],
    before: (tester) async {
      await tester.tap(find.text('open'));
      await pumpFrames(tester, 8);
    },
  );
  _golden(
    'phone_share_image',
    phoneLeft,
    sharePanel,
    only: const [Brightness.light],
    before: (tester) async {
      await tester.tap(find.text('open'));
      await pumpFrames(tester, 8);
      await tester.tap(find.byKey(const ValueKey('share-to-image')));
      await pumpFrames(tester, 8);
    },
  );

  // ── 600 and 840 ────────────────────────────────────────────────────────
  _golden('w600_chat', w600, (b) => homeApp(brightness: b), only: const [Brightness.light]);
  _golden('w840_chat', w840, (b) => homeApp(brightness: b));

  // ── 1280 ───────────────────────────────────────────────────────────────
  _golden(
    'w1280_search',
    w1280,
    (b) => goldenApp(
      home: SessionSearchPage(now: searchNow),
      brightness: b,
      overrides: [
        sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
        sessionContentSearchProvider.overrideWithValue(
          FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)}),
        ),
        currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
      ],
    ),
    only: const [Brightness.light],
    before: (tester) async {
      await tester.enterText(find.byType(TextField), '登录');
      await tester.pump(SessionSearchController.debounce);
      await pumpFrames(tester, 4);
      FocusManager.instance.primaryFocus?.unfocus();
      await pumpFrames(tester, 3);
    },
  );
  _golden(
    'w1280_terminal',
    w1280,
    (b) => goldenApp(
      home: const TerminalPage(sessionId: 's1'),
      brightness: b,
      overrides: terminalOverrides(FakeTerminalBackend()..createdScreen = sampleScreen),
    ),
    only: const [Brightness.light],
    before: settleTerminal,
  );
}
