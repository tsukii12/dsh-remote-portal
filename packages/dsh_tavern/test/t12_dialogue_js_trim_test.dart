import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// ST 7e8663cd9c184a550b37238218bdd32c6efc68e9: parseMesExamples,
// parseExampleIntoIndividual, populateDialogueExamples and getChat.
// The 17 native rows below transcribe the saved original-function probe's
// independent literal expectations. No probe or research file runs in this test.
const _counter = _MessageCounter();

final class _MessageCounter implements PromptTokenCounter {
  const _MessageCounter();
  @override
  String get name => 'one unit per nonempty content (toy)';
  @override
  bool get exact => false;
  @override
  int countText(String text) => text.isEmpty ? 0 : 1;
  @override
  int countMessage(Map<String, Object?> message) => message['content'] == '' ? 0 : 1;
}

PromptInput _input(String examples, {List<PromptExample> worldExamples = const []}) => PromptInput(
  preset: ChatPreset({
    'openai_max_context': 1000,
    'openai_max_tokens': 0,
    'names_behavior': -1,
    'new_chat_prompt': '',
    'new_example_chat_prompt': '',
    'send_if_empty': '',
    'squash_system_messages': false,
    'stream_openai': false,
    'prompts': [
      {'identifier': 'dialogueExamples', 'role': 'system', 'marker': true, 'content': ''},
      {'identifier': 'chatHistory', 'role': 'system', 'marker': true, 'content': ''},
    ],
    'prompt_order': [
      {
        'character_id': 100001,
        'order': [
          {'identifier': 'dialogueExamples', 'enabled': true},
          {'identifier': 'chatHistory', 'enabled': true},
        ],
      },
    ],
  }),
  card: {'name': 'C', 'mes_example': examples},
  history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
  model: 'fixture-model',
  characterId: 'card',
  userName: 'User',
  deepseek: false,
  worldExamples: worldExamples,
);

String _snapshot(PromptInput input) => jsonEncode({
  'preset': input.preset.raw,
  'card': input.card,
  'history': [
    for (final item in input.history) {'id': item.id, 'role': item.role, 'content': item.content},
  ],
  'worldExamples': [
    for (final example in input.worldExamples)
      {
        'before': example.before,
        'content': example.fragment.content,
        'role': example.fragment.role,
        'expandMacros': example.fragment.expandMacros,
        'trimOnOverflow': example.fragment.trimOnOverflow,
        'source': example.fragment.source.toJson(),
      },
  ],
});

List<List<String>> _origins(List<PromptSegment> segments) => [
  for (final segment in segments) [for (final source in segment.sources) '${source.kind}/${source.id}'],
];

void _expectMetadata(
  PromptAssembly result,
  List<Map<String, Object?>> messages,
  List<List<String>> origins,
  int remaining, {
  String? reason,
}) {
  expect(result.beforePostProcessing.map((segment) => segment.message).toList(), messages, reason: reason);
  expect(result.afterPostProcessing.map((segment) => segment.message).toList(), messages, reason: reason);
  expect(_origins(result.beforePostProcessing), origins, reason: reason);
  expect(_origins(result.afterPostProcessing), origins, reason: reason);
  expect(result.excluded, isEmpty, reason: reason);
  expect(result.budget, 1000, reason: reason);
  expect(result.remainingBudget, remaining, reason: reason);
  expect(result.counterName, 'one unit per nonempty content (toy)', reason: reason);
  expect(result.exactTokenCounts, isFalse, reason: reason);
}

void main() {
  test('public assembler preserves native dialogue NEL in complete messages', () {
    const assembler = PromptAssembler(counter: _counter);
    final ordinaryInput = _input('<START>\nUser:  X \t');
    final ordinaryBefore = _snapshot(ordinaryInput);
    final ordinary = assembler.assemble(ordinaryInput);
    const ordinaryMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'X', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ];
    expect(ordinary.body['messages'], ordinaryMessages);
    _expectMetadata(ordinary, ordinaryMessages, [
      ['card/card:mes_example'],
      ['history/h'],
    ], 995);
    expect(_snapshot(ordinaryInput), ordinaryBefore);

    final input = _input('<START>\nUser:\u0085X\u0085');
    final before = _snapshot(input);
    print('DIALOGUE_EXAMPLES_READY');
    final result = assembler.assemble(input);
    // The complete public messages array is the first target assertion.
    expect(result.body['messages'], const <Map<String, Object?>>[
      {'role': 'system', 'content': '\u0085X\u0085', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ]);
    _expectMetadata(
      result,
      const [
        {'role': 'system', 'content': '\u0085X\u0085', 'name': 'example_user'},
        {'role': 'user', 'content': 'H'},
      ],
      [
        ['card/card:mes_example'],
        ['history/h'],
      ],
      995,
    );
    expect(_snapshot(input), before);
  });

  test('native dialogue source matrix and explicit-role bypass retain messages and origins', () {
    const assembler = PromptAssembler(counter: _counter);
    // WI inputs start at the already activated native-example boundary.
    // This exercises assembly, not WI scanning, import or HTTP transport.
    for (final row in _cases) {
      final input = _input(
        row.card,
        worldExamples: [
          for (var i = 0; i < row.world.length; i++)
            PromptExample(
              before: row.world[i].$1,
              fragment: PromptFragment(row.world[i].$2, PromptSource('world', 'wi:$i')),
            ),
        ],
      );
      final before = _snapshot(input);
      final result = assembler.assemble(input);
      expect(result.body['messages'], row.messages, reason: row.id);
      _expectMetadata(result, row.messages, row.origins, row.remaining, reason: row.id);
      expect(_snapshot(input), before, reason: row.id);
    }

    // Existing local CCV3 contract, separate from the 17 original-ST rows:
    // an explicit role bypasses native speaker parsing for the entire body.
    final input = _input(
      '',
      worldExamples: const [
        PromptExample(
          before: true,
          fragment: PromptFragment('\u0085NO SPEAKER\u0085', PromptSource('world', 'explicit-role'), role: 'assistant'),
        ),
      ],
    );
    final before = _snapshot(input);
    final result = assembler.assemble(input);
    const messages = <Map<String, Object?>>[
      {'role': 'assistant', 'content': '\u0085NO SPEAKER\u0085'},
      {'role': 'user', 'content': 'H'},
    ];
    expect(result.body['messages'], messages);
    _expectMetadata(result, messages, [
      ['world/explicit-role'],
      ['history/h'],
    ], 995);
    expect(_snapshot(input), before);
  });
}

final class _DialogueCase {
  const _DialogueCase({
    required this.id,
    required this.card,
    required this.world,
    required this.messages,
    required this.origins,
    required this.remaining,
  });
  final String id;
  final String card;
  final List<(bool, String)> world;
  final List<Map<String, Object?>> messages;
  final List<List<String>> origins;
  final int remaining;
}

const _cases = <_DialogueCase>[
  _DialogueCase(
    id: 'ordinary-ascii',
    card: '<START>\nUser:  X \t',
    world: [],
    messages: [
      {'role': 'system', 'content': 'X', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'card-nel-body',
    card: '<START>\nUser:\u0085X\u0085',
    world: [],
    messages: [
      {'role': 'system', 'content': '\u0085X\u0085', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'card-nel-only-body',
    card: '<START>\nUser:\u0085',
    world: [],
    messages: [
      {'role': 'system', 'content': '\u0085', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'card-nel-before-speaker-with-header',
    card: '<START>\n\u0085User: Q',
    world: [],
    messages: [
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['history/h'],
    ],
    remaining: 996,
  ),
  _DialogueCase(
    id: 'card-nel-before-speaker-no-header',
    card: '\u0085User: Q',
    world: [],
    messages: [
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['history/h'],
    ],
    remaining: 996,
  ),
  _DialogueCase(
    id: 'ascii-before-speaker',
    card: '<START>\n \tUser: Q',
    world: [],
    messages: [
      {'role': 'system', 'content': 'Q', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'nbsp-bom-trim',
    card: '<START>\n\u00a0\ufeffUser: \u00a0X\ufeff',
    world: [],
    messages: [
      {'role': 'system', 'content': 'X', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'zwsp-before-speaker-retained',
    card: '<START>\n\u200bUser: Q',
    world: [],
    messages: [
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['history/h'],
    ],
    remaining: 996,
  ),
  _DialogueCase(
    id: 'nel-is-not-line-break',
    card: '<START>\nUser: A\u0085C: B',
    world: [],
    messages: [
      {'role': 'system', 'content': 'A\u0085C: B', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'ls-is-not-lf',
    card: '<START>\nUser: A\u2028C: B',
    world: [],
    messages: [
      {'role': 'system', 'content': 'A\u2028C: B', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'crlf-speaker-switch',
    card: '<START>\r\nUser:\u0085X\u0085\r\nC: A',
    world: [],
    messages: [
      {'role': 'system', 'content': '\u0085X\u0085', 'name': 'example_user'},
      {'role': 'system', 'content': 'A', 'name': 'example_assistant'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 994,
  ),
  _DialogueCase(
    id: 'repeated-speaker-first-prefix-only',
    card: '<START>\nUser: A\nUser: B\nC: C',
    world: [],
    messages: [
      {'role': 'system', 'content': 'A\nUser: B', 'name': 'example_user'},
      {'role': 'system', 'content': 'C', 'name': 'example_assistant'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 994,
  ),
  _DialogueCase(
    id: 'indented-later-speaker-is-continuation',
    card: '<START>\nUser: A\n \tC: B',
    world: [],
    messages: [
      {'role': 'system', 'content': 'A\n \tC: B', 'name': 'example_user'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'native-wi-before-nel-body',
    card: '<START>\nC: CARD',
    world: [(true, '<START>\nUser:\u0085W\u0085')],
    messages: [
      {'role': 'system', 'content': '\u0085W\u0085', 'name': 'example_user'},
      {'role': 'system', 'content': 'CARD', 'name': 'example_assistant'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['world/wi:0'],
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 994,
  ),
  _DialogueCase(
    id: 'native-wi-after-nel-prefix',
    card: '<START>\nC: CARD',
    world: [(false, '<START>\n\u0085User: Q')],
    messages: [
      {'role': 'system', 'content': 'CARD', 'name': 'example_assistant'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['card/card:mes_example'],
      ['history/h'],
    ],
    remaining: 995,
  ),
  _DialogueCase(
    id: 'native-wi-mixed-order',
    card: '<START>\nC: CARD',
    world: [(true, '<START>\nUser: A'), (false, '<START>\nC:\u0085B\u0085'), (true, '<START>\nUser:\u0085C\u0085')],
    messages: [
      {'role': 'system', 'content': '\u0085C\u0085', 'name': 'example_user'},
      {'role': 'system', 'content': 'A', 'name': 'example_user'},
      {'role': 'system', 'content': 'CARD', 'name': 'example_assistant'},
      {'role': 'system', 'content': '\u0085B\u0085', 'name': 'example_assistant'},
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['world/wi:2'],
      ['world/wi:0'],
      ['card/card:mes_example'],
      ['world/wi:1'],
      ['history/h'],
    ],
    remaining: 992,
  ),
  _DialogueCase(
    id: 'empty-start-control',
    card: '<START>',
    world: [],
    messages: [
      {'role': 'user', 'content': 'H'},
    ],
    origins: [
      ['history/h'],
    ],
    remaining: 996,
  ),
];
