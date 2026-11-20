// The dock is measured, not eyeballed: each bar is as tall as the activity
// strip, its two glyphs sit on the end caps' centres (mirrored), its text
// starts where the strip's does, all bars share the strip's and composer's
// side edges, and the gaps in the stack are equal. The open checklist lines
// up with its header.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/goal_bar.dart';
import 'package:dsh_app/ui/chat/dock/todo_bar.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/dock_harness.dart';
import 'support/goal_fakes.dart';

const _eps = 0.01;

Rect _glass(WidgetTester tester, Type bar) =>
    tester.getRect(find.descendant(of: find.byType(bar), matching: find.byType(GlassSurface)).first);

Future<void> _pumpFull(WidgetTester tester, {double textScale = 1}) => DockHarness(
  state: ChatState(loading: false, running: true, todos: todosRunning, goal: goalOf()),
).pump(tester, strip: true, textScale: textScale);

void main() {
  setUpAll(() async {
    await loadTestFonts();
  });
  setUp(() => runClock = () => dockNow);
  tearDown(() => runClock = DateTime.now);

  for (final scale in [1.0, 1.3]) {
    group('text ×$scale', () {
      testWidgets('bars: as tall as the strip, glyphs on the caps, mirrored', (tester) async {
        await _pumpFull(tester, textScale: scale);
        final strip = tester.getRect(find.byType(ActivityStrip));
        for (final (bar, lead) in [(TodoBar, AppIcons.todo), (GoalBar, AppIcons.goal)]) {
          final pill = _glass(tester, bar);
          expect(pill.height, moreOrLessEquals(strip.height, epsilon: _eps), reason: '$bar');
          final leading = tester.getCenter(find.byIcon(lead));
          final trailing = tester.getCenter(find.descendant(of: find.byType(bar), matching: find.byType(Icon)).last);
          final cap = pill.height / 2;
          // Each glyph on its cap's centre: as far from the side as from the
          // top and bottom.
          expect(leading.dx - pill.left, moreOrLessEquals(cap, epsilon: _eps), reason: '$bar');
          expect(pill.right - trailing.dx, moreOrLessEquals(cap, epsilon: _eps), reason: '$bar');
          expect(leading.dy, moreOrLessEquals(pill.center.dy, epsilon: _eps), reason: '$bar');
          expect(trailing.dy, moreOrLessEquals(pill.center.dy, epsilon: _eps), reason: '$bar');
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('text starts where the strip text does', (tester) async {
        await _pumpFull(tester, textScale: scale);
        final stripText = tester.getRect(find.text('跑')).left - tester.getRect(find.byType(ActivityStrip)).left;
        final todoText = tester.getRect(find.text('3/7 · 正在：跑测试')).left - _glass(tester, TodoBar).left;
        final goalText = tester.getRect(find.text('目标')).left - _glass(tester, GoalBar).left;
        expect(todoText, moreOrLessEquals(DockMetrics.textStart, epsilon: _eps));
        expect(goalText, moreOrLessEquals(DockMetrics.textStart, epsilon: _eps));
        expect(stripText, moreOrLessEquals(DockMetrics.textStart, epsilon: 0.5));
      });

      testWidgets('one column: same side edges, equal gaps', (tester) async {
        await _pumpFull(tester, textScale: scale);
        final todo = _glass(tester, TodoBar);
        final goal = _glass(tester, GoalBar);
        final strip = tester.getRect(find.byType(ActivityStrip));
        final composer = tester.getRect(find.byType(Composer));
        for (final r in [todo, goal, strip]) {
          expect(r.left, moreOrLessEquals(composer.left, epsilon: _eps));
          expect(r.right, moreOrLessEquals(composer.right, epsilon: _eps));
        }
        expect(composer.left, 12);
        expect(goal.top - todo.bottom, moreOrLessEquals(DockMetrics.gap, epsilon: _eps));
        expect(strip.top - goal.bottom, moreOrLessEquals(DockMetrics.gap, epsilon: _eps));
        expect(composer.top - strip.bottom, moreOrLessEquals(DockMetrics.gap, epsilon: _eps));
      });

      testWidgets('the open list lines up with its header', (tester) async {
        await _pumpFull(tester, textScale: scale);
        await tester.tap(find.byType(TodoBar));
        await pumpFrames(tester, 6);
        final header = tester.getCenter(find.byIcon(AppIcons.todo));
        final headerText = tester.getRect(find.text('3/7 · 正在：跑测试')).left;
        for (final row in tester.widgetList<TodoDockRow>(find.byType(TodoDockRow)).take(4)) {
          final glyph = tester.getCenter(find.descendant(of: find.byWidget(row), matching: find.byType(Icon)));
          final text = tester.getRect(find.text(row.todo.content));
          expect(glyph.dx, moreOrLessEquals(header.dx, epsilon: _eps));
          expect(text.left, moreOrLessEquals(headerText, epsilon: _eps));
          // The glyph centres on the first line of its text.
          final line =
              (tester.widget<Text>(find.text(row.todo.content)).style!.fontSize! * scale) *
              tester.widget<Text>(find.text(row.todo.content)).style!.height!;
          expect(glyph.dy, moreOrLessEquals(text.top + line / 2, epsilon: 0.5));
        }
        // The card keeps its side edges and grows upward only.
        final open = _glass(tester, TodoBar);
        final goal = _glass(tester, GoalBar);
        expect(goal.top - open.bottom, moreOrLessEquals(DockMetrics.gap, epsilon: _eps));
      });
    });
  }

  testWidgets('a narrow phone at large text: one line each, no overflow', (tester) async {
    await DockHarness(
      state: ChatState(
        loading: false,
        running: true,
        todos: const [...todosDone, TodoItem('把所有登录相关的接口迁移到新的认证服务并且补齐所有测试', 'in_progress')],
        goal: goalOf(objective: '把登录、注册和找回密码全部迁到新的认证服务，并且在迁移过程中保持旧接口可用'),
      ),
    ).pump(tester, textScale: 1.3, viewSize: const Size(360, 700));
    expect(tester.takeException(), isNull);
    expect(_glass(tester, TodoBar).height, _glass(tester, GoalBar).height);
  });
}
