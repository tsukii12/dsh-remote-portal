import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;
Json op(String operation, String path, [Object? value]) => {
  'op': operation,
  'path': path,
  if (operation != 'remove') 'value': value,
  'why': 'rule test',
};
StateDefinition def(Json properties, {Object? init, List<Object?> rules = const []}) => StateDefinition.parse({
  'schema': {'type': 'object', 'properties': properties},
  'init': ?init,
  'rules': rules,
});
Json rule(String id, List<Object?> actions, {Object? when = true, bool once = true}) => {
  'id': id,
  'when': when,
  'once': once,
  'do': actions,
};
Json state(List<Object?> ops) => {'type': 'state', 'ops': ops};
List<Object?> codes(List<Json> issues) => issues.map((x) => x['code']).toList();

void main() {
  test('derive topological order and fallback dependencies do not depend on property order', () {
    final d = def({
      'c': {
        'type': 'integer',
        'x-dsh-derive': {
          'var': [
            'missing',
            {'var': 'b'},
          ],
        },
      },
      'b': {
        'type': 'integer',
        'x-dsh-derive': {
          '+': [
            {'var': 'a'},
            1,
          ],
        },
      },
      'missing': {'type': 'integer'},
      'a': {'type': 'integer', 'default': 2},
      'mood': {
        'x-dsh-derive': {
          'if': [
            {
              '>': [
                {'var': 'c'},
                2,
              ],
            },
            'warm',
            'cold',
          ],
        },
      },
    });
    expect(d.initialPreview().value, {'a': 2, 'b': 3, 'c': 3, 'mood': 'warm'});
    final s = d.startSession(valueExists: false);
    expect(s.apply([op('set', '/a', 0)], actor: StateActor.user).acceptedCount, 1);
    expect(s.finish(runRules: false).value, {'a': 0, 'b': 1, 'c': 1, 'mood': 'cold'});
  });

  test('derive inside items reads the DSH root and concrete instances preserve indices', () {
    final d = def(
      {
        'seed': {'type': 'integer'},
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'd': {
                'type': 'integer',
                'x-dsh-derive': {'var': 'seed'},
              },
            },
          },
        },
      },
      init: {
        'seed': 3,
        'items': [<String, Object?>{}, <String, Object?>{}],
      },
    );
    expect(d.initialPreview().value, {
      'seed': 3,
      'items': [
        {'d': 3},
        {'d': 3},
      ],
    });
    final s = d.startSession(valueExists: false);
    s.apply([op('set', '/seed', 4)], actor: StateActor.user);
    expect(s.finish(runRules: false).value, {
      'seed': 4,
      'items': [
        {'d': 4},
        {'d': 4},
      ],
    });
  });

  test('static string index and length dependencies use root data without becoming unknown schema children', () {
    final d = def({
      'first': {
        'type': 'string',
        'x-dsh-derive': {'var': 'word.0'},
      },
      'size': {
        'type': 'integer',
        'x-dsh-derive': {'var': 'word.length'},
      },
      'word': {'type': 'string', 'default': 'AB'},
    });
    expect(d.initialPreview().value, {'word': 'AB', 'first': 'A', 'size': 2});
    final s = d.startSession(valueExists: false);
    expect(s.apply([op('set', '/word', 'Z')], actor: StateActor.user).acceptedCount, 1);
    expect(s.finish(runRules: false).value, {'word': 'Z', 'first': 'Z', 'size': 1});
  });

  test('container dependency waits for descendant derive before copying public result', () {
    final d = def(
      {
        'copy': {
          'type': 'object',
          'properties': {
            'v': {'type': 'integer'},
          },
          'x-dsh-derive': {'var': 'box'},
        },
        'box': {
          'type': 'object',
          'properties': {
            'v': {
              'type': 'integer',
              'x-dsh-derive': {
                '+': [
                  {'var': 'seed'},
                  1,
                ],
              },
            },
          },
        },
        'seed': {'type': 'integer'},
      },
      init: {'seed': 2, 'box': <String, Object?>{}},
    );
    expect(d.initialPreview().value, {
      'seed': 2,
      'box': {'v': 3},
      'copy': {'v': 3},
    });
  });

  test('derived producer can create an array before consumers use its new item instances', () {
    final d = def(
      {
        'copy': {
          'type': 'integer',
          'x-dsh-derive': {'var': 'made.0.d'},
        },
        'made': {
          'type': 'array',
          'x-dsh-derive': {'var': 'base'},
          'items': {
            'type': 'object',
            'properties': {
              'd': {
                'type': 'integer',
                'x-dsh-derive': {'var': 'seed'},
              },
            },
          },
        },
        'base': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'd': {'type': 'integer'},
            },
          },
        },
        'seed': {'type': 'integer'},
      },
      init: {
        'base': [<String, Object?>{}],
        'seed': 7,
      },
    );
    final preview = d.initialPreview();
    expect(preview.valid, isTrue, reason: '${preview.issues}');
    expect((preview.value as Json)['copy'], 7);
    expect((preview.value as Json)['made'], [
      {'d': 7},
    ]);
  });

  test('unknown, cyclic, dynamic and unresolved array dependencies are explicit failures', () {
    final cyclic = def({
      'a': {
        'type': 'integer',
        'x-dsh-derive': {'var': 'b'},
      },
      'b': {
        'type': 'integer',
        'x-dsh-derive': {'var': 'a'},
      },
    });
    expect(codes(cyclic.initialPreview().issues), contains('derive_cycle'));
    final unknown = def({
      'a': {
        'type': 'integer',
        'x-dsh-derive': {'var': 'missing'},
      },
    });
    expect(codes(unknown.initialPreview().issues), contains('derive_dependency'));
    final dynamic = def({
      'a': {
        'type': 'integer',
        'x-dsh-derive': {
          'var': {
            'if': [true, 'x', 'y'],
          },
        },
      },
    });
    expect(codes(dynamic.issues), contains('logic_dynamic_var'));
    final unresolved = def(
      {
        'a': {
          'type': 'integer',
          'x-dsh-derive': {
            'var': ['xs.0', 9],
          },
        },
        'xs': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
      },
      init: {'xs': <Object?>[]},
    );
    expect(codes(unresolved.initialPreview().issues), contains('derive_array_dependency'));
  });

  test('first derive establishes step baseline; later clamp is audited and failure rolls back direct write', () {
    final d = def(
      {
        'x': {'type': 'number'},
        'd': {
          'type': 'number',
          'x-dsh-step': 3,
          'x-dsh-derive': {
            '*': [
              {'var': 'x'},
              10,
            ],
          },
        },
      },
      init: {'x': 10},
    );
    final s = d.startSession(valueExists: false);
    final result = s.apply([op('set', '/x', 11), op('set', '/x', 1e308)], actor: StateActor.user);
    expect(result.acceptedCount, 1);
    expect(result.rejectedCount, 1);
    expect(result.receipts.first['clamps'], [containsPair('actual', 103)]);
    final end = s.finish(runRules: false);
    expect(end.value, {'x': 11, 'd': 103});
    expect(end.changes.singleWhere((x) => x['path'] == '/d')['actor'], 'rules');
  });

  test('derive respects inherited rules permission and direct edits cannot replace derived values', () {
    final d = def(
      {
        'x': {'type': 'integer'},
        'd': {
          'type': 'integer',
          'x-dsh-by': ['user'],
          'x-dsh-derive': {'var': 'x'},
        },
      },
      init: {'x': 1},
    );
    expect(codes(d.initialPreview().issues), contains('permission'));
    final normal = def(
      {
        'x': {'type': 'integer'},
        'd': {
          'type': 'integer',
          'x-dsh-derive': {'var': 'x'},
        },
      },
      init: {'x': 1},
    );
    final s = normal.startSession(valueExists: false);
    expect(
      s.apply([
        op('set', '/d', 2),
        op('set', '', {'x': 2, 'd': 2}),
      ], actor: StateActor.user).rejectedCount,
      2,
    );
  });

  test('ordered one-pass rules see earlier writes and derive but never revisit earlier conditions', () {
    final d = def(
      {
        'n': {'type': 'integer'},
        'double': {
          'type': 'integer',
          'x-dsh-derive': {
            '*': [
              {'var': 'n'},
              2,
            ],
          },
        },
      },
      init: {'n': 0},
      rules: [
        rule(
          'earlier',
          [
            state([op('add', '/n', 100)]),
          ],
          when: {
            '==': [
              {'var': 'n'},
              1,
            ],
          },
          once: false,
        ),
        rule(
          'set',
          [
            state([op('set', '/n', 1)]),
          ],
          when: {
            '==': [
              {'var': 'n'},
              0,
            ],
          },
          once: false,
        ),
        rule(
          'after',
          [
            {'type': 'notice', 'text': 'derived ready'},
          ],
          when: {
            '==': [
              {'var': 'double'},
              2,
            ],
          },
        ),
      ],
    );
    final result = d.startSession(valueExists: false).finish();
    expect(result.value, {'n': 1, 'double': 2});
    expect(result.effects.single['text'], 'derived ready');
    expect((result.runtime as Json)['firedRules'], ['id:after']);
  });

  test('manual initialization finish(false) has no effects; explicit finish runs once only', () {
    final d = def(
      {
        'n': {'type': 'integer', 'default': 0},
      },
      rules: [
        rule('r', [
          state([op('add', '/n', 1)]),
        ], once: false),
      ],
    );
    final quiet = d.startSession(valueExists: false).finish(runRules: false);
    expect(quiet.value, {'n': 0});
    expect(quiet.runtimeExists, isFalse);
    final active = d.startSession(valueExists: true, value: quiet.value);
    final once = active.finish();
    expect(once.value, {'n': 1});
    expect(active.finish().value, {'n': 1});
  });

  test('partial accepted rule consumes once while rejected operations remain visible', () {
    final d = def(
      {
        'n': {'type': 'integer', 'default': 0},
      },
      rules: [
        rule('partial', [
          state([op('add', '/n', 1), op('set', '/n', 'bad')]),
          {'type': 'prompt', 'text': '{{user}} literal'},
          {'type': 'notice', 'text': 'notice'},
          {
            'type': 'event',
            'name': 'scene',
            'data': {
              'a': [1, null],
            },
          },
          {'type': 'unlock', 'kind': 'ending', 'id': 'end', 'title': 'done'},
        ]),
      ],
    );
    final first = d.startSession(valueExists: false).finish();
    expect(first.value, {'n': 1});
    expect(first.receipts.where((x) => x['accepted'] == false), hasLength(1));
    expect(first.effects.map((x) => x['type']), ['prompt', 'notice', 'event', 'unlock']);
    expect(first.effects.first['text'], '{{user}} literal');
    expect((first.runtime as Json)['firedRules'], ['id:partial']);
    final second = d
        .startSession(valueExists: true, value: first.value, runtimeExists: true, runtime: first.runtime)
        .finish();
    expect(second.value, {'n': 1});
    expect(second.effects, isEmpty);
  });

  test('all-rejected once rule does not consume; accepted no-op does consume without fake changes', () {
    final d = def(
      {
        'n': {'type': 'integer', 'default': 0},
      },
      rules: [
        rule('failed', [
          state([op('set', '/n', 'bad')]),
        ]),
        rule('noop', [
          state([op('set', '/n', 0)]),
        ]),
      ],
    );
    final result = d.startSession(valueExists: false).finish();
    expect((result.runtime as Json)['firedRules'], ['id:noop']);
    expect(result.changes, isEmpty);
    expect(result.receipts.last['changed'], isFalse);
  });

  test('rules and multiple external calls share step and operation budgets', () {
    final d = def(
      {
        'n': {'type': 'integer', 'x-dsh-step': 5},
      },
      rules: [
        rule('r', [
          state([op('add', '/n', 100)]),
        ]),
      ],
    );
    final s = d.startSession(valueExists: true, value: {'n': 0});
    s.apply([op('add', '/n', 5)], actor: StateActor.model, source: 'call-0');
    s.apply([op('add', '/n', -10)], actor: StateActor.model, source: 'call-1');
    expect(s.finish().value, {'n': 5});
    final full = d.startSession(valueExists: true, value: {'n': 0});
    full.apply([for (var i = 0; i < 256; i++) op('set', '/n', 0)], actor: StateActor.user);
    final result = full.finish();
    expect(result.value, {'n': 0});
    expect(result.runtimeExists, isFalse);
    expect(codes(result.issues), contains('operations_limit'));
  });

  test('bad runtime shapes are preserved and make the complete session read-only', () {
    final d = def(
      {
        'n': {'type': 'integer', 'default': 0},
      },
      rules: [
        rule('r', [
          {'type': 'notice', 'text': 'must not fire'},
        ]),
      ],
    );
    final invalid = <Object?>[
      null,
      <String, Object?>{},
      {'version': 2},
      {'version': 1, 'firedRules': null},
      {
        'version': 1,
        'firedRules': [1],
      },
      {'version': 1, 'pendingPrompts': null},
      {
        'version': 1,
        'pendingPrompts': [
          {'id': 'x', 'text': 2},
        ],
      },
      {
        'version': 1,
        'pendingPrompts': [
          {'id': 'x', 'text': 'a'},
          {'id': 'x', 'text': 'b'},
        ],
      },
    ];
    for (final runtime in invalid) {
      final s = d.startSession(valueExists: false, runtimeExists: true, runtime: runtime);
      expect(
        s.apply([
          op('set', '', {'n': 4}),
        ], actor: StateActor.user).rejectedCount,
        1,
      );
      final result = s.finish();
      expect(result.valueExists, isFalse);
      expect(result.runtime, runtime);
      expect(result.runtimeExists, isTrue);
      expect(result.effects, isEmpty);
      expect(result.changed, isFalse);
    }
  });

  test('valid runtime preserves unknown members and pending prompts when once ledger grows', () {
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        rule('new', [
          {'type': 'notice', 'text': 'notice'},
        ]),
      ],
    );
    final runtime = <String, Object?>{
      'version': 1,
      'firedRules': ['id:old'],
      'pendingPrompts': [
        {'id': 'p', 'text': '{{char}}', 'vendor': 9},
      ],
      'future': {'x': null},
    };
    final result = d.startSession(valueExists: true, value: {'n': 0}, runtimeExists: true, runtime: runtime).finish();
    expect((result.runtime as Json)['firedRules'], ['id:old', 'id:new']);
    expect((result.runtime as Json)['pendingPrompts'], runtime['pendingPrompts']);
    expect((result.runtime as Json)['future'], {'x': null});
    expect(runtime['firedRules'], ['id:old']);
  });

  test('stable ids survive rule reorder metadata edits and explicit-id content changes', () {
    final automatic = <String, Object?>{
      'when': true,
      'once': true,
      'do': [
        {'type': 'notice', 'text': 'auto'},
      ],
    };
    final explicit = rule('fixed', [
      {'type': 'notice', 'text': 'before'},
    ]);
    final first = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [automatic, explicit],
    ).startSession(valueExists: true, value: {'n': 0}).finish();
    final changed = def(
      {
        'n': {'type': 'integer', 'description': 'new label'},
      },
      rules: [
        rule('fixed', [
          {'type': 'notice', 'text': 'after'},
        ]),
        automatic,
      ],
    );
    final second = changed
        .startSession(valueExists: true, value: first.value, runtimeExists: true, runtime: first.runtime)
        .finish();
    expect(second.effects, isEmpty);
    final differentAuto = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        {
          'when': true,
          'once': true,
          'do': [
            {'type': 'notice', 'text': 'changed auto'},
          ],
        },
      ],
    ).startSession(valueExists: true, value: first.value, runtimeExists: true, runtime: first.runtime).finish();
    expect(differentAuto.effects.single['text'], 'changed auto');
  });

  test('identical anonymous rules have occurrence ids and duplicate explicit ids disable every related rule', () {
    final auto = {
      'when': true,
      'once': true,
      'do': [
        state([op('add', '/n', 1)]),
      ],
    };
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        auto,
        auto,
        rule('duplicate', [
          state([op('add', '/n', 100)]),
        ]),
        rule('duplicate', [
          state([op('add', '/n', 100)]),
        ]),
        rule('unknown', [
          {'type': 'script', 'text': 'not supported'},
        ]),
        rule('valid', [
          {'type': 'notice', 'text': 'ok'},
        ]),
      ],
    );
    final result = d.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(result.value, {'n': 2});
    expect(result.effects.single['text'], 'ok');
    final fired = (result.runtime as Json)['firedRules']! as List<Object?>;
    expect(fired, hasLength(3));
    expect((fired[0]! as String).endsWith(':0'), isTrue);
    expect((fired[1]! as String).endsWith(':1'), isTrue);
    expect(codes(d.issues), containsAll(['rule_duplicate_id', 'rule_action']));
  });

  test('action limit rejects remainder explicitly and preserves successful partial once consumption', () {
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        rule('many', [
          for (var i = 0; i < 257; i++) {'type': 'notice', 'text': '$i'},
        ]),
        rule('later', [
          state([op('set', '/n', 9)]),
        ]),
      ],
    );
    final result = d.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(result.effects, hasLength(256));
    expect(result.value, {'n': 0});
    expect((result.runtime as Json)['firedRules'], ['id:many']);
    expect(codes(result.issues), contains('rule_actions_limit'));
  });

  test('effect byte limit rejects oversized suffix without discarding earlier accepted effect', () {
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        rule('bytes', [
          {'type': 'notice', 'text': 'accepted'},
          {'type': 'prompt', 'text': '字' * (256 * 1024)},
          state([op('set', '/n', 9)]),
        ]),
      ],
    );
    final result = d.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(result.effects, hasLength(1));
    expect(result.value, {'n': 0});
    expect((result.runtime as Json)['firedRules'], ['id:bytes']);
    expect(codes(result.issues), contains('rule_effects_limit'));
  });

  test('rule count limit executes at most first 256 and keeps the raw definition', () {
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        for (var i = 0; i < 257; i++)
          rule('r$i', [
            {'type': 'notice', 'text': '$i'},
          ]),
      ],
    );
    final result = d.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(result.effects, hasLength(256));
    expect(codes(result.issues), contains('rules_limit'));
  });

  test('rule judgment receipts explain false conditions once skips and condition failures', () {
    final d = def(
      {
        'n': {'type': 'integer'},
      },
      rules: [
        rule('false', [
          {'type': 'notice', 'text': 'no'},
        ], when: false),
        rule('already', [
          {'type': 'notice', 'text': 'no'},
        ]),
        rule(
          'error',
          [
            {'type': 'notice', 'text': 'no'},
          ],
          when: {
            '/': [1, 0],
          },
        ),
        rule('valid', [
          {'type': 'notice', 'text': 'yes'},
        ]),
      ],
    );
    final result = d
        .startSession(
          valueExists: true,
          value: {'n': 0},
          runtimeExists: true,
          runtime: {
            'version': 1,
            'firedRules': ['id:already'],
          },
        )
        .finish();
    final judgments = result.receipts.where((x) => (x['operation'] as Json)['op'] == 'rule').toList();
    expect(judgments.map((x) => x['status']), ['not_matched', 'once_skipped', 'condition_error', 'matched']);
    expect(judgments.last['consumedOnce'], isTrue);
    expect(result.effects.single['text'], 'yes');
    expect(result.valid, isTrue);
  });

  test('automatic derive or complete-candidate failure makes finish invalid for the caller commit gate', () {
    final d = def(
      {
        'x': {'type': 'number'},
        'd': {
          'type': 'number',
          'x-dsh-derive': {
            '/': [
              1,
              {'var': 'x'},
            ],
          },
        },
      },
      rules: [
        rule('must-not-run', [
          {'type': 'notice', 'text': 'no'},
        ]),
      ],
    );
    final result = d.startSession(valueExists: true, value: {'x': 0, 'd': 10}).finish();
    expect(result.valid, isFalse);
    expect(result.value, {'x': 0, 'd': 10});
    expect(result.effects, isEmpty);
    expect(result.receipts.single['accepted'], isFalse);
    final bad = def(
      {
        'n': {'type': 'integer', 'minimum': 0},
      },
      rules: [
        rule('must-not-run', [
          {'type': 'notice', 'text': 'no'},
        ]),
      ],
    ).startSession(valueExists: true, value: {'n': -1}).finish();
    expect(bad.valid, isFalse);
    expect(bad.value, {'n': -1});
    expect(bad.effects, isEmpty);
  });
}
