import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/widgets/command_result_text.dart';
import 'package:flutter_test/flutter_test.dart';

String? copy(String name, String text) => commandResultCopy(CommandNotice(id: 'c', name: name, text: text, done: true));

void main() {
  final cases = <(String, String, String)>[
    ('compact', 'Compacted 9 history items (~34000 tokens).', '已压缩 9 条历史记录（约 34K tokens）'),
    ('compact', 'No compactable history yet.', '还没有可压缩的内容'),
    ('compact', 'Compaction cancelled.', '已取消压缩'),
    (
      'compact',
      'Compaction is unavailable because this process has an active compaction, or the agent is not idle.',
      '正在忙，稍后再压缩',
    ),
    ('compact', 'Compaction finished, but the session could not be saved.', '已压缩，但没能保存'),
    ('compact', 'Usage: /compact (no arguments)', '/compact 不带参数'),
    (
      'compact',
      'The history selected for compaction changed before it could be replaced. The attempt is recorded in the session log.',
      '对话有变化，请再试一次',
    ),
    (
      'compact',
      'Compaction could not produce a useful summary. The attempt is recorded in the session log.',
      '没能完成压缩，请再试一次',
    ),
    (
      'compact',
      'Compaction did not finish cleanly; some session history may have changed. Inspect the current session state before retrying.',
      '压缩未完成，请查看对话',
    ),
    ('plan', 'Plan mode on. Use /plan off to leave.', '已进入计划模式'),
    ('plan', 'Entering plan mode (applies from the next step). Use /plan off to leave.', '下一步起进入计划模式'),
    ('plan', 'Plan mode off.', '已退出计划模式'),
    ('plan', 'Leaving plan mode (applies from the next step).', '下一步起退出计划模式'),
    ('plan', 'Plan mode entry cancelled.', '已取消进入计划模式'),
    ('plan', 'Plan mode is already inactive.', '当前未开启计划模式'),
    ('plan', 'Attachments cannot accompany /plan off.', '退出计划模式时不能附带文件'),
    ('permission', 'preset auto', '已切换为自动审查'),
    ('permission', 'preset read-only', '已切换为仅可查看'),
    ('permission', 'current preset workspace-write (available: read-only, workspace-write, auto)', '当前权限：工作区内修改'),
    ('permission', 'unknown preset "bad" (available: read-only, workspace-write)', '没有这个权限预设'),
    ('feedback', 'Feedback recorded for session s1\nAnonymous user: anonymous-123.', '反馈已提交'),
    ('feedback', 'Feedback text is required. Usage: /feedback <text>', '写上反馈内容再发送'),
    ('goal', 'No goal to clear.', '还没有目标'),
    ('goal', 'Goal cleared.', '已清除目标'),
    ('goal', 'No goal is currently set.\nUsage: /goal [<objective>|clear|edit <objective>|pause|resume]', '还没有目标'),
    (
      'goal',
      'Goal editing requires a replacement objective.\nUsage: /goal [<objective>|clear|edit <objective>|pause|resume]',
      '写上新的目标再发送',
    ),
    (
      'goal',
      'Attachments only accompany a goal objective: /goal <objective> or /goal edit <objective>.',
      '附件需要和目标一起发送',
    ),
    (
      'goal',
      'The goal command is not valid for the current state. Run /goal to view available commands.',
      '当前无法执行，请查看目标',
    ),
  ];
  for (final (name, text, expected) in cases) {
    test('$name: $text', () {
      expect(copy(name, text), expected);
      expect(copy(name, '$text extra'), isNull);
      expect(copy('plugin-command', text), isNull);
    });
  }
  test('goal state has at most three lines and preserves the objective', () {
    for (final phase in ['active', 'paused', 'blocked', 'complete']) {
      final raw =
          'Goal updated\nStatus: $phase\n${phase == 'blocked' ? 'Blocker: TOOL: waiting\n' : ''}'
          'Objective: 第一行\n第二行\nRounds: 2/10\nActivation: armed\n\n'
          'Commands: /goal edit <objective>, /goal pause, /goal clear';
      final result = copy('goal', raw)!;
      expect(result.split('\n'), hasLength(3));
      expect(result, contains('第一行 第二行'));
      expect(result, endsWith('第 2/10 轮'));
      expect(copy('goal', '$raw\nextra'), isNull);
    }
  });
  test('plugin alternatives and Chinese text are left alone', () {
    for (final name in ['compact', 'goal', 'plan', 'feedback', 'permission']) {
      expect(copy(name, '已完成'), isNull);
      expect(copy(name, 'Plugin says done.'), isNull);
    }
  });
}
