import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

final _time = DateTime(2026, 10, 23);
ChatState state({
  bool running = true,
  List<PendingPrompt> pending = const [],
  int steps = 15,
  bool longHistory = false,
  bool steering = false,
}) => ChatState(
  loading: false,
  running: running,
  pending: pending,
  items: [
    if (longHistory)
      user(0, List.generate(30, (i) => 'Earlier history paragraph $i remains above the current turn.').join('\n\n')),
    user(2, '问题'),
    for (var i = 0; i < steps; i++) ...[
      tool('t$i', 'bash', {'command': 'echo $i'}, result: '$i'),
      assistant(i + 3, '', reasoning: '思考 $i'),
    ],
    if (steering) user(50, '补充说明'),
    assistant(100, '最终回答', rowKey: 'm1.20'),
  ],
  turns: [
    TurnTrace(
      turn: 1,
      startSeq: 1,
      start: _time,
      spans: const [],
      endSeq: running ? null : 101,
      end: running ? null : _time.add(const Duration(seconds: 30)),
      endReason: running ? null : const TurnEndReason('completed'),
    ),
  ],
);

Future<ChatHarness> mount(WidgetTester tester, {bool reduced = false, int steps = 15, bool longHistory = false}) async {
  usePhoneView(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {'s1': state(steps: steps, longHistory: longHistory)},
  );
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: const ChatList(sessionId: 's1', topInset: 0, bottomInset: 0),
          ),
        ),
      ),
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester, 4);
  return harness;
}

ScrollPosition position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first)
    .position;

void main() {
  setUpAll(loadTestFonts);
  for (final fluid in [false, true]) {
    for (final steering in [false, true]) {
      for (final loadingFirst in [false, true]) {
        testWidgets(
          'opening an active turn preserves visible history on completion (fluid=$fluid, steering=$steering, loading=$loadingFirst)',
          (tester) async {
            usePhoneView(tester);
            final harness = ChatHarness(
              session: 's1',
              states: {'s1': loadingFirst ? const ChatState() : state(longHistory: true, steering: steering)},
            );
            await tester.pumpWidget(
              testApp(
                Scaffold(
                  body: AppMotionScope(
                    fluid: fluid,
                    child: const ChatList(sessionId: 's1', topInset: 24, bottomInset: 6),
                  ),
                ),
                overrides: harness.overrides,
              ),
            );
            if (loadingFirst) {
              harness.controllers['s1']!.emit(state(longHistory: true, steering: steering));
              await tester.pump();
            }
            final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == '最终回答');
            final viewport = tester.getRect(find.byType(ChatList));
            // Keeping the running turn after the center must not introduce an initial jump.
            expect(tester.getBottomRight(reply).dy, closeTo(viewport.bottom - 6 - AppSpace.sm, .5));
            final history = find.byKey(const ValueKey('u0'));
            for (var drag = 0; drag < 12; drag++) {
              await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
              await pumpFrames(tester, 35);
              if (history.evaluate().isNotEmpty && tester.getBottomRight(history).dy > viewport.bottom + 100) break;
            }
            final before = tester.getRect(history);
            expect(before.top, lessThan(viewport.top + 24));
            expect(
              before.bottom,
              greaterThan(viewport.bottom + 100),
              reason: 'The reader sees history; the changing current turn is below the whole viewport.',
            );
            harness.controllers['s1']!.emit(state(running: false, longHistory: true, steering: steering));
            await pumpFrames(tester, 12);
            expect(tester.getRect(history).top, closeTo(before.top, .5));
            expect(tester.takeException(), isNull);
            // Completion still folds immediately, and explicitly returning to the latest works.
            await tester.tap(find.byIcon(AppIcons.scrollToBottom));
            await pumpFrames(tester, 35);
            expect(position(tester).pixels, closeTo(position(tester).maxScrollExtent, .5));
            expect(find.byType(TurnProcess), findsOneWidget);
            expect(find.byType(ToolRow), findsNothing);
          },
        );
      }
    }
  }
  testWidgets('pinned completion collapses monotonically and keeps the reply bottom fixed', (tester) async {
    // Keep this original bottom-follow contract in the scrollable regime.
    final harness = await mount(tester, longHistory: true);
    final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == '最终回答');
    final bottom = tester.getBottomRight(reply).dy;
    harness.controllers['s1']!.emit(state(running: false, longHistory: true));
    await tester.pump();
    var previous = tester.getSize(find.byType(TurnProcess)).height;
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final height = tester.getSize(find.byType(TurnProcess)).height;
      expect(position(tester).maxScrollExtent, greaterThan(position(tester).minScrollExtent));
      expect(height, lessThanOrEqualTo(previous + 0.5));
      expect(tester.getBottomRight(reply).dy, closeTo(bottom, 0.5));
      expect(position(tester).pixels, closeTo(position(tester).maxScrollExtent, 0.5));
      previous = height;
    }
    expect(find.byType(ToolRow), findsNothing);
    expect(previous, 32);
    position(tester).jumpTo(position(tester).minScrollExtent);
    await tester.pump();
    position(tester).jumpTo(position(tester).maxScrollExtent);
    await tester.pump();
    expect(tester.getSize(find.byType(TurnProcess)).height, 32);
  });
  testWidgets('a minimal short turn follows its actual net growth without a handoff jump', (tester) async {
    final harness = await mount(tester, steps: 1);
    final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == '最终回答');
    final expectedTop = tester.getTopLeft(find.byType(ChatList)).dy + AppSpace.sm;
    final initialBottom = tester.getBottomRight(reply).dy;
    harness.controllers['s1']!.emit(state(running: false, steps: 1));
    await tester.pump();
    expect(tester.getBottomRight(reply).dy, closeTo(initialBottom, .5));
    var previousBottom = initialBottom;
    var previousFootprint = tester.getSize(find.byType(TurnProcess)).height + tester.getSize(reply).height;
    final initialFootprint = previousFootprint;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final p = position(tester);
      final bottom = tester.getBottomRight(reply).dy;
      final footprint = tester.getSize(find.byType(TurnProcess)).height + tester.getSize(reply).height;
      // Here the new summary and reply actions together are taller than the
      // old one-step process. A fixed first row must follow that net growth.
      expect(bottom, greaterThanOrEqualTo(previousBottom - .5), reason: 'frame $frame must not reverse');
      expect(bottom - previousBottom, closeTo(footprint - previousFootprint, .5), reason: 'frame $frame');
      expect(tester.getTopLeft(find.byKey(const ValueKey('u2'))).dy, closeTo(expectedTop, .5));
      expect(p.minScrollExtent, closeTo(p.maxScrollExtent, .01));
      expect(p.pixels, closeTo(p.minScrollExtent, .01));
      expect(tester.takeException(), isNull, reason: 'frame $frame');
      previousBottom = bottom;
      previousFootprint = footprint;
    }
    expect(previousFootprint, greaterThan(initialFootprint));
    expect(previousBottom - initialBottom, closeTo(previousFootprint - initialFootprint, .5));
    expect(tester.getSize(find.byType(TurnProcess)).height, 32);
    expect(find.byType(ToolRow), findsNothing);
  });
  for (final steps in [2, 15]) {
    testWidgets('completion keeps the top fixed once short, with continuous reply motion ($steps steps)', (
      tester,
    ) async {
      final harness = await mount(tester, steps: steps);
      final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == '最终回答');
      final anchoredBottom = tester.getBottomRight(reply).dy;
      final expectedTop = tester.getTopLeft(find.byType(ChatList)).dy + AppSpace.sm;
      harness.controllers['s1']!.emit(state(running: false, steps: steps));
      await tester.pump();
      var previousHeight = tester.getSize(find.byType(TurnProcess)).height;
      var previousBottom = tester.getBottomRight(reply).dy;
      expect(previousBottom, closeTo(anchoredBottom, .5), reason: 'The handoff must not insert a header-sized jump.');
      var previousFootprint = previousHeight + tester.getSize(reply).height;
      var previousShort = position(tester).maxScrollExtent - position(tester).minScrollExtent < .01;
      var longFrames = previousShort ? 0 : 1;
      var shortFrames = previousShort ? 1 : 0;
      final trace = <String>[];
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final p = position(tester);
        final height = tester.getSize(find.byType(TurnProcess)).height;
        final bottom = tester.getBottomRight(reply).dy;
        final short = p.maxScrollExtent - p.minScrollExtent < .01;
        final heightDelta = height - previousHeight;
        final footprint = height + tester.getSize(reply).height;
        final footprintDelta = footprint - previousFootprint;
        final bottomDelta = bottom - previousBottom;
        expect(heightDelta, lessThanOrEqualTo(.5), reason: 'frame $frame');
        expect(bottomDelta, lessThanOrEqualTo(.5), reason: 'frame $frame must not move back down');
        // Include the reply actions that grow during the same handoff. At the
        // boundary only the unconsumed part of the total reduction moves the
        // reply; it cannot jump farther than that reduction.
        expect(footprintDelta, lessThanOrEqualTo(.5));
        expect(bottomDelta, greaterThanOrEqualTo(footprintDelta - .5), reason: 'frame $frame has a jump');
        if (short) {
          shortFrames++;
          expect(tester.getTopLeft(find.byKey(const ValueKey('u2'))).dy, closeTo(expectedTop, .5));
          if (previousShort) expect(bottomDelta, closeTo(footprintDelta, .5), reason: 'frame $frame');
        } else {
          longFrames++;
          expect(bottom, closeTo(anchoredBottom, .5));
        }
        expect(p.pixels, closeTo(p.maxScrollExtent, .5));
        expect(tester.takeException(), isNull, reason: 'frame $frame');
        trace.add('$frame,${height.toStringAsFixed(3)},${bottom.toStringAsFixed(3)},$short');
        previousHeight = height;
        previousFootprint = footprint;
        previousBottom = bottom;
        previousShort = short;
      }
      debugPrint('P1b settle $steps: frame,height,replyBottom,short\n${trace.join('\n')}');
      expect(shortFrames, greaterThan(2));
      if (steps == 15) expect(longFrames, greaterThan(0));
      if (steps == 2) expect(longFrames, 0);
      expect(previousHeight, 32);
      expect(find.byType(ToolRow), findsNothing);
    });
  }
  testWidgets('a turn folds as soon as it ends, even while the list is scrolled up', (tester) async {
    final harness = await mount(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 450));
    await pumpFrames(tester, 5);
    expect(find.byType(ToolRow), findsWidgets);
    harness.controllers['s1']!.emit(state(running: false));
    await pumpFrames(tester, 10);
    position(tester).jumpTo(position(tester).maxScrollExtent);
    await pumpFrames(tester, 5);
    expect(find.byType(TurnProcess), findsOneWidget);
    expect(find.byType(ToolRow), findsNothing);
  });
  testWidgets('a tool detail opened during the turn closes when the turn folds', (tester) async {
    final harness = await mount(tester);
    final last = find.byWidgetPredicate((w) => w is ToolRow && w.item.callId == 't14');
    await tester.tap(find.descendant(of: last, matching: find.text('运行')));
    await pumpFrames(tester, 5);
    expect(find.byType(ToolDetail), findsOneWidget);
    harness.controllers['s1']!.emit(state(running: false));
    await pumpFrames(tester, 25);
    expect(find.byType(TurnProcess), findsOneWidget);
    expect(find.byType(ToolDetail), findsNothing);
  });
  testWidgets('reduced motion settles immediately without a residual animation', (tester) async {
    final harness = await mount(tester, reduced: true);
    harness.controllers['s1']!.emit(state(running: false));
    await tester.pump();
    expect(tester.getSize(find.byType(TurnProcess)).height, 32);
    expect(find.byType(ToolRow), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
