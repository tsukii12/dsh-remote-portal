import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('public assembler keeps an empty tool result before an enhanced reasoning prefix', () {
    const history = [
      PromptHistoryMessage(id: 'empty-user', role: 'user', content: ''),
      PromptHistoryMessage(id: 'empty-assistant', role: 'assistant', content: '', toolCallId: 'not-a-tool'),
      PromptHistoryMessage(id: 'empty-system', role: 'system', content: ''),
      PromptHistoryMessage(id: 'call', role: 'assistant', content: '', toolCalls: _calls),
      PromptHistoryMessage(id: 'result', role: 'tool', content: '', toolCallId: 'call-1'),
    ];
    final tools = <Map<String, Object?>>[
      {
        'type': 'function',
        'function': {
          'name': 'unmounted_new_tool',
          'parameters': {'type': 'object', 'required': <Object?>[]},
        },
      },
    ];
    final historyBefore = _historySnapshot(history);
    final toolsBefore = jsonEncode(tools);
    final result = _assemble(history, context: 2000, tools: tools);
    final wire = _wire(result);

    // Common premises must succeed before the complete semantic comparison.
    expect(result.body['thinking'], {'type': 'enabled'});
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.body.containsKey('tool_choice'), isFalse);
    expect(result.excluded.any((item) => item.reason == 'prefill-mode-tools'), isTrue);
    expect(result.excluded.where((item) => item.reason == 'history-budget'), isEmpty);
    expect(result.remainingBudget, greaterThanOrEqualTo(0));
    expect(wire.where((item) => item['tool_calls'] != null), hasLength(1));
    expect(wire.where((item) => item['prefix'] == true && item['reasoning_content'] == 'P'), hasLength(1));
    expect(_historySnapshot(history), historyBefore);
    expect(jsonEncode(tools), toolsBefore);
    print('T12 empty-tool READY: call and reasoning P present; tools unmounted; finite budget; inputs unchanged');

    // S2 predicts exactly the first and third messages; no indexing can hide
    // the missing empty result behind a convenience exception.
    expect(wire, _expectedWire);
    expect(result.beforePostProcessing.map((item) => item.message).toList(), [
      {'role': 'assistant', 'content': '', 'tool_calls': _calls},
      {'role': 'tool', 'content': '', 'tool_call_id': 'call-1'},
      {'role': 'assistant', 'content': 'P'},
    ]);
    expect(result.beforePostProcessing.map((item) => item.sources.map((source) => source.id).toList()).toList(), [
      ['call'],
      ['result'],
      ['assistant_prefill'],
    ]);
    expect(result.afterPostProcessing.map((item) => item.sources.map((source) => source.id).toList()).toList(), [
      ['call'],
      ['result'],
      ['assistant_prefill'],
    ]);
    expect(result.remainingBudget, 1992);
  });

  test('empty tool result uses declared costs under existing history budget clipping', () {
    const history = [
      PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD'),
      PromptHistoryMessage(id: 'call', role: 'assistant', content: '', toolCalls: _calls),
      PromptHistoryMessage(id: 'result', role: 'tool', content: '', toolCallId: 'call-1'),
    ];

    // Declared toy costs: fixed overhead 3, prefix 1, call 2, result 2.
    // OLD cannot fit; keeping a structural result does not make it free.
    final exact = _assemble(history, context: 8);
    expect(exact.budget, 8);
    expect(_wire(exact), _expectedWire);
    expect(exact.remainingBudget, 0);
    expect(exact.excluded.where((item) => item.reason == 'history-budget').map((item) => item.id).toList(), ['old']);

    // After overhead and prefix, one unit cannot admit the newest result.
    // Preserve the existing newest-first stop, without pairing or force-fit.
    final narrow = _assemble(history, context: 5);
    expect(narrow.budget, 5);
    expect(_wire(narrow), [
      {'role': 'assistant', 'content': '', 'reasoning_content': 'P', 'prefix': true},
    ]);
    expect(narrow.remainingBudget, 1);
    expect(narrow.excluded.where((item) => item.reason == 'history-budget').map((item) => item.id).toList(), [
      'result',
      'call',
      'old',
    ]);
  });
}

const _calls = <Map<String, Object?>>[
  {
    'id': 'call-1',
    'type': 'function',
    'function': {'name': 'old', 'arguments': '{}'},
  },
];

const _expectedWire = <Map<String, Object?>>[
  {'role': 'assistant', 'content': '', 'tool_calls': _calls, 'reasoning_content': ''},
  {'role': 'tool', 'content': '', 'tool_call_id': 'call-1'},
  {'role': 'assistant', 'content': '', 'reasoning_content': 'P', 'prefix': true},
];

PromptAssembly _assemble(
  List<PromptHistoryMessage> history, {
  required int context,
  List<Map<String, Object?>> tools = const [],
}) => const PromptAssembler(counter: _DeclaredToolCounter()).assemble(
  PromptInput(
    preset: ChatPreset({
      'openai_max_context': context,
      'openai_max_tokens': 0,
      'names_behavior': -1,
      'new_chat_prompt': '',
      'new_example_chat_prompt': '',
      'send_if_empty': '',
      'show_thoughts': true,
      'assistant_prefill': 'P',
      'extensions': {
        'dshgo': {
          'prefill': {'enabled': true, 'target': 'reasoning'},
        },
      },
      'prompts': [
        {'identifier': 'chatHistory', 'role': 'system', 'marker': true},
      ],
      'prompt_order': [
        {
          'character_id': 100001,
          'order': [
            {'identifier': 'chatHistory', 'enabled': true},
          ],
        },
      ],
    }),
    card: const {'name': 'C'},
    history: history,
    model: 'fixture-model',
    deepseek: true,
    tools: tools,
    toolChoice: tools.isEmpty ? null : 'required',
  ),
);

List<Map<String, Object?>> _wire(PromptAssembly result) =>
    (result.body['messages']! as List<Object?>).cast<Map<String, Object?>>();

String _historySnapshot(List<PromptHistoryMessage> history) => jsonEncode([
  for (final item in history)
    {
      'id': item.id,
      'role': item.role,
      'content': item.content,
      if (item.toolCalls != null) 'tool_calls': item.toolCalls,
      if (item.toolCallId != null) 'tool_call_id': item.toolCallId,
    },
]);

// Declared fixture costs, not a tokenizer, provider bill, or timing probe.
final class _DeclaredToolCounter implements PromptTokenCounter {
  const _DeclaredToolCounter();

  @override
  String get name => 'T12 declared structural-message costs';

  @override
  bool get exact => false;

  @override
  int countMessage(Map<String, Object?> message) {
    if (message['role'] == 'tool' && message['content'] == '') return 2;
    if (message['tool_calls'] is List<Object?>) return 2;
    return (message['content'] as String? ?? '').length;
  }

  @override
  int countText(String text) => text.length;
}
