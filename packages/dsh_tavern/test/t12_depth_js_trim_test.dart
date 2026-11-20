import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

const _nel = '\u0085';
const _counter = _MessageCounter();

final class _MessageCounter implements PromptTokenCounter {
  const _MessageCounter();
  @override
  String get name => 'one token per nonempty message';
  @override
  bool get exact => false;
  @override
  int countText(String text) => text.isEmpty ? 0 : 1;
  @override
  int countMessage(Map<String, Object?> message) => message['content'] == '' ? 0 : 1;
}

PromptInjection _injection(
  String text, {
  String id = 'z',
  bool enhanced = false,
  bool split = false,
  bool literal = false,
}) => PromptInjection(
  fragment: PromptFragment(text, PromptSource('extension', id), role: split ? 'system' : null, expandMacros: !literal),
  depth: 0,
  v3Depth: enhanced,
);

PromptAssembly _assemble({
  List<PromptInjection> injections = const [],
  PromptExpansion? expansion,
  String? own,
  bool absoluteWorld = false,
  List<PromptFragment> worldBefore = const [],
}) {
  final definitions = <Map<String, Object?>>[
    {'identifier': 'chatHistory', 'role': 'system', 'marker': true},
    if (own != null)
      {
        'identifier': 'own',
        'role': 'system',
        'content': own,
        'system_prompt': false,
        'injection_position': 1,
        'injection_depth': 0,
        'injection_order': 100,
      },
    if (absoluteWorld)
      {
        'identifier': 'worldInfoBefore',
        'role': 'system',
        'marker': true,
        'injection_position': 1,
        'injection_depth': 0,
        'injection_order': 100,
      },
  ];
  return const PromptAssembler(counter: _counter).assemble(
    PromptInput(
      preset: ChatPreset({
        'openai_max_context': 1000,
        'openai_max_tokens': 0,
        'names_behavior': -1,
        'new_chat_prompt': '',
        'new_example_chat_prompt': '',
        'send_if_empty': '',
        'wi_format': '',
        'prompts': definitions,
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              for (final definition in definitions) {'identifier': definition['identifier'], 'enabled': true},
            ],
          },
        ],
      }),
      card: const {'name': 'C'},
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
      model: 'fixture-model',
      deepseek: false,
      injections: injections,
      worldBefore: worldBefore,
      expansion: expansion,
    ),
  );
}

List<Map<String, Object?>> _wire(PromptAssembly result) =>
    (result.body['messages']! as List<Object?>).cast<Map<String, Object?>>();
List<Map<String, Object?>> _messages(List<String> injected) => [
  {'role': 'user', 'content': 'H'},
  for (final text in injected) {'role': 'system', 'content': text},
];
List<List<String>> _sourceIds(List<PromptSegment> segments) =>
    segments.map((segment) => segment.sources.map((source) => source.id).toList()).toList();
String _snapshot(List<PromptInjection> injections) => jsonEncode([
  for (final injection in injections)
    {
      'depth': injection.depth,
      'role': injection.role,
      'v3Depth': injection.v3Depth,
      'content': injection.fragment.content,
      'fragmentRole': injection.fragment.role,
      'expandMacros': injection.fragment.expandMacros,
      'source': injection.fragment.source.toJson(),
    },
]);

void main() {
  test('public assembler preserves a NEL-only depth injection in the complete request', () {
    final calls = <String>[];
    String expand(String text, Map<String, String> overrides) {
      calls.add(text);
      return text;
    }

    final ordinary = _assemble(injections: [_injection(' \u00a0A\ufeff ')], expansion: expand);
    expect(_wire(ordinary), _messages(['A']));
    expect(ordinary.remainingBudget, 995);
    expect(calls.where((text) => text == 'A'), hasLength(2));
    final empty = _assemble(injections: [_injection(' \u00a0\ufeff\t ')], expansion: expand);
    expect(_wire(empty), _messages([]));
    expect(empty.remainingBudget, 996);
    final injections = [_injection(_nel)];
    final before = _snapshot(injections);
    calls.clear();
    print('DEPTH_JS_TRIM_READY');
    final result = _assemble(injections: injections, expansion: expand);
    // This complete public request comparison is the first target assertion.
    expect(_wire(result), _messages([_nel]));
    expect(result.beforePostProcessing.map((segment) => segment.message).toList(), _wire(result));
    expect(_sourceIds(result.beforePostProcessing), [
      ['h'],
      ['z'],
    ]);
    expect(_sourceIds(result.afterPostProcessing), [
      ['h'],
      ['z'],
    ]);
    expect(_snapshot(injections), before);
    expect(result.excluded, isEmpty);
    expect(result.budget, 1000);
    expect(result.remainingBudget, 995);
    expect(result.exactTokenCounts, isFalse);
    // Registry expansion and the later history pass both become reachable.
    expect(calls.where((text) => text == _nel), hasLength(2));
  });

  test('depth JavaScript trimming preserves grouping expansion and literal boundaries', () {
    for (final mode in [(false, false), (true, false), (false, true)]) {
      final (enhanced, split) = mode;
      for (final row in <(String, String)>[
        (
          ' $_nel'
              'A$_nel ',
          '$_nel'
              'A$_nel',
        ),
        (_nel, _nel),
        (' \u00a0A\ufeff ', 'A'),
        (' \u00a0\ufeff\t ', ''),
        (' \u200b ', '\u200b'),
      ]) {
        final result = _assemble(
          injections: [_injection(row.$1, enhanced: enhanced, split: split)],
        );
        expect(_wire(result), _messages(row.$2.isEmpty ? [] : [row.$2]), reason: '$mode / ${jsonEncode(row.$1)}');
      }
      final calls = <String>[];
      final expanded = _assemble(
        injections: [_injection(' {{emit}} ', enhanced: enhanced, split: split)],
        expansion: (text, _) {
          calls.add(text);
          return text.replaceAll('{{emit}}', _nel);
        },
      );
      expect(_wire(expanded), _messages([_nel]), reason: '$mode / expansion result');
      expect(calls.where((text) => text == '{{emit}}'), hasLength(1));
      expect(calls.where((text) => text == _nel), hasLength(1));
      final sorted = _assemble(
        injections: [
          _injection(' B ', id: 'z', enhanced: enhanced, split: split),
          _injection(_nel, id: 'a', enhanced: enhanced, split: split),
        ],
      );
      expect(_wire(sorted), _messages(split ? [_nel, 'B'] : ['$_nel\nB']));
      expect(
        _sourceIds(sorted.beforePostProcessing),
        split
            ? [
                ['h'],
                ['a'],
                ['z'],
              ]
            : [
                ['h'],
                ['a', 'z'],
              ],
      );
    }
    for (final enhanced in [false, true]) {
      final combined = _assemble(
        own:
            ' $_nel'
            'P$_nel ',
        injections: [
          _injection(
            ' $_nel'
            'A$_nel ',
            enhanced: enhanced,
          ),
        ],
      );
      expect(
        _wire(combined),
        _messages([
          '$_nel'
              'P$_nel\n$_nel'
              'A$_nel',
        ]),
      );
      expect(_sourceIds(combined.beforePostProcessing), [
        ['h'],
        ['own', 'z'],
      ]);
    }
    final ownPiece = _assemble(
      absoluteWorld: true,
      worldBefore: [
        const PromptFragment(
          ' $_nel'
          'OWN$_nel ',
          PromptSource('world', 'w'),
          role: 'system',
        ),
      ],
      injections: [
        _injection(
          ' $_nel'
          'EXT$_nel ',
        ),
      ],
    );
    expect(
      _wire(ownPiece),
      _messages([
        '$_nel'
            'OWN$_nel',
        '$_nel'
            'EXT$_nel',
      ]),
    );
    expect(_sourceIds(ownPiece.beforePostProcessing), [
      ['h'],
      ['w'],
      ['z'],
    ]);
    final literalCalls = <String>[];
    final literal = _assemble(
      injections: [_injection(' $_nel{{emit}}$_nel ', literal: true)],
      expansion: (text, _) {
        literalCalls.add(text);
        return text.replaceAll('{{emit}}', 'WRONG');
      },
    );
    expect(_wire(literal), _messages(['$_nel{{emit}}$_nel']));
    expect(literalCalls.any((text) => text.contains('{{emit}}')), isFalse);
    expect(_sourceIds(literal.beforePostProcessing), [
      ['h'],
      ['z'],
    ]);
  });
}
