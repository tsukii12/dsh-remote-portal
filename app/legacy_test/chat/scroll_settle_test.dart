// The list settles without a jolt: frame by frame, the last row stays 8 above
// the composer column (no seam while the activity strip rises or sinks), and
// the reply / the sent bubble only ever move one way while a turn ends or a
// message is echoed (no "pushed up, then falls back").

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/run_info_fixture.dart';

double _lastRowBottom(WidgetTester tester) {
  final rows = find.descendant(
    of: find.byType(ChatList),
    matching: find.byWidgetPredicate((w) => w is KeyedSubtree && w.key is ValueKey<String>),
  );
  var bottom = double.negativeInfinity;
  for (final e in rows.evaluate()) {
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r.bottom > bottom) bottom = r.bottom;
  }
  return bottom;
}

/// Top of the composer column (strip, banners and composer).
double _columnTop(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byType(Composer), matching: find.byType(SafeArea)).first).top;

/// The seam between the last row and the column; 0 when it sits 8 above.
double _seam(WidgetTester tester) => _columnTop(tester) - 8 - _lastRowBottom(tester);

double _top(WidgetTester tester, Type type) => tester.getRect(find.byType(type).last).top;

Future<FakeChatController> _open(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  // Keep these bottom-seam checks in the scrollable regime. Short content
  // now aligns at the top; chat_top_boundary_test covers that contract.
  tester.view.physicalSize = const Size(780, 1200);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 10);
  return harness.controllers['s1']!;
}

/// Pumps [frames] frames, checking the seam and that [watch]'s top never
/// moves back the other way.
Future<void> _settle(WidgetTester tester, Type watch, {int frames = 30}) async {
  final tops = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final p = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;
    expect(p.maxScrollExtent, greaterThan(p.minScrollExtent));
    expect(_seam(tester), moreOrLessEquals(0, epsilon: 0.5), reason: 'f$i');
    tops.add(_top(tester, watch));
  }
  final up = tops.last <= tops.first;
  for (var i = 1; i < tops.length; i++) {
    final step = tops[i] - tops[i - 1];
    expect(up ? step : -step, lessThanOrEqualTo(0.5), reason: 'frame $i moved back: $tops');
  }
}

void main() {
  testWidgets('a turn ends: actions and cards ease in as the strip sinks', (tester) async {
    final chat = await _open(tester, const ChatState(loading: false));
    for (final seq in [6, 12, 20, 30, 38]) {
      final t = runInfoTranscript(throughSeq: seq);
      chat.emit(ChatState(items: t.items, running: true, loading: false, turns: t.turns));
      await pumpFrames(tester, 30);
    }
    final before = _top(tester, AssistantMessage);
    chat.emit(runInfoState(finished: true));
    await _settle(tester, AssistantMessage);
    // The reply's actions and the change card took room: it moved up.
    expect(_top(tester, AssistantMessage), lessThan(before));
  });

  testWidgets('a message is echoed: "发送中" folds as the strip rises', (tester) async {
    final done = runInfoState(finished: true);
    final chat = await _open(tester, done);
    chat.emit(
      ChatState(
        items: done.items,
        loading: false,
        turns: done.turns,
        pending: [PendingPrompt(requestId: 'r2', text: '再跑一遍测试', time: DateTime(2026))],
      ),
    );
    await _settle(tester, UserBubble, frames: 12);
    expect(find.text('发送中'), findsOneWidget);

    final echo = UserChatItem(
      seq: 100,
      time: DateTime(2026),
      text: '再跑一遍测试',
      images: const [],
      files: const [],
      requestId: 'r2',
    );
    chat.emit(
      ChatState(
        items: [...done.items, echo],
        loading: false,
        running: true,
        turns: [
          ...done.turns,
          TurnTrace(turn: 100, startSeq: 99, start: DateTime(2026), spans: const []),
        ],
      ),
    );
    await _settle(tester, UserBubble);
    expect(find.text('发送中'), findsNothing);
  });

  testWidgets('a quote unfolds above the composer and folds away', (tester) async {
    await _open(tester, runInfoState(finished: true));
    final quotes = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)))
        .read(composerQuoteProvider.notifier);
    double glass() => tester.getSize(find.byType(Composer)).height;

    // Either way the glass changes height over many frames, never in one
    // step; no seam opens above it and the reply moves one way.
    Future<void> change(void Function() edit) async {
      final heights = [glass()];
      edit();
      final tops = <double>[];
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final p = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;
        expect(p.maxScrollExtent, greaterThan(p.minScrollExtent));
        expect(_seam(tester), moreOrLessEquals(0, epsilon: 0.5), reason: 'f$i');
        heights.add(glass());
        tops.add(_top(tester, AssistantMessage));
      }
      final total = heights.last - heights.first;
      expect(total.abs(), greaterThan(30));
      for (var i = 1; i < heights.length; i++) {
        final step = heights[i] - heights[i - 1];
        expect(step * total.sign, greaterThanOrEqualTo(-0.5), reason: '$heights');
        expect(step.abs(), lessThan(total.abs() / 3), reason: '$heights');
      }
      for (var i = 1; i < tops.length; i++) {
        final step = tops[i] - tops[i - 1];
        expect(step * total.sign, lessThanOrEqualTo(0.5), reason: '$tops');
      }
    }

    await change(() => quotes.set('s1', '超时重试多发了一次请求'));
    expect(find.text('超时重试多发了一次请求'), findsOneWidget);
    await change(() => quotes.clear('s1'));
    expect(find.text('超时重试多发了一次请求'), findsNothing);
  });
}
