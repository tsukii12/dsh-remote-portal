// The dock above the composer (light + dark): every state of the todo and
// goal bars, the whole stack over the activity strip and the composer, and
// the goal sheet and its 清除 confirmation.
// Regenerate with
// `flutter test --update-goldens test/chat/dock/dock_golden_test.dart`.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/goal_dock_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/goal_bar.dart';
import 'package:dsh_app/ui/chat/dock/todo_bar.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/dock_harness.dart';
import 'support/goal_fakes.dart';

/// Chat text behind the glass, so the blur has something to show.
Widget _behind(BuildContext context) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
    child: Text(
      '登录按钮连点会重复提交，是因为提交期间没有禁用按钮，'
      '而且接口没有做幂等。先给提交加一把锁，再补一个连点测试。'
      '测试跑完之后，我会更新 README 里的运行说明。',
      style: theme.textTheme.bodyLarge,
    ),
  );
}

Future<void> _pumpStates(WidgetTester tester, Brightness brightness) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1500);
  addTearDown(tester.view.reset);
  TodoDockSummary todos(List<TodoItem> items, {bool running = true}) => TodoDockSummary.of(items, running: running)!;
  final bars = <Widget>[
    TodoBar(summary: todos(todosRunning)),
    TodoBar(summary: todos(todosDone)),
    TodoBar(summary: todos(todosRunning, running: false)),
    TodoBar(summary: todos(todosRunning), initiallyOpen: true),
    GoalBar(
      goal: DockGoal(projection: goalOf(), activation: GoalActivation.armed),
      onTap: () {},
    ),
    GoalBar(
      goal: DockGoal(projection: goalOf(phase: GoalPhase.paused)),
      onTap: () {},
    ),
    GoalBar(
      goal: DockGoal(projection: goalOf(), activation: GoalActivation.disarmed),
      onTap: () {},
    ),
    GoalBar(
      goal: DockGoal(
        projection: goalOf(phase: GoalPhase.blocked, blocked: '需要你确认数据库'),
      ),
      onTap: () {},
    ),
    GoalBar(
      goal: DockGoal(projection: goalOf(), busy: true),
      onTap: () {},
    ),
  ];
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Builder(
          builder: (context) => AppBackdrop(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 24),
              child: BackdropGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final bar in bars) Padding(padding: const EdgeInsets.only(bottom: 12), child: bar)],
                ),
              ),
            ),
          ),
        ),
      ),
      brightness: brightness,
    ),
  );
  await pumpFrames(tester, 4);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });
  setUp(() => runClock = () => dockNow);
  tearDown(() => runClock = DateTime.now);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    group('goldens ($suffix)', () {
      testWidgets('states', (tester) async {
        await _pumpStates(tester, brightness);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dock_states_$suffix.png'));
      });

      testWidgets('stack: todo, goal, strip, composer over the chat', (tester) async {
        await DockHarness(
          state: ChatState(loading: false, running: true, todos: todosRunning, goal: goalOf()),
        ).pump(
          tester,
          brightness: brightness,
          strip: true,
          above: Builder(builder: _behind),
        );
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dock_stack_$suffix.png'));
      });

      testWidgets('deck: todo, goal, strip folded into one row, then spread', (tester) async {
        final harness = DockHarness(
          state: ChatState(loading: false, running: true, todos: todosRunning, goal: goalOf()),
        );
        await harness.pump(tester, brightness: brightness, strip: true, deck: true, above: Builder(builder: _behind));
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dock_deck_folded_$suffix.png'));
        await tester.tap(find.byType(ActivityStrip));
        await pumpFrames(tester);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dock_deck_spread_$suffix.png'));
      });

      testWidgets('stack, checklist open', (tester) async {
        await DockHarness(
          state: ChatState(loading: false, running: true, todos: todosRunning, goal: goalOf()),
        ).pump(
          tester,
          brightness: brightness,
          strip: true,
          above: Builder(builder: _behind),
        );
        await tester.tap(find.byType(TodoBar));
        await pumpFrames(tester, 6);
        await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/dock_open_$suffix.png'));
      });

      testWidgets('goal sheet', (tester) async {
        await DockHarness(
          state: ChatState(loading: false, goal: goalOf(rounds: 3, objective: '把登录迁到新接口\n并补齐连点测试，旧接口保留到下个版本')),
        ).pump(tester, brightness: brightness);
        await tester.tap(find.byType(GoalBar));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dock_goal_sheet_$suffix.png'));
      });

      testWidgets('goal sheet, blocked', (tester) async {
        await DockHarness(
          state: ChatState(
            loading: false,
            goal: goalOf(phase: GoalPhase.blocked, rounds: 12, max: 12, blocked: '轮次用完了，提高上限后再继续'),
          ),
        ).pump(tester, brightness: brightness);
        await tester.tap(find.byType(GoalBar));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dock_goal_blocked_$suffix.png'));
      });

      testWidgets('清除 confirmation', (tester) async {
        await DockHarness(
          state: ChatState(loading: false, goal: goalOf(objective: '把登录迁到新接口，并补齐连点测试')),
        ).pump(tester, brightness: brightness);
        await tester.tap(find.byType(GoalBar));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清除目标'));
        await tester.pumpAndSettle();
        expect(find.text('清除目标？'), findsOneWidget);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dock_goal_clear_$suffix.png'));
      });
    });
  }

  test('bars are the strip height', () {
    expect(DockMetrics.height, 36);
    expect(DockMetrics.edge * 2 + DockMetrics.glyph, DockMetrics.height);
  });
}
