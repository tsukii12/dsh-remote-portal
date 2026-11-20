// Plugin tool cards (`meta["dsh-go/view"]`) in the row model: a call with a
// card never hides in a tool group, and when a finished turn folds, its
// tool row goes inside while the card itself stays in the stream. Turns
// without a card (or with a card that cannot be drawn) fold like any other
// turn: same rows, same keys.

import 'dart:convert';

import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

final _t0 = DateTime(2026, 10, 25, 9);

TurnTrace _trace(int startSeq, int endSeq, {String reason = 'completed'}) => TurnTrace(
  turn: startSeq,
  startSeq: startSeq,
  start: _t0,
  spans: const [],
  endSeq: endSeq,
  end: _t0.add(const Duration(seconds: 30)),
  endReason: TurnEndReason(reason),
);

TurnTrace _running(int startSeq) => TurnTrace(turn: startSeq, startSeq: startSeq, start: _t0, spans: const []);

const _card = {
  'type': 'stack',
  'title': '东京 · 今天',
  'children': [
    {'type': 'metric', 'label': '最高', 'value': '21°'},
  ],
};

ToolChatItem _tool(int seq, String id, {Object? meta}) => ToolChatItem(
  callId: id,
  name: 'weather_card',
  arguments: jsonEncode({'city': id}),
  status: ToolStatus.succeeded,
  seq: seq,
  meta: meta,
);

ToolChatItem _carded(int seq, String id) => _tool(seq, id, meta: {'dsh-go/view': _card});

/// Type, key and card placement of every row, folds opened up.
List<String> _shape(List<ChatRow> rows) => [
  for (final row in rows) ...[
    switch (row) {
      ToolCallRow(:final card) => '${row.runtimeType} ${row.key} ${card.name}',
      _ => '${row.runtimeType} ${row.key}',
    },
    if (row is TurnProcessRow) ...[
      for (final inner in row.rows)
        switch (inner) {
          ToolCallRow(:final card) => '  ${inner.key} ${card.name}',
          ToolGroupRow(:final tools) => '  ${inner.key} [${tools.map((t) => t.callId).join(',')}]',
          _ => '  ${inner.runtimeType} ${inner.key}',
        },
    ],
    if (row is ToolGroupRow) '  [${row.tools.map((t) => t.callId).join(',')}] live=${row.live}',
  ],
];

void main() {
  test('only a drawable card counts', () {
    expect(hasToolCard(_carded(1, 'x')), isTrue);
    expect(hasToolCard(_tool(1, 'x')), isFalse);
    expect(
      hasToolCard(
        _tool(
          1,
          'x',
          meta: {
            'dsh-go/view': {'type': 'gauge'},
          },
        ),
      ),
      isFalse,
    );
    expect(hasToolCard(_tool(1, 'x', meta: {'diffs': []})), isFalse);
  });

  group('a finished turn folds', () {
    List<ChatItem> turn({required ToolChatItem middle}) => [
      user(1, '东京今天天气怎么样'),
      assistant(2, '', reasoning: '查一下'),
      _tool(2, 'a'),
      middle,
      assistant(5, '东京今天 21°。'),
    ];

    test('the tool row goes in, the card stays out, before the answer', () {
      final rows = deriveRows(
        items: turn(middle: _carded(3, 'w')),
        turns: [_trace(0, 6)],
        foldTurns: true,
      );
      expect(_shape(rows), [
        'UserRow u1',
        'TurnProcessRow tp0',
        '  AssistantRow a2',
        '  ta inline',
        '  tw rowOnly',
        'ToolCallRow tw cardOnly',
        'AssistantRow a5',
      ]);
      final process = rows[1] as TurnProcessRow;
      expect(process.toolCalls, 2);
      final answer = rows.last as AssistantRow;
      expect(answer.showActions, isTrue);
      expect(answer.footnote, isNotNull);
    });

    test('no card, or a card that cannot be drawn: exactly as before', () {
      List<String> shape(ToolChatItem middle) => _shape(
        deriveRows(
          items: turn(middle: middle),
          turns: [_trace(0, 6)],
          foldTurns: true,
        ),
      );
      final before = shape(_tool(3, 'w'));
      expect(before, [
        'UserRow u1',
        'TurnProcessRow tp0',
        '  AssistantRow a2',
        '  ta inline',
        '  tw inline',
        'AssistantRow a5',
      ]);
      expect(
        shape(
          _tool(
            3,
            'w',
            meta: {
              'dsh-go/view': {'type': 'gauge'},
            },
          ),
        ),
        before,
      );
      expect(shape(_tool(3, 'w', meta: {'dsh-go/view': 'x' * 9000})), before);
      expect(shape(_tool(3, 'w', meta: {'path': 'a.txt'})), before);
    });

    test('a failed turn stays open, card and all', () {
      final rows = deriveRows(
        items: turn(middle: _carded(3, 'w')),
        turns: [_trace(0, 6, reason: 'error')],
        foldTurns: true,
      );
      expect(rows.whereType<TurnProcessRow>(), isEmpty);
      expect(rows.whereType<ToolCallRow>().last.card, ToolCardPlacement.inline);
    });
  });

  test('steered: each piece keeps its own key and its own cards', () {
    // turn/start 0, the prompt 1, a steer at 6, turn/end 12.
    final rows = deriveRows(
      items: [
        user(1, '查东京和大阪'),
        assistant(2, '', reasoning: '先查东京'),
        _carded(2, 'tokyo'),
        _tool(4, 'note'),
        user(6, '再加上京都'),
        assistant(7, '', reasoning: '查京都和大阪'),
        _carded(7, 'kyoto'),
        _carded(8, 'osaka'),
        assistant(10, '三个城市都晴。'),
      ],
      turns: [_trace(0, 12)],
      foldTurns: true,
    );
    expect(_shape(rows), [
      'UserRow u1',
      'TurnProcessRow tp0@6',
      '  AssistantRow a2',
      '  ttokyo rowOnly',
      '  tnote inline',
      'ToolCallRow ttokyo cardOnly',
      'UserRow u6',
      'TurnProcessRow tp0',
      '  AssistantRow a7',
      '  tkyoto rowOnly',
      '  tosaka rowOnly',
      'ToolCallRow tkyoto cardOnly',
      'ToolCallRow tosaka cardOnly',
      'AssistantRow a10',
    ]);
  });

  group('tool groups', () {
    List<ChatItem> calls(Set<String> carded) => [
      user(1, 'q'),
      for (final (i, id) in ['a', 'b', 'c', 'w', 'd', 'e', 'f'].indexed)
        carded.contains(id) ? _carded(2 + i, id) : _tool(2 + i, id),
    ];

    test('a call with a card is never hidden in a group', () {
      final rows = deriveRows(items: calls({'w'}), turns: [_running(0)], running: true);
      expect(_shape(rows), [
        'UserRow u1',
        'ToolGroupRow gta',
        '  [a,b,c] live=false',
        'ToolCallRow tw inline',
        'ToolGroupRow gtd',
        '  [d,e,f] live=true',
      ]);
    });

    test('short runs around a card stay single rows', () {
      final rows = deriveRows(
        items: [user(1, 'q'), _tool(2, 'a'), _carded(3, 'w'), _tool(4, 'b'), _tool(5, 'c')],
        turns: [_running(0)],
        running: true,
      );
      expect(_shape(rows), [
        'UserRow u1',
        'ToolCallRow ta inline',
        'ToolCallRow tw inline',
        'ToolCallRow tb inline',
        'ToolCallRow tc inline',
      ]);
    });

    test('without a card: one group, as before', () {
      final rows = deriveRows(items: calls(const {}), turns: [_running(0)], running: true);
      expect(_shape(rows), ['UserRow u1', 'ToolGroupRow gta', '  [a,b,c,w,d,e,f] live=true']);
    });
  });
}
