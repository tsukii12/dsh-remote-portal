import 'dart:convert';

import 'package:dsh_tavern/src/story/story_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

Json _act(String id, {Object? when = false, int minTurns = 0, int? maxTurns}) => {
  'id': id,
  'when': when,
  'minTurns': minTurns,
  'maxTurns': ?maxTurns,
};

Json _ending(String id, {Object? when = true, String? title}) => {
  'id': id,
  'title': title ?? 'Ending $id',
  'when': when,
};

StoryDefinition _definition({List<Json>? acts, List<Json> endings = const []}) => StoryDefinition.parse({
  'acts': acts ?? [_act('a')],
  'endings': endings,
});

StoryResult _turn(
  StoryDefinition definition, {
  Object? state = const <String, Object?>{},
  Object? runtime,
  bool? runtimeExists,
  String invocation = 'turn-1',
  bool countTurn = true,
}) => definition.settle(
  state: state,
  runtimeExists: runtimeExists ?? runtime != null,
  runtime: runtime,
  invocationId: invocation,
  countTurn: countTurn,
);

Json _saved(StoryResult result) => result.runtime! as Json;
List<Object?> _codes(List<Json> issues) => issues.map((issue) => issue['code']).toList();

void main() {
  test('missing story is a detached no-op without runtime initialization', () {
    final definition = StoryDefinition.parse(null);
    final before = definition.inspect(runtimeExists: false);
    expect(before.defined, isFalse);
    expect(before.executable, isFalse);
    expect(before.initialized, isFalse);
    expect(before.valid, isTrue);
    final result = _turn(definition, state: Object());
    expect(result.runtimeExists, isFalse);
    expect(result.initialized, isFalse);
    expect(result.changed, isFalse);
    expect(result.effects, isEmpty);
  });

  test('parse and inspect compile a dormant condition without evaluating it', () {
    final definition = _definition(
      endings: [
        _ending(
          'unsafe-domain',
          when: {
            '/': [1, 0],
          },
        ),
      ],
    );
    expect(definition.executable, isTrue);
    expect(definition.issues, isEmpty);
    final read = definition.inspect(runtimeExists: false);
    expect(read.valid, isTrue);
    expect(read.initialized, isFalse);
    expect(read.unlockedEndings, isEmpty);
    final result = _turn(definition);
    expect(result.valid, isFalse);
    expect(result.runtimeExists, isFalse);
    expect(result.effects, isEmpty);
    expect(_codes(result.issues), contains('story_condition'));
  });

  test('initial preview shows declared first-act progress without running true conditions', () {
    final raw = <String, Object?>{
      'outline': 'private',
      'acts': [
        {..._act('first', when: true), 'title': 'First', 'goal': 'Wait for a real turn'},
        _act('second'),
      ],
      'tension': [2, 5],
      'endings': [_ending('would-unlock')],
    };
    final definition = StoryDefinition.parse(raw);
    final preview = definition.inspect(runtimeExists: false);
    expect(preview.initialized, isFalse);
    expect(preview.valid, isTrue);
    expect(preview.currentActId, 'first');
    expect(preview.currentActIndex, 0);
    expect(preview.actTurns, 0);
    expect(preview.completed, isFalse);
    expect(preview.currentAct!['goal'], 'Wait for a real turn');
    expect(preview.currentAct!['tension'], 2);
    expect(preview.unlockedEndings, isEmpty);
    expect(_turn(definition, countTurn: false).runtimeExists, isFalse);
    final noActs = _definition(acts: [], endings: [_ending('e')]).inspect(runtimeExists: false);
    expect(noActs.completed, isTrue);
    expect(noActs.currentActId, isNull);
    expect(noActs.actTurns, 0);
    expect(noActs.unlockedEndings, isEmpty);
    expect(noActs.initialized, isFalse);
  });

  test('definition JSON accepts exactly one MiB and preserves an oversized declaration', () {
    const limit = 1024 * 1024;
    final overhead = utf8.encode(jsonEncode({'outline': ''})).length;
    final outline = ''.padRight(limit - overhead, 'a');
    final exact = <String, Object?>{'outline': outline};
    expect(utf8.encode(jsonEncode(exact)), hasLength(limit));
    expect(StoryDefinition.parse(exact).executable, isTrue);
    final oversized = <String, Object?>{'outline': '${outline}b'};
    final rejected = StoryDefinition.parse(oversized);
    expect(rejected.executable, isFalse);
    expect(_codes(rejected.issues), contains('story_definition_limit'));
    expect(rejected.raw, oversized);
    expect(_turn(rejected).runtimeExists, isFalse);
  });

  test('definition size counts UTF-8 bytes instead of Dart string code units', () {
    const limit = 1024 * 1024;
    final overhead = utf8.encode(jsonEncode({'outline': ''})).length;
    final text = List.filled((limit - overhead) ~/ 3, '界').join();
    final exactText = '$text${''.padRight(limit - overhead - utf8.encode(text).length)}';
    final exact = <String, Object?>{'outline': exactText};
    expect(utf8.encode(jsonEncode(exact)), hasLength(limit));
    expect(jsonEncode(exact).length, lessThan(limit));
    expect(StoryDefinition.parse(exact).executable, isTrue);
    final rejected = StoryDefinition.parse({'outline': '$exactText界'});
    expect(_codes(rejected.issues), contains('story_definition_limit'));
    expect(rejected.executable, isFalse);
  });

  test('acts and endings independently accept 256 and reject 257 before execution', () {
    for (final name in ['acts', 'endings']) {
      final declarations = <Json>[
        for (var i = 0; i < 256; i++) name == 'acts' ? _act('a$i') : _ending('e$i', when: false),
      ];
      final exact = StoryDefinition.parse({name: declarations});
      expect(exact.executable, isTrue, reason: name);
      final oversized = <String, Object?>{
        name: [...declarations, name == 'acts' ? _act('extra') : _ending('extra')],
      };
      final rejected = StoryDefinition.parse(oversized);
      expect(rejected.executable, isFalse, reason: name);
      expect(rejected.issues.single['code'], 'story_declaration_limit');
      expect(rejected.issues.single['path'], '/$name');
      expect(rejected.raw, oversized);
      expect(_turn(rejected).runtimeExists, isFalse);
    }
  });

  test('unsupported operators are rejected even in a dormant branch', () {
    final raw = {
      'acts': [
        _act(
          'a',
          when: {
            'if': [
              false,
              {'hostCode': 'run'},
              true,
            ],
          },
        ),
      ],
    };
    final definition = StoryDefinition.parse(raw);
    expect(definition.executable, isFalse);
    expect(_codes(definition.issues), contains('story_condition'));
    expect(definition.issues.single['path'], '/acts/0/when');
    expect(definition.raw, raw);
    expect(_turn(definition).changed, isFalse);
  });

  test('unknown annotations are preserved and canonical fingerprints ignore object key order', () {
    final annotation = <String, Object?>{
      'nested': <Object?>[1, '{{literal}}'],
    };
    final raw = <String, Object?>{
      'acts': [_act('a')],
      'author': annotation,
    };
    final definition = StoryDefinition.parse(raw);
    final reordered = StoryDefinition.parse({
      'author': annotation,
      'acts': [_act('a')],
    });
    expect(definition.executable, isTrue);
    expect(definition.fingerprint, reordered.fingerprint);
    expect(definition.issues.single['kind'], 'unknown');
    (annotation['nested']! as List<Object?>).add('caller change');
    expect((definition.raw! as Json)['author'], {
      'nested': [1, '{{literal}}'],
    });
    final copy = definition.raw! as Json;
    (copy['author']! as Json)['nested'] = 'getter change';
    expect((definition.raw! as Json)['author'], {
      'nested': [1, '{{literal}}'],
    });
    expect(StoryDefinition.parse(raw).fingerprint, isNot(definition.fingerprint));
  });

  test('invalid declaration shapes and future versions remain non-executable', () {
    final values = <Object?>[
      false,
      [],
      {'acts': null},
      {
        'acts': [null],
      },
      {
        'acts': [_act('')],
      },
      {
        'acts': [
          {..._act('a'), 'title': 3},
        ],
      },
      {'endings': null},
      {
        'endings': [null],
      },
      {
        'endings': [
          {'id': 'e', 'title': 'E'},
        ],
      },
      {
        'endings': [_ending('e', title: '')],
      },
      {'outline': null},
    ];
    for (final raw in values) {
      final definition = StoryDefinition.parse(raw);
      expect(definition.defined, isTrue, reason: '$raw');
      expect(definition.executable, isFalse, reason: '$raw');
      expect(definition.raw, raw);
      expect(_turn(definition).changed, isFalse);
    }
    for (final version in <Object?>[null, 2, '1']) {
      final definition = StoryDefinition.parse({
        'acts': [_act('a')],
      }, version: version);
      expect(_codes(definition.issues), contains('story_version'));
      expect(definition.executable, isFalse);
    }
  });

  test('duplicate act or ending identities disable the complete definition', () {
    final acts = _definition(acts: [_act('same'), _act('same')]);
    final endings = _definition(endings: [_ending('same'), _ending('same')]);
    expect(_codes(acts.issues), contains('story_act_id'));
    expect(_codes(endings.issues), contains('story_ending_id'));
    for (final definition in [acts, endings]) {
      expect(definition.executable, isFalse);
      expect(_turn(definition).effects, isEmpty);
      expect(_turn(definition).runtimeExists, isFalse);
    }
  });

  test('tension is one finite advisory number per act with no invented range', () {
    final definition = StoryDefinition.parse({
      'outline': '{{private outline}}',
      'acts': [_act('a'), _act('b')],
      'tension': [-3, 12.5],
    });
    expect(definition.executable, isTrue);
    expect(definition.outline, '{{private outline}}');
    expect(definition.tension, [-3, 12.5]);
    definition.tension!.clear();
    final current = _turn(definition).snapshot.currentAct!;
    expect(current['tension'], -3);
    expect(current['title'], '');
    expect(current['goal'], '');
    expect(current.containsKey('outline'), isFalse);
    for (final value in <Object?>[
      null,
      [1],
      [1, '2'],
      [1, double.infinity],
    ]) {
      final bad = StoryDefinition.parse({
        'acts': [_act('a'), _act('b')],
        'tension': value,
      });
      expect(bad.executable, isFalse);
    }
  });

  test('minimum counts committed invocations before allowing a true condition', () {
    final definition = _definition(acts: [_act('a', when: true, minTurns: 2), _act('b', when: true)]);
    final first = _turn(definition);
    expect(first.snapshot.currentActId, 'a');
    expect(first.snapshot.actTurns, 1);
    expect(first.effects, isEmpty);
    final second = _turn(definition, runtime: first.runtime, invocation: 'turn-2');
    expect(second.snapshot.currentActId, 'b');
    expect(second.snapshot.currentActIndex, 1);
    expect(second.snapshot.actTurns, 0);
    expect(second.snapshot.completed, isFalse);
    expect(second.effects.single['reason'], 'condition');
    expect(second.effects.single['fromActId'], 'a');
    expect(second.effects.single['toActId'], 'b');
    expect(first.snapshot.currentActId, 'a');
  });

  test('maximum forces at its boundary despite a false condition', () {
    final definition = _definition(acts: [_act('a', minTurns: 1, maxTurns: 3), _act('b')]);
    final first = _turn(definition);
    final second = _turn(definition, runtime: first.runtime, invocation: 'turn-2');
    expect(second.snapshot.currentActId, 'a');
    expect(second.snapshot.actTurns, 2);
    final third = _turn(definition, runtime: second.runtime, invocation: 'turn-3');
    expect(third.snapshot.currentActId, 'b');
    expect(third.snapshot.actTurns, 0);
    expect(third.effects.single['reason'], 'maximum');
  });

  test('contradictory or noninteger turn bounds cannot bypass the minimum', () {
    for (final bounds in <Json>[
      {'minTurns': 3, 'maxTurns': 2},
      {'minTurns': -1},
      {'maxTurns': null},
      {'minTurns': 1.5},
      {'maxTurns': true},
    ]) {
      final definition = StoryDefinition.parse({
        'acts': [
          {..._act('a'), ...bounds},
        ],
      });
      expect(definition.executable, isFalse, reason: '$bounds');
      expect(_codes(definition.issues), contains('story_act_turns'));
    }
  });

  test('zero maximum waits for a real counted invocation and advances only one act', () {
    final definition = _definition(acts: [_act('a', maxTurns: 0), _act('b', maxTurns: 0), _act('c')]);
    final read = definition.inspect(runtimeExists: false);
    expect(read.initialized, isFalse);
    expect(_turn(definition, countTurn: false).runtimeExists, isFalse);
    final result = _turn(definition);
    expect(result.snapshot.currentActId, 'b');
    expect(result.snapshot.actTurns, 0);
    expect(result.effects, hasLength(1));
  });

  test('last act retains its final progress and does not keep incrementing after completion', () {
    final definition = _definition(acts: [_act('last', when: true)]);
    final first = _turn(definition);
    expect(first.snapshot.completed, isTrue);
    expect(first.snapshot.currentActId, 'last');
    expect(first.snapshot.actTurns, 1);
    expect(first.effects.single['toActId'], isNull);
    final later = _turn(definition, runtime: first.runtime, invocation: 'turn-2');
    expect(later.snapshot.completed, isTrue);
    expect(later.snapshot.actTurns, 1);
    expect(later.effects, isEmpty);
    expect(_saved(later)['lastInvocationId'], 'turn-2');
  });

  test('noncounting settlement neither initializes nor evaluates conditions', () {
    final definition = _definition(
      endings: [
        _ending(
          'bad',
          when: {
            '/': [1, 0],
          },
        ),
      ],
    );
    final quiet = _turn(definition, countTurn: false, invocation: '', state: double.infinity);
    expect(quiet.valid, isTrue);
    expect(quiet.runtimeExists, isFalse);
    expect(quiet.effects, isEmpty);
    expect(quiet.issues, isEmpty);
    final normal = _definition();
    final first = _turn(normal);
    final unchanged = _turn(normal, runtime: first.runtime, countTurn: false, invocation: 'turn-2');
    expect(unchanged.runtime, first.runtime);
    expect(unchanged.changed, isFalse);
    expect(unchanged.changes, isEmpty);
  });

  test('same invocation is idempotent even when a caller supplies different condition data', () {
    final definition = _definition(
      endings: [
        _ending('e', when: {'var': 'ready'}),
      ],
    );
    final first = _turn(definition, state: {'ready': false});
    final duplicate = _turn(definition, state: {'ready': true}, runtime: first.runtime);
    expect(duplicate.runtime, first.runtime);
    expect(duplicate.effects, isEmpty);
    expect(duplicate.changed, isFalse);
    expect(duplicate.initialized, isFalse);
    expect(duplicate.snapshot.actTurns, 1);
  });

  test('different invocations continue a node while sibling candidates stay independent', () {
    final definition = _definition(
      endings: [
        _ending('e', when: {'var': 'ready'}),
      ],
    );
    final parent = _turn(definition);
    final baseline = jsonEncode(parent.runtime);
    final branchA = _turn(definition, runtime: parent.runtime, invocation: 'branch-a', state: {'ready': true});
    final branchB = _turn(definition, runtime: parent.runtime, invocation: 'branch-b', state: {'ready': false});
    expect(branchA.snapshot.actTurns, 2);
    expect(branchB.snapshot.actTurns, 2);
    expect(branchA.snapshot.unlockedEndings, ['e']);
    expect(branchB.snapshot.unlockedEndings, isEmpty);
    expect(jsonEncode(parent.runtime), baseline);
    final continued = _turn(definition, runtime: branchA.runtime, invocation: 'continue-a', state: {'ready': true});
    expect(continued.snapshot.actTurns, 3);
    expect(continued.effects, isEmpty);
    expect(continued.snapshot.unlockedEndings, ['e']);
  });

  test('conditions use JsonLogic truthiness for numbers strings lists and objects', () {
    final cases = <(Object?, bool)>[
      (0, false),
      (2, true),
      ('', false),
      ('false', true),
      (<Object?>[], false),
      (<Object?>[false], true),
      (<String, Object?>{}, true),
      (null, false),
    ];
    for (final (value, expected) in cases) {
      final definition = _definition(
        acts: [
          _act('a', when: {'var': 'value'}),
        ],
      );
      final result = _turn(definition, state: {'value': value});
      expect(result.snapshot.completed, expected, reason: '$value');
      expect(result.valid, isTrue);
    }
  });

  test('conditions read the supplied final DSH value without modifying it', () {
    final state = <String, Object?>{
      'nested': <String, Object?>{'score': 7},
      'local': 'untouched',
    };
    final original = jsonEncode(state);
    final definition = _definition(
      acts: [
        _act(
          'a',
          when: {
            '>=': [
              {'var': 'nested.score'},
              7,
            ],
          },
        ),
      ],
      endings: [
        _ending(
          'e',
          when: {
            '===': [
              {'var': 'nested.score'},
              7,
            ],
          },
        ),
      ],
    );
    final result = _turn(definition, state: state);
    expect(result.snapshot.completed, isTrue);
    expect(result.snapshot.unlockedEndings, ['e']);
    expect(jsonEncode(state), original);
    expect(_saved(result).containsKey('nested'), isFalse);
  });

  test('a runtime condition error discards earlier chapter and ending candidates', () {
    final definition = _definition(
      acts: [_act('a', when: true), _act('b')],
      endings: [
        _ending('first'),
        _ending(
          'bad',
          when: {
            '/': [
              1,
              {'var': 'denominator'},
            ],
          },
        ),
      ],
    );
    final failed = _turn(definition, state: {'denominator': 0});
    expect(failed.valid, isFalse);
    expect(failed.runtimeExists, isFalse);
    expect(failed.runtime, isNull);
    expect(failed.changes, isEmpty);
    expect(failed.effects, isEmpty);
    expect(failed.issues.single['path'], '/endings/1/when');
    final recovered = _turn(definition, state: {'denominator': 1});
    expect(recovered.valid, isTrue);
    expect(recovered.snapshot.currentActId, 'b');
    expect(recovered.snapshot.unlockedEndings, ['first', 'bad']);
  });

  test('runtime condition failure preserves an existing snapshot byte for JSON value', () {
    final definition = _definition(
      endings: [
        _ending(
          'e',
          when: {
            '/': [
              1,
              {'var': 'd'},
            ],
          },
        ),
      ],
    );
    final first = _turn(definition, state: {'d': 1});
    final raw = _saved(first)..['unlockedEndings'] = <String>[];
    raw['custom'] = <String, Object?>{
      'keep': <Object?>[null, 4],
    };
    final encoded = jsonEncode(raw);
    final failure = _turn(definition, runtime: raw, invocation: 'turn-2', state: {'d': 0});
    expect(failure.valid, isFalse);
    expect(failure.changed, isFalse);
    expect(jsonEncode(failure.runtime), encoded);
    expect(jsonEncode(raw), encoded);
  });

  test('empty invocation and nonfinite final data cannot initialize or advance', () {
    final definition = _definition();
    final missingId = _turn(definition, invocation: '  ');
    expect(_codes(missingId.issues), contains('story_invocation'));
    expect(missingId.runtimeExists, isFalse);
    final first = _turn(definition);
    final badData = _turn(definition, runtime: first.runtime, invocation: 'turn-2', state: {'bad': double.nan});
    expect(_codes(badData.issues), contains('story_state'));
    expect(badData.runtime, first.runtime);
    expect(badData.effects, isEmpty);
  });

  test('maximum can advance without evaluating an unnecessary invalid-domain condition', () {
    final definition = _definition(
      acts: [
        _act(
          'a',
          when: {
            '/': [1, 0],
          },
          maxTurns: 1,
        ),
      ],
    );
    final result = _turn(definition);
    expect(result.valid, isTrue);
    expect(result.snapshot.completed, isTrue);
    expect(result.effects.single['reason'], 'maximum');
  });

  test('conditions below the minimum are dormant and a later failure keeps prior progress', () {
    final definition = _definition(
      acts: [
        _act(
          'a',
          when: {
            '/': [1, 0],
          },
          minTurns: 2,
        ),
      ],
    );
    final first = _turn(definition);
    expect(first.valid, isTrue);
    expect(first.snapshot.actTurns, 1);
    final second = _turn(definition, runtime: first.runtime, invocation: 'turn-2');
    expect(second.valid, isFalse);
    expect(second.runtime, first.runtime);
    expect(second.effects, isEmpty);
    expect(second.changed, isFalse);
  });

  test('empty acts allow condition endings but do not invent a current act', () {
    final definition = _definition(acts: [], endings: [_ending('e')]);
    final result = _turn(definition, state: null);
    expect(result.valid, isTrue);
    expect(result.initialized, isTrue);
    expect(result.snapshot.completed, isTrue);
    expect(result.snapshot.currentActId, isNull);
    expect(result.snapshot.currentActIndex, isNull);
    expect(result.snapshot.actTurns, 0);
    expect(result.snapshot.unlockedEndings, ['e']);
    expect(result.effects.single['type'], 'unlock');
  });

  test('all satisfied endings unlock once in declaration order and retain action ids', () {
    final definition = _definition(
      endings: [
        _ending('z'),
        _ending('a'),
        _ending('later', when: {'var': 'later'}),
      ],
    );
    final first = _turn(definition);
    expect(first.snapshot.unlockedEndings, ['z', 'a']);
    expect(first.effects.map((effect) => effect['id']), ['z', 'a']);
    expect(first.effects.map((effect) => effect['effectId']), ['turn-1:story:0', 'turn-1:story:1']);
    final next = _turn(definition, runtime: first.runtime, invocation: 'turn-2', state: {'later': true});
    expect(next.snapshot.unlockedEndings, ['z', 'a', 'later']);
    expect(next.effects.single['id'], 'later');
    expect(next.effects.single['effectId'], 'turn-2:story:0');
    expect(next.effects.single['kind'], 'ending');
  });

  test('an ending may unlock after the final act and its title is literal data', () {
    final title = '{{setvar::x::9}} <script>text</script>';
    final definition = _definition(
      acts: [_act('last', when: true)],
      endings: [
        _ending('e', title: title, when: {'var': 'ready'}),
      ],
    );
    final first = _turn(definition);
    final next = _turn(definition, runtime: first.runtime, invocation: 'turn-2', state: {'ready': true});
    expect(next.snapshot.completed, isTrue);
    expect(next.snapshot.actTurns, 1);
    expect(next.effects.single['title'], title);
    expect(next.effects.single['id'], 'e');
    expect(_saved(next).containsKey('variables'), isFalse);
  });

  test('explicit null runtime is preserved as invalid instead of initialized', () {
    final definition = _definition(endings: [_ending('e')]);
    final read = definition.inspect(runtimeExists: true, runtime: null);
    expect(read.initialized, isTrue);
    expect(read.valid, isFalse);
    expect(_codes(read.issues), contains('story_runtime_shape'));
    final result = _turn(definition, runtimeExists: true);
    expect(result.runtimeExists, isTrue);
    expect(result.runtime, isNull);
    expect(result.changed, isFalse);
    expect(result.initialized, isFalse);
    expect(result.effects, isEmpty);
  });

  test('future runtime and unknown annotations are retained without clearing the ledger', () {
    final definition = _definition(endings: [_ending('e')]);
    final raw = _saved(_turn(definition))
      ..['version'] = 2
      ..['future'] = <String, Object?>{'preserve': true};
    final encoded = jsonEncode(raw);
    final read = definition.inspect(runtimeExists: true, runtime: raw);
    expect(read.valid, isFalse);
    expect(_codes(read.issues), contains('story_runtime_version'));
    final result = _turn(definition, runtime: raw, invocation: 'turn-2');
    expect(jsonEncode(result.runtime), encoded);
    expect(result.changed, isFalse);
    expect(result.effects, isEmpty);
    expect(jsonEncode(raw), encoded);
  });

  test('malformed required runtime fields remain read-only', () {
    final definition = _definition(acts: [_act('a'), _act('b')], endings: [_ending('e')]);
    final first = _turn(definition);
    final corruptions = <Json>[
      {'actId': 'foreign'},
      {'actTurns': -1},
      {'actTurns': '1'},
      {'completed': null},
      {'completed': true},
      {
        'unlockedEndings': ['e', 'e'],
      },
      {
        'unlockedEndings': ['foreign'],
      },
      {'lastInvocationId': ''},
      {'definitionFingerprint': 'foreign'},
    ];
    for (final fields in corruptions) {
      final raw = <String, Object?>{..._saved(first), ...fields};
      final original = jsonEncode(raw);
      final result = _turn(definition, runtime: raw, invocation: 'turn-2');
      expect(result.valid, isFalse, reason: '$fields');
      expect(result.changed, isFalse);
      expect(result.effects, isEmpty);
      expect(jsonEncode(result.runtime), original);
    }
    final missing = _saved(first)..remove('lastInvocationId');
    expect(_turn(definition, runtime: missing, invocation: 'turn-2').valid, isFalse);
  });

  test('definition changes never silently restart or reinterpret saved progress', () {
    final old = _definition(endings: [_ending('e')]);
    final first = _turn(old);
    final updated = StoryDefinition.parse({
      ...(old.raw! as Json),
      'outline': 'An edited story, with the same identities',
    });
    expect(updated.fingerprint, isNot(old.fingerprint));
    final read = updated.inspect(runtimeExists: true, runtime: first.runtime);
    expect(read.valid, isFalse);
    expect(_codes(read.issues), contains('story_runtime_definition'));
    final result = _turn(updated, runtime: first.runtime, invocation: 'turn-2');
    expect(result.runtime, first.runtime);
    expect(result.changed, isFalse);
    expect(result.effects, isEmpty);
  });

  test('unknown valid runtime fields survive normal settlement and all getters detach', () {
    final definition = _definition(
      endings: [
        _ending('e', when: {'var': 'ready'}),
      ],
    );
    final raw = _saved(_turn(definition));
    raw['custom'] = <String, Object?>{
      'list': <Object?>['keep'],
    };
    final original = jsonEncode(raw);
    final result = _turn(definition, runtime: raw, invocation: 'turn-2', state: {'ready': true});
    expect(result.valid, isTrue);
    expect(_saved(result)['custom'], {
      'list': ['keep'],
    });
    final exposed = _saved(result);
    ((exposed['custom']! as Json)['list']! as List<Object?>).add('mutated');
    result.effects.single['title'] = 'mutated';
    result.snapshot.unlockedEndings.clear();
    result.snapshot.currentAct!['goal'] = 'mutated';
    expect(_saved(result)['custom'], {
      'list': ['keep'],
    });
    expect(result.effects.single['title'], 'Ending e');
    expect(result.snapshot.unlockedEndings, ['e']);
    expect(result.snapshot.currentAct!['goal'], '');
    expect(jsonEncode(raw), original);
  });

  test('nonfinite saved JSON is diagnosed without normalizing the stored value', () {
    final definition = _definition();
    final raw = _saved(_turn(definition))..['unknown'] = double.infinity;
    final result = _turn(definition, runtime: raw, invocation: 'turn-2');
    expect(result.valid, isFalse);
    expect(_codes(result.issues), contains('story_runtime_shape'));
    expect(_saved(result)['unknown'], double.infinity);
    expect(result.changed, isFalse);
    expect(result.effects, isEmpty);
  });

  test('JSON roundtrip retains progress and once state without executing on read', () {
    final definition = _definition(endings: [_ending('e')]);
    final first = _turn(definition);
    final restored = jsonDecode(jsonEncode(first.runtime)) as Json;
    final before = jsonEncode(restored);
    final read = definition.inspect(runtimeExists: true, runtime: restored);
    expect(read.valid, isTrue);
    expect(read.actTurns, 1);
    expect(read.unlockedEndings, ['e']);
    expect(jsonEncode(restored), before);
    final second = _turn(definition, runtime: restored, invocation: 'turn-2');
    expect(second.snapshot.actTurns, 2);
    expect(second.effects, isEmpty);
  });

  test('changes carry separate old and new runtime values and serialization is detached', () {
    final definition = _definition();
    final first = _turn(definition);
    final second = _turn(definition, runtime: first.runtime, invocation: 'turn-2');
    final turns = second.changes.singleWhere((change) => change['path'] == '/actTurns');
    expect(turns['old'], 1);
    expect(turns['new'], 2);
    expect(turns['oldExists'], isTrue);
    expect(turns['newExists'], isTrue);
    turns['new'] = 99;
    expect(second.changes.singleWhere((change) => change['path'] == '/actTurns')['new'], 2);
    final serialized = second.toJson();
    (serialized['runtime']! as Json)['actTurns'] = 99;
    (serialized['snapshot']! as Json)['actTurns'] = 99;
    expect(_saved(second)['actTurns'], 2);
    expect(second.snapshot.actTurns, 2);
    expect(second.initialized, isFalse);
    expect(first.initialized, isTrue);
  });
}
