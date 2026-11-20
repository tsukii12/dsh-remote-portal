import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/widgets/message_menu.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

final code = 'final selectedWord = ${List.generate(30, (i) => 'segment$i').join(' ')};\nreturn selectedWord;';
final markdown = '代码示例。\n\n```dart\n$code\n```';

Finder codeParagraph() => find.descendant(
  of: find.byType(CodeBlock),
  matching: find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('final selectedWord')),
);

String selected(RenderParagraph paragraph) => paragraph.selections
    .where((selection) => !selection.isCollapsed)
    .map((selection) => selection.textInside(paragraph.text.toPlainText()))
    .join();

Future<void> selectThenScroll(WidgetTester tester, String surface) async {
  // SelectionArea only clears focus-lost selections while the app is active.
  debugPrint(jsonEncode({'surface': surface, 'lifecycleBefore': tester.binding.lifecycleState?.name}));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  final paragraph = tester.renderObject<RenderParagraph>(codeParagraph());
  final word = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 6, extentOffset: 18)).single;
  await tester.longPressAt(paragraph.localToGlobal(word.toRect().center));
  await tester.pumpAndSettle();
  expect(selected(paragraph), 'selectedWord');
  final originalRange = paragraph.selections.single;
  final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
  expect(region.selectionOverlay, isNotNull);
  final selectedFocus = FocusManager.instance.primaryFocus;
  final position = tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(CodeBlock),
          matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right),
        ),
      )
      .position;
  final before = position.pixels;
  await tester.dragFrom(paragraph.localToGlobal(Offset(270, word.toRect().center.dy)), const Offset(-80, 0));
  await tester.pumpAndSettle();
  debugPrint(
    jsonEncode({
      'surface': surface,
      'pixelsBefore': before,
      'pixelsAfter': position.pixels,
      'selectedAfter': selected(paragraph),
      'sameFocus': identical(FocusManager.instance.primaryFocus, selectedFocus),
      'overlayAfter': region.selectionOverlay != null,
    }),
  );
  expect(position.pixels - before, greaterThan(40));
  expect(selected(paragraph), 'selectedWord');
  expect(paragraph.selections.single, originalRange);
  expect(FocusManager.instance.primaryFocus, same(selectedFocus));
  expect(region.selectionOverlay, isNotNull);

  final handle = paragraph.getBoxesForSelection(paragraph.selections.single).single.toRect().bottomRight;
  final drag = await tester.startGesture(paragraph.localToGlobal(handle + const Offset(1, 5)));
  await drag.moveBy(const Offset(50, 0));
  await tester.pump();
  expect(region.selectionOverlay!.isDraggingEndHandle, isTrue);
  debugPrint(jsonEncode({'surface': surface, 'endHandle': region.selectionOverlay!.isDraggingEndHandle}));
  await drag.up();
  await tester.pumpAndSettle();
  debugPrint(
    jsonEncode({
      'surface': surface,
      'extended': selected(paragraph),
      'originalRange': [originalRange.start, originalRange.end],
      'extendedRange': [paragraph.selections.single.start, paragraph.selections.single.end],
    }),
  );
  final extendedRange = paragraph.selections.single;
  // A fluid reply can shift the starting edge slightly as its press scale
  // settles. The original range must remain selected and the end must extend.
  expect(extendedRange.start, lessThanOrEqualTo(originalRange.start));
  expect(extendedRange.end, greaterThan(originalRange.end));
  expect(selected(paragraph), contains('selectedWord'));
  expect(tester.takeException(), isNull);
}

Future<FocusNode> focusedInput(WidgetTester tester, {bool separateScope = false}) async {
  usePhoneView(tester);
  final focus = FocusNode();
  addTearDown(focus.dispose);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(loading: false, items: [assistant(1, List.filled(45, '可滚动的回复内容。').join('\n\n'))]),
    },
  );
  const list = ChatList(sessionId: 's1', topInset: 24, bottomInset: 0);
  final field = TextField(focusNode: focus);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Column(
          children: [
            Expanded(child: separateScope ? FocusScope(child: list) : list),
            separateScope ? FocusScope(child: field) : field,
          ],
        ),
      ),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester, 4);
  await tester.showKeyboard(find.byType(TextField));
  await tester.pump();
  expect(focus.hasFocus, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
  return focus;
}

ScrollPosition listPosition(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;

void main() {
  setUpAll(loadTestFonts);

  for (final fluid in [false, true]) {
    testWidgets('chat code keeps its selection after horizontal scrolling, fluid=$fluid', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(loading: false, items: [assistant(1, markdown)]),
        },
      );
      await tester.pumpWidget(
        testApp(
          AppMotionScope(
            fluid: fluid,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: false),
                child: const Scaffold(body: ChatList(sessionId: 's1', topInset: 24, bottomInset: 0)),
              ),
            ),
          ),
          overrides: harness.overrides,
        ),
      );
      await pumpFrames(tester, 4);
      expect(AppMotion.fluid(tester.element(find.byType(CodeBlock))), fluid);
      await selectThenScroll(tester, 'chat-fluid=$fluid');
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('select-text sheet keeps the same selection after horizontal scrolling', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showSelectTextSheet(context, markdown, markdown: true),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await selectThenScroll(tester, 'sheet');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('dragging the message list still dismisses its input keyboard', (tester) async {
    final focus = await focusedInput(tester);
    final position = listPosition(tester);
    final before = position.pixels;
    await tester.drag(find.byType(ChatList), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(before - 80));
    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('programmatic movement keeps the input keyboard open', (tester) async {
    final focus = await focusedInput(tester);
    final position = listPosition(tester);
    expect(position.pixels, greaterThan(position.minScrollExtent + 100));
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('dragging the message list leaves another focus scope alone', (tester) async {
    final focus = await focusedInput(tester, separateScope: true);
    final position = listPosition(tester);
    final before = position.pixels;
    await tester.drag(find.byType(ChatList), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(before - 80));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
