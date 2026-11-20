import 'package:dsh_app/ui/terminal/terminal_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support.dart';

Finder cell(TerminalExtraKey key) => find.byKey(ValueKey('terminal-key-${key.name}'));

void away(WidgetTester tester, AppLifecycleState target) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    if (state == target) break;
  }
}

void resume(WidgetTester tester) {
  switch (tester.binding.lifecycleState) {
    case AppLifecycleState.paused:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    case AppLifecycleState.hidden:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    default:
      break;
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

class Keys {
  final modifiers = TerminalModifiers();
  final sent = <TerminalExtraKey>[];

  Future<void> open(WidgetTester tester) async {
    resume(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: ExtraKeysRow(modifiers: modifiers, onKey: sent.add),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      resume(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      modifiers.dispose();
    });
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('terminal hold sends no protocol writes after ${state.name}', (tester) async {
      resume(tester);
      final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
      await pumpTerminalPage(tester, backend);
      final attach = backend.attachOf('a');
      final gesture = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.up)));
      var ended = false;
      try {
        await tester.pump(const Duration(milliseconds: 200));
        expect(attach.written, isEmpty);
        away(tester, state);
        await tester.pump(const Duration(seconds: 1));
        expect(attach.written, isEmpty, reason: 'No held key reaches the real TerminalAttachment encoder');
        resume(tester);
        await tester.pump();
        await gesture.up();
        ended = true;
        await tester.pump(const Duration(milliseconds: 120));
        expect(attach.written, isEmpty, reason: 'A late release does not turn the retired hold into a tap');
        await tester.tap(cell(TerminalExtraKey.up));
        await tester.pump();
        expect(attach.written, '\x1b[A', reason: 'A fresh foreground gesture still sends one arrow');
      } finally {
        resume(tester);
        if (!ended) await gesture.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('an already repeating key stops and never resumes the old hold', (tester) async {
    final keys = Keys();
    await keys.open(tester);
    final gesture = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.right)));
    var ended = false;
    try {
      await tester.pump(const Duration(milliseconds: 421));
      await tester.pump(const Duration(milliseconds: 120));
      expect(keys.sent, List.filled(3, TerminalExtraKey.right));
      away(tester, AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(keys.sent, hasLength(3));
      resume(tester);
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      ended = true;
      expect(keys.sent, hasLength(3));
      await tester.tap(cell(TerminalExtraKey.right));
      expect(keys.sent, hasLength(4));
    } finally {
      resume(tester);
      if (!ended) await gesture.cancel();
    }
  });

  testWidgets('a pending modifier lock is cancelled without clearing an existing lock', (tester) async {
    final keys = Keys();
    await keys.open(tester);
    keys.modifiers.lock(TerminalExtraKey.alt);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.ctrl)));
    var ended = false;
    try {
      await tester.pump(const Duration(milliseconds: 200));
      away(tester, AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(keys.modifiers.ctrl, ModifierMode.off);
      expect(keys.modifiers.alt, ModifierMode.locked);
      resume(tester);
      await tester.pump();
      await gesture.up();
      ended = true;
      expect(keys.modifiers.ctrl, ModifierMode.off);
      await tester.tap(cell(TerminalExtraKey.ctrl));
      expect(keys.modifiers.ctrl, ModifierMode.armed);
      final fresh = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.ctrl)));
      await tester.pump(const Duration(milliseconds: 451));
      await fresh.up();
      expect(keys.modifiers.ctrl, ModifierMode.locked);
    } finally {
      resume(tester);
      if (!ended) await gesture.cancel();
    }
  });

  testWidgets('a second finger on one key cannot replace or orphan its active hold', (tester) async {
    final keys = Keys();
    await keys.open(tester);
    final point = tester.getCenter(cell(TerminalExtraKey.left));
    final first = await tester.startGesture(point, pointer: 1);
    TestGesture? second;
    var firstEnded = false;
    var secondEnded = false;
    try {
      await tester.pump(const Duration(milliseconds: 421));
      expect(keys.sent, hasLength(1));
      second = await tester.startGesture(point, pointer: 2);
      await second.up();
      secondEnded = true;
      await tester.pump(const Duration(milliseconds: 120));
      expect(keys.sent, hasLength(3), reason: 'Only the first pointer owns the repeat timer');
      await first.up();
      firstEnded = true;
      await tester.pump(const Duration(seconds: 1));
      expect(keys.sent, hasLength(3), reason: 'No orphan timer survives release');
    } finally {
      if (!secondEnded) await second?.cancel();
      if (!firstEnded) await first.cancel();
    }
  });

  testWidgets('a pointer down delivered while inactive cannot become a later foreground tap', (tester) async {
    final keys = Keys();
    await keys.open(tester);
    away(tester, AppLifecycleState.inactive);
    final gesture = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.tab)));
    resume(tester);
    await tester.pump();
    await gesture.up();
    expect(keys.sent, isEmpty);
    await tester.tap(cell(TerminalExtraKey.tab));
    expect(keys.sent, [TerminalExtraKey.tab]);
  });

  testWidgets('ordinary tap, drag, pointer cancel and disposal keep their existing behavior', (tester) async {
    final keys = Keys();
    await keys.open(tester);
    await tester.tap(cell(TerminalExtraKey.esc));
    expect(keys.sent, [TerminalExtraKey.esc]);
    final drag = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.down)));
    await drag.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(seconds: 1));
    await drag.up();
    expect(keys.sent, hasLength(1));
    final cancelled = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.down)));
    await cancelled.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(keys.sent, hasLength(1));
    final disposed = await tester.startGesture(tester.getCenter(cell(TerminalExtraKey.down)));
    await tester.pumpWidget(const SizedBox.shrink());
    await disposed.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(keys.sent, hasLength(1));
    away(tester, AppLifecycleState.paused);
    resume(tester);
    expect(tester.takeException(), isNull);
  });
}
