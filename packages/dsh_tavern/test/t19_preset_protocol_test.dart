import 'dart:convert';

import 'package:dsh_tavern/src/prompt/deepseek_processing.dart';
import 'package:dsh_tavern/src/prompt/preset.dart';
import 'package:dsh_tavern/src/prompt/prompt_assembler.dart';
import 'package:dsh_tavern/src/prompt/prompt_types.dart';
import 'package:test/test.dart';

void main() {
  test('numeric strings count the budget while max_tokens keeps its request type', () {
    final preset = _preset({
      'openai_max_context': '512',
      'openai_max_tokens': '32',
      'temperature': '0.75',
      'presence_penalty': true,
      'frequency_penalty': false,
      'top_p': '0.25',
    });
    for (final deepseek in [false, true]) {
      final result = _assemble(preset, deepseek: deepseek);
      expect(result.budget, 480);
      expect(result.body['max_tokens'], '32');
      expect(result.body['temperature'], 0.75);
      expect(result.body['presence_penalty'], 1);
      expect(result.body['frequency_penalty'], 0);
      expect(result.body['top_p'], 0.25);
    }
  });

  test('Number uses JS whitespace and radix syntax with explicit finite fallback', () {
    for (final (value, expected) in <(Object?, num)>[
      ('\u00a0\ufeff0x200\u2029', 512),
      ('0b1000000000', 512),
      ('0o1000', 512),
      ('5.12e2', 512),
      ([512], 512),
      ([], 0),
      (true, 1),
      (false, 0),
      (null, 0),
      ('', 0),
      ('\u0085512\u0085', 777),
      ('Infinity', 777),
      ('bad', 777),
      ({'n': 512}, 777),
    ]) {
      expect(presetNumber(value, 777), expected, reason: '$value');
    }
    expect(_assemble(_preset({'openai_max_context': 'bad'})).budget, 3995);
  });

  test('execution normalization is detached and raw export stays lossless', () {
    final raw = _preset({
      'temperature': '0.25',
      'show_thoughts': 'false',
      'foreign': {
        'array': [0, false, null, '鲸'],
      },
      'prompt_order': [
        {
          'character_id': 100001.0,
          'order': [
            {'identifier': 'custom', 'enabled': 'false', 'foreign': 7},
          ],
        },
      ],
    }).raw;
    final preset = ChatPreset(raw);
    final before = jsonEncode(raw);
    final settings = preset.settings;
    expect(settings['temperature'], '0.25');
    expect(settings['show_thoughts'], isTrue);
    final order = _order(settings);
    expect(order.single['enabled'], isTrue);
    expect(order.single['foreign'], 7);
    order.single['enabled'] = false;
    (settings['foreign']! as Map<String, Object?>)['array'] = [];
    expect(jsonEncode(preset.raw), before);
    expect(jsonDecode(preset.encode()), raw);
    expect(_order(preset.settings).single['enabled'], isTrue);
  });

  test('prompt text follows substituteParams falsey guard then JS String', () {
    for (final (content, expected) in <(Object?, String)>[
      (true, 'true'),
      (42, '42'),
      (1e-7, '1e-7'),
      (false, ''),
      (0, ''),
      (null, ''),
      ([1, null, 3], '1,,3'),
      ({'a': 1}, '[object Object]'),
    ]) {
      expect(_text(_assemble(_preset({}, content: content)), 'custom'), expected, reason: '$content');
    }
  });

  test('template scalars expand without type casts', () {
    final result = _assemble(
      _preset({
        'scenario_format': true,
        'personality_format': 42,
        'new_chat_prompt': true,
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'scenario', 'enabled': true},
              {'identifier': 'charPersonality', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
      }),
      card: const {'name': 'C', 'scenario': 'scene', 'personality': 'kind'},
    );
    expect(_text(result, 'scenario'), 'true');
    expect(_text(result, 'charPersonality'), '42');
    expect(_text(result, 'newMainChat'), 'true');
  });

  test('enabled uses JS truthiness including the nonempty word false', () {
    for (final value in <Object?>[true, 'false', '0', 1, [], {}]) {
      expect(_text(_assemble(_preset({}, enabled: value)), 'custom'), 'CUSTOM', reason: '$value');
    }
    for (final value in <Object?>[false, 0, '', null]) {
      expect(_text(_assemble(_preset({}, enabled: value)), 'custom'), '', reason: '$value');
    }
  });

  test('system_prompt and forbid_overrides keep ST strict booleans', () {
    expect(_text(_assemble(_preset({}, definition: {'system_prompt': 'false'})), 'custom'), '');
    expect(_text(_assemble(_preset({}, definition: {'system_prompt': false})), 'custom'), 'CUSTOM');
    for (final (flag, expected) in <(Object?, String)>[(true, 'BASE'), ('true', 'CARD'), (false, 'CARD')]) {
      final result = _assemble(
        _preset({
          'prompts': [
            {'identifier': 'main', 'content': 'BASE', 'role': 'system', 'forbid_overrides': flag},
          ],
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'main', 'enabled': true},
              ],
            },
          ],
        }),
        card: const {'name': 'C', 'system_prompt': 'CARD'},
      );
      expect(_text(result, 'main'), expected, reason: '$flag');
    }
  });

  test('position and depth retain strict numeric comparison', () {
    for (final (position, depth, expected) in <(Object?, Object?, List<String>)>[
      ('1', 0, ['CUSTOM', 'HISTORY']),
      (true, 0, ['CUSTOM', 'HISTORY']),
      (1, '0', ['HISTORY']),
      (1, false, ['HISTORY']),
      (1, 0, ['HISTORY', 'CUSTOM']),
    ]) {
      final result = _assemble(
        _preset(
          {
            'prompt_order': [
              {
                'character_id': 100001,
                'order': [
                  {'identifier': 'custom', 'enabled': true},
                  {'identifier': 'chatHistory', 'enabled': true},
                ],
              },
            ],
          },
          definition: {'role': 'assistant', 'injection_position': position, 'injection_depth': depth},
        ),
        history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'HISTORY')],
      );
      expect(
        result.beforePostProcessing.map((segment) => segment.message['content']),
        expected,
        reason: '$position / $depth',
      );
    }
  });

  test('names_behavior does not reinterpret string enum values', () {
    for (final (mode, hasName, content) in <(Object?, bool, String)>[
      (1, true, 'raw'),
      ('1', false, 'raw'),
      (2, false, 'N: raw'),
      ('2', false, 'raw'),
      (0, false, 'N: raw'),
      (false, false, 'raw'),
    ]) {
      final result = _assemble(
        _preset({
          'names_behavior': mode,
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'chatHistory', 'enabled': true},
              ],
            },
          ],
        }),
        history: const [PromptHistoryMessage(id: 'h', role: 'user', content: 'raw', name: 'N', forceAvatar: true)],
      );
      final message = result.beforePostProcessing.singleWhere((segment) => segment.id == 'h').message;
      expect(message.containsKey('name'), hasName, reason: '$mode');
      expect(message['content'], content, reason: '$mode');
    }
  });

  test('roles default only on falsey values and do not throw on foreign scalars', () {
    for (final (role, expected) in <(Object?, Object?)>[
      (null, 'system'),
      (false, 'system'),
      (0, 'system'),
      ('', 'system'),
      (true, true),
      (17, 17),
    ]) {
      final result = _assemble(_preset({}, definition: {'role': role}));
      expect(result.beforePostProcessing.single.message['role'], expected);
    }
  });

  test('numeric identifiers match their original type and labels are safe text', () {
    final raw = _preset({
      'prompts': [
        {'identifier': 77, 'name': 42, 'role': 'system', 'content': true, 'system_prompt': false},
      ],
      'prompt_order': [
        {
          'character_id': 100001,
          'order': [
            {'identifier': 77, 'enabled': true},
          ],
        },
      ],
    }).raw;
    final result = _assemble(ChatPreset(raw));
    expect(result.beforePostProcessing.single.message['content'], 'true');
    expect(result.beforePostProcessing.single.sources.single.label, '42');
    final group = (raw['prompt_order']! as List<Object?>).single! as Map<String, Object?>;
    group['order'] = [
      {'identifier': '77', 'enabled': true},
    ];
    expect(_assemble(ChatPreset(raw)).beforePostProcessing, isEmpty);
  });

  test('continue and squash switches use truthiness without parsing words', () {
    final continued = _assemble(
      _preset({
        'continue_prefill': 'false',
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
      }),
      type: 'continue',
      history: const [PromptHistoryMessage(id: 'h', role: 'assistant', content: 'A')],
    );
    expect(_text(continued, 'continuePrefill'), 'A');
    final squashed = _assemble(
      _preset({
        'squash_system_messages': 'false',
        'prompts': [
          {'identifier': 'a', 'role': 'system', 'content': 'A', 'system_prompt': false},
          {'identifier': 'b', 'role': 'system', 'content': 'B', 'system_prompt': false},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'a', 'enabled': true},
              {'identifier': 'b', 'enabled': true},
            ],
          },
        ],
      }),
    );
    expect(squashed.beforePostProcessing.single.message['content'], 'A\nB');
  });

  final groupCases = <(String, Object?, bool, bool)>[
    ('missing list', null, true, false),
    (
      'only another group',
      [
        {
          'character_id': 100000,
          'order': [
            {'identifier': 'custom', 'enabled': true},
          ],
        },
      ],
      true,
      false,
    ),
    (
      'first empty group',
      [
        {'character_id': 100001, 'order': []},
        {
          'character_id': 100000,
          'order': [
            {'identifier': 'custom', 'enabled': true},
          ],
        },
      ],
      false,
      false,
    ),
    (
      'null order',
      [
        {'character_id': 100001, 'order': null},
      ],
      false,
      false,
    ),
    (
      'first duplicate stays empty',
      [
        {'character_id': 100001, 'order': []},
        {
          'character_id': 100001,
          'order': [
            {'identifier': 'custom', 'enabled': true},
          ],
        },
      ],
      false,
      false,
    ),
    (
      'string id is active',
      [
        {
          'character_id': '100001',
          'order': [
            {'identifier': 'custom', 'enabled': 'false'},
          ],
        },
      ],
      false,
      true,
    ),
  ];
  for (final (label, groups, main, custom) in groupCases) {
    test('prompt order: $label', () {
      final preset = _preset({'prompt_order': groups});
      final result = _assemble(preset);
      expect(_text(result, 'main').isNotEmpty, main);
      expect(_text(result, 'custom').isNotEmpty, custom);
      expect(preset.raw['prompt_order'], groups);
    });
  }

  test('malformed order containers become a safe empty first match', () {
    for (final order in <Object?>[
      'bad',
      false,
      17,
      {'entry': 'custom'},
    ]) {
      final preset = _preset({
        'prompt_order': [
          {'character_id': 100001, 'order': order},
        ],
      });
      expect(_assemble(preset).beforePostProcessing, isEmpty);
      expect(_order(preset.settings), isEmpty);
    }
  });

  test('DeepSeek effort and limits use original switch and forwarding semantics', () {
    for (final effort in <Object?>[
      true,
      false,
      17,
      null,
      ['low'],
      {},
    ]) {
      final body = deepSeekRequestBody(
        messages: const [],
        settings: {'show_thoughts': 'false', 'reasoning_effort': effort, 'openai_max_tokens': '33', 'top_p': false},
        model: 'm',
        generationType: 'normal',
      );
      expect(body['thinking'], {'type': 'enabled'});
      expect(body['reasoning_effort'], 'high');
      expect(body['max_tokens'], '33');
      expect(body['top_p'], 2.220446049250313e-16);
    }
    final absent = deepSeekRequestBody(messages: const [], settings: const {}, model: 'm', generationType: 'normal');
    expect(absent['max_tokens'], 300);
    expect(absent.containsKey('reasoning_effort'), isFalse);
  });

  test('DeepSeek top_p handles NaN and zero before nonfinite JSON normalization', () {
    const keys = ['temperature', 'top_p', 'presence_penalty', 'frequency_penalty'];
    const epsilon = 2.220446049250313e-16;
    // Independent fixed-ST Number -> DeepSeek OR -> JSON expectations. The
    // previous oracle incorrectly grouped NaN with Infinity for this field.
    for (final (label, value, generic, deepSeekTopP) in <(String, Object?, num?, num?)>[
      ('finite', 0.75, 0.75, 0.75),
      ('finite string', '0.25', 0.25, 0.25),
      ('negative finite', -0.5, -0.5, -0.5),
      ('zero', 0, 0, epsilon),
      ('negative zero', -0.0, 0, epsilon),
      ('zero string', '0', 0, epsilon),
      ('negative zero string', '-0', 0, epsilon),
      ('explicit null', null, 0, epsilon),
      ('false', false, 0, epsilon),
      ('empty string', '', 0, epsilon),
      ('empty array', <Object?>[], 0, epsilon),
      ('bad string', 'bad', null, epsilon),
      ('NEL', '\u0085', null, epsilon),
      ('object', <String, Object?>{}, null, epsilon),
      ('bad array', ['bad'], null, epsilon),
      ('Infinity', 'Infinity', null, null),
      ('negative Infinity', '-Infinity', null, null),
      ('overflow', '1e309', null, null),
      ('negative overflow', '-1e309', null, null),
    ]) {
      for (final deepseek in [false, true]) {
        final body = _assemble(_preset({for (final key in keys) key: value}), deepseek: deepseek).body;
        for (final key in keys) {
          expect(
            body[key],
            deepseek && key == 'top_p' ? deepSeekTopP : generic,
            reason: '$key / $label / deepseek=$deepseek',
          );
        }
        expect(() => jsonEncode(body), returnsNormally);
      }
    }
    for (final deepseek in [false, true]) {
      final body = _assemble(_preset({}), deepseek: deepseek).body;
      expect(
        {for (final key in keys) key: body[key]},
        {'temperature': 1, 'top_p': 1, 'presence_penalty': 0, 'frequency_penalty': 0},
      );
      expect(() => jsonEncode(body), returnsNormally);
    }
  });

  test('seed compares coercively but generic forwarding preserves the source value', () {
    for (final seed in <Object?>['42', 0, false, null, 'Infinity', '1e309']) {
      final preset = _preset({'seed': seed});
      expect(_assemble(preset).body['seed'], seed);
      expect(_assemble(preset).body.containsKey('seed'), isTrue);
      expect(_assemble(preset, deepseek: true).body.containsKey('seed'), isFalse);
    }
    expect(_assemble(_preset({'seed': 'bad'})).body.containsKey('seed'), isFalse);
  });
}

ChatPreset _preset(
  Map<String, Object?> overrides, {
  Object? content = 'CUSTOM',
  Object? enabled = true,
  Map<String, Object?> definition = const {},
}) => ChatPreset({
  'openai_max_context': 1000,
  'openai_max_tokens': 100,
  'new_chat_prompt': '',
  'prompts': [
    {'identifier': 'custom', 'role': 'system', 'content': content, 'system_prompt': false, ...definition},
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        {'identifier': 'custom', 'enabled': enabled},
      ],
    },
  ],
  ...overrides,
});

PromptAssembly _assemble(
  ChatPreset preset, {
  bool deepseek = false,
  String type = 'normal',
  Map<String, Object?> card = const {'name': 'C'},
  List<PromptHistoryMessage> history = const [],
}) => const PromptAssembler(counter: _Counter()).assemble(
  PromptInput(preset: preset, card: card, history: history, model: 'm', deepseek: deepseek, generationType: type),
);

String _text(PromptAssembly result, String id) => result.beforePostProcessing
    .where((segment) => segment.id == id)
    .map((segment) => segment.message['content'])
    .join();

List<Map<String, Object?>> _order(Map<String, Object?> settings) {
  final group = (settings['prompt_order']! as List<Object?>).whereType<Map<String, Object?>>().firstWhere(
    (group) => '${group['character_id']}' == '100001',
  );
  return (group['order']! as List<Object?>).whereType<Map<String, Object?>>().toList();
}

class _Counter implements PromptTokenCounter {
  const _Counter();
  @override
  String get name => 'T19 deterministic message counter';
  @override
  bool get exact => true;
  @override
  int countMessage(Map<String, Object?> message) => message['content'] == '' ? 0 : 1;
  @override
  int countText(String text) => text.isEmpty ? 0 : 1;
}
