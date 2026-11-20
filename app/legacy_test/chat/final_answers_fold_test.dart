import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/media/media_paths.dart';
import 'package:dsh_app/ui/chat/tool_view.dart' show ToolCardPlacement;
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

final _time = DateTime(2026, 11, 6);

TurnTrace _trace(int start, int end) => TurnTrace(
  turn: start,
  startSeq: start,
  start: _time,
  spans: const [],
  endSeq: end,
  end: _time.add(const Duration(seconds: 30)),
  endReason: const TurnEndReason('completed'),
);

List<String> _visibleText(List<ChatRow> rows) => [
  for (final row in rows.whereType<AssistantRow>())
    if (row.item.text.isNotEmpty) row.item.text,
];

void _expectUniqueKeys(List<ChatRow> rows) {
  final keys = [
    for (final row in rows) ...[row.key, if (row is TurnProcessRow) ...row.rows.map((r) => r.key)],
  ];
  expect(keys.toSet().length, keys.length);
}

void main() {
  test('all explicit final answers stay out; progress and thinking fold', () {
    final turn = _trace(0, 9);
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        assistant(2, 'Checking the source', reasoning: 'plan'),
        tool('read', 'read', {'file_path': 'example.dart'}),
        assistant(4, 'Full answer', reasoning: 'conclusion', isFinalAnswer: true, rowKey: 'm1.2'),
        assistant(5, 'Checking a late result'),
        assistant(7, 'Additional detail', reasoning: 'follow-up', isFinalAnswer: true, rowKey: 'm1.4'),
      ],
      turns: [turn],
      foldTurns: true,
    );
    expect(rows.map((r) => r.runtimeType), [UserRow, TurnProcessRow, AssistantRow, AssistantRow]);
    expect(_visibleText(rows), ['Full answer', 'Additional detail']);
    final answers = rows.whereType<AssistantRow>().toList();
    expect(answers.map((r) => r.key), ['m1.2', 'm1.4']);
    expect(answers.every((r) => r.item.isFinalAnswer && r.item.reasoning.isEmpty), isTrue);
    expect(answers.first.footnote, isNull);
    expect(answers.last.footnote, same(turn));
    expect(answers.last.showActions, isTrue);
    final process = rows.whereType<TurnProcessRow>().single;
    expect(process.messages, 2);
    expect(process.toolCalls, 1);
    expect(process.rows.whereType<AssistantRow>().map((r) => r.item.text).where((s) => s.isNotEmpty), [
      'Checking the source',
      'Checking a late result',
    ]);
    expect(process.rows.whereType<AssistantRow>().map((r) => r.item.reasoning).where((s) => s.isNotEmpty), [
      'plan',
      'conclusion',
      'follow-up',
    ]);
    _expectUniqueKeys(rows);
  });

  test('two final answers without process do not create an empty fold', () {
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        assistant(2, 'Full answer', isFinalAnswer: true),
        assistant(3, 'Additional detail', isFinalAnswer: true),
      ],
      turns: [_trace(0, 4)],
      foldTurns: true,
    );
    expect(rows.whereType<TurnProcessRow>(), isEmpty);
    expect(_visibleText(rows), ['Full answer', 'Additional detail']);
    expect((rows.last as AssistantRow).showActions, isTrue);
  });

  test('late progress, reasoning and tools cannot hide an explicit final', () {
    final turn = _trace(0, 8);
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        assistant(2, 'Full answer', isFinalAnswer: true),
        assistant(3, 'Checking a late result'),
        tool('read', 'read', {'file_path': 'example.dart'}),
        assistant(6, '', reasoning: 'late thinking'),
      ],
      turns: [turn],
      foldTurns: true,
    );
    expect(_visibleText(rows), ['Full answer']);
    expect(rows.whereType<TurnProcessRow>().single.messages, 1);
    expect(rows.whereType<TurnFootnoteRow>(), isEmpty);
    final answer = rows.whereType<AssistantRow>().single;
    expect(answer.showActions, isTrue);
    expect(answer.footnote, same(turn));
    _expectUniqueKeys(rows);
  });

  test('a lone trailing thinking pill still leaves the final answer visible', () {
    final turn = _trace(0, 4);
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        assistant(2, 'Full answer', isFinalAnswer: true),
        assistant(3, '', reasoning: 'late thinking'),
      ],
      turns: [turn],
      foldTurns: true,
    );
    expect(_visibleText(rows), ['Full answer']);
    expect(rows.whereType<AssistantRow>().first.footnote, same(turn));
  });

  test('legacy messages without final metadata keep the positional fallback', () {
    final rows = deriveRows(
      items: [user(1, 'question'), assistant(2, 'Working'), assistant(3, 'Answer')],
      turns: [_trace(0, 4)],
      foldTurns: true,
    );
    expect(_visibleText(rows), ['Answer']);
    final process = rows.whereType<TurnProcessRow>().single;
    expect(process.messages, 1);
    expect((process.rows.single as AssistantRow).item.text, 'Working');
  });

  test('final-answer selection never crosses a user steer or a turn boundary', () {
    final first = _trace(0, 8);
    final second = _trace(9, 13);
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        assistant(2, 'First answer', isFinalAnswer: true),
        user(3, 'follow-up'),
        assistant(4, 'Working'),
        assistant(6, 'Second answer', isFinalAnswer: true),
        assistant(7, 'Second addendum', isFinalAnswer: true),
        assistant(10, 'Background progress'),
        assistant(11, 'Background answer', isFinalAnswer: true),
      ],
      turns: [first, second],
      foldTurns: true,
    );
    expect(_visibleText(rows), ['First answer', 'Second answer', 'Second addendum', 'Background answer']);
    final answers = rows.whereType<AssistantRow>().toList();
    expect(answers.map((r) => r.footnote), [null, null, same(first), same(second)]);
    expect(rows.whereType<TurnProcessRow>().map((r) => r.trace), [same(first), same(second)]);
    _expectUniqueKeys(rows);
  });

  test('tool cards retain order and never receive the answer footnote', () {
    final turn = _trace(0, 5);
    ToolChatItem card(String id) => tool(
      id,
      'weather_card',
      {},
      meta: {
        'dsh-go/view': {
          'type': 'stack',
          'children': [
            {'type': 'text', 'text': id},
          ],
        },
      },
    );
    final rows = deriveRows(
      items: [
        user(1, 'question'),
        card('before'),
        assistant(2, 'Full answer', reasoning: 'first reasoning', isFinalAnswer: true),
        card('middle'),
        assistant(3, 'Additional detail', reasoning: 'second reasoning', isFinalAnswer: true),
        card('tail'),
        assistant(4, 'Late progress'),
      ],
      turns: [turn],
      foldTurns: true,
    );
    expect(rows.map((r) => r.runtimeType), [
      UserRow,
      TurnProcessRow,
      ToolCallRow,
      AssistantRow,
      ToolCallRow,
      AssistantRow,
      ToolCallRow,
    ]);
    expect(rows.whereType<ToolCallRow>().map((r) => r.item.callId), ['before', 'middle', 'tail']);
    expect(rows.whereType<ToolCallRow>().every((r) => r.card == ToolCardPlacement.cardOnly), isTrue);
    final answers = rows.whereType<AssistantRow>().toList();
    expect(answers.first.footnote, isNull);
    expect(answers.last.footnote, same(turn));
    expect(answers.last.showActions, isTrue);
    final process = rows.whereType<TurnProcessRow>().single;
    expect(process.toolCalls, 3);
    expect(process.messages, 1);
    expect(process.rows.whereType<ToolCallRow>().every((r) => r.card == ToolCardPlacement.rowOnly), isTrue);
    expect(answers.every((r) => r.item.reasoning.isEmpty && r.item.isFinalAnswer), isTrue);
  });

  testWidgets('completion leaves both formal replies visible after the process collapses', (tester) async {
    usePhoneView(tester);
    final items = <ChatItem>[
      user(1, 'question'),
      assistant(2, 'Checking'),
      assistant(3, 'Full answer', isFinalAnswer: true, rowKey: 'm1.2'),
      assistant(4, 'Additional detail', isFinalAnswer: true, rowKey: 'm1.3'),
    ];
    ChatState state(bool running) => ChatState(
      loading: false,
      running: running,
      items: items,
      turns: [if (running) TurnTrace(turn: 0, startSeq: 0, start: _time, spans: const []) else _trace(0, 5)],
    );
    final harness = ChatHarness(session: 's1', states: {'s1': state(true)});
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: ChatList(sessionId: 's1', topInset: 0, bottomInset: 0)),
        overrides: harness.overrides,
      ),
    );
    await pumpFrames(tester, 4);
    harness.controllers['s1']!.emit(state(false));
    await pumpFrames(tester, 30);
    expect(find.byType(TurnProcess), findsOneWidget);
    for (final text in ['Full answer', 'Additional detail']) {
      final reply = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == text);
      expect(reply, findsOneWidget);
      expect(tester.getSize(reply).height, greaterThan(0));
      expect(find.ancestor(of: reply, matching: find.byType(TurnProcess)), findsNothing);
    }
    expect(find.byWidgetPredicate((w) => w is AssistantMessage && w.item.text == 'Checking'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('text-only rendering copies retain final-answer metadata', () {
    final original = assistant(2, 'Answer with an image', isFinalAnswer: true);
    final visible = replyWithText(original, 'Answer');
    expect(visible.isFinalAnswer, isTrue);
    expect(visible.key, original.key);
  });

  test('a late synthetic subagent result preserves both finals from wire events', () {
    final transcript = ChatTranscript();
    var seq = 0;
    void event(String type, Map<String, Object?> data) {
      transcript.apply(
        parseFollowFrame('synthetic', {
          'type': 'event',
          'event': {'type': type, 'seq': seq++, 'time': _time.millisecondsSinceEpoch, 'data': data},
        }),
      );
    }

    void message(int step, String text, String phase) {
      event('step/start', {'turn': 1, 'step': step});
      event('assistant/message', {
        'turn': 1,
        'step': step,
        'message': {
          'id': 'reply-$step',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {
            'kind': 'model',
            'provider': 'openai-codex',
            'model': 'synthetic-model',
            'replayState': {
              'response': {'kind': 'pi-ai', 'version': 2},
              'blocks': [
                {
                  'type': 'text',
                  'textSignature': jsonEncode({'v': 1, 'id': 'text-$step', 'phase': phase}),
                },
              ],
            },
          },
        },
      });
      event('step/end', {'turn': 1, 'step': step});
    }

    event('turn/start', {'turn': 1});
    event('user/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'question'},
      ],
      'source': {'kind': 'user'},
    });
    message(1, 'Checking', 'commentary');
    message(2, 'Full answer', 'final_answer');
    for (final kind in ['agent-message', 'subagent-settled']) {
      event('user/message', {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'synthetic late result'},
        ],
        'source': {'kind': kind},
      });
    }
    message(3, 'Additional detail', 'final_answer');
    event('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
    expect(transcript.items.whereType<UserChatItem>(), hasLength(1));
    expect(transcript.items.whereType<AssistantChatItem>().map((m) => m.isFinalAnswer), [false, true, true]);
    final rows = deriveRows(items: transcript.items, turns: transcript.turns, foldTurns: true);
    expect(_visibleText(rows), ['Full answer', 'Additional detail']);
    expect(rows.whereType<TurnProcessRow>().single.messages, 1);
    expect(rows.whereType<AssistantRow>().last.footnote, same(transcript.turns.single));
    _expectUniqueKeys(rows);
  });
}
