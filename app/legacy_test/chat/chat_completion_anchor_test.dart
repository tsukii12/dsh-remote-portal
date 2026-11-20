import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'turn_settle_test.dart' show state;

Future<ChatHarness> _open(WidgetTester tester, {required bool fluid}) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state(longHistory: true)});
  await tester.pumpWidget(
    testApp(
      AppMotionScope(fluid: fluid, child: const ChatScreen()),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester, 40);
  return harness;
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable)).first)
    .position;

Future<Finder> _readHistory(WidgetTester tester) async {
  final old = find.byKey(const ValueKey('u0'));
  final viewport = tester.getRect(find.byType(ChatList));
  for (var drag = 0; drag < 12; drag++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await pumpFrames(tester, 35);
    if (old.evaluate().isNotEmpty && tester.getBottomRight(old).dy > viewport.bottom + 100) break;
  }
  expect(_position(tester).extentAfter, greaterThan(300));
  expect(old, findsOneWidget);
  expect(
    tester.getBottomRight(old).dy,
    greaterThan(viewport.bottom + 100),
    reason: 'The changing current turn is below the entire readable viewport.',
  );
  expect(tester.getTopLeft(old).dy, lessThan(100), reason: 'The long history spans the readable viewport.');
  return old;
}

void main() {
  setUpAll(loadTestFonts);
  for (final fluid in [false, true]) {
    final tier = fluid ? 'fluid' : 'standard';
    testWidgets('$tier completion keeps the focused editor and IME connection', (tester) async {
      final harness = await _open(tester, fluid: fluid);
      final editor = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
      await tester.showKeyboard(editor);
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      const editing = TextEditingValue(
        text: '正在输入下一条消息',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 3, end: 7),
      );
      tester.testTextInput.updateEditingValue(editing);
      await pumpFrames(tester, 30);
      final composer = tester.widget<Composer>(find.byType(Composer));
      expect(composer.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      harness.controllers['s1']!.emit(state(running: false, longHistory: true));
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(composer.focusNode!.hasFocus, isTrue, reason: 'frame $frame');
        expect(tester.testTextInput.isVisible, isTrue, reason: 'frame $frame');
        expect(composer.controller.value, editing, reason: 'frame $frame');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('$tier completion leaves older history in place', (tester) async {
      final harness = await _open(tester, fluid: fluid);
      final old = await _readHistory(tester);
      final oldTop = tester.getTopLeft(old).dy;
      harness.controllers['s1']!.emit(state(running: false, longHistory: true));
      await pumpFrames(tester, 40);
      expect(tester.getTopLeft(old).dy, closeTo(oldTop, 1));
      expect(_position(tester).extentAfter, greaterThan(100));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('completion resizes the viewport without taking an active drag', (tester) async {
    final harness = await _open(tester, fluid: true);
    final old = await _readHistory(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    final oldTop = tester.getTopLeft(old).dy;
    harness.controllers['s1']!.emit(state(running: false, longHistory: true));
    await pumpFrames(tester, 25);
    expect(tester.getTopLeft(old).dy, closeTo(oldTop, 1));
    final before = _position(tester).pixels;
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(_position(tester).pixels, lessThan(before - 40), reason: 'The same drag still controls the list.');
    await gesture.up();
    expect(tester.takeException(), isNull);
  });
}
