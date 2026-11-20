// When the todo bar shows and what it says (official TodoDock: shown while
// the session's `todos` projection has items — a finished list stays after
// its turn ends, until the next turn starts and clears it).

import 'package:dsh_app/ui/chat/dock/todo_bar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _read = TodoItem('读代码', 'completed');
const _fix = TodoItem('给提交加锁', 'in_progress');
const _test = TodoItem('跑测试', 'pending');
const _docs = TodoItem('更新 README', 'pending');

void main() {
  test('no list, or an empty one: no bar', () {
    expect(TodoDockSummary.of(null, running: true), isNull);
    expect(TodoDockSummary.of(const [], running: true), isNull);
  });

  test('running: the count and what is being done', () {
    final s = TodoDockSummary.of(const [_read, _fix, _test, _docs], running: true)!;
    expect(s.count, '1/4');
    expect(s.label, '正在：给提交加锁');
    expect(s.fraction, 0.25);
    expect(s.current, _fix);
  });

  test('between items: the next pending one', () {
    final s = TodoDockSummary.of(const [_read, TodoItem('给提交加锁', 'completed'), _test], running: true)!;
    expect(s.count, '2/3');
    expect(s.label, '下一步：跑测试');
  });

  test('the turn stopped short: what comes next, the bar stays', () {
    final s = TodoDockSummary.of(const [_read, _fix, _test], running: false)!;
    expect(s.label, '下一步：给提交加锁');
  });

  test('all done: stays after the turn ends (the next turn clears it)', () {
    const done = [_read, TodoItem('给提交加锁', 'completed')];
    for (final running in [true, false]) {
      final s = TodoDockSummary.of(done, running: running)!;
      expect(s.count, '2/2');
      expect(s.label, '全部完成');
      expect(s.fraction, 1);
    }
  });

  test('equal lists are equal summaries (the dock rebuilds on change only)', () {
    final a = TodoDockSummary.of(const [_read, _fix], running: true);
    final b = TodoDockSummary.of([
      const TodoItem('读代码', 'completed'),
      const TodoItem('给提交加锁', 'in_progress'),
    ], running: true);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(TodoDockSummary.of(const [_read, _fix], running: false)));
    expect(a, isNot(TodoDockSummary.of(const [_read, TodoItem('给提交加锁', 'completed')], running: true)));
  });
}
