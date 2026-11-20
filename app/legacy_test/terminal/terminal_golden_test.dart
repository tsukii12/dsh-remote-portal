// Goldens of the terminal page (light + dark): a live shell with the key row,
// several tabs with an ended one selected, the selection bar, a lost
// terminal, and a connection without terminals.
//
//   flutter test --update-goldens test/terminal

import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import '../shell/golden_harness.dart';
import 'support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeTerminalBackend backend;

  // A fresh conversation: the page starts one shell at the phone's size.
  goldenBoth(
    'terminal_live',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend = FakeTerminalBackend()..createdScreen = sampleScreen;
      return terminalOverrides(backend);
    },
    before: settleTerminal,
  );

  // Ctrl armed for the next key, Alt locked: pills behind the labels.
  goldenBoth(
    'terminal_modifiers',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend = FakeTerminalBackend()..createdScreen = sampleScreen;
      return terminalOverrides(backend);
    },
    before: (tester) async {
      await settleTerminal(tester);
      await tester.tap(find.byKey(const ValueKey('terminal-key-ctrl')));
      final hold = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('terminal-key-alt'))));
      await tester.pump(const Duration(milliseconds: 600));
      await hold.up();
      await settleTerminal(tester);
    },
  );

  goldenBoth(
    'terminal_tabs_ended',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend =
          FakeTerminalBackend(
              terminals: [
                infoJson('t1', title: 'bash'),
                infoJson('t2', title: 'flutter test'),
                infoJson('t3', title: '构建', state: 'exited', exitCode: 1),
              ],
            )
            ..screens['t1'] = sampleScreen
            ..screens['t3'] =
                '\$ flutter build apk --release\r\n'
                'Running Gradle task \'assembleRelease\'...\r\n'
                '\x1b[31mFAILURE: Build failed with an exception.\x1b[0m\r\n'
                '\r\n'
                '* What went wrong:\r\n'
                'Execution failed for task \':app:minifyReleaseWithR8\'.\r\n';
      return terminalOverrides(backend);
    },
    before: (tester) async {
      await settleTerminal(tester);
      await tester.tap(find.byKey(const ValueKey('terminal-tab-t3')));
      await settleTerminal(tester);
    },
  );

  goldenBoth(
    'terminal_selection',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend = FakeTerminalBackend()..createdScreen = sampleScreen;
      return terminalOverrides(backend);
    },
    before: (tester) async {
      await settleTerminal(tester);
      final view = tester.getRect(find.byType(TerminalView));
      await tester.longPressAt(view.topLeft + const Offset(40, 70));
      await settleTerminal(tester);
    },
  );

  goldenBoth(
    'terminal_missing',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend = FakeTerminalBackend(terminals: [infoJson('t1', title: 'bash')]);
      return terminalOverrides(backend);
    },
    before: (tester) async {
      await settleTerminal(tester);
      backend.host.remove('t1');
      backend.attachOf('t1').lose();
      await settleTerminal(tester);
      await tester.tap(find.text('重新连接'));
      await settleTerminal(tester);
    },
  );

  goldenBoth(
    'terminal_actions',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () {
      backend = FakeTerminalBackend()..createdScreen = sampleScreen;
      return terminalOverrides(backend);
    },
    before: (tester) async {
      await settleTerminal(tester);
      await tester.tap(find.byKey(const ValueKey('terminal-more')));
      await settleTerminal(tester);
      await tester.tap(find.text('新建终端'));
      await settleTerminal(tester);
    },
  );

  goldenBoth(
    'terminal_unsupported',
    () => const TerminalPage(sessionId: 's1'),
    overrides: () => terminalOverrides(FakeTerminalBackend(supported: false)),
    before: settleTerminal,
  );
}
