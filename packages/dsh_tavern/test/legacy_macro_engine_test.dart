import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/macros/macro_engine.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/legacy-macro-oracle.json').readAsStringSync()) as Map<String, Object?>;
  final legacyCases = _rows(fixture['legacyCases']);
  final postProcessCases = _rows(fixture['postProcessCases']);

  group('actual fixed ST legacy source oracle', () {
    for (final row in legacyCases) {
      test(row['id']! as String, () => _checkOracle(row, legacy: true));
    }
  });

  group('postProcess uses the actual source call and failure boundaries', () {
    for (final row in postProcessCases) {
      test(row['id']! as String, () {
        _checkOracle(row, legacy: true);
        _checkOracle(row, legacy: false);
      });
    }
  });

  test('adding the legacy engine keeps 46 no-hook new-engine oracle results', () {
    for (final row in legacyCases.where((row) => row.containsKey('modern'))) {
      _checkOracle(row, legacy: false);
    }
  });

  const engine = LegacyMacroEngine();
  MacroContext context({
    Map<String, Object?>? local,
    Map<String, Object?> card = const {},
    bool replaceCharacterCard = true,
    double Function()? random,
  }) => MacroContext(
    localVariables: local,
    userName: 'U',
    charName: 'C',
    card: card,
    replaceCharacterCard: replaceCharacterCard,
    chatId: 'review',
    now: DateTime.utc(2024, 2, 29, 18, 7, 8, 123),
    timeZoneOffset: Duration.zero,
    random: random ?? () => 0.99,
  );

  test('an empty input skips eager card fields and callbacks', () {
    final local = <String, Object?>{'x': 0};
    final c = context(local: local, card: {'personality': '{{incvar::x}}'});
    expect(engine.expand('', c, postProcess: (_) => throw StateError('not called')), '');
    expect(local, {'x': 0});
  });

  test('eager field work repeats on each nonempty expansion but aliases share it', () {
    final local = <String, Object?>{'x': 0};
    final card = <String, Object?>{
      'personality': '{{incvar::x}}',
      'first_mes': '{{incvar::x}}',
      'unknown': {'preserved': true},
    };
    final before = jsonEncode(card);
    final c = context(local: local, card: card);
    expect(engine.expand('plain', c), 'plain');
    expect(local['x'], 2);
    expect(engine.expand('{{personality}}/{{personality}}', c), '3/3');
    expect(local['x'], 4);
    expect(jsonEncode(card), before);
  });

  test('dedicated original is per expansion and does not enter card base calls', () {
    final c = context(card: {'system_prompt': '{{original}}'});
    const text = '{{charPrompt}}|{{original}}|{{original}}';
    expect(engine.expand(text, c, overrides: {'original': 'MAIN'}), '{{original}}|MAIN|');
    expect(engine.expand(text, c, overrides: {'original': 'NEXT'}), '{{original}}|NEXT|');
    // Other raw environment keys retain old Object.assign behavior. The
    // uppercase spelling is an additional constant, not the dedicated input.
    expect(engine.expand('{{original}}/{{original}}', context(), overrides: {'ORIGINAL': 'X'}), 'X/X');
  });

  test('angle group names use group while curly environment keys remain distinct', () {
    final c = MacroContext(
      userName: 'U',
      charName: 'C',
      group: 'A, B',
      groupNotMuted: 'A',
      notChar: 'U, B',
      replaceCharacterCard: false,
    );
    expect(
      engine.expand(
        '<USER>/<BOT>/<CHAR>/<CHARIFNOTGROUP>/<GROUP>/'
        '{{charIfNotGroup}}/{{groupNotMuted}}/{{notChar}}',
        c,
        overrides: {'charIfNotGroup': 'CUSTOM'},
      ),
      'U/C/C/A, B/A, B/CUSTOM/A/U, B',
    );
  });

  test('legacy if text does not suppress random evaluation and dice draws', () {
    var draws = 0;
    final c = context(
      random: () {
        draws++;
        return 0.99;
      },
    );
    expect(engine.expand('{{if false}}{{random::a::b}}{{else}}ok{{/if}}', c), '{{if false}}b{{else}}ok{{/if}}');
    expect(draws, 1);
    expect(engine.expand('{{roll:2d6+1}}/{{roll::1d1}}/{{roll:bad}}', c), '13//');
    expect(draws, 3);
  });

  test('pick never consumes the entropy callback and ignores reroll state', () {
    final c = MacroContext(
      chatId: 'review',
      pickRerollSeed: 'again',
      replaceCharacterCard: false,
      random: () => throw StateError('pick must not use entropy'),
    );
    const text = '{{pick::a::b::c::d::e::f::g::h::i::j}}';
    expect(engine.expand(text, c), 'h');
    expect(engine.expand(text, c), 'h');
  });

  test('zero cached hash falls back only in legacy and keeps the shared context unchanged', () {
    const text = '{{pick::a::b::c::d::e::f::g::h::i::j}}';
    final c = MacroContext(
      chatId: 'review',
      chatIdHash: 0,
      replaceCharacterCard: false,
      random: () => throw StateError('pick must not use entropy'),
    );
    expect(engine.expand(text, c), 'h');
    expect(c.chatId, 'review');
    expect(c.chatIdHash, 0);
    expect(const MacroEngine().expand(text, c), 'a');
    expect(engine.expand(text, c), 'h');
  });

  test('an invalid random callback leaves its whole pass unchanged', () {
    var calls = 0;
    final local = <String, Object?>{};
    final c = context(local: local, random: () => ++calls == 1 ? 0.0 : 1.0);
    expect(
      engine.expand('{{setvar::x::kept}}{{random::a::b}}/{{random::c::d}}', c),
      '{{random::a::b}}/{{random::c::d}}',
    );
    expect(local, {'x': 'kept'});
    expect(calls, 2);
  });

  test('raw legacy values reach the hook before replacement string coercion', () {
    final object = <String, Object?>{'a': '.*'};
    final c = MacroContext(
      localVariables: {'x': object},
      maxContext: 100,
      maxResponse: 20,
      replaceCharacterCard: false,
    );
    final seen = <Object?>[];
    expect(
      engine.expand(
        '{{getvar::x}}/{{maxPrompt}}',
        c,
        postProcess: (value) {
          seen.add(value);
          return value;
        },
      ),
      '[object Object]/80',
    );
    expect(identical(seen[0], object), isTrue);
    expect(seen[1], '80');
    expect(seen[1], isA<String>());
  });

  test('explicit-null swipe marker matters only to legacy absent numeric id', () {
    const modern = MacroEngine();
    const text = '{{currentSwipeId}}';
    for (final (message, legacyValue, newValue) in <(MacroMessage, String, String)>[
      (const MacroMessage(text: 'absent'), 'NaN', ''),
      (const MacroMessage(text: 'null', swipeIdIsNull: true), '', ''),
      (const MacroMessage(text: 'numeric', swipeId: 3, swipeIdIsNull: true), '4', '4'),
    ]) {
      final c = MacroContext(history: [message], replaceCharacterCard: false);
      expect(engine.expand(text, c), legacyValue);
      expect(modern.expand(text, c), newValue);
    }
  });
}

List<Map<String, Object?>> _rows(Object? value) => (value! as List<Object?>).cast<Map<String, Object?>>();

Map<String, Object?> _map(Object? value) => Map<String, Object?>.from(value! as Map<String, Object?>);

void _checkOracle(Map<String, Object?> row, {required bool legacy}) {
  final data = jsonDecode(jsonEncode(row['context'])) as Map<String, Object?>;
  final local = _map(data['local']);
  final global = _map(data['global']);
  final context = MacroContext(
    localVariables: local,
    globalVariables: global,
    card: _map(data['card']),
    replaceCharacterCard: data['replaceCharacterCard']! as bool,
    userName: data['userName']! as String,
    charName: data['charName']! as String,
    persona: data['persona']! as String,
    model: data['model']! as String,
    input: data['input']! as String,
    now: DateTime.parse(data['now']! as String),
    timeZoneOffset: Duration(minutes: data['offsetMinutes']! as int),
    locale: data['locale']! as String,
    maxContext: data['maxContext']! as int,
    maxResponse: data['maxResponse']! as int,
    maxPrompt: data['maxPrompt']! as int,
    chatId: data['chatId']! as String,
    chatIdHash: data['chatIdHash'] as int?,
    original: data['original'] as String?,
    pickRerollSeed: data['pickRerollSeed'],
    preferCharacterPrompt: data['preferCharacterPrompt']! as bool,
    preferCharacterJailbreak: data['preferCharacterJailbreak']! as bool,
    collapseNewlines: data['collapseNewlines']! as bool,
    firstIncludedMessageId: data['firstIncludedMessageId'] as int?,
    firstDisplayedMessageId: data['firstDisplayedMessageId'] as int?,
    lastGenerationType: data['lastGenerationType']! as String,
    outlets: _map(data['outlets']).map((key, value) => MapEntry(key, value! as String)),
    history: _rows(data['history'])
        .map(
          (message) => MacroMessage(
            text: message['mes']! as String,
            isUser: message['is_user'] == true,
            isSystem: message['is_system'] == true,
            swipeId: message['swipe_id'] as int?,
            swipeIdIsNull: message.containsKey('swipe_id') && message['swipe_id'] == null,
            swipeCount: (message['swipes'] as List<Object?>?)?.length,
            sentAt: message['send_date'] is String ? DateTime.parse(message['send_date']! as String) : null,
          ),
        )
        .toList(),
    random: () => (data['random']! as num).toDouble(),
  );
  final config = _map(row['config']);
  final overrides = _map(row['overrides']).map((key, value) => MapEntry(key, value! as String));
  final trace = <Map<String, Object?>>[];
  var hookCalls = 0;
  final hookName = row['hook'] as String?;
  Object? process(Object? value) {
    hookCalls++;
    switch (hookName) {
      case 'regex':
        trace.add({'value': value, 'type': _jsType(value)});
        return _sanitizeForOracle(value);
      case 'throwOnSecond':
        if (hookCalls == 2) throw StateError('deliberate postProcess failure');
        return '[${_hookString(value)}]';
      case 'wrap':
        return '[${_hookString(value)}]';
      case 'null':
        return null;
      case 'object':
        return {'text': '.*'};
      default:
        throw StateError('Unknown fixture hook $hookName');
    }
  }

  final text = row['text']! as String;
  final output = legacy
      ? LegacyMacroEngine(
          instruct: _map(config['instruct']),
          systemPrompt: _map(config['systemPrompt']),
          contextTemplate: _map(config['contextTemplate']),
        ).expand(text, context, overrides: overrides, postProcess: hookName == null ? null : process)
      : const MacroEngine().expand(text, context, overrides: overrides, postProcess: hookName == null ? null : process);
  final key = legacy ? 'legacy' : 'modern';
  final expected = _map(row[key]);
  final reason = '${row['id']} ($key)';
  expect(output, expected['output'], reason: reason);
  expect(local, expected['local'], reason: '$reason local variables');
  expect(global, expected['global'], reason: '$reason global variables');
  if (row.containsKey('calls')) {
    expect(trace, _map(row['calls'])[key], reason: '$reason hook values and types');
  }
}

String _jsType(Object? value) => switch (value) {
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  _ => 'object',
};

// Test callback corresponding to the actual fixed-ST sanitizeRegexMacro. The
// fixture records the macro result before this callback, including raw types.
Object? _sanitizeForOracle(Object? value) {
  if (value is! String || value.isEmpty) return value;
  return value
      .split('')
      .map(
        (character) => switch (character) {
          '\n' => r'\n',
          '\r' => r'\r',
          '\t' => r'\t',
          '\u000b' => r'\v',
          '\f' => r'\f',
          '\u0000' => r'\0',
          _ => r'.^$*+?{}[]\/|()'.contains(character) ? '\\$character' : character,
        },
      )
      .join();
}

String _hookString(Object? value) {
  if (value is num && value.isFinite && value == value.truncateToDouble()) return '${value.toInt()}';
  if (value is Map<String, Object?>) return '[object Object]';
  return '$value';
}
