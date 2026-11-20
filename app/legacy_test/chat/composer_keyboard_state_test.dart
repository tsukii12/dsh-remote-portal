import 'package:dsh_app/ui/chat/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Rig {
  final inputs = <TextEditingController>[TextEditingController(text: '草稿')];
  TextEditingController get input => inputs.last;
  final focus = FocusNode();
  final otherFocus = FocusNode();
  bool running = true;
  bool busy = false;
  bool stopping = false;
  int sends = 0;
  int stops = 0;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              Composer(
                controller: input,
                focusNode: focus,
                connected: true,
                running: running,
                busy: busy,
                stopping: stopping,
                onSend: () => sends++,
                onStop: () => stops++,
              ),
              TextField(focusNode: otherFocus),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
  }

  KeyEventResult key(WidgetTester tester, LogicalKeyboardKey logical, int ms) {
    final wrapper = tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(Composer),
            matching: find.byWidgetPredicate(
              (w) => w is Focus && !w.canRequestFocus && w.skipTraversal && w.onKeyEvent != null,
            ),
          )
          .first,
    );
    return wrapper.onKeyEvent!(
      focus,
      KeyDownEvent(
        physicalKey: logical == LogicalKeyboardKey.escape ? PhysicalKeyboardKey.escape : PhysicalKeyboardKey.keyA,
        logicalKey: logical,
        timeStamp: Duration(milliseconds: ms),
      ),
    );
  }

  KeyEventResult escape(WidgetTester tester, int ms) => key(tester, LogicalKeyboardKey.escape, ms);

  void dispose() {
    focus.dispose();
    otherFocus.dispose();
    for (final input in inputs) {
      input.dispose();
    }
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('committed collapsed composing range allows Ctrl+Enter', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.pump(tester);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 2, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(rig.sends, 1);
    expect(rig.input.text, '你好');
  });

  testWidgets('IME consumes its Escape without confirming an earlier stop', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.pump(tester);
    expect(rig.escape(tester, 0), KeyEventResult.handled);
    rig.input.value = const TextEditingValue(text: '拼', composing: TextRange(start: 0, end: 1));
    expect(rig.escape(tester, 100), KeyEventResult.ignored);
    rig.input.clearComposing();
    expect(rig.escape(tester, 200), KeyEventResult.handled);
    expect(rig.stops, 0, reason: 'IME cancellation is not stop confirmation');
    rig.escape(tester, 300);
    expect(rig.stops, 1);
  });

  for (final mode in ['busy', 'stopping']) {
    testWidgets('$mode disables keyboard stop just as it disables the button', (tester) async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      rig.busy = mode == 'busy';
      rig.stopping = mode == 'stopping';
      await rig.pump(tester);
      expect(rig.escape(tester, 0), KeyEventResult.handled);
      expect(rig.escape(tester, 100), KeyEventResult.handled);
      expect(rig.stops, 0);
      rig.busy = rig.stopping = false;
      await rig.pump(tester);
      rig.escape(tester, 200);
      expect(rig.stops, 0);
      rig.escape(tester, 300);
      expect(rig.stops, 1);
    });
  }

  for (final transition in ['idle', 'busy', 'new draft', 'focus', 'other key']) {
    testWidgets('$transition invalidates the earlier Escape', (tester) async {
      final rig = _Rig();
      addTearDown(rig.dispose);
      await rig.pump(tester);
      rig.escape(tester, 0);
      switch (transition) {
        case 'idle':
          rig.running = false;
          await rig.pump(tester);
          rig.running = true;
          await rig.pump(tester);
        case 'busy':
          rig.busy = true;
          await rig.pump(tester);
          rig.busy = false;
          await rig.pump(tester);
        case 'new draft':
          rig.inputs.add(TextEditingController(text: '新的草稿'));
          await rig.pump(tester);
        case 'focus':
          rig.otherFocus.requestFocus();
          await tester.pump();
          expect(rig.focus.hasFocus, isFalse);
          rig.focus.requestFocus();
          await tester.pump();
        case 'other key':
          rig.key(tester, LogicalKeyboardKey.keyA, 100);
      }
      rig.escape(tester, 200);
      expect(rig.stops, 0);
      rig.escape(tester, 300);
      expect(rig.stops, 1);
    });
  }

  testWidgets('ordinary rebuild preserves an eligible Escape pair', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await rig.pump(tester);
    rig.escape(tester, 0);
    await rig.pump(tester);
    rig.escape(tester, 100);
    expect(rig.stops, 1);
  });
}
