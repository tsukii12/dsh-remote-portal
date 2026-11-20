import 'package:dsh_app/ui/chat/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  Future<(TextEditingController, FocusNode)> pump(
    WidgetTester tester, {
    String text = '',
    bool running = false,
    bool enterSends = false,
    bool connected = true,
    bool busy = false,
    bool sessionReady = true,
    VoidCallback? send,
    VoidCallback? stop,
  }) async {
    final input = TextEditingController(text: text);
    final focus = FocusNode();
    addTearDown(input.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Composer(
            controller: input,
            focusNode: focus,
            connected: connected,
            busy: busy,
            sessionReady: sessionReady,
            hardwareEnterSends: enterSends,
            running: running,
            onSend: send ?? () {},
            onStop: stop ?? () {},
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).contentInsertionConfiguration, isNull);
    return (input, focus);
  }

  for (final modifier in [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.metaLeft]) {
    testWidgets('${modifier.keyLabel} + Enter sends once without adding a newline', (tester) async {
      var sends = 0;
      final (input, _) = await pump(tester, text: '草稿', send: () => sends++);
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
      expect(sends, 1);
      expect(input.text, '草稿');
    });
  }

  testWidgets('opt-in Enter sends once; Shift+Enter and software IME keep newlines', (tester) async {
    var sends = 0;
    final (input, _) = await pump(tester, text: '草稿', enterSends: true, send: () => sends++);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    expect(input.text, '草稿');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sends, 1);
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.newline);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    expect(sends, 1);
  });

  testWidgets('holding Enter does not send repeatedly or insert repeat newlines', (tester) async {
    var sends = 0;
    final (_, node) = await pump(tester, text: '草稿', enterSends: true, send: () => sends++);
    final focus = tester.widget<Focus>(
      find.byWidgetPredicate((w) => w is Focus && !w.canRequestFocus && w.skipTraversal && w.onKeyEvent != null).first,
    );
    expect(
      focus.onKeyEvent!(
        node,
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration(milliseconds: 30),
        ),
      ),
      KeyEventResult.handled,
    );
    expect(sends, 0);
  });

  testWidgets('opt-in Enter leaves IME composition alone and supports numpad Enter', (tester) async {
    var sends = 0;
    final (input, _) = await pump(tester, text: '拼', enterSends: true, send: () => sends++);
    input.value = const TextEditingValue(text: '拼', composing: TextRange(start: 0, end: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 0);
    input.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(sends, 1);
  });

  for (final disabled in ['disconnected', 'busy', 'unready', 'empty']) {
    testWidgets('opt-in Enter cannot send when $disabled', (tester) async {
      var sends = 0;
      await pump(
        tester,
        text: disabled == 'empty' ? '' : '草稿',
        enterSends: true,
        connected: disabled != 'disconnected',
        busy: disabled == 'busy',
        sessionReady: disabled != 'unready',
        send: () => sends++,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 0);
    });
  }

  testWidgets('empty running composer swallows Ctrl+Enter; ordinary Enter does not send', (tester) async {
    var sends = 0;
    var stops = 0;
    await pump(tester, running: true, send: () => sends++, stop: () => stops++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(sends, 0);
    expect(stops, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 0);
  });

  testWidgets('Escape requires two down events within 500ms and swallows the first', (tester) async {
    var stops = 0;
    final (_, node) = await pump(tester, running: true, stop: () => stops++);
    final focus = tester.widget<Focus>(
      find.byWidgetPredicate((w) => w is Focus && !w.canRequestFocus && w.skipTraversal && w.onKeyEvent != null).first,
    );
    KeyEventResult escape(int ms) => focus.onKeyEvent!(
      node,
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.escape,
        logicalKey: LogicalKeyboardKey.escape,
        timeStamp: Duration(milliseconds: ms),
      ),
    );
    expect(escape(0), KeyEventResult.handled);
    expect(stops, 0);
    expect(escape(600), KeyEventResult.handled);
    expect(stops, 0);
    expect(escape(900), KeyEventResult.handled);
    expect(stops, 1);
  });

  testWidgets('idle Escape and composing Enter are ignored', (tester) async {
    final (input, node) = await pump(tester);
    final focus = tester.widget<Focus>(
      find.byWidgetPredicate((w) => w is Focus && !w.canRequestFocus && w.skipTraversal && w.onKeyEvent != null).first,
    );
    expect(
      focus.onKeyEvent!(
        node,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.ignored,
    );
    input.value = const TextEditingValue(text: '拼', composing: TextRange(start: 0, end: 1));
    expect(
      focus.onKeyEvent!(
        node,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.ignored,
    );
  });
}
