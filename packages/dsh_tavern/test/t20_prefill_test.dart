import 'dart:convert';

import 'package:dsh_tavern/src/prompt/deepseek_processing.dart';
import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

void main() {
  test('ordinary ST keeps content behavior and ignores the Claude prefill field', () {
    final result = _assemble(_preset(enabled: null, text: 'CLAUDE-ONLY'));
    expect(_wire(result), [
      {'role': 'user', 'content': 'H'},
    ]);
    final nativeTail = _assemble(
      _preset(enabled: null, text: 'CLAUDE-ONLY'),
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: 'OLD')],
    );
    expect(_wire(nativeTail).last, {'role': 'assistant', 'content': 'OLD', 'prefix': true});
  });

  test('disabled enhancement does not expand its extra prefill', () {
    var calls = 0;
    final result = _assemble(
      _preset(enabled: false, target: 'reasoning', text: '{{tick}}'),
      expand: (text, _) => text == '{{tick}}' ? 'P${++calls}' : text,
    );
    expect(calls, 0);
    expect(_wire(result), [
      {'role': 'user', 'content': 'H'},
    ]);
  });

  test('missing target preserves exact content including think tags', () {
    const text = ' <think>\nP</think>\nTAIL ';
    final result = _assemble(_preset(target: null, text: text));
    expect(_wire(result).last, {'role': 'assistant', 'content': text, 'prefix': true});
  });

  test('explicit reasoning target is present on the wire and charged to the budget', () {
    final result = _assemble(_preset(target: 'reasoning', text: 'THINK'));
    expect(_wire(result).last, {'role': 'assistant', 'content': '', 'reasoning_content': 'THINK', 'prefix': true});
    expect(result.beforePostProcessing.last.message['content'], 'THINK');
    expect(result.afterPostProcessing.last.tokens, 5);
    expect(result.remainingBudget, 2000 - 3 - 1 - 5);
    expect(result.afterPostProcessing.last.sources.single.id, 'assistant_prefill');
    expect(result.afterPostProcessing.last.sources.single.details['target'], 'reasoning');
  });

  test('thinking disabled keeps a reasoning-target template in content verbatim', () {
    const text = '<think>\nP';
    final result = _assemble(_preset(target: 'reasoning', text: text, settings: {'show_thoughts': false}));
    expect(_wire(result).last, {'role': 'assistant', 'content': text, 'prefix': true});
    expect(result.body['thinking'], {'type': 'disabled'});
  });

  test('generic connections retain content and report unsupported reasoning target', () {
    final result = _assemble(_preset(target: 'reasoning', text: 'P'), deepseek: false);
    expect(_wire(result).last, {'role': 'assistant', 'content': 'P'});
    expect(result.excluded.any((item) => item.reason == 'reasoning-prefill-unsupported'), isTrue);
    expect(result.afterPostProcessing.last.tokens, 1);
  });

  test('reasoning tail stays separate from existing assistant history and its tags', () {
    const old = '<think>OLD</think>\nANSWER';
    final result = _assemble(
      _preset(target: 'reasoning', text: 'NEW'),
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: old)],
    );
    expect(_wire(result), [
      {'role': 'assistant', 'content': old},
      {'role': 'assistant', 'content': '', 'reasoning_content': 'NEW', 'prefix': true},
    ]);
    expect(result.afterPostProcessing.first.sources.single.kind, 'history');
    expect(result.afterPostProcessing.last.sources.single.kind, 'preset');
  });

  test('only a final preset assistant is adopted when the extra field is empty', () {
    final preset = _preset(
      target: 'reasoning',
      text: '',
      prompts: const [
        {'identifier': 'ordered', 'role': 'assistant', 'content': 'ORDERED', 'system_prompt': false},
      ],
      order: const ['chatHistory', 'ordered'],
    );
    final result = _assemble(preset);
    expect(_wire(result).last, {'role': 'assistant', 'content': '', 'reasoning_content': 'ORDERED', 'prefix': true});
    expect(result.afterPostProcessing.last.sources.single.id, 'ordered');
  });

  test('a real trailing system prompt does not move an earlier assistant to the end', () {
    final result = _assemble(
      _preset(
        target: 'reasoning',
        text: '',
        prompts: const [
          {'identifier': 'ordered', 'role': 'assistant', 'content': 'ORDERED', 'system_prompt': false},
          {'identifier': 'end', 'role': 'system', 'content': 'END', 'system_prompt': false},
        ],
        order: const ['chatHistory', 'ordered', 'end'],
      ),
    );
    expect(_wire(result).map((message) => message['content']), ['H', 'ORDERED', 'END']);
    expect(_wire(result).last['role'], 'user');
    expect(_wire(result).any((message) => message.containsKey('reasoning_content')), isFalse);
    expect(result.excluded.any((item) => item.reason == 'no-preset-prefill-tail'), isTrue);
  });

  test('history-only final assistant keeps its native channel in enhanced mode', () {
    final result = _assemble(
      _preset(target: 'reasoning', text: ''),
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: 'HISTORY')],
    );
    expect(_wire(result).last, {'role': 'assistant', 'content': 'HISTORY', 'prefix': true});
    expect(result.excluded.any((item) => item.reason == 'no-preset-prefill-tail'), isTrue);
  });

  test('continue preserves original content and skips extra macros with an exclusion', () {
    var calls = 0;
    final result = _assemble(
      _preset(
        target: 'reasoning',
        text: '{{tick}}',
        settings: {'continue_prefill': true, 'continue_postfix': 'POSTFIX'},
      ),
      type: 'continue',
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: 'OLD')],
      expand: (text, _) => text == '{{tick}}' ? 'P${++calls}' : text,
    );
    expect(calls, 0);
    expect(_wire(result).last, {'role': 'assistant', 'content': 'OLD', 'prefix': true});
    expect(result.excluded.any((item) => item.reason == 'enhanced-prefill-continue'), isTrue);
  });

  test('continue nudge also skips the new preset prefill without moving history', () {
    final result = _assemble(
      _preset(
        target: 'reasoning',
        text: 'EXTRA',
        settings: {
          'continue_prefill': false,
          'continue_postfix': '~',
          'continue_nudge_prompt': 'NUDGE {{lastChatMessage}}',
        },
      ),
      type: 'continue',
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: 'OLD')],
    );
    expect(_wire(result).map((message) => message['content']), ['OLD', 'NUDGE OLD~']);
    expect(_wire(result).any((message) => message.containsKey('reasoning_content')), isFalse);
  });

  test('new reasoning fragment does not absorb the CCV3 content prefill', () {
    final result = _assemble(
      _preset(target: 'reasoning', text: 'P'),
      worldPrefill: const [PromptFragment('W', PromptSource('worldInfo', 'entry'))],
    );
    expect(_wire(result), [
      {'role': 'user', 'content': 'H'},
      {'role': 'assistant', 'content': 'W'},
      {'role': 'assistant', 'content': '', 'reasoning_content': 'P', 'prefix': true},
    ]);
    expect(result.afterPostProcessing[1].sources.single.kind, 'worldInfo');
  });

  test('prefill macros expand once across before/after/request inspection', () {
    var calls = 0;
    final result = _assemble(
      _preset(target: 'reasoning', text: '{{tick}}'),
      expand: (text, _) => text == '{{tick}}' ? 'P${++calls}' : text,
    );
    expect(calls, 1);
    expect(result.beforePostProcessing.last.message['content'], 'P1');
    expect(result.afterPostProcessing.last.message['reasoning_content'], 'P1');
    expect(_wire(result).last['reasoning_content'], 'P1');
    result.toJson();
    expect(calls, 1);
  });

  test('prefill emptiness uses JS whitespace and retains NEL exactly', () {
    const spaces = [
      0x09,
      0x0a,
      0x0b,
      0x0c,
      0x0d,
      0x20,
      0xa0,
      0x1680,
      0x2000,
      0x2001,
      0x2002,
      0x2003,
      0x2004,
      0x2005,
      0x2006,
      0x2007,
      0x2008,
      0x2009,
      0x200a,
      0x2028,
      0x2029,
      0x202f,
      0x205f,
      0x3000,
      0xfeff,
    ];
    for (final code in spaces) {
      final result = _assemble(_preset(text: String.fromCharCode(code)));
      expect(_wire(result), [
        {'role': 'user', 'content': 'H'},
      ], reason: '$code');
      expect(result.excluded.any((item) => item.reason == 'empty-prefill'), isTrue);
    }
    for (final text in ['\u0085', '\u00a0\u0085 ']) {
      final result = _assemble(_preset(text: text));
      expect(_wire(result).last, {'role': 'assistant', 'content': text, 'prefix': true});
    }
  });

  test('only the chosen reasoning prefix unwraps leading think/thinking tags', () {
    for (final (text, expected) in const <(String, String)>[
      ('plain', 'plain'),
      ('<think>\nP', 'P'),
      ('<THINKING >\r\nP</ thinking>\nTAIL', 'P\nTAIL'),
      (' \t< think > P</think>TAIL', 'P\nTAIL'),
      ('answer <think>literal', 'answer <think>literal'),
      ('\u0085<think>P', '\u0085<think>P'),
    ]) {
      final result = _assemble(_preset(target: 'reasoning', text: text));
      expect(_wire(result).last['content'], '');
      expect(_wire(result).last['reasoning_content'], expected, reason: text);
      expect(result.afterPostProcessing.last.tokens, expected.length);
    }
  });

  test('large unmounted tool definitions cannot overflow a narrow enhanced turn', () {
    final tools = _largeTools();
    final result = _assemble(
      _preset(target: 'reasoning', settings: {'openai_max_context': 6}),
      tools: tools,
    );
    expect(_wire(result).last['reasoning_content'], 'P');
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.body.containsKey('tool_choice'), isFalse);
    expect(result.remainingBudget, 1);
    expect(result.excluded.any((item) => item.reason == 'prefill-mode-tools'), isTrue);
    expect(tools.single['function'], containsPair('description', List<String>.filled(10000, 'x').join()));
    expect(
      () => _assemble(_preset(enabled: null, settings: {'openai_max_context': 6}), tools: tools),
      throwsA(isA<PromptBudgetExceeded>()),
    );
  });

  test('prefill mode excludes tools even when the final system prevents a prefix', () {
    final result = _assemble(
      _preset(
        target: 'reasoning',
        text: '',
        settings: {'openai_max_context': 6},
        prompts: const [
          {'identifier': 'end', 'role': 'system', 'content': 'S', 'system_prompt': false},
        ],
        order: const ['chatHistory', 'end'],
      ),
      tools: _largeTools(),
    );
    expect(_wire(result).single, {'role': 'user', 'content': 'H\n\nS'});
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.body.containsKey('tool_choice'), isFalse);
    expect(result.remainingBudget, 1);
    expect(result.excluded.any((item) => item.reason == 'prefill-mode-tools'), isTrue);
  });

  test('continue-prefill mode excludes tool costs before reserving its old text', () {
    final result = _assemble(
      _preset(enabled: null, settings: {'continue_prefill': true, 'openai_max_context': 7}),
      type: 'continue',
      tools: _largeTools(),
      history: const [PromptHistoryMessage(id: 'old', role: 'assistant', content: 'OLD')],
    );
    expect(_wire(result).last, {'role': 'assistant', 'content': 'OLD', 'prefix': true});
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.remainingBudget, 1);
  });

  test('CCV3-prefill mode also avoids large tool costs before budgeting', () {
    final result = _assemble(
      _preset(enabled: null, settings: {'openai_max_context': 6}),
      tools: _largeTools(),
      worldPrefill: const [PromptFragment('W', PromptSource('worldInfo', 'entry'))],
    );
    expect(_wire(result).last, {'role': 'assistant', 'content': 'W', 'prefix': true});
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.body.containsKey('tool_choice'), isFalse);
    expect(result.remainingBudget, 1);
  });

  test('ordinary non-prefill turns keep configured tools and their choice', () {
    final result = _assemble(
      _preset(enabled: null),
      tools: const [
        {
          'type': 'function',
          'function': {
            'name': 'ordinary',
            'parameters': {'type': 'object'},
          },
        },
      ],
    );
    expect(result.body['tools'], isNotEmpty);
    expect(result.body['tool_choice'], 'required');
    expect(result.excluded.any((item) => item.reason == 'prefill-mode-tools'), isFalse);
  });

  test('historical tool call/result pairs survive an enhanced reasoning prefix', () {
    final result = _assemble(
      _preset(target: 'reasoning'),
      tools: _largeTools(),
      history: const [
        PromptHistoryMessage(
          id: 'call',
          role: 'assistant',
          content: '',
          toolCalls: [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {'name': 'old', 'arguments': '{}'},
            },
          ],
        ),
        PromptHistoryMessage(id: 'result', role: 'tool', content: 'RESULT', toolCallId: 'call-1'),
      ],
    );
    final wire = _wire(result);
    expect(wire[0]['tool_calls'], [
      {
        'id': 'call-1',
        'type': 'function',
        'function': {'name': 'old', 'arguments': '{}'},
      },
    ]);
    expect(wire[0]['reasoning_content'], '');
    expect(wire[1], {'role': 'tool', 'content': 'RESULT', 'tool_call_id': 'call-1'});
    expect(wire[2], {'role': 'assistant', 'content': '', 'reasoning_content': 'P', 'prefix': true});
    expect(result.body.containsKey('tools'), isFalse);
  });

  test('mandatory reasoning prefix exceeds a narrow budget without macro replay', () {
    var calls = 0;
    expect(
      () => _assemble(
        _preset(target: 'reasoning', text: '{{tick}}', settings: {'openai_max_context': 5}),
        expand: (text, _) => text == '{{tick}}' ? 'LONG_PREFILL_${++calls}' : text,
      ),
      throwsA(
        isA<PromptBudgetExceeded>().having((error) => error.identifier, 'mandatory source', 'enhancedAssistantPrefill'),
      ),
    );
    expect(calls, 1);
  });

  test('estimated counter does not treat nonempty reasoning input as an empty message', () {
    const counter = EstimatedTokenCounter();
    expect(counter.countMessage({'role': 'assistant', 'content': '', 'reasoning_content': '输入思考'}), greaterThan(0));
    expect(counter.countMessage({'role': 'assistant', 'content': '', 'reasoning_content': ''}), 0);
  });

  test('final request guard removes newly supplied tools from any explicit prefix', () {
    final body = deepSeekRequestBody(
      messages: const [
        PromptSegment(
          id: 'prefix',
          message: {'role': 'assistant', 'content': 'P', 'prefix': true},
          sources: [],
          tokens: 1,
        ),
      ],
      settings: const {},
      model: 'm',
      generationType: 'normal',
      tools: _largeTools(),
      toolChoice: 'required',
    );
    expect(body.containsKey('tools'), isFalse);
    expect(body.containsKey('tool_choice'), isFalse);
  });
}

ChatPreset _preset({
  bool? enabled = true,
  String? target = 'content',
  String text = 'P',
  Map<String, Object?> settings = const {},
  List<Map<String, Object?>> prompts = const [],
  List<String> order = const ['chatHistory'],
}) => ChatPreset({
  'openai_max_context': 2000,
  'openai_max_tokens': 0,
  'names_behavior': -1,
  'new_chat_prompt': '',
  'new_example_chat_prompt': '',
  'send_if_empty': '',
  'show_thoughts': true,
  'assistant_prefill': text,
  if (enabled != null)
    'extensions': {
      'dshgo': {
        'prefill': {'enabled': enabled, 'target': ?target},
      },
    },
  'prompts': [
    {'identifier': 'chatHistory', 'role': 'system', 'marker': true},
    ...prompts,
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        for (final id in order) {'identifier': id, 'enabled': true},
      ],
    },
  ],
  ...settings,
});

PromptAssembly _assemble(
  ChatPreset preset, {
  bool deepseek = true,
  String type = 'normal',
  List<PromptHistoryMessage> history = const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
  List<Map<String, Object?>> tools = const [],
  List<PromptFragment> worldPrefill = const [],
  PromptExpansion? expand,
}) => const PromptAssembler(counter: _TextCounter()).assemble(
  PromptInput(
    preset: preset,
    card: const {'name': 'C'},
    history: history,
    model: 'm',
    generationType: type,
    deepseek: deepseek,
    tools: tools,
    toolChoice: tools.isEmpty ? null : 'required',
    assistantPrefill: worldPrefill,
    expansion: expand,
  ),
);

List<Map<String, Object?>> _wire(PromptAssembly result) =>
    (result.body['messages']! as List<Object?>).cast<Map<String, Object?>>();

List<Map<String, Object?>> _largeTools() => [
  {
    'type': 'function',
    'function': {
      'name': 'large_tool',
      'description': List<String>.filled(10000, 'x').join(),
      'parameters': {'type': 'object'},
    },
  },
];

class _TextCounter implements PromptTokenCounter {
  const _TextCounter();
  @override
  String get name => 'T20 deterministic text-length counter';
  @override
  bool get exact => true;
  @override
  int countMessage(Map<String, Object?> message) =>
      (message['content'] as String? ?? '').length +
      (message.containsKey('tool_calls') ? jsonEncode(message['tool_calls']).length : 0);
  @override
  int countText(String text) => text.length;
}
