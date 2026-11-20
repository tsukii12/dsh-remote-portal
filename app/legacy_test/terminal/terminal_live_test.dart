// The terminal workspace against a real `dsh web` (no model calls).
//
// Skipped unless DSH_LIVE_URL holds the launch URL (with `?token=`) of a
// throwaway engine and DSH_LIVE_CWD a directory it may use:
//
//   DSH_LIVE_URL='http://127.0.0.1:3297/?token=…' DSH_LIVE_CWD=/tmp/x \
//     flutter test test/terminal/terminal_live_test.dart
library;

import 'dart:io';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final cwd = Platform.environment['DSH_LIVE_CWD'];

  test('open, type, resize, exit, restore and close against a live engine', () async {
    SharedPreferences.setMockInitialValues({});
    TerminalWorkspace.viewSizeWait = Duration.zero;
    TerminalWorkspace.resizeSettle = Duration.zero;
    final launch = DshLaunchUrl.tryParse(url!)!;
    final client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
    addTearDown(client.close);
    final session = (await client.createSession(cwd: cwd)).sessionId;

    Future<void> until(bool Function() ok, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!ok()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out: $what');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    ProviderContainer open() {
      final container = ProviderContainer(
        overrides: [terminalBackendProvider.overrideWith((ref, id) => ClientTerminalBackend(client, id))],
      );
      container.listen(terminalWorkspaceProvider(session), (_, _) {});
      return container;
    }

    var container = open();
    TerminalWorkspaceState read() => container.read(terminalWorkspaceProvider(session));
    TerminalWorkspace workspace() => container.read(terminalWorkspaceProvider(session).notifier);
    String screen() => read().selected!.terminal.buffer.lines.toList().map((l) => l.toString()).join('\n');

    await until(() => read().selected?.phase == TerminalPhase.live, 'first terminal live');
    final id = read().selected!.id;
    expect(read().selected!.writable, isTrue);

    // Pick bash explicitly for predictable output.
    final shells = await workspace().shells();
    final bash = shells.firstWhere((s) => s.name == 'bash');
    await workspace().newTerminal(shellPath: bash.path);
    await until(() => read().selected?.phase == TerminalPhase.live && read().selected!.id != id, 'bash live');
    final bashId = read().selected!.id;
    workspace().resize(bashId, 60, 20);
    read().selected!.terminal.textInput('echo "中文-\$((6*7))"; stty size\r');
    await until(() => screen().contains('中文-42') && screen().contains('20 60'), 'echo and stty output');

    // Leave the page: the shell keeps running and comes back with its screen.
    container.dispose();
    container = open();
    await until(() => read().tabs.length == 2 && !read().loading, 'restored tabs');
    workspace().select(bashId);
    await until(() => read().selected?.phase == TerminalPhase.live, 'bash reattached');
    expect(screen(), contains('中文-42'));

    read().selected!.terminal.textInput('exit 3\r');
    await until(() => read().selected?.phase == TerminalPhase.ended, 'exit');
    expect(read().selected!.exitCode, 3);

    for (final tab in [...read().tabs]) {
      workspace().closeTab(tab.id);
    }
    await until(() => read().tabs.isEmpty, 'closed');
    // Closing runs in the background (provider grace period included).
    var left = await client.listTerminals(session);
    for (var i = 0; i < 40 && left.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      left = await client.listTerminals(session);
    }
    expect([for (final t in left) '${t.title} ${t.state}'], isEmpty);
    container.dispose();
  }, skip: url == null || cwd == null ? 'set DSH_LIVE_URL and DSH_LIVE_CWD to run' : null);
}
