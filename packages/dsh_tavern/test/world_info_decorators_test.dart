import 'dart:convert';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

late RegexWorker _worker;

void main() {
  setUpAll(() {
    _worker = RegexWorker();
  });
  tearDownAll(() => _worker.close());
  test('unknown decorators follow more than five fallbacks and strip adjacent CRLF', () async {
    final result = await _run(
      '@@unknown\r\n@@@instruct_depth 4\r\n@@@missing_one\r\n@@@missing_two\r\n'
      '@@@missing_three\r\n@@@missing_four\r\n@@@activate\r\n\r\n 文本🐳 \r\n',
      text: 'absent',
    );
    expect(result.beforeText, ' 文本🐳 \r\n');
    expect(result.activated.single.reason, 'decorator-activate');
  });

  test('known decorators ignore fallbacks, activate beats dont, disabled still wins', () async {
    expect((await _run('@@dont_activate\n@@@activate\nbody')).activated, isEmpty);
    expect((await _run('@@dont_activate\n@@activate\nbody', text: 'absent')).beforeText, 'body');
    expect((await _run('@@activate\nbody', enabled: false)).activated, isEmpty);
    expect((await _run('@@activate')).beforeText, isEmpty);
  });

  test('first occurrence wins and invalid values allow a fallback', () async {
    expect((await _run('@@activate_only_after 8\n@@activate_only_after 0\nbody', assistants: 3)).activated, isEmpty);
    expect(
      (await _run('@@activate_only_every 0\n@@@activate\nbody', text: 'absent', assistants: 0)).beforeText,
      'body',
    );
    expect((await _run('@@role invalid\n@@@role assistant\n@@depth 0\nbody')).depths.single.role, 2);
  });

  test('assistant counts, greeting index and asset name are explicit', () async {
    const body = '@@activate_only_after 2\n@@activate_only_every 2\n@@is_greeting 1\n@@is_user_icon pilot\nbody';
    expect((await _run(body, assistants: 4, greeting: 1, icon: 'pilot')).beforeText, 'body');
    expect((await _run(body, assistants: 3, greeting: 1, icon: 'pilot')).activated, isEmpty);
    expect((await _run(body, assistants: 4, greeting: 0, icon: 'pilot')).activated, isEmpty);
    expect((await _run(body, assistants: 4, greeting: 1, icon: 'other')).activated, isEmpty);
    expect(
      (await _run('@@is_greeting 0\n@@@dont_activate\nbody')).activated,
      isEmpty,
      reason: 'Unavailable original greeting permits its supported fallback.',
    );
  });

  test('depth, reverse depth, role and section priorities are explicit', () async {
    final reverse = await _run('@@reverse_depth 2\n@@role user\nbody', count: 5);
    expect(reverse.depths.single.depth, 3);
    expect(reverse.depths.single.role, 1);
    expect((await _run('@@depth -2\n@@reverse_depth 0\nbody', count: 5)).depths.single.depth, 0);
    expect((await _run('@@depth 2.9\nbody', count: 5)).depths.single.depth, 2);
    expect((await _run('@@depth 10001\nbody', count: 5)).depths.single.depth, 5);
    expect((await _run('@@reverse_depth -10001\nbody', count: 5)).depths.single.depth, 5);
    expect(
      (await _run('@@depth 10001\nbody', count: 0)).depths,
      isEmpty,
      reason: 'No history key is present, so this nonconstant entry is not admitted.',
    );
    final section = await _run('@@position before_desc\n@@depth 0\nbody');
    expect(section.depths, isEmpty);
    expect(section.sections['before_desc']!.single.content, 'body');
    final fallback = await _run('@@position scenario\n@@@position after_desc\nbody');
    expect(fallback.sections.containsKey('after_desc'), isTrue);
    expect((await _run('@@position scenario\nbody', scenario: '背景')).sections['scenario']!.single.content, 'body');
    expect(
      (await _run(
        '@@position scenario\n@@@position after_desc\nbody',
        scenario: '背景',
        sections: const {},
      )).sections['after_desc']!.single.content,
      'body',
      reason: 'Nonempty card fields do not imply an enabled prompt slot.',
    );
  });

  test('scan depth controls ordinary and repeated additional keys', () async {
    const body = '@@scan_depth 1\n@@additional_keys red, blue\n@@additional_keys green\nbody';
    expect((await _run(body, text: 'key blue green')).beforeText, 'body');
    expect((await _run(body, text: 'key blue')).activated, isEmpty);
    expect(
      (await _run(
        '@@scan_depth 1\nbody',
        messages: const [WorldInfoMessage('key'), WorldInfoMessage('other')],
      )).activated,
      isEmpty,
    );
    expect(
      (await _run(
        '@@scan_depth 2\nbody',
        messages: const [WorldInfoMessage('key'), WorldInfoMessage('other')],
      )).beforeText,
      'body',
    );
    expect((await _run('@@exclude_keys red,blue\nbody', text: 'key blue')).activated, isEmpty);
  });

  test('assistant prefill requires explicit V3 role and raw depth zero before clamping', () async {
    for (final value in [
      ('@@depth 0\n@@role assistant', true),
      ('@@depth 0.0\n@@role assistant', true),
      ('@@reverse_depth 2\n@@role assistant', true),
      ('@@depth 0\n@@reverse_depth 1\n@@role assistant', true),
      ('@@depth -1\n@@role assistant', false),
      ('@@depth 0.5\n@@role assistant', false),
      ('@@reverse_depth 3\n@@role assistant', false),
      ('@@reverse_depth 1.5\n@@role assistant', false),
      ('@@depth 1\n@@reverse_depth 2\n@@role assistant', false),
      ('@@position before_desc\n@@depth 0\n@@role assistant', false),
      ('@@depth 0\n@@role user', false),
    ]) {
      final hit = (await _run('${value.$1}\nbody', count: 2, constant: true)).activated.single;
      expect(hit.assistantPrefill, value.$2, reason: value.$1);
      expect(hit.withContent('post-processed').assistantPrefill, value.$2, reason: value.$1);
    }
    const native = <String, Object?>{'position': 4, 'depth': 0, 'role': 2};
    for (final content in ['body', '@@role assistant\nbody', '@@depth 0\nbody']) {
      final hit = (await _run(content, count: 2, constant: true, extensions: native)).activated.single;
      expect(hit.depth, 0);
      expect(hit.role, 2);
      expect(hit.assistantPrefill, isFalse, reason: content);
      expect(hit.withContent('post-processed').assistantPrefill, isFalse, reason: content);
    }
  });

  test('V3 regex keys reject any invalid pattern and ignore exclude keys', () async {
    expect(
      (await _run('@@additional_keys b.+e\n@@exclude_keys blue\nbody', text: 'key blue', useRegex: true)).beforeText,
      'body',
    );
    expect((await _run('@@additional_keys blue,[\nbody', text: 'key blue', useRegex: true)).activated, isEmpty);
    expect((await _run('body', text: 'key', keys: ['key', '['], useRegex: true)).activated, isEmpty);
    expect((await _run('body', text: 'KEY', useRegex: true, caseSensitive: true)).activated, isEmpty);
    expect((await _run('body', text: 'KEY', useRegex: true)).beforeText, 'body');
    expect((await _run('body', text: 'KEY', keys: ['/key/i'], useRegex: true, caseSensitive: true)).beforeText, 'body');
    expect((await _run('@@additional_keys /blue/i\nbody', text: 'key BLUE', useRegex: true)).beforeText, 'body');
    expect((await _run('body', text: 'key', keys: ['key', '/key/invalid'], useRegex: true)).activated, isEmpty);
    expect(
      (await _run('body', text: 'key', keys: ['/key/y'], useRegex: true)).activated,
      isEmpty,
      reason: 'The native scan buffer begins with its U+0001 separator; sticky matching cannot skip it.',
    );
  });

  test('keep and dont-after require two prior admissions and do not double count retries', () async {
    const keep = '@@keep_activate_after_match\nbody';
    final first = await _run(keep, count: 1);
    final retry = await _run(keep, count: 1, state: first.decoratorState);
    expect(jsonEncode(retry.decoratorState), jsonEncode(first.decoratorState));
    expect((await _run(keep, count: 2, text: 'absent', state: first.decoratorState)).activated, isEmpty);
    final second = await _run(keep, count: 2, state: first.decoratorState);
    expect(
      (await _run(keep, count: 3, text: 'absent', state: second.decoratorState)).activated.single.reason,
      'decorator-keep',
    );
    expect((await _run('$keep changed', count: 3, text: 'absent', state: second.decoratorState)).activated, isEmpty);
    const stop = '@@dont_activate_after_match\nbody';
    final a = await _run(stop, count: 1);
    final b = await _run(stop, count: 2, state: a.decoratorState);
    expect((await _run(stop, count: 3, state: b.decoratorState)).activated, isEmpty);
    final preview = await _run(keep, count: 3, state: first.decoratorState, dryRun: true);
    expect(jsonEncode(preview.decoratorState), jsonEncode(first.decoratorState));
  });

  test('V3 regex mode ignores constant and validates all primary patterns', () async {
    expect((await _run('body', constant: true, useRegex: true, keys: ['['])).activated, isEmpty);
    expect((await _run('body', constant: true, useRegex: true, text: 'absent')).activated, isEmpty);
    expect((await _run('body', constant: true, useRegex: true)).beforeText, 'body');
    expect(
      (await _run('body', constant: true, text: 'absent')).beforeText,
      'body',
      reason: 'Ordinary nonregex constant entries keep their native activation path.',
    );
  });

  test('capacity and UI prompt decorators expose explicit decisions', () async {
    const body = '@@ignore_on_max_context\n@@disable_ui_prompt system_prompt\nbody';
    expect((await _run(body, capacity: true)).activated, isEmpty);
    final room = await _run(body, capacity: false);
    expect(room.activated.single.ignoreOnMaxContext, isTrue);
    expect(room.disabledUiPrompts, {'system_prompt'});
    expect((await _run(body)).activated.single.ignoreOnMaxContext, isFalse);
    expect((await _run('@@disable_ui_prompt post_history_instructions\nbody')).disabledUiPrompts, {
      'post_history_instructions',
    });
  });

  test('sticky validates regex syntax while force decorators keep their declared override', () async {
    for (final key in ['[', 'absent']) {
      final book = WorldInfoBook.fromJson(
        id: 'v3',
        source: WorldInfoSource.character,
        json: {
          'entries': [
            {
              'id': 0,
              'keys': [key],
              'enabled': true,
              'use_regex': true,
              'insertion_order': 100,
              'content': 'body',
              'extensions': {'sticky': 3},
            },
          ],
        },
      );
      final result = await WorldInfoEngine(worker: _worker).evaluate(
        WorldInfoInput(
          books: [book],
          messages: const [WorldInfoMessage('key')],
          maxContext: 10000,
          tokenCount: (value) => value.length,
          random: () => throw StateError('Unexpected draw'),
          timedWorldInfo: {
            'sticky': {
              'v3.0': {'hash': book.entries.single.stHash, 'start': 0, 'end': 3, 'protected': false},
            },
          },
        ),
      );
      expect(result.activated.map((hit) => hit.reason).toList(), key == '[' ? <String>[] : ['sticky']);
    }
    final calls = <String>[];
    final forced = await _run(
      '@@activate\n@@additional_keys [\nbody',
      keys: ['['],
      useRegex: true,
      expand: (value) {
        calls.add(value);
        return value;
      },
    );
    expect(forced.beforeText, 'body');
    expect(calls, ['body'], reason: 'The explicit IN ANY CASE policy does not evaluate skipped key macros.');
  });

  test('optional admission refinalization retains timer array persistence semantics', () async {
    final book = WorldInfoBook.fromJson(
      id: 'v3',
      source: WorldInfoSource.character,
      json: {
        'entries': [
          {
            'id': 0,
            'keys': <Object?>[],
            'enabled': true,
            'constant': true,
            'insertion_order': 100,
            'content': '@@ignore_on_max_context\nbody',
            'extensions': {'sticky': 3},
          },
        ],
      },
    );
    final inputState = <String, Object?>{'sticky': <Object?>[], 'cooldown': <Object?>[]};
    final result = await WorldInfoEngine(worker: _worker).evaluate(
      WorldInfoInput(
        books: [book],
        messages: const [WorldInfoMessage('key')],
        maxContext: 10000,
        tokenCount: (value) => value.length,
        random: () => throw StateError('Unexpected draw'),
        timedWorldInfo: inputState,
        contextAtCapacity: false,
      ),
    );
    expect(result.activated, hasLength(1));
    expect(result.timedWorldInfo, inputState);
    final removed = result.withoutEntries({('v3', '0')});
    expect(removed.activated, isEmpty);
    expect(removed.timedWorldInfo, inputState);
    expect(removed.decoratorState, isEmpty);
    expect(inputState, {'sticky': <Object?>[], 'cooldown': <Object?>[]});
  });

  test('full prompt exclusions remove new admissions without repeating the scan or side effects', () async {
    final book = WorldInfoBook.fromJson(
      id: 'v3',
      source: WorldInfoSource.character,
      json: {
        'entries': [
          for (var id = 0; id < 2; id++)
            {
              'id': id,
              'keys': <Object?>[],
              'enabled': true,
              'constant': true,
              'insertion_order': 100 - id,
              'position': 'before_char',
              'content': '${id == 0 ? '@@ignore_on_max_context\n' : ''}entry-$id',
              'extensions': {'sticky': 3, 'cooldown': 2, 'probability': 50, 'use_probability': true},
            },
        ],
      },
    );
    var expansions = 0;
    var draws = 0;
    final result = await WorldInfoEngine(worker: _worker).evaluate(
      WorldInfoInput(
        books: [book],
        messages: const [WorldInfoMessage('key')],
        maxContext: 10000,
        tokenCount: (value) => value.length,
        contextAtCapacity: false,
        random: () {
          draws++;
          return 0.25;
        },
        expand: (value) {
          expansions++;
          return value;
        },
        timedWorldInfo: const {
          'sticky': {
            'gone.9': {'hash': 9, 'start': 0, 'end': 1, 'protected': false},
          },
        },
      ),
    );
    expect(result.activated, hasLength(2));
    expect(draws, 2);
    final calls = expansions;
    final retained = result.withoutEntries({('v3', '0')});
    expect(retained.activated.single.uid, '1');
    for (final type in ['sticky', 'cooldown']) {
      expect((retained.timedWorldInfo[type]! as Map<String, Object?>).keys, ['v3.1']);
    }
    expect(retained.decoratorState.keys, ['${book.entries[1].stHash}']);
    expect(draws, 2);
    expect(expansions, calls);
    expect(result.activated, hasLength(2));
    expect((result.timedWorldInfo['sticky']! as Map<String, Object?>).keys, ['v3.0', 'v3.1']);
  });

  test('section placement overrides a native depth before world-info regex sees it', () async {
    final book = WorldInfoBook.fromJson(
      id: 'section',
      source: WorldInfoSource.character,
      json: {
        'entries': [
          {
            'id': 0,
            'keys': <Object?>[],
            'constant': true,
            'enabled': true,
            'insertion_order': 100,
            'content': '@@position scenario\nX',
            'extensions': {'position': 4, 'depth': 3},
          },
        ],
      },
    );
    final observed = <int?>[];
    final result = await WorldInfoEngine(worker: _worker).evaluate(
      WorldInfoInput(
        books: [book],
        messages: const [WorldInfoMessage('key')],
        maxContext: 10000,
        tokenCount: (value) => value.length,
        random: () => throw StateError('Unexpected draw'),
        scenario: 'Scene',
        availablePromptSections: const {'scenario'},
        postProcessContent: (entry, content, depth) {
          observed.add(depth);
          return '$content!';
        },
      ),
    );
    expect(observed, [null]);
    expect(result.depths, isEmpty);
    expect(result.sections['scenario']!.single.content, 'X!');
  });
}

Future<WorldInfoResult> _run(
  String content, {
  String text = 'key',
  int count = 1,
  List<WorldInfoMessage>? messages,
  bool enabled = true,
  int? assistants,
  int? greeting,
  String? icon,
  String scenario = '',
  Map<String, Object?> state = const {},
  bool dryRun = false,
  bool? capacity,
  bool useRegex = false,
  bool constant = false,
  bool caseSensitive = false,
  List<String> keys = const ['key'],
  Set<String>? sections,
  String Function(String)? expand,
  Map<String, Object?> extensions = const {},
}) {
  final book = WorldInfoBook.fromJson(
    id: 'v3',
    source: WorldInfoSource.character,
    json: {
      'entries': [
        {
          'id': 0,
          'keys': keys,
          'content': content,
          'enabled': enabled,
          'insertion_order': 100,
          'position': 'before_char',
          'use_regex': useRegex,
          if (constant) 'constant': true,
          'case_sensitive': caseSensitive,
          'extensions': extensions,
        },
      ],
    },
  );
  return WorldInfoEngine(worker: _worker).evaluate(
    WorldInfoInput(
      books: [book],
      messages: messages ?? [for (var i = 0; i < count; i++) WorldInfoMessage(text)],
      maxContext: 10000,
      tokenCount: (value) => value.length,
      random: () => throw StateError('Unexpected random draw'),
      settings: const WorldInfoSettings(scanDepth: 100),
      assistantMessageCount: assistants,
      greetingIndex: greeting,
      userIconName: icon,
      scenario: scenario,
      decoratorState: state,
      dryRun: dryRun,
      contextAtCapacity: capacity,
      availablePromptSections: sections,
      expand: expand ?? (value) => value,
    ),
  );
}
