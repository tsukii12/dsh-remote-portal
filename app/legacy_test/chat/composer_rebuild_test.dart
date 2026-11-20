import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _Input extends TextEditingController {
  _Input({super.text});

  bool get listening => hasListeners;
}

class _Rig {
  _Rig({String text = '', this.withFooter = false}) : input = _Input(text: text);

  final bool withFooter;
  _Input input;
  final focus = FocusNode();
  bool running = false;
  bool connected = true;
  bool sessionReady = true;
  bool busy = false;
  bool hasAttachments = false;
  int sends = 0;
  int stops = 0;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              controller: input,
              focusNode: focus,
              footer: withFooter ? const Text('Model') : null,
              running: running,
              connected: connected,
              sessionReady: sessionReady,
              busy: busy,
              hasAttachments: hasAttachments,
              onSend: () => sends++,
              onStop: () => stops++,
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await pumpFrames(tester, 3);
  }
}

class _Builds {
  int chrome = 0;
  int fields = 0;
  int editors = 0;

  void observe() {
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is PetCover) chrome++;
      if (element.widget is TextField) fields++;
      if (element.widget is EditableText) editors++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
  }

  void report(String scenario) =>
      debugPrint('[WORK] $scenario: PetCover=$chrome TextField=$fields EditableText=$editors');
}

void main() {
  setUpAll(loadTestFonts);

  Future<_Rig> mount(WidgetTester tester, {String text = '', bool withFooter = false}) async {
    usePhoneView(tester);
    final rig = _Rig(text: text, withFooter: withFooter);
    final initial = rig.input;
    addTearDown(initial.dispose);
    addTearDown(rig.focus.dispose);
    await rig.pump(tester);
    return rig;
  }

  for (final withFooter in [false, true]) {
    testWidgets('typing a nonempty draft leaves composer controls idle (footer $withFooter)', (tester) async {
      final rig = await mount(tester, text: '草稿', withFooter: withFooter);
      final field = tester.widget<TextField>(find.byType(TextField));
      final builds = _Builds()..observe();
      for (var i = 1; i <= 20; i++) {
        final text = '草稿${'字' * i}';
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(rig.input.text, text);
        expect(tester.state<EditableTextState>(find.byType(EditableText)).renderEditable.text!.toPlainText(), text);
      }
      builds.report('20 nonempty typing updates, footer=$withFooter');
      expect(builds.editors, greaterThan(0), reason: 'the live editor must still render changed text');
      expect(builds.chrome, 0);
      expect(tester.widget<TextField>(find.byType(TextField)), same(field));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('selection and composing updates do not rebuild the surrounding controls', (tester) async {
    final rig = await mount(tester, text: '拼音草稿');
    final builds = _Builds()..observe();
    for (final value in [
      const TextEditingValue(text: '拼音草稿', selection: TextSelection.collapsed(offset: 1)),
      const TextEditingValue(
        text: '拼音草稿',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
      const TextEditingValue(text: '拼音草稿', selection: TextSelection(baseOffset: 1, extentOffset: 3)),
    ]) {
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      expect(rig.input.value, value);
    }
    builds.report('selection and IME composition');
    expect(builds.chrome, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whitespace can grow the editor without changing empty-draft controls', (tester) async {
    final rig = await mount(tester);
    final initialHeight = tester.getSize(find.byType(TextField)).height;
    final builds = _Builds()..observe();
    for (final text in [' ', '  ', '\n\n']) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await pumpFrames(tester, 2);
      expect(rig.input.text, text);
    }
    builds.report('empty whitespace and newlines');
    expect(tester.getSize(find.byType(TextField)).height, greaterThan(initialHeight));
    expect(builds.chrome, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty transitions still switch stop and send and preserve send gates', (tester) async {
    final rig = await mount(tester);
    rig.running = true;
    await rig.pump(tester);
    expect(find.byIcon(AppIcons.stopGenerating), findsOneWidget);
    rig.input.text = '下一条';
    await pumpFrames(tester, 3);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    expect(rig.sends, 1);
    for (final gate in ['connected', 'sessionReady', 'busy']) {
      rig.connected = gate != 'connected';
      rig.sessionReady = gate != 'sessionReady';
      rig.busy = gate == 'busy';
      await rig.pump(tester);
      final send = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '发送');
      expect(tester.widget<Semantics>(send).properties.enabled, isFalse);
    }
    rig.connected = rig.sessionReady = true;
    rig.busy = false;
    rig.input.clear();
    await rig.pump(tester);
    expect(find.byIcon(AppIcons.stopGenerating), findsOneWidget);
    rig.hasAttachments = true;
    await rig.pump(tester);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
    expect(rig.sends, 1);
    expect(rig.stops, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the controller transfers draft controls and removes old listeners', (tester) async {
    final rig = await mount(tester, text: '旧草稿');
    final old = rig.input;
    final replacement = _Input();
    addTearDown(replacement.dispose);
    rig.input = replacement;
    rig.running = true;
    await rig.pump(tester);
    expect(find.byIcon(AppIcons.stopGenerating), findsOneWidget);
    expect(old.listening, isFalse);
    final builds = _Builds()..observe();
    old.clear();
    await tester.pump();
    expect(builds.chrome, 0);
    expect(replacement.text, isEmpty);
    replacement.text = '当前草稿';
    await pumpFrames(tester, 3);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller, same(replacement));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.listening, isFalse);
    replacement.clear();
    expect(tester.takeException(), isNull);
  });
}
