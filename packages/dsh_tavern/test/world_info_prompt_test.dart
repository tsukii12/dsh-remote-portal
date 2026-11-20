import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

const _counter = _ContentCounter();
const _slots = [
  'worldInfoBefore',
  'main',
  'worldInfoAfter',
  'charDescription',
  'charPersonality',
  'scenario',
  'personaDescription',
  'dialogueExamples',
  'chatHistory',
  'jailbreak',
];

ChatPreset _preset({
  int capacity = 1000,
  Map<String, Map<String, Object?>> definitions = const {},
  Map<String, Object?> settings = const {},
}) => ChatPreset({
  // The assembler reserves three units independently of message content.
  'openai_max_context': capacity + 3, 'openai_max_tokens': 0,
  'new_chat_prompt': '', 'new_example_chat_prompt': '', 'new_group_chat_prompt': '',
  'scenario_format': '', 'personality_format': '', 'wi_format': '',
  'group_nudge_prompt': '', 'impersonation_prompt': '', 'continue_nudge_prompt': '',
  'send_if_empty': '', 'continue_postfix': '', 'continue_prefill': false,
  'squash_system_messages': false, 'names_behavior': 0,
  'prompts': [
    for (final id in _slots)
      <String, Object?>{
        'identifier': id,
        'name': id,
        'role': 'system',
        'content': '',
        'system_prompt': true,
        ...?definitions[id],
      },
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        for (final id in _slots) {'identifier': id, 'enabled': true},
      ],
    },
  ],
  ...settings,
});

PromptFragment _world(String id, String text, {String? role, bool optional = false}) => PromptFragment(
  text,
  PromptSource('world', id, details: {'bookId': 'book', 'uid': id}),
  role: role,
  trimOnOverflow: optional,
);

PromptAssembly _assemble({
  int capacity = 1000,
  ChatPreset? preset,
  Map<String, Object?> card = const {'name': 'Guide'},
  List<PromptHistoryMessage> history = const [],
  List<PromptFragment> before = const [],
  List<PromptFragment> after = const [],
  Map<String, List<PromptFragment>> sections = const {},
  Set<String> disabled = const {},
  List<PromptFragment> prefill = const [],
  List<PromptInjection> injections = const [],
  List<PromptExample> examples = const [],
  bool pinExamples = false,
  bool deepseek = false,
  String type = 'normal',
  String quietPrompt = '',
  List<Map<String, Object?>> tools = const [],
  PromptExpansion? expansion,
  PromptExpansion? baseExpansion,
}) => const PromptAssembler(counter: _counter).assemble(
  PromptInput(
    preset: preset ?? _preset(capacity: capacity),
    card: card,
    history: history,
    model: 'test-model',
    userName: 'User',
    characterId: 'card',
    generationType: type,
    deepseek: deepseek,
    worldBefore: before,
    worldAfter: after,
    worldSections: sections,
    disabledUiPrompts: disabled,
    assistantPrefill: prefill,
    injections: injections,
    worldExamples: examples,
    pinExamples: pinExamples,
    quietPrompt: quietPrompt,
    tools: tools,
    expansion: expansion,
    cardExpansion: baseExpansion,
  ),
);

List<String> _texts(PromptAssembly result) => [
  for (final segment in result.beforePostProcessing) segment.message['content'] as String,
];
List<PromptSegment> _from(PromptAssembly result, String source) =>
    result.beforePostProcessing.where((segment) => segment.sources.any((item) => item.id == source)).toList();
List<String> _trimmed(PromptAssembly result) =>
    result.excluded.where((item) => item.reason == 'v3-ignore-on-max-context').map((item) => item.id).toList();

void main() {
  test('four sections surround or append to the card slot without mutating raw fields', () {
    final card = <String, Object?>{
      'name': 'Guide',
      'description': 'D',
      'personality': 'P',
      'scenario': 'S',
      'foreign': {'preserved': true},
    };
    final result = _assemble(
      card: card,
      sections: {
        'before_desc': [_world('bd', 'B')],
        'after_desc': [_world('ad', 'A')],
        'personality': [_world('wp', 'WP')],
        'scenario': [_world('ws', 'WS')],
      },
    );
    expect(_texts(result), ['B', 'D', 'A', 'P', 'WP', 'S', 'WS']);
    expect(_from(result, 'card:description').single.message['content'], 'D');
    expect(_from(result, 'wp').single.sources.single.details, {'bookId': 'book', 'uid': 'wp'});
    expect(card, {
      'name': 'Guide',
      'description': 'D',
      'personality': 'P',
      'scenario': 'S',
      'foreign': {'preserved': true},
    });
  });

  for (final role in ['system', 'user', 'assistant']) {
    test('explicit $role survives every supported placement before transport processing', () {
      final result = _assemble(
        card: {'name': 'Guide', 'description': 'D', 'personality': 'P', 'scenario': 'S'},
        before: [_world('before', 'WB', role: role)],
        after: [_world('after', 'WA', role: role)],
        sections: {
          'before_desc': [_world('bd', 'BD', role: role)],
          'after_desc': [_world('ad', 'AD', role: role)],
          'personality': [_world('wp', 'WP', role: role)],
          'scenario': [_world('ws', 'WS', role: role)],
        },
        examples: [
          PromptExample(before: true, fragment: _world('eb', 'Bare example before', role: role)),
          PromptExample(before: false, fragment: _world('ea', 'Bare example after', role: role)),
        ],
        injections: [
          PromptInjection(
            fragment: const PromptFragment('aggregate', PromptSource('note', '2_floating_prompt')),
            placement: PromptPlacement.beforeMain,
            fragments: [
              _world('anb', 'AN before', role: role),
              const PromptFragment('AN base', PromptSource('note', 'base')),
            ],
          ),
          PromptInjection(
            fragment: const PromptFragment('aggregate', PromptSource('note', 'an_after')),
            placement: PromptPlacement.afterMain,
            fragments: [_world('ana', 'AN after', role: role)],
          ),
          PromptInjection(depth: 1, fragment: _world('depth', 'Depth', role: role)),
        ],
        history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
      );
      for (final id in ['before', 'after', 'bd', 'ad', 'wp', 'ws', 'eb', 'ea', 'anb', 'ana', 'depth']) {
        expect(_from(result, id).single.message['role'], role, reason: id);
      }
      expect(_from(result, 'eb').single.message, {'role': role, 'content': 'Bare example before'});
      expect(_from(result, 'base').single.message['role'], 'system');
    });
  }

  test('section pieces inherit the preset marker role only when no explicit role is supplied', () {
    final result = _assemble(
      preset: _preset(
        definitions: {
          'charDescription': {'role': 'user'},
        },
      ),
      card: {'name': 'Guide', 'description': 'D'},
      sections: {
        'before_desc': [_world('before', 'B', role: 'assistant')],
        'after_desc': [_world('after', 'A')],
      },
    );
    expect(result.beforePostProcessing.map((segment) => segment.message['role']), ['assistant', 'user', 'user']);
    expect(_texts(result), ['B', 'D', 'A']);
  });

  test('ordinary world fragments retain the single aggregate wi_format macro pass', () {
    final calls = <String>[];
    final result = _assemble(
      preset: _preset(settings: {'wi_format': 'W<{0}>'}),
      before: [_world('a', 'A'), _world('b', 'B')],
      expansion: (text, _) {
        calls.add(text);
        return text;
      },
    );
    expect(_texts(result), ['W<A\nB>']);
    expect(calls.where((text) => text.startsWith('W<')), ['W<A\nB>']);
    expect(result.beforePostProcessing.single.sources.map((source) => source.id), ['a', 'b']);
  });

  test('decorated world entries keep wi_format, their roles and independent origins', () {
    final result = _assemble(
      preset: _preset(settings: {'wi_format': 'W<{0}>'}),
      before: [
        _world('a', 'A', role: 'user'),
        _world('b', 'B'),
      ],
    );
    expect(_texts(result), ['W<A>', 'W<B>']);
    expect(result.beforePostProcessing.map((segment) => segment.message['role']), ['user', 'system']);
    expect(_from(result, 'a').single.sources.single.id, 'a');
  });

  test('UI disabling suppresses preset and card overrides but preserves the relative main anchor', () {
    final normalCalls = <String>[];
    final baseCalls = <String>[];
    final preset = _preset(
      definitions: {
        'main': {'content': '{{presetMain}}'},
        'jailbreak': {'content': '{{presetTail}}'},
      },
    );
    final before = preset.encode();
    final result = _assemble(
      preset: preset,
      card: {'name': 'Guide', 'system_prompt': '{{cardMain}}', 'post_history_instructions': '{{cardTail}}'},
      disabled: {'system_prompt', 'post_history_instructions'},
      injections: const [
        PromptInjection(
          fragment: PromptFragment('NOTE', PromptSource('note', 'note')),
          placement: PromptPlacement.beforeMain,
        ),
      ],
      expansion: (text, _) {
        normalCalls.add(text);
        return text;
      },
      baseExpansion: (text, _) {
        baseCalls.add(text);
        return text;
      },
    );
    expect(_texts(result), ['NOTE']);
    expect(normalCalls, isNot(contains('{{presetMain}}')));
    expect(normalCalls, isNot(contains('{{presetTail}}')));
    expect(normalCalls, isNot(contains('{{cardMain}}')));
    expect(normalCalls, isNot(contains('{{cardTail}}')));
    // Initial eager card preparation precedes WI, so it remains observable.
    expect(baseCalls, containsAll(['{{cardMain}}', '{{cardTail}}']));
    expect(result.excluded.where((item) => item.reason == 'v3-disable-ui-prompt').map((item) => item.id), [
      'main',
      'jailbreak',
    ]);
    expect(result.excluded.firstWhere((item) => item.id == 'main').sources.map((source) => source.kind), [
      'preset',
      'card',
    ]);
    expect(preset.encode(), before);
  });

  test('disabled absolute main remains an anchor and cannot overwrite an explicit extension role', () {
    final result = _assemble(
      preset: _preset(
        definitions: {
          'main': {'content': 'BLOCKED', 'role': 'user', 'injection_position': 1, 'injection_depth': 1},
        },
      ),
      disabled: {'system_prompt'},
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'NEW'),
      ],
      injections: [
        PromptInjection(
          fragment: _world('explicit', 'EXPLICIT', role: 'assistant'),
          placement: PromptPlacement.beforeMain,
        ),
        const PromptInjection(
          fragment: PromptFragment('INHERITED', PromptSource('note', 'inherit')),
          placement: PromptPlacement.afterMain,
        ),
      ],
    );
    expect(_texts(result), ['OLD', 'EXPLICIT', 'INHERITED', 'NEW']);
    expect(_from(result, 'explicit').single.message['role'], 'assistant');
    expect(_from(result, 'inherit').single.message['role'], 'user');
  });

  for (final uiType in ['system_prompt', 'post_history_instructions']) {
    test('disabling $uiType leaves the other UI prompt and its card override enabled', () {
      final result = _assemble(
        preset: _preset(
          definitions: {
            'main': {'content': 'PRESET MAIN'},
            'jailbreak': {'content': 'PRESET TAIL'},
          },
        ),
        card: {'name': 'Guide', 'system_prompt': 'CARD MAIN', 'post_history_instructions': 'CARD TAIL'},
        disabled: {uiType, 'foreign_ui_type'},
      );
      expect(_texts(result), [uiType == 'system_prompt' ? 'CARD TAIL' : 'CARD MAIN']);
      expect(result.excluded.where((item) => item.reason == 'v3-disable-ui-prompt'), hasLength(1));
    });
  }

  test('optional fixed entries are refunded before any history is truncated', () {
    final result = _assemble(
      preset: _preset(
        capacity: 8,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      before: [_world('optional', 'OPTION', optional: true)],
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'old'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'new'),
      ],
    );
    expect(_texts(result), ['M', 'old', 'new']);
    expect(_trimmed(result), ['optional']);
    expect(result.excluded.where((item) => item.reason == 'history-budget'), isEmpty);
    expect(result.remainingBudget, 1);
    expect(result.counterName, _counter.name);
    expect(result.exactTokenCounts, isFalse);
  });

  test('an optional entry larger than the whole context does not prevent mandatory content', () {
    final result = _assemble(
      preset: _preset(
        capacity: 3,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      before: [_world('large', 'XXXXX', optional: true)],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
    );
    expect(_texts(result), ['M', 'H']);
    expect(_trimmed(result), ['large']);
    expect(result.remainingBudget, 1);
  });

  test('optional removal follows first charged entry order and stops once there is room', () {
    final result = _assemble(
      preset: _preset(
        capacity: 10,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      before: [_world('first', 'AAAA', optional: true), _world('second', 'BB', optional: true)],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HHHH')],
    );
    expect(_texts(result), ['BB', 'M', 'HHHH']);
    expect(_trimmed(result), ['first']);
    expect(result.remainingBudget, 3);
  });

  test('reaching exact capacity trims an optional entry and retains all history', () {
    final result = _assemble(
      preset: _preset(
        capacity: 4,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      before: [_world('optional', 'W', optional: true)],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HH')],
    );
    expect(_texts(result), ['M', 'HH']);
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 1);
  });

  test('native exact-fit and newest contiguous history policies remain unchanged without optional pieces', () {
    final result = _assemble(
      preset: _preset(
        capacity: 4,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'old'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'new'),
      ],
    );
    expect(_texts(result), ['M', 'new']);
    expect(result.remainingBudget, 0);
    expect(result.excluded.single.id, 'old');
    expect(result.excluded.single.reason, 'history-budget');
  });

  test('mandatory overflow remains typed after every optional piece has been removed', () {
    expect(
      () => _assemble(
        preset: _preset(
          capacity: 0,
          definitions: {
            'main': {'content': 'M'},
          },
        ),
        before: [_world('optional', 'O', optional: true)],
      ),
      throwsA(isA<PromptBudgetExceeded>().having((error) => error.identifier, 'identifier', 'main')),
    );
  });

  test('a mixed relative author note loses only the optional entry, never its base or required neighbor', () {
    final result = _assemble(
      preset: _preset(
        capacity: 7,
        definitions: {
          'main': {'content': 'M'},
        },
      ),
      injections: [
        PromptInjection(
          fragment: const PromptFragment('wrong aggregate', PromptSource('note', '2_floating_prompt')),
          placement: PromptPlacement.afterMain,
          fragments: [
            _world('optional', 'OOOO', optional: true),
            const PromptFragment('AN', PromptSource('note', 'base')),
            _world('required', 'K'),
          ],
        ),
      ],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
    );
    expect(_texts(result), ['M', 'AN', 'K', 'H']);
    expect(_from(result, 'base'), hasLength(1));
    expect(_from(result, 'required'), hasLength(1));
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 2);
  });

  test('a mixed depth group preserves final order and mandatory pieces after optional removal', () {
    final result = _assemble(
      capacity: 6,
      injections: [
        PromptInjection(
          depth: 0,
          fragment: const PromptFragment('wrong aggregate', PromptSource('note', 'depth-note')),
          fragments: [
            _world('optional', 'OOOO', optional: true),
            const PromptFragment('AN', PromptSource('note', 'base')),
            _world('required', 'K'),
          ],
        ),
      ],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HH')],
    );
    expect(_texts(result), ['HH', 'AN', 'K']);
    expect(_trimmed(result), ['optional']);
    expect(result.excluded.where((item) => item.reason == 'history-budget'), isEmpty);
    expect(result.remainingBudget, 1);
  });

  test('decorated depth keeps native role-group order and the final entry order inside each role', () {
    final result = _assemble(
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'NEW'),
      ],
      injections: [
        PromptInjection(
          depth: 1,
          fragment: const PromptFragment('aggregate', PromptSource('note', 'depth')),
          fragments: [
            _world('s1', 'S1', role: 'system'),
            _world('a', 'A', role: 'assistant'),
            _world('u', 'U', role: 'user'),
            _world('s2', 'S2', role: 'system'),
          ],
        ),
      ],
    );
    expect(_texts(result), ['OLD', 'A', 'U', 'S1', 'S2', 'NEW']);
  });

  test('an absolute card slot keeps its required card body when its optional section is removed', () {
    final result = _assemble(
      preset: _preset(
        capacity: 5,
        definitions: {
          'charDescription': {'injection_position': 1, 'injection_depth': 1},
        },
      ),
      card: {'name': 'Guide', 'description': 'DD'},
      sections: {
        'before_desc': [_world('optional', 'OOOO', optional: true)],
      },
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HH')],
    );
    expect(_texts(result), ['DD', 'HH']);
    expect(_from(result, 'card:description'), hasLength(1));
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 1);
  });

  test('a history budget stop reports an uncharged optional depth tail without expanding it again', () {
    final calls = <String>[];
    final result = _assemble(
      capacity: 3,
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'OOO'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'HH'),
      ],
      injections: [PromptInjection(depth: 2, fragment: _world('optional', '{{once}}', optional: true))],
      expansion: (text, _) {
        calls.add(text);
        return text == '{{once}}' ? 'W' : text;
      },
    );
    expect(_texts(result), ['HH']);
    expect(result.remainingBudget, 1);
    expect(_trimmed(result), ['optional']);
    expect(result.excluded.where((item) => item.reason == 'history-budget').map((item) => item.id), ['old']);
    expect(calls.where((text) => text == '{{once}}'), hasLength(1));
    expect(
      calls.where((text) => text == 'W'),
      isEmpty,
      reason: 'The unvisited depth tail must not run the history expansion pass.',
    );
  });

  test('all blocks of an optional example entry and only their own prefixes are refunded together', () {
    final result = _assemble(
      preset: _preset(capacity: 12, settings: {'new_example_chat_prompt': 'E'}),
      card: {'name': 'Guide', 'mes_example': '<START>\nGuide: C'},
      pinExamples: true,
      examples: [
        PromptExample(
          before: true,
          fragment: _world('optional', '<START>\nUser: OOO\n<START>\nGuide: PPP', optional: true),
        ),
      ],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HHH')],
    );
    expect(_texts(result), ['E', 'C', 'HHH']);
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 7);
  });

  test('an unpinned oversized optional example does not block the next required card example', () {
    final result = _assemble(
      preset: _preset(capacity: 4, settings: {'new_example_chat_prompt': 'E'}),
      card: {'name': 'Guide', 'mes_example': '<START>\nGuide: C'},
      examples: [PromptExample(before: true, fragment: _world('optional', '<START>\nUser: OOOOO', optional: true))],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
    );
    expect(_texts(result), ['E', 'C', 'H']);
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 1);
  });

  test('a required example budget stop reports its uncharged optional tail without replaying base macros', () {
    final baseCalls = <String>[];
    final normalCalls = <String>[];
    final result = _assemble(
      capacity: 3,
      card: {'name': 'Guide', 'mes_example': '<START>\nUser: OOOO'},
      examples: [PromptExample(before: false, fragment: _world('optional', '{{once}}', role: 'user', optional: true))],
      baseExpansion: (text, _) {
        baseCalls.add(text);
        return text == '{{once}}' ? 'W' : text;
      },
      expansion: (text, _) {
        normalCalls.add(text);
        return text;
      },
    );
    expect(_texts(result), isEmpty);
    expect(result.remainingBudget, 3);
    expect(_trimmed(result), ['optional']);
    expect(result.excluded.where((item) => item.reason == 'whole-example-budget'), hasLength(1));
    expect(baseCalls.where((text) => text == '{{once}}'), hasLength(1));
    expect(baseCalls.where((text) => text == 'W'), isEmpty);
    expect(normalCalls.where((text) => text == 'W'), isEmpty);
  });

  test('world example base expansion still runs in mixed input order before before-items are prepended', () {
    final calls = <String>[];
    final result = _assemble(
      examples: [
        PromptExample(before: true, fragment: _world('first', 'FIRST', role: 'assistant')),
        PromptExample(before: false, fragment: _world('middle', 'MIDDLE', role: 'user')),
        PromptExample(before: true, fragment: _world('last', 'LAST', role: 'system')),
      ],
      baseExpansion: (text, _) {
        if (text.isNotEmpty) calls.add(text);
        return text;
      },
    );
    expect(calls.where((text) => ['FIRST', 'MIDDLE', 'LAST'].contains(text)), ['FIRST', 'MIDDLE', 'LAST']);
    expect(_texts(result), ['LAST', 'FIRST', 'MIDDLE']);
  });

  test('DeepSeek concatenates explicit prefill last, after controls and send_if_empty', () {
    final result = _assemble(
      deepseek: true,
      preset: _preset(settings: {'send_if_empty': 'EMPTY'}),
      quietPrompt: 'QUIET',
      prefill: [
        _world('p1', 'A', role: 'assistant'),
        _world('p2', 'B', role: 'assistant'),
      ],
      history: const [PromptHistoryMessage(id: 'h', role: 'assistant', content: 'H')],
    );
    expect(_texts(result), ['H', 'EMPTY', 'QUIET', 'A', 'B']);
    expect(result.afterPostProcessing.last.message, {'role': 'assistant', 'content': 'A\n\nB', 'prefix': true});
    expect(result.afterPostProcessing.last.sources.map((source) => source.id), ['p1', 'p2']);
  });

  test('explicit world prefill follows the raw continuation prefill without adding a local postfix', () {
    final result = _assemble(
      deepseek: true,
      type: 'continue',
      preset: _preset(settings: {'continue_prefill': true, 'continue_postfix': 'LOCAL'}),
      prefill: [_world('p', 'W', role: 'assistant')],
      history: const [PromptHistoryMessage(id: 'h', role: 'assistant', content: 'H')],
    );
    expect(result.afterPostProcessing.last.message, {'role': 'assistant', 'content': 'H\n\nW', 'prefix': true});
    expect(_texts(result).join(), isNot(contains('LOCAL')));
  });

  test('optional prefill is removed before losing a mandatory history message', () {
    final result = _assemble(
      capacity: 5,
      deepseek: true,
      prefill: [_world('optional', 'PPPP', role: 'assistant', optional: true)],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HH')],
    );
    expect(_texts(result), ['HH']);
    expect(_trimmed(result), ['optional']);
    expect(result.afterPostProcessing.last.message.containsKey('prefix'), isFalse);
    expect(result.remainingBudget, 3);
  });

  test('ADD04 prefill mode removes newly configured tools before budgeting', () {
    final result = _assemble(
      deepseek: true,
      prefill: [_world('p', 'W', role: 'assistant')],
      tools: const [
        {
          'type': 'function',
          'function': {
            'name': 'tool',
            'parameters': {'type': 'object'},
          },
        },
      ],
    );
    expect(result.afterPostProcessing.last.message['role'], 'assistant');
    expect(result.afterPostProcessing.last.message['content'], 'W');
    expect(result.afterPostProcessing.last.message['prefix'], isTrue);
    expect(result.body.containsKey('tools'), isFalse);
    expect(result.body.containsKey('tool_choice'), isFalse);
    expect(result.excluded.any((item) => item.reason == 'prefill-mode-tools'), isTrue);
  });

  test('trimming expanded content never replays a macro and cannot leak its source through squash or DeepSeek', () {
    var ticks = 0;
    final result = _assemble(
      deepseek: true,
      preset: _preset(
        capacity: 3,
        definitions: {
          'main': {'content': 'M'},
        },
        settings: {'squash_system_messages': true},
      ),
      before: [_world('optional', '{{tick}}', optional: true)],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
      expansion: (text, _) => text.replaceAllMapped(RegExp(r'\{\{tick\}\}'), (_) {
        ticks++;
        return 'OOOO';
      }),
    );
    expect(ticks, 1);
    expect(_texts(result), ['M', 'H']);
    expect(
      result.afterPostProcessing.expand((segment) => segment.sources).any((source) => source.id == 'optional'),
      isFalse,
    );
    expect(_trimmed(result), ['optional']);
    expect(result.remainingBudget, 1);
  });

  test('known depth author notes retain the eager pass, but a budget refund adds no extra pass', () {
    var ticks = 0;
    final result = _assemble(
      capacity: 3,
      injections: [
        PromptInjection(
          depth: 0,
          fragment: const PromptFragment('aggregate', PromptSource('note', '2_floating_prompt')),
          fragments: [
            _world('optional', '{{tick}}', optional: true),
            const PromptFragment('A', PromptSource('note', 'base')),
          ],
        ),
      ],
      history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'H')],
      expansion: (text, _) => text.replaceAllMapped(RegExp(r'\{\{tick\}\}'), (_) {
        ticks++;
        return 'OOOO';
      }),
    );
    expect(ticks, 2);
    expect(_texts(result), ['H', 'A']);
    expect(_trimmed(result), ['optional']);
  });

  test('V3 oversized depth inserts before the oldest message without lifting the native depth gate', () {
    final result = _assemble(
      history: const [
        PromptHistoryMessage(id: 'old', role: 'user', content: 'OLD'),
        PromptHistoryMessage(id: 'new', role: 'user', content: 'NEW'),
      ],
      injections: [
        PromptInjection(depth: 10001, v3Depth: true, fragment: _world('v3', 'V3')),
        PromptInjection(depth: 10001, fragment: _world('native', 'NATIVE')),
        PromptInjection(depth: -1, v3Depth: true, fragment: _world('negative', 'NEGATIVE')),
      ],
    );
    expect(_texts(result), ['V3', 'OLD', 'NEW']);
    expect(_from(result, 'native'), isEmpty);
    expect(_from(result, 'negative'), isEmpty);
  });

  test('V3 depth remains usable when the actual history itself exceeds ten thousand messages', () {
    final result = _assemble(
      capacity: 20000,
      history: [for (var i = 0; i < 10002; i++) PromptHistoryMessage(id: '$i', role: 'user', content: 'H')],
      injections: [
        PromptInjection(depth: 10002, v3Depth: true, fragment: _world('v3', 'V3')),
        PromptInjection(depth: 10002, fragment: _world('native', 'NATIVE')),
      ],
    );
    expect(result.beforePostProcessing, hasLength(10003));
    expect(result.beforePostProcessing.first.message['content'], 'V3');
    expect(result.beforePostProcessing.last.sources.single.id, '10001');
    expect(_from(result, 'native'), isEmpty);
  });
}

final class _ContentCounter implements PromptTokenCounter {
  const _ContentCounter();
  @override
  String get name => 'test UTF-16 content units; not model tokens';
  @override
  bool get exact => false;
  @override
  int countMessage(Map<String, Object?> message) => (message['content'] as String? ?? '').length;
  @override
  int countText(String text) => text.length;
}
