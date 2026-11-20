// The fluid tier's streaming: paced text, a thinking window in continuous motion, a list
// that glides after a growing reply, and nothing moving when a reply finishes.

import 'dart:math' as math;

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/stream_pacer.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/common/fluid_bits.dart';
import 'package:dsh_app/ui/common/streaming_cursor.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';

Widget fluidApp(Widget child, {bool fluid = true, List<dynamic> overrides = const []}) => testApp(
  AppMotionScope(fluid: fluid, child: child),
  overrides: overrides.cast(),
);

Widget reply(AssistantChatItem item, {bool fluid = true}) => fluidApp(
  Scaffold(
    body: ListView(
      padding: EdgeInsets.zero,
      children: [AssistantMessage(item: item)],
    ),
  ),
  fluid: fluid,
);

ChatState chat(List<ChatItem> items) => ChatState(items: items, title: '测试', loading: false);

String lines(int n) => [for (var i = 0; i < n; i++) '这是第 $i 段正文，写得长一点长一点长一点长一点长一点长一点。'].join('\n\n');

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  group('StreamPacer', () {
    test('what was already there does not count as arriving fast', () {
      final pacer = StreamPacer(shown: 1000);
      pacer.advance(1 / 60, 1000);
      pacer.advance(1 / 60, 1030);
      expect(pacer.shown, lessThan(1010));
    });

    test('lumps come out as an even flow', () {
      final pacer = StreamPacer();
      const frame = 1 / 60;
      var arrived = 0;
      final steps = <int>[];
      for (var i = 0; i < 600; i++) {
        // 40 characters every 20 frames: a lumpy 120 characters a second.
        if (i % 20 == 0) arrived += 40;
        final before = pacer.shown;
        pacer.advance(frame, arrived);
        if (i > 120) steps.add(pacer.shown - before);
      }
      // Without pacing one frame in 20 would carry all 40, the rest none.
      expect(steps.reduce(math.max), lessThan(12));
      expect(steps.where((s) => s == 0).length, lessThan(steps.length ~/ 2));
    });

    test('never trails far, however fast the text comes', () {
      final pacer = StreamPacer();
      var arrived = 0;
      for (var i = 0; i < 300; i++) {
        arrived += 50; // 3000 characters a second
        pacer.advance(1 / 60, arrived);
        if (i > 60) expect(arrived - pacer.shown, lessThan(3000 * StreamPacer.maxLag * 1.2));
      }
    });

    test('catches up after the text stops and never passes it', () {
      final pacer = StreamPacer();
      pacer.advance(0.016, 500);
      for (var i = 0; i < 120; i++) {
        pacer.advance(1 / 60, 500);
      }
      expect(pacer.shown, 500);
      expect(pacer.caughtUp(500), isTrue);
      pacer.advance(1 / 60, 300);
      expect(pacer.shown, 300, reason: 'text that was replaced by less');
    });

    test('reset starts over from there', () {
      final pacer = StreamPacer(shown: 100)..reset(10);
      expect(pacer.shown, 10);
    });
  });

  group('fluidTickerText', () {
    test('short text is what the plain window shows', () {
      for (final text in ['', '想一想', '**粗**\n\n\n下一段']) {
        expect(fluidTickerText(text), thinkingTickerText(text));
      }
    });

    test('a long thought keeps its start between steps, so its lines keep their wrapping', () {
      final long = '这是思考的一段内容，长长的。\n' * 400;
      expect(long.length, greaterThan(4000));
      var changes = 0;
      var previous = fluidTickerText(long);
      for (var i = 1; i < 300; i++) {
        final next = fluidTickerText('$long${'字' * i}');
        if (!next.startsWith(previous.substring(0, 40))) changes++;
        previous = next;
      }
      // The plain window moves its start on every character.
      expect(changes, lessThan(3));
    });

    test('always holds the newest text', () {
      final long = '${'一' * 5000}最新的字';
      expect(fluidTickerText(long), endsWith('最新的字'));
      expect(fluidTickerText(long).length, lessThan(2700));
    });
  });

  group('the reveal', () {
    final samples = {
      'paragraphs': '第一段正文。\n\n第二段正文写长一点写长一点写长一点写长一点写长一点写长一点写长一点。\n\n第三段。',
      'heading': '开头。\n\n## 标题\n\n后面。',
      'lists': '开头。\n\n- 一\n- 二\n\n1. 甲\n2. 乙\n\n后面。',
      'code': '开头。\n\n```dart\nvoid main() {}\n```\n\n后面。',
      'quote': '开头。\n\n> 引用\n\n后面。',
      'table': '开头。\n\n| 甲 | 乙 |\n|---|---|\n| 1 | 2 |\n\n后面。',
    };

    for (final MapEntry(key: name, value: text) in samples.entries) {
      testWidgets('nothing moves when a reply finishes: $name', (tester) async {
        usePhoneView(tester);
        Widget body(bool streaming, {bool reveal = true}) => fluidApp(
          Scaffold(
            body: SingleChildScrollView(
              child: MarkdownBody(
                key: const Key('b'),
                text: text,
                streaming: streaming,
                reveal: reveal,
                selectable: false,
              ),
            ),
          ),
        );
        await tester.pumpWidget(body(false, reveal: false));
        final plain = tester.getSize(find.byKey(const Key('b'))).height;
        await tester.pumpWidget(const SizedBox());

        await tester.pumpWidget(body(true));
        await tester.pump(const Duration(seconds: 2));
        final streaming = tester.getSize(find.byKey(const Key('b'))).height;
        await tester.pumpWidget(body(false));
        await tester.pumpAndSettle();
        final finished = tester.getSize(find.byKey(const Key('b'))).height;
        expect(streaming, moreOrLessEquals(plain, epsilon: 0.5));
        expect(finished, moreOrLessEquals(plain, epsilon: 0.5));
      });
    }

    testWidgets('a table keeps its columns when the reply finishes', (tester) async {
      usePhoneView(tester);
      const text = '开头。\n\n| Alpha Header | Beta | Gamma Header |\n|---|---|---|\n| 1 | 2 | 3 |\n\n后面。';
      Widget body(bool streaming) => fluidApp(
        Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(text: text, streaming: streaming, reveal: true, selectable: false),
          ),
        ),
      );
      await tester.pumpWidget(body(true));
      await tester.pump(const Duration(seconds: 2));
      final streaming = tester.getSize(find.byType(Table).first);
      await tester.pumpWidget(body(false));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Table).first), streaming);
    });

    testWidgets('the state of a reply survives its end, and it has no cursor', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(reply(assistant(2, '', rowKey: 'm', streaming: true)));
      final state = tester.state(find.byType(AssistantMessage));
      await tester.pumpWidget(reply(assistant(2, '第一段', rowKey: 'm', streaming: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).reveal, isTrue);
      expect(find.byType(StreamingCursor), findsNothing);
      await tester.pumpWidget(reply(assistant(2, '第一段', rowKey: 'm')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(AssistantMessage)), same(state));
      expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).reveal, isTrue);
    });

    testWidgets('a reply mounted halfway shows what is there instead of retyping it', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(reply(assistant(2, lines(3), rowKey: 'm', streaming: true)));
      expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).reveal, isFalse);
    });

    testWidgets('the standard tier keeps its cursor and no reveal', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(reply(assistant(2, '', rowKey: 'm', streaming: true), fluid: false));
      await tester.pumpWidget(reply(assistant(2, '第一段', rowKey: 'm', streaming: true), fluid: false));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).reveal, isFalse);
      expect(find.byType(StreamingCursor), findsOneWidget);
    });

    testWidgets('a long pause gets a quiet dot, new text puts it away', (tester) async {
      usePhoneView(tester);
      Finder dot() => find.byWidgetPredicate((w) => w is AnimatedOpacity && w.child is RepaintBoundary);
      await tester.pumpWidget(reply(assistant(2, '', rowKey: 'm', streaming: true)));
      await tester.pumpWidget(reply(assistant(2, '第一段', rowKey: 'm', streaming: true)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<AnimatedOpacity>(dot()).opacity, 0);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(dot()).opacity, 1);
      await tester.pumpWidget(reply(assistant(2, '第一段接着写', rowKey: 'm', streaming: true)));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(dot()).opacity, 0);
      await tester.pumpWidget(reply(assistant(2, '第一段接着写', rowKey: 'm')));
      await tester.pumpAndSettle();
      expect(dot(), findsNothing);
    });
  });

  group('the thinking window', () {
    Widget window(String text, {bool fluid = true}) => fluidApp(
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, child: ThinkingTicker(text: text)),
        ),
      ),
      fluid: fluid,
    );

    /// The top of the text: what the eye follows. A new line comes in below the window
    /// and only this rise brings it up, so a line landing at once would show here.
    double top(WidgetTester tester) => tester.getRect(find.byType(Text).first).top;

    testWidgets('keeps its height and rises in small steps, never a line at once', (tester) async {
      usePhoneView(tester);
      var text = '开始想这个问题，接着往下想一点内容。' * 20;
      await tester.pumpWidget(window(text));
      final height = tester.getSize(find.byType(ThinkingTicker)).height;
      await tester.pump();
      var largest = 0.0;
      var last = top(tester);
      final line = height / ThinkingTicker.rows;
      var rises = 0;
      for (var i = 0; i < 400; i++) {
        if (i % 6 == 0) {
          text += '接着往下想一点内容，继续往下想。';
          await tester.pumpWidget(window(text));
        }
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSize(find.byType(ThinkingTicker)).height, height);
        final now = top(tester);
        final step = (now - last).abs();
        if (step > 0.01) rises++;
        if (step > largest) largest = step;
        last = now;
      }
      expect(rises, greaterThan(20), reason: 'it did move');
      expect(largest, lessThan(line * 0.5));
      await tester.pumpAndSettle();
    });

    testWidgets('a thought past the length limit does not jump either', (tester) async {
      usePhoneView(tester);
      var text = '这是思考的一段内容，长长的。\n' * 180;
      await tester.pumpWidget(window(text));
      await tester.pump();
      for (var i = 0; i < 300; i++) {
        if (i % 3 == 0) {
          text += '再多想一句话。\n';
          await tester.pumpWidget(window(text));
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('ends on the last word, even between publishes', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(window('开始'));
      await tester.pumpWidget(window('开始想完了'));
      await tester.pumpAndSettle();
      expect(find.text('开始想完了'), findsOneWidget);
    });

    testWidgets('a big lump rises instead of landing at once', (tester) async {
      usePhoneView(tester);
      // Inside the length limit, past which the head of the text is what moves.
      var text = '开始想这个问题，接着往下想一点内容。' * 5;
      await tester.pumpWidget(window(text));
      final line = tester.getSize(find.byType(ThinkingTicker)).height / ThinkingTicker.rows;
      await tester.pumpAndSettle();
      text += '一下子来了很多内容，一下子来了很多内容。' * 6;
      await tester.pumpWidget(window(text));
      var last = top(tester);
      var largest = 0.0;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = top(tester);
        largest = math.max(largest, (now - last).abs());
        last = now;
      }
      expect(largest, lessThan(line * 1.5));
      await tester.pumpAndSettle();
    });

    testWidgets('settles and stops its ticker when the text stops', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(window('一行'));
      await tester.pumpWidget(window('一行${'多写一些内容，' * 60}'));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the standard tier keeps the plain window', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(window('一行', fluid: false));
      expect(find.byType(AnimatedContainer), findsOneWidget);
    });
  });

  group('following', () {
    Future<ChatHarness> open(WidgetTester tester, {bool fluid = true, String text = ''}) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': chat([user(1, '问题'), assistant(2, '${lines(30)}$text', rowKey: 'm', streaming: true)]),
        },
      );
      await tester.pumpWidget(fluidApp(const ChatScreen(), overrides: harness.overrides, fluid: fluid));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return harness;
    }

    ScrollPosition position(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    void grow(ChatHarness harness, String more) {
      harness.controllers['s1']!.emit(
        chat([user(1, '问题'), assistant(2, '${lines(30)}$more', rowKey: 'm', streaming: true)]),
      );
    }

    testWidgets('the header\'s title and status crossfade, the conversation fades in', (tester) async {
      await open(tester);
      final swaps = find.descendant(of: find.byType(ChatHeader), matching: find.byType(FluidTextSwap));
      expect(swaps, findsNWidgets(2));
      expect(find.byType(FluidFadeIn), findsOneWidget);
    });

    testWidgets('a new line is glided to, and it arrives', (tester) async {
      final harness = await open(tester);
      expect(position(tester).extentAfter, lessThan(1));
      grow(harness, '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      final behind = position(tester).extentAfter;
      expect(behind, greaterThan(1), reason: 'not snapped');
      var last = behind;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = position(tester).extentAfter;
        expect(now, lessThanOrEqualTo(last + 0.01), reason: 'only ever closing in');
        last = now;
      }
      expect(position(tester).extentAfter, lessThan(1));
    });

    testWidgets('the standard tier still lands in the same frame', (tester) async {
      final harness = await open(tester, fluid: false);
      grow(harness, '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段');
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(position(tester).extentAfter, lessThan(1));
    });

    testWidgets('a finger pulling back stops the following for good', (tester) async {
      final harness = await open(tester);
      grow(harness, '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段');
      await tester.pump(const Duration(milliseconds: 40));
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final parked = position(tester).pixels;
      grow(harness, '\n\n又来一段又来一段\n\n再来一段再来一段');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position(tester).pixels, parked);
    });

    // A reply growing every frame while the finger moves a little at a time: nothing
    // may take the drag away, in either tier.
    for (final fluid in [true, false]) {
      final tier = fluid ? 'fluid' : 'standard';

      testWidgets('$tier: a slow drag up takes hold while the reply grows', (tester) async {
        final harness = await open(tester, fluid: fluid);
        final gesture = await tester.startGesture(const Offset(200, 300));
        var more = '';
        for (var i = 0; i < 60; i++) {
          more += '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段';
          grow(harness, more);
          await gesture.moveBy(const Offset(0, 5));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(position(tester).extentAfter, greaterThan(200), reason: 'the list went with the finger');
        final held = position(tester).pixels;
        await gesture.up();
        for (var i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        grow(harness, '$more\n\n又来一段又来一段');
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(position(tester).pixels, lessThanOrEqualTo(held + 1), reason: 'and it stays where it was left');
      });

      testWidgets('$tier: a fling up runs its course while the reply grows', (tester) async {
        final harness = await open(tester, fluid: fluid);
        var more = '';
        await tester.fling(find.byType(Scrollable).first, const Offset(0, 120), 2000, warnIfMissed: false);
        for (var i = 0; i < 60; i++) {
          more += '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段';
          grow(harness, more);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(position(tester).extentAfter, greaterThan(300), reason: 'the fling carried');
      });

      testWidgets('$tier: a resting finger holds the list, and letting go catches up', (tester) async {
        final harness = await open(tester, fluid: fluid);
        final gesture = await tester.startGesture(const Offset(200, 300));
        await tester.pump(const Duration(milliseconds: 16));
        final before = position(tester).pixels;
        var more = '';
        for (var i = 0; i < 20; i++) {
          more += '\n\n新的一段新的一段新的一段新的一段';
          grow(harness, more);
          await tester.pump(const Duration(milliseconds: 16));
          expect(position(tester).pixels, before, reason: 'not moving under the finger');
        }
        await gesture.up();
        for (var i = 0; i < 90; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(position(tester).extentAfter, lessThan(1));
      });

      testWidgets('$tier: dragged back to the bottom, following resumes', (tester) async {
        final harness = await open(tester, fluid: fluid);
        final gesture = await tester.startGesture(const Offset(200, 300));
        for (var i = 0; i < 20; i++) {
          await gesture.moveBy(const Offset(0, 10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        for (var i = 0; i < 40; i++) {
          await gesture.moveBy(const Offset(0, -10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 500));
        grow(harness, '\n\n新的一段新的一段新的一段新的一段新的一段新的一段新的一段新的一段');
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(position(tester).extentAfter, lessThan(1));
      });
    }
  });

  group('tool rows', () {
    Widget row(ToolStatus status) => fluidApp(
      Scaffold(
        body: ToolRow(
          key: const ValueKey('t'),
          item: tool('t1', 'bash', {'command': 'ls'}, status: status),
          onRespond: (_, _) async {},
        ),
      ),
    );

    testWidgets('running is the quiet arc; finishing draws a check, then goes quiet', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(row(ToolStatus.running));
      expect(find.byType(QuietArc), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(row(ToolStatus.succeeded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DrawnCheck), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(DrawnCheck), findsNothing);
      expect(find.byType(QuietArc), findsNothing);
    });

    testWidgets('a row built finished stays quiet', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(row(ToolStatus.succeeded));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(DrawnCheck), findsNothing);
    });

    testWidgets('a failure shows its mark without a check first', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(row(ToolStatus.running));
      await tester.pumpWidget(row(ToolStatus.failed));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(DrawnCheck), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(QuietArc), findsNothing);
    });
  });
}
