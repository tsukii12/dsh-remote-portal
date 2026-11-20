import 'dart:async';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'support.dart';

Future<Completer<Map<String, Object?>>> beginPaste(WidgetTester tester, FakeTerminalBackend backend) async {
  final clipboard = Completer<Map<String, Object?>>();
  var reads = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method != 'Clipboard.getData') return null;
    reads++;
    return clipboard.future;
  });
  addTearDown(() {
    if (!clipboard.isCompleted) clipboard.complete({'text': ''});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  backend.screens['a'] = 'hello world\r\n\$ ';
  await pumpTerminalPage(tester, backend);
  final view = tester.getRect(find.byType(TerminalView));
  await tester.longPressAt(view.topLeft + const Offset(14, 8));
  await settleTerminal(tester);
  await tester.tap(find.text('粘贴'));
  await tester.pump();
  expect(reads, 1);
  expect(backend.attachOf('a').written, isEmpty);
  return clipboard;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a clipboard reply cannot paste into another terminal tab', (tester) async {
    final backend = FakeTerminalBackend(
      terminals: [
        infoJson('a', title: 'first'),
        infoJson('b', title: 'second'),
      ],
    );
    final clipboard = await beginPaste(tester, backend);
    final first = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    await tester.tap(find.byKey(const ValueKey('terminal-tab-b')));
    await settleTerminal(tester);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).terminal, isNot(same(first)));

    clipboard.complete({'text': 'clipboard text'});
    await settleTerminal(tester);
    expect(backend.attachOf('a').written, isEmpty);
    expect(backend.attachOf('b').written, isEmpty);
  });

  testWidgets('a clipboard reply cannot paste into a fresh attachment of the same terminal', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    final clipboard = await beginPaste(tester, backend);
    final previous = backend.attachOf('a');
    final first = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    previous.lose();
    await settleTerminal(tester);
    await tester.tap(find.text('重新连接'));
    await settleTerminal(tester);
    expect(backend.attaches, hasLength(2));
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).terminal, isNot(same(first)));

    clipboard.complete({'text': 'clipboard text'});
    await settleTerminal(tester);
    expect(previous.written, isEmpty);
    expect(backend.attachOf('a').written, isEmpty);
  });

  testWidgets('a clipboard reply still pastes after metadata changes on the same screen', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    final clipboard = await beginPaste(tester, backend);
    final first = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    backend.attachOf('a').state(infoJson('a', title: 'renamed'));
    await settleTerminal(tester);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).terminal, same(first));

    clipboard.complete({'text': 'clipboard text'});
    await settleTerminal(tester);
    expect(backend.attachOf('a').written, 'clipboard text');
  });

  testWidgets('a clipboard reply respects input ownership lost while reading', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    final clipboard = await beginPaste(tester, backend);
    backend.attachOf('a').state(infoJson('a'), writable: false);
    await settleTerminal(tester);

    clipboard.complete({'text': 'clipboard text'});
    await settleTerminal(tester);
    expect(backend.attachOf('a').written, isEmpty);
  });

  testWidgets('a clipboard reply cannot paste after the terminal page closes', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    final clipboard = await beginPaste(tester, backend);
    final previous = backend.attachOf('a');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    clipboard.complete({'text': 'clipboard text'});
    await settleTerminal(tester);
    expect(previous.written, isEmpty);
  });

  testWidgets('a same-frame reconnect does not receive an earlier clipboard reply', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    final clipboard = await beginPaste(tester, backend);
    final previous = backend.attachOf('a');
    final first = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final screen = tester.widget<TerminalScreen>(find.byType(TerminalScreen));
    final container = ProviderScope.containerOf(tester.element(find.byType(TerminalScreen)));

    previous.lose();
    await tester.idle();
    backend.reconnects.add(null);
    await tester.idle();

    expect(backend.attaches, hasLength(2));
    final current = container.read(terminalWorkspaceProvider(screen.sessionId)).selected!;
    expect(current.phase, TerminalPhase.live);
    expect(current.writable, isTrue);
    expect(current.terminal, isNot(same(first)), reason: 'the workspace has consumed the new attachment snapshot');
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal,
      same(first),
      reason: 'no frame has rebuilt the terminal widget',
    );
    expect(tester.takeException(), isNull);

    clipboard.complete({'text': 'stale clipboard frame probe'});
    await tester.idle();
    expect(previous.written, isEmpty);
    expect(backend.attachOf('a').written, isEmpty);
  });
}
