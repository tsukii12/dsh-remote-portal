// The dock in the chat screen: it sits in the composer column above the
// activity strip, and the list follows the column frame by frame while a bar
// rises, sinks or the checklist opens (no seam, no jump).

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/goal_dock_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/chat/dock/goal_bar.dart';
import 'package:dsh_app/ui/chat/dock/todo_bar.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';
import '../support/run_info_fixture.dart';
import 'support/goal_fakes.dart';

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

double _columnTop(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byType(Composer), matching: find.byType(SafeArea)).first).top;

/// 0 when the last row sits 8 above the composer column.
double _seam(WidgetTester tester) => _columnTop(tester) - 8 - _lastRowBottom(tester);

Future<FakeChatController> _open(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  // Bottom-seam assertions require overflowing content. Short transcripts
  // intentionally align at the top, including while dock bars change height.
  tester.view.physicalSize = const Size(780, 1200);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  final backend = FakeGoalBackend(canRead: false);
  addTearDown(backend.close);
  await tester.pumpWidget(
    testApp(const ChatScreen(), overrides: [...harness.overrides, goalBackendProvider.overrideWithValue(backend)]),
  );
  await pumpFrames(tester, 10);
  return harness.controllers['s1']!;
}

Future<void> _framesWithoutSeam(WidgetTester tester, {int frames = 24}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final p = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.position;
    expect(p.maxScrollExtent, greaterThan(p.minScrollExtent));
    expect(_seam(tester), moreOrLessEquals(0, epsilon: 0.5), reason: 'f$i');
  }
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  testWidgets('in the composer column: above the strip, same side edges', (tester) async {
    SharedPreferences.setMockInitialValues({DockFoldController.key: false});
    final running = runInfoState();
    await _open(
      tester,
      ChatState(
        items: running.items,
        running: true,
        loading: false,
        turns: running.turns,
        todos: running.todos,
        goal: goalOf(),
      ),
    );
    final todo = tester.getRect(find.byType(TodoBar));
    final goal = tester.getRect(find.byType(GoalBar));
    final strip = tester.getRect(find.byType(ActivityStrip));
    final composer = tester.getRect(find.byType(Composer));
    expect(todo.bottom, lessThan(goal.top));
    expect(goal.bottom, lessThan(strip.top));
    for (final r in [todo, goal, strip]) {
      expect(r.left, composer.left);
    }
    for (final r in [goal, strip]) {
      expect(r.right, composer.right);
    }
    // The top bar makes room for the fold button, which ends where the composer does.
    final fold = tester.getRect(find.byKey(const ValueKey('dock-fold')));
    expect(fold.top, todo.top);
    expect(fold.right, composer.right);
    expect(fold.left - todo.right, DockStackMetrics.accessoryGap);
    // The strip does not repeat the count the todo bar shows.
    expect(find.textContaining('进度 '), findsNothing);
    expect(_seam(tester), moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('folded: todo, goal and strip take one row, the strip shows the count, a tap spreads them', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final running = runInfoState();
    await _open(
      tester,
      ChatState(
        items: running.items,
        running: true,
        loading: false,
        turns: running.turns,
        todos: running.todos,
        goal: goalOf(),
      ),
    );
    final todo = tester.getRect(find.byType(TodoBar));
    final goal = tester.getRect(find.byType(GoalBar));
    final strip = tester.getRect(find.byType(ActivityStrip));
    final composer = tester.getRect(find.byType(Composer));
    expect(strip.top - goal.top, moreOrLessEquals(DockStackMetrics.peek, epsilon: 0.01));
    expect(goal.top - todo.top, moreOrLessEquals(DockStackMetrics.peek, epsilon: 0.01));
    expect(strip.left, composer.left);
    expect(strip.right, composer.right);
    // The todo bar is behind: the strip says the count instead.
    expect(find.textContaining('进度 '), findsOneWidget);
    expect(_seam(tester), moreOrLessEquals(0, epsilon: 0.5));

    await tester.tap(find.byType(ActivityStrip));
    await _framesWithoutSeam(tester);
    expect(tester.getRect(find.byType(TodoBar)).bottom, lessThan(tester.getRect(find.byType(GoalBar)).top));
    expect(tester.getRect(find.byType(GoalBar)).bottom, lessThan(tester.getRect(find.byType(ActivityStrip)).top));
    expect(find.textContaining('进度 '), findsNothing);
  });

  testWidgets('bars rising and sinking: the list follows every frame', (tester) async {
    final done = runInfoState(finished: true);
    final chat = await _open(tester, ChatState(items: done.items, loading: false, turns: done.turns));
    expect(find.byType(TodoBar), findsNothing);

    chat.emit(
      ChatState(
        items: done.items,
        loading: false,
        turns: done.turns,
        todos: const [TodoItem('找到重复提交的原因', 'completed'), TodoItem('补一个连点测试', 'pending')],
        goal: goalOf(),
      ),
    );
    await _framesWithoutSeam(tester);
    expect(find.byType(TodoBar), findsOneWidget);
    expect(find.byType(GoalBar), findsOneWidget);

    await tester.tap(find.byType(TodoBar));
    await _framesWithoutSeam(tester);

    chat.emit(ChatState(items: done.items, loading: false, turns: done.turns));
    await _framesWithoutSeam(tester);
    expect(find.byType(TodoBar), findsNothing);
    expect(find.byType(GoalBar), findsNothing);
  });

  tearDown(() => runClock = DateTime.now);
}
