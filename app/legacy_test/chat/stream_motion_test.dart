// New rows ease in (fade + rise 8) once, the first time they show; what was
// already there when the conversation opened never animates. Expanding a
// tool row keeps its detail mounted while it collapses again. The waiting dots
// hand over to whatever comes next by cross-fading on the same line.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/stream_motion.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/common/typing_indicator.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<void> _noRespond(ApprovalRequest r, ApprovalDecision d) async {}

/// The opacity painted over [finder], 1 when nothing fades it.
double _opacityOf(WidgetTester tester, Finder finder) {
  final fades = find.ancestor(of: finder, matching: find.byType(Opacity));
  var value = 1.0;
  for (final element in fades.evaluate()) {
    value *= (element.widget as Opacity).opacity;
  }
  return value;
}

ChatState _state(List<ChatItem> items) => ChatState(items: items, title: '测试', loading: false);

/// One reply alone in a list, as in the chat: full width, height unbounded.
Widget _reply(AssistantChatItem item, {bool reduced = false}) => testApp(
  Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Scaffold(
        body: ListView(
          padding: EdgeInsets.zero,
          children: [AssistantMessage(item: item)],
        ),
      ),
    ),
  ),
);

double _replyHeight(WidgetTester tester) => tester.getSize(find.byType(AssistantMessage)).height;

/// The cross-fade's opacity over [finder].
double _fadeOf(WidgetTester tester, Finder finder) =>
    tester.widget<FadeTransition>(find.ancestor(of: finder, matching: find.byType(FadeTransition)).first).opacity.value;

/// How far the hand-off still holds [finder] below its place.
double _riseOf(WidgetTester tester, Finder finder) => tester
    .widget<Transform>(find.ancestor(of: finder, matching: find.byType(Transform)).first)
    .transform
    .getTranslation()
    .y;

/// The largest height change between two 16 ms frames over [frames] frames.
Future<double> _largestStep(WidgetTester tester, int frames) async {
  var largest = 0.0;
  var last = _replyHeight(tester);
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final height = _replyHeight(tester);
    final step = (height - last).abs();
    if (step > largest) largest = step;
    last = height;
  }
  return largest;
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  testWidgets('a new reply fades in once; the history does not', (tester) async {
    final first = [user(1, '第一个问题'), assistant(2, '第一个回答')];
    final harness = ChatHarness(session: 's1', states: {'s1': _state(first)});
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    // Opened with these rows: already in place, no fade.
    expect(_opacityOf(tester, find.text('第一个回答')), 1);

    harness.controllers['s1']!.emit(_state([...first, user(3, '第二个问题'), assistant(4, '第二个回答')]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final early = _opacityOf(tester, find.text('第二个回答'));
    expect(early, lessThan(1));
    expect(_opacityOf(tester, find.text('第一个回答')), 1);

    await tester.pump(const Duration(milliseconds: 400));
    expect(_opacityOf(tester, find.text('第二个回答')), 1);
  });

  testWidgets('committing a reply preserves its state and folds the expanded thinking', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([user(1, '问题'), assistant(2, '回答', rowKey: 'm1.1', streaming: true, reasoning: '完整思考')]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    await tester.tap(find.byType(ThinkingPill));
    await pumpFrames(tester, 10);
    // 展开时只有全文,行内预览让位。
    expect(find.descendant(of: find.byType(ThinkingPill), matching: find.text('完整思考')), findsOneWidget);
    bool pillExpanded() => tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byType(ThinkingPill),
                matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.expanded != null),
              )
              .first,
        )
        .properties
        .expanded!;
    expect(pillExpanded(), isTrue);
    final state = tester.state(find.byType(AssistantMessage));
    harness.controllers['s1']!.emit(_state([user(1, '问题'), assistant(16, '回答', rowKey: 'm1.1', reasoning: '完整思考')]));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(find.byType(AssistantMessage)), same(state));
      expect(_opacityOf(tester, find.text('回答')), 1);
    }
    // 一轮结束:亲手展开的全文收回去,只剩一行预览。
    expect(pillExpanded(), isFalse);
  });

  testWidgets('adding a visual fence preserves the reply state', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([assistant(2, '回答', rowKey: 'm1.1', streaming: true)]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    final state = tester.state(find.byType(AssistantMessage));
    harness.controllers['s1']!.emit(_state([assistant(2, '回答\n\n```dsh-ui\n', rowKey: 'm1.1', streaming: true)]));
    await tester.pump();
    expect(tester.state(find.byType(AssistantMessage)), same(state));
  });

  testWidgets('reduced motion: new rows are simply there', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: StreamFadeIn(child: Text('第二个回答')),
        ),
      ),
    );
    expect(_opacityOf(tester, find.text('第二个回答')), 1);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('the dots cross-fade to the thinking row on the same line', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', streaming: true)));
    expect(_replyHeight(tester), StreamRow.minHeight);

    await tester.pumpWidget(_reply(assistant(2, '', reasoning: '先看一下', streaming: true)));
    final pill = tester.state(find.byType(ThinkingPill));
    expect(find.byType(TypingIndicator), findsOneWidget);
    expect(_replyHeight(tester), StreamRow.minHeight);
    await tester.pump();

    // Out: 90 ms, linear, in place. In: 160 ms on Grok's curve, rising 3.
    await tester.pump(const Duration(milliseconds: 45));
    final eased = const Cubic(0.23, 1, 0.32, 1).transform(45 / 160);
    expect(_fadeOf(tester, find.byType(TypingIndicator)), closeTo(0.5, 0.01));
    expect(_riseOf(tester, find.byType(TypingIndicator)), 0);
    expect(_fadeOf(tester, find.byType(ThinkingPill)), closeTo(eased, 0.01));
    expect(_riseOf(tester, find.byType(ThinkingPill)), closeTo(3 * (1 - eased), 0.02));

    await tester.pump(const Duration(milliseconds: 46));
    await tester.pump();
    expect(find.byType(TypingIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 70));
    expect(_fadeOf(tester, find.byType(ThinkingPill)), 1);
    expect(_riseOf(tester, find.byType(ThinkingPill)), 0);
    expect(tester.state(find.byType(ThinkingPill)), same(pill));
  });

  testWidgets('the three-line window grows in after the dots, not all in one frame', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', streaming: true)));
    await tester.pumpWidget(_reply(assistant(2, '', reasoning: '先看一下', streaming: true)));
    expect(await _largestStep(tester, 30), lessThan(13));
    expect(_replyHeight(tester), closeTo(StreamRow.minHeight + 13 * 1.3 * 3 + 12, 0.5));
    expect(find.byType(ThinkingTicker), findsOneWidget);
  });

  testWidgets('the dots hand over to shorter text without a step', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', streaming: true)));
    await tester.pumpWidget(_reply(assistant(2, '回答', streaming: true)));
    expect(_replyHeight(tester), StreamRow.minHeight);
    expect(await _largestStep(tester, 15), lessThan(2));
    expect(_replyHeight(tester), closeTo(16 * 1.65, 0.5));
    expect(find.byType(TypingIndicator), findsNothing);
  });

  testWidgets('the first text after thinking fades in once and grows in with its gap', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', reasoning: '先看一下', streaming: true)));
    await pumpFrames(tester);
    final pill = tester.state(find.byType(ThinkingPill));

    await tester.pumpWidget(_reply(assistant(2, '回答', reasoning: '先看一下', streaming: true)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final halfway = _opacityOf(tester, find.byType(MarkdownBody));
    expect(halfway, greaterThan(0));
    expect(halfway, lessThan(1));
    await tester.pump(const Duration(milliseconds: 101));
    expect(_opacityOf(tester, find.byType(MarkdownBody)), 1);

    // More text never fades again, and the gap under the row is where it was.
    await tester.pumpWidget(_reply(assistant(2, '回答接着写', reasoning: '先看一下', streaming: true)));
    await tester.pump();
    expect(_opacityOf(tester, find.byType(MarkdownBody)), 1);
    await pumpFrames(tester);
    expect(tester.state(find.byType(ThinkingPill)), same(pill));
    final gap = tester.getTopLeft(find.byType(MarkdownBody)).dy - tester.getBottomLeft(find.byType(ThinkingPill)).dy;
    expect(gap, 8);
  });

  testWidgets('the hand-over from thinking to text never pushes the list up by the new line', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', reasoning: '先看一下', streaming: true)));
    await pumpFrames(tester);
    final before = _replyHeight(tester);
    await tester.pumpWidget(_reply(assistant(2, '回答', reasoning: '先看一下', streaming: true)));
    expect((_replyHeight(tester) - before).abs(), lessThan(13), reason: 'the frame the text arrives on');
    expect(await _largestStep(tester, 30), lessThan(13));
  });

  testWidgets('a reply that never waited here carries no hand-off', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '回答', reasoning: '先看一下')));
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(_opacityOf(tester, find.byType(MarkdownBody)), 1);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('reduced motion: the hand-off and the first text are simply there', (tester) async {
    await tester.pumpWidget(_reply(assistant(2, '', streaming: true), reduced: true));
    await tester.pumpWidget(_reply(assistant(2, '', reasoning: '先看一下', streaming: true), reduced: true));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TypingIndicator), findsNothing);
    expect(_fadeOf(tester, find.byType(ThinkingPill)), 1);
    expect(_riseOf(tester, find.byType(ThinkingPill)), 0);
    expect(_replyHeight(tester), closeTo(StreamRow.minHeight + 13 * 1.3 * 3 + 12, 0.5));

    await tester.pumpWidget(_reply(assistant(2, '回答', reasoning: '先看一下', streaming: true), reduced: true));
    expect(_opacityOf(tester, find.byType(MarkdownBody)), 1);
  });

  testWidgets('after a tool row the dots take the thinking row\'s place exactly', (tester) async {
    usePhoneView(tester);
    final done = [
      user(1, '问题'),
      tool('b', 'bash', {'command': 'echo hi'}, result: 'hi'),
    ];
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([...done, assistant(3, '', rowKey: 'm1.1', streaming: true)]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    final before = tester.getTopLeft(find.byType(AssistantMessage)).dy;
    harness.controllers['s1']!.emit(
      _state([...done, assistant(3, '', rowKey: 'm1.1', streaming: true, reasoning: '嗯')]),
    );
    await tester.pump();
    expect(tester.getTopLeft(find.byType(AssistantMessage)).dy, before);
  });

  testWidgets('after a tool row the dots hand over to direct text without a step', (tester) async {
    usePhoneView(tester);
    final done = [
      user(1, '问题'),
      tool('b', 'bash', {'command': 'echo hi'}, result: 'hi'),
    ];
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([...done, assistant(3, '', rowKey: 'm1.1', streaming: true)]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    final before = tester.getTopLeft(find.byType(AssistantMessage)).dy;
    harness.controllers['s1']!.emit(_state([...done, assistant(3, '回答', rowKey: 'm1.1', streaming: true)]));
    await tester.pump();
    var last = tester.getTopLeft(find.byType(AssistantMessage)).dy;
    expect((last - before).abs(), lessThan(1), reason: 'the frame the text arrives on');
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = tester.getTopLeft(find.byType(AssistantMessage)).dy;
      expect((now - last).abs(), lessThan(3), reason: 'frame $i');
      last = now;
    }
    expect(last - before, closeTo(8, 0.01), reason: 'the usual gap once settled');
  });

  testWidgets('tool detail stays mounted while it collapses', (tester) async {
    usePhoneView(tester);
    final item = tool('b', 'bash', {'command': 'echo hi'}, result: 'hi');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ToolRow(item: item, onRespond: _noRespond),
        ),
      ),
    );
    expect(find.byType(ToolDetail), findsNothing);
    await tester.tap(find.text('运行'));
    await pumpFrames(tester, 4);
    expect(find.byType(ToolDetail), findsOneWidget);

    await tester.tap(find.text('运行'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-collapse: still there, shrinking.
    expect(find.byType(ToolDetail), findsOneWidget);
    await pumpFrames(tester, 4);
    expect(find.byType(ToolDetail), findsNothing);
  });
}
