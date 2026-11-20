// The dock above the composer: the todo bar (official input.dock#todo) and
// the goal bar (official ui-goal GoalBar) — what they say, the checklist that
// opens in place, when they come and go, and the goal actions end to end.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:dsh_app/ui/chat/dock/goal_bar.dart';
import 'package:dsh_app/ui/chat/dock/todo_bar.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';
import 'support/dock_harness.dart';
import 'support/goal_fakes.dart';

ChatState _state({List<TodoItem>? todos, GoalProjection? goal, bool running = true}) =>
    ChatState(loading: false, running: running, todos: todos, goal: goal);

double _dockHeight(WidgetTester tester) =>
    tester.getSize(find.byType(DockSlot).first).height + tester.getSize(find.byType(DockSlot).last).height;

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  group('todo bar', () {
    testWidgets('the count, what is being done, a thin progress line', (tester) async {
      await DockHarness(state: _state(todos: todosRunning)).pump(tester);
      expect(find.text('3/7 · 正在：跑测试'), findsOneWidget);
      final line = tester.widget<DockProgressLine>(find.byType(DockProgressLine));
      expect(line.fraction, closeTo(3 / 7, 1e-9));
      expect(find.byType(TodoDockRow), findsNothing, reason: 'folded');
    });

    testWidgets('a tap opens the checklist in place; another folds it', (tester) async {
      await DockHarness(state: _state(todos: todosRunning)).pump(tester);
      final folded = tester.getRect(find.byType(TodoBar));
      await tester.tap(find.text('3/7 · 正在：跑测试'));
      await pumpFrames(tester, 6);
      expect(find.byType(TodoDockRow), findsNWidgets(7));
      final open = tester.getRect(find.byType(TodoBar));
      expect(open.bottom, folded.bottom, reason: 'grows upward');
      expect(open.height, greaterThan(folded.height + 100));

      // Styled like the 进度 tab: done is faded, the current one is bold.
      final theme = Theme.of(tester.element(find.byType(TodoBar)));
      Text row(String text) => tester.widget<Text>(find.text(text));
      expect(row('给提交加锁').style!.color, isNot(theme.colorScheme.onSurface));
      expect(row('跑测试').style!.fontWeight, FontWeight.w600);
      expect(row('整理改动说明').style!.color, theme.colorScheme.onSurface);
      expect(find.byIcon(AppIcons.success), findsNWidgets(3));
      expect(find.byIcon(AppIcons.inProgress), findsOneWidget);
      expect(find.byIcon(AppIcons.pending), findsNWidgets(3));

      await tester.tap(find.text('3/7 · 正在：跑测试'));
      await pumpFrames(tester, 6);
      expect(find.byType(TodoDockRow), findsNothing);
      expect(tester.getRect(find.byType(TodoBar)), folded);
    });

    testWidgets('a long list scrolls inside the card, the current item in view', (tester) async {
      final long = [
        for (var i = 0; i < 18; i++) TodoItem('第 ${i + 1} 项', 'completed'),
        const TodoItem('正在做的这一项', 'in_progress'),
        for (var i = 0; i < 6; i++) TodoItem('之后的第 ${i + 1} 项', 'pending'),
      ];
      await DockHarness(state: _state(todos: long)).pump(tester);
      await tester.tap(find.byType(TodoBar));
      await pumpFrames(tester, 6);
      final card = tester.getRect(find.byType(TodoBar));
      expect(card.height, lessThanOrEqualTo(DockMetrics.height + TodoBar.maxList));
      final current = tester.getRect(find.text('正在做的这一项'));
      expect(current.top, greaterThan(card.top + DockMetrics.height));
      expect(current.bottom, lessThan(card.bottom));
      final scrollable = find.descendant(of: find.byType(TodoBar), matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      final start = position.pixels;
      await tester.drag(scrollable, const Offset(0, -100));
      await pumpFrames(tester);
      expect(position.pixels, greaterThan(start));
      final end = position.pixels;
      await tester.drag(scrollable, const Offset(0, 100));
      await pumpFrames(tester);
      expect(position.pixels, lessThan(end));
      expect(tester.getRect(find.byType(TodoBar)), card);
    });

    testWidgets('wrapped todos in the spread deck can be dragged to the last row and stay there', (tester) async {
      SharedPreferences.setMockInitialValues({DockFoldController.key: false});
      final long = [
        for (var i = 0; i < 20; i++)
          TodoItem('Item $i: verify the entire checklist can scroll', i == 0 ? 'in_progress' : 'pending'),
      ];
      await DockHarness(
        state: _state(todos: long, goal: goalOf()),
      ).pump(tester, deck: true, strip: true);
      await tester.tap(find.byType(TodoBar));
      await pumpFrames(tester);
      final scrollable = find.descendant(of: find.byType(TodoBar), matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      final card = tester.getRect(find.byType(TodoBar));
      expect(position.maxScrollExtent, greaterThan(0));
      final start = position.pixels;
      await tester.drag(scrollable, const Offset(0, -100));
      await pumpFrames(tester);
      expect(position.pixels, greaterThan(start));
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -140));
        await pumpFrames(tester, 2);
      }
      // The activity strip or composer can relayout the whole deck while it runs.
      final deckLayout = find.byElementPredicate((e) => e is RenderObjectElement && e.renderObject is RenderDockStack);
      tester.renderObject<RenderDockStack>(deckLayout).markNeedsLayout();
      await pumpFrames(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      final viewport = tester.getRect(scrollable);
      final last = tester.getRect(find.text(long.last.content));
      expect(last.top, greaterThanOrEqualTo(viewport.top));
      expect(last.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.getRect(find.byType(TodoBar)), card);
      final end = position.pixels;
      await tester.drag(scrollable, const Offset(0, 100));
      await pumpFrames(tester);
      expect(position.pixels, lessThan(end));
      expect(tester.takeException(), isNull);
    });

    testWidgets('all done: stays after the turn ends', (tester) async {
      final h = DockHarness(state: _state(todos: todosDone));
      await h.pump(tester);
      expect(find.text('3/3 · 全部完成'), findsOneWidget);
      await h.emit(tester, _state(todos: todosDone, running: false));
      expect(find.text('3/3 · 全部完成'), findsOneWidget);
      expect(_dockHeight(tester), DockMetrics.height + DockMetrics.gap);
    });

    testWidgets('stopped short: the bar stays and says what comes next', (tester) async {
      final h = DockHarness(state: _state(todos: todosRunning));
      await h.pump(tester);
      await h.emit(tester, _state(todos: todosRunning, running: false));
      expect(find.text('3/7 · 下一步：跑测试'), findsOneWidget);
    });

    testWidgets('a new turn clears the list: the bar sinks; a new list rises', (tester) async {
      final h = DockHarness(state: _state(todos: todosRunning));
      await h.pump(tester);
      final shown = _dockHeight(tester);
      expect(shown, DockMetrics.height + DockMetrics.gap);

      h.chat.emit(_state());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final sinking = _dockHeight(tester);
      expect(sinking, inExclusiveRange(0, shown));
      expect(find.text('3/7 · 正在：跑测试'), findsOneWidget, reason: 'kept while sinking');
      await pumpFrames(tester, 4);
      expect(_dockHeight(tester), 0);

      await h.emit(tester, _state(todos: const [TodoItem('读代码', 'in_progress')]));
      expect(find.text('0/1 · 正在：读代码'), findsOneWidget);
      expect(_dockHeight(tester), shown);
    });

    testWidgets('reduced motion: in and out at once', (tester) async {
      final h = DockHarness(state: _state());
      await h.pump(tester, disableAnimations: true);
      h.chat.emit(_state(todos: todosRunning));
      await tester.pump();
      expect(_dockHeight(tester), DockMetrics.height + DockMetrics.gap);
      h.chat.emit(_state());
      await tester.pump();
      await tester.pump();
      expect(_dockHeight(tester), 0);
    });

    testWidgets('one button for screen readers, with its state', (tester) async {
      final semantics = tester.ensureSemantics();
      await DockHarness(state: _state(todos: todosRunning)).pump(tester);
      expect(tester.getSemantics(find.byType(TodoBar).first), isNot(isNull));
      expect(find.bySemanticsLabel('待办 3/7，正在：跑测试'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('goal bar', () {
    testWidgets('the objective on one line; the bar sits under the todo bar', (tester) async {
      await DockHarness(
        state: _state(
          todos: todosRunning,
          goal: goalOf(objective: '把登录迁到新接口\n然后补齐测试'),
        ),
      ).pump(tester);
      expect(find.text('目标'), findsOneWidget);
      expect(find.text('把登录迁到新接口'), findsOneWidget);
      expect(find.text('已暂停'), findsNothing);
      expect(tester.getRect(find.byType(GoalBar)).top, greaterThan(tester.getRect(find.byType(TodoBar)).bottom));
    });

    testWidgets('paused and blocked read at a glance', (tester) async {
      final h = DockHarness(
        state: _state(goal: goalOf(phase: GoalPhase.paused)),
      );
      await h.pump(tester);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.byIcon(AppIcons.paused), findsOneWidget);
      await h.emit(
        tester,
        _state(
          goal: goalOf(revision: 2, phase: GoalPhase.blocked, blocked: '需要你确认数据库'),
        ),
      );
      expect(find.text('受阻'), findsOneWidget);
      expect(find.byIcon(AppIcons.error), findsOneWidget);
    });

    testWidgets('tap → 暂停: the bar says so before the log does', (tester) async {
      final goal = goalOf(rounds: 3);
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final h = DockHarness(
        state: _state(goal: goal),
        backend: backend,
      );
      await h.pump(tester);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      expect(find.text('把登录迁到新接口，并补齐连点测试'), findsNWidgets(2));
      expect(find.text('进行中 · 第 3 / 256 轮'), findsOneWidget);
      expect(find.text('编辑目标'), findsOneWidget);
      expect(find.text('恢复'), findsNothing);
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['pause s1 goal-1@1']);
      expect(find.text('已暂停'), findsOneWidget);
    });

    testWidgets('a disarmed goal offers 恢复', (tester) async {
      final goal = goalOf();
      final backend = FakeGoalBackend()
        ..current = goal
        ..onRead = () => GoalView(projection: goal, activation: GoalActivation.disarmed);
      final h = DockHarness(
        state: _state(goal: goal),
        backend: backend,
      );
      await h.pump(tester);
      expect(find.text('已暂停'), findsOneWidget);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      expect(find.text('暂停'), findsNothing);
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'resume s1 goal-1@1');
      expect(find.text('已暂停'), findsNothing);
    });

    testWidgets('编辑: several lines kept; empty or unchanged cannot be saved', (tester) async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      await DockHarness(
        state: _state(goal: goal),
        backend: backend,
      ).pump(tester);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑目标'));
      await tester.pumpAndSettle();
      final field = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
      FilledButton save() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
      expect(save().onPressed, isNull, reason: 'unchanged');
      await tester.enterText(field, '   ');
      await tester.pump();
      expect(save().onPressed, isNull, reason: 'empty');
      await tester.enterText(field, '只迁移登录\n不动注册');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['edit s1 goal-1@1 只迁移登录\n不动注册']);
      expect(find.text('只迁移登录'), findsOneWidget, reason: 'first line on the bar');
    });

    testWidgets('清除 asks first; confirming takes the bar away', (tester) async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      await DockHarness(
        state: _state(goal: goal),
        backend: backend,
      ).pump(tester);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除目标'));
      await tester.pumpAndSettle();
      expect(find.text('清除目标？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(backend.calls, isEmpty);
      expect(find.byType(GoalBar), findsOneWidget);

      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除目标'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清除'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['clear s1 goal-1@1']);
      expect(find.byType(GoalBar), findsNothing);
    });

    testWidgets('a refusal is a short toast', (tester) async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)
        ..current = goal
        ..fail = const DshRemoteException(
          'GOAL_STALE_REVISION',
          'stale goal ref "goal-1" revision 1; current is "goal-1" revision 2',
        );
      await DockHarness(
        state: _state(goal: goal),
        backend: backend,
      ).pump(tester);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂停'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没能暂停：目标刚有变化，再试一次'), findsOneWidget);
      expect(find.text('已暂停'), findsNothing);
    });

    testWidgets('the sheet closes by itself when the goal goes away', (tester) async {
      final goal = goalOf();
      final h = DockHarness(state: _state(goal: goal));
      await h.pump(tester);
      await tester.tap(find.byType(GoalBar));
      await tester.pumpAndSettle();
      expect(find.text('编辑目标'), findsOneWidget);
      h.chat.emit(_state());
      await tester.pumpAndSettle();
      expect(find.text('编辑目标'), findsNothing);
    });
  });

  testWidgets('under a todo bar the strip leaves the count out', (tester) async {
    final activity = RunActivity(
      kind: ActivityKind.tool,
      title: '跑',
      detail: 'flutter test',
      detailIsCode: true,
      todoDone: 3,
      todoTotal: 5,
    );
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              ActivityStrip(activity: activity),
              ActivityStrip(activity: activity, todoProgress: false),
            ],
          ),
        ),
      ),
    );
    expect(find.text('进度 3/5'), findsOneWidget);
  });

  test('goalHeadline: the first non-empty line', () {
    expect(goalHeadline('\n  迁移登录 \n补测试'), '迁移登录');
    expect(goalHeadline('一行'), '一行');
  });
}
