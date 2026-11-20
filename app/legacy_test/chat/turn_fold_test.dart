// The whole-turn fold: which turns fold, what goes inside, where the answer,
// footnote and change card end up; plus the thinking preview rules. Over the
// timed fixture (support/run_info_fixture.dart), the captured cancel, and
// small synthetic transcripts for the edge cases.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/run_info_fixture.dart';
import 'support/sample_chat.dart';

final _t0 = DateTime(2026, 10, 23, 14, 30);

TurnTrace trace({
  required int startSeq,
  required int endSeq,
  String reason = 'completed',
  Duration took = const Duration(seconds: 42),
}) => TurnTrace(
  turn: startSeq,
  startSeq: startSeq,
  start: _t0,
  spans: const [],
  endSeq: endSeq,
  end: _t0.add(took),
  endReason: TurnEndReason(reason),
);

List<Type> types(List<ChatRow> rows) => [for (final r in rows) r.runtimeType];

void main() {
  group('the timed fixture', () {
    test('a finished turn folds its process; the answer stays out', () {
      final s = runInfoState(finished: true);
      final rows = deriveRows(items: s.items, turns: s.turns, foldTurns: true);
      expect(types(rows), [UserRow, TurnProcessRow, AssistantRow, ChangeCardRow]);

      final process = rows[1] as TurnProcessRow;
      final tools = s.items.whereType<ToolChatItem>().length;
      expect(process.toolCalls, tools);
      expect(process.trace, same(s.turns.single));
      expect(turnProcessLabel(process), startsWith('已完成 · $tools 次工具调用'));
      // Nothing is lost: every tool call is somewhere inside.
      final inside = [
        for (final r in process.rows)
          ...switch (r) {
            ToolCallRow(:final item) => [item.callId],
            ToolGroupRow(:final tools) => [for (final t in tools) t.callId],
            _ => const <String>[],
          },
      ];
      expect(inside, [for (final t in s.items.whereType<ToolChatItem>()) t.callId]);

      final answer = rows[2] as AssistantRow;
      final last = s.items.whereType<AssistantChatItem>().last;
      expect(answer.item.id, last.id);
      expect(answer.item.text, last.text);
      expect(answer.item.reasoning, isEmpty);
      expect(answer.showActions, isTrue);
      expect(answer.footnote, same(s.turns.single));
      if (last.reasoning.trim().isNotEmpty) {
        final thinking = process.rows.last as AssistantRow;
        expect(thinking.item.reasoning, last.reasoning);
        expect(thinking.item.text, isEmpty);
      }
    });

    test('off by default: the rows are what they always were', () {
      final s = runInfoState(finished: true);
      final rows = deriveRows(items: s.items, turns: s.turns);
      expect(rows.whereType<TurnProcessRow>(), isEmpty);
    });

    test('the running turn stays open; the finished one before it folds', () {
      final s = runInfoState();
      final rows = deriveRows(items: s.items, turns: s.turns, running: true, foldTurns: true);
      expect(rows.whereType<TurnProcessRow>(), hasLength(1));
      final second = rows.lastIndexWhere((r) => r is UserRow);
      expect(rows.indexWhere((r) => r is TurnProcessRow), lessThan(second));
      expect(rows.skip(second).whereType<ToolCallRow>(), isNotEmpty);
    });
  });

  test('a stopped turn stays open', () {
    final t = ChatTranscript();
    for (final line in File('../packages/dsh_client/test/fixtures/follow_cancel.jsonl').readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      t.apply(parseFollowFrame('s', jsonDecode(line)));
    }
    expect(t.turns.where((x) => !x.running), isNotEmpty);
    final rows = deriveRows(items: t.items, turns: t.turns, foldTurns: true);
    expect(rows.whereType<TurnProcessRow>(), isEmpty);
  });

  group('synthetic', () {
    test('a plain answer with its thinking does not fold', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          assistant(2, 'a', reasoning: 'hmm'),
        ],
        turns: [trace(startSeq: 1, endSeq: 3)],
        foldTurns: true,
      );
      expect(types(rows), [UserRow, AssistantRow]);
      expect((rows[1] as AssistantRow).item.reasoning, 'hmm');
    });

    test('interim messages count; tools after the last reply fold it too', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          assistant(2, '先看看', reasoning: 'r1'),
          tool('a', 'bash', {'command': 'ls'}),
          assistant(4, '', reasoning: 'r2'),
          tool('b', 'read', {'file_path': 'x'}),
        ],
        turns: [trace(startSeq: 1, endSeq: 6)],
        foldTurns: true,
      );
      expect(types(rows), [UserRow, TurnProcessRow, TurnFootnoteRow]);
      final process = rows[1] as TurnProcessRow;
      expect(process.toolCalls, 2);
      expect(process.messages, 1);
      expect(turnProcessLabel(process), '已完成 · 2 次工具调用 · 1 条消息');
      // The interim reply carries no actions inside the fold.
      expect(process.rows.whereType<AssistantRow>().every((r) => !r.showActions), isTrue);
    });

    // Steered turns and several turns between two user messages fold piece
    // by piece: see rows_fold_test.dart.

    test('a failed turn stays open', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          tool('a', 'bash', {'command': 'ls'}),
          assistant(3, 'partial'),
        ],
        turns: [trace(startSeq: 1, endSeq: 4, reason: 'error')],
        foldTurns: true,
      );
      expect(rows.whereType<TurnProcessRow>(), isEmpty);
    });
  });

  group('thinking preview', () {
    test('settled: the first line, without bold markers', () {
      expect(thinkingPreview('**看需求**\n用户想折叠工具调用'), '看需求');
    });

    test('the live window keeps the tail, without bold markers or blank runs', () {
      expect(thinkingTickerText('第一段\n**第二段**\n\n\n第三段\n正在写'), '第一段\n第二段\n第三段\n正在写');
      expect(thinkingTickerText('  先看看\n然后  '), '先看看\n然后');
    });
  });
}
