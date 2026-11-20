import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

Json _leaf({bool nullable = false}) => {
  'type': nullable ? ['string', 'null'] : 'string',
  'x-dsh-hidden': true,
};
StateDefinition _definition(Json properties, {List<Object?> rules = const [], Object? init}) => StateDefinition.parse({
  'schema': {'type': 'object', 'properties': properties},
  'rules': rules,
  'init': ?init,
});
StateSecretFact _fact(String path, String value, {String? slot, bool exists = false, Object? expected}) =>
    StateSecretFact(
      slotId: slot ?? path,
      entityId: 'entity',
      path: path,
      expectedExists: exists,
      expectedValue: expected,
      value: value,
    );
Object? _ordered(Object? value) {
  if (value is Json) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List<Object?>) return value.map(_ordered).toList();
  return value;
}

StateSecretPlan _plan(StateDefinition definition, Object? value, List<StateSecretFact> facts, {String id = 'batch'}) =>
    StateSecretPlan(
      id: id,
      stateDefinitionFingerprint: definition.fingerprint,
      baselineFingerprint: sha256
          .convert(utf8.encode(jsonEncode(_ordered({'exists': true, 'value': value}))))
          .toString(),
      facts: facts,
    );
Json _op(String op, String path, [Object? value, String why = 'terminal edit']) => {
  'op': op,
  'path': path,
  if (op != 'remove') 'value': value,
  'why': why,
};
List<Object?> _codes(List<Json> issues) => issues.map((issue) => issue['code']).toList();

void main() {
  test('absent and explicit null leaves inherit hidden permission and prepare without finishing', () {
    final d = _definition({
      'box': {
        'type': 'object',
        'x-dsh-hidden': true,
        'x-dsh-by': ['rules', 'user'],
        'properties': {
          'a': {'type': 'string', 'x-dsh-hidden': false},
          'b': {
            'type': ['string', 'null'],
          },
        },
      },
    });
    final a = <String, Object?>{
      'box': <String, Object?>{'b': null},
    };
    final runtime = <String, Object?>{
      'version': 1,
      'future': <String, Object?>{
        'kept': [1, null],
      },
    };
    final s = d.startSession(valueExists: true, value: a, runtimeExists: true, runtime: runtime);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/box/a', '甲🐋'), _fact('/box/b', '乙', exists: true)]));
    expect(p.accepted, isTrue, reason: '${p.issues}');
    expect(p.value, {
      'box': {'a': '甲🐋', 'b': '乙'},
    });
    expect(p.valueFingerprint, _plan(d, p.value, []).baselineFingerprint);
    expect(p.toJson(), containsPair('valueFingerprint', p.valueFingerprint));
    expect(p.runtime, runtime);
    expect(p.changes.map((row) => row['path']), unorderedEquals(['/box/a', '/box/b']));
    expect(p.receipts.last['status'], 'prepared');
    expect(() => s.secretTerminalPhase(p), throwsStateError);
    final all = s.finish(runRules: false);
    final phase = s.secretTerminalPhase(p);
    expect(all.changes, hasLength(2));
    expect(phase.changes, isEmpty);
    expect(phase.receipts, isEmpty);
    expect(phase.effects, isEmpty);
    expect(phase.changed, isFalse);
  });

  test('a later failed operation rolls back the whole batch but spends the shared 256 budget', () {
    final d = _definition(
      {
        'a': _leaf(),
        'b': {..._leaf(), 'maxLength': 1},
        'n': {'type': 'integer'},
      },
      rules: [
        {
          'id': 'last',
          'when': true,
          'do': [
            {
              'type': 'state',
              'ops': [_op('add', '/n', 1)],
            },
          ],
        },
      ],
    );
    final a = <String, Object?>{'n': 0};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/a', 'accepted attempt'), _fact('/b', 'too long')]));
    expect(p.accepted, isFalse);
    expect(p.value, a);
    expect(p.changes, isEmpty);
    expect(p.receipts.first['accepted'], isTrue);
    expect(p.receipts.first['rolledBack'], isTrue);
    expect(p.receipts[1]['accepted'], isFalse);
    expect(p.receipts.last['status'], 'rejected');
    expect(p.receipts.last['rolledBack'], isTrue);
    final later = s.apply([for (var i = 0; i < 255; i++) _op('add', '/n', 1)], actor: StateActor.user);
    expect(later.acceptedCount, 254);
    expect(later.rejectedCount, 1);
    expect(later.receipts.first['index'], 3);
    final all = s.finish();
    expect(all.value, {'n': 254});
    final phase = s.secretTerminalPhase(p);
    expect(_codes(phase.issues), contains('operations_limit'));
    expect(phase.receipts.every((row) => row['source'] != 'secret:batch'), isTrue);
    expect(phase.changes.single['actor'], 'user');
  });

  test('all CAS checks precede every write and differ from ordinary from conflict reporting', () {
    final d = _definition({'a': _leaf(), 'b': _leaf(nullable: true)});
    final a = <String, Object?>{'b': 'already bound'};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(
      _plan(d, a, [_fact('/a', 'must not appear'), _fact('/b', 'replacement', exists: true)]),
    );
    expect(p.accepted, isFalse);
    expect(_codes(p.issues), contains('secret_cas'));
    expect(p.receipts, hasLength(1));
    expect(s.finish(runRules: false).value, a);
    final missing = <String, Object?>{};
    final mismatch = d.startSession(valueExists: true, value: missing);
    final refused = mismatch.prepareSecretFacts(_plan(d, missing, [_fact('/b', 'value', exists: true)]));
    expect(refused.accepted, isFalse);
    expect(_codes(refused.issues), contains('secret_cas'));
    final ordinary = d.startSession(valueExists: true, value: missing);
    final conflict = ordinary.apply([
      {..._op('set', '/b', 'ordinary'), 'from': null},
    ], actor: StateActor.rules);
    expect(conflict.acceptedCount, 1);
    expect(conflict.receipts.single['conflict'], containsPair('actualExists', false));
  });

  test('root array unknown missing parent and non-object parent targets are rejected', () {
    final d = _definition({
      'box': {
        'type': ['object', 'null'],
        'properties': {'s': _leaf()},
      },
      'items': {'type': 'array', 'items': _leaf()},
    });
    for (final entry in <(Json, String)>[
      (<String, Object?>{}, ''),
      (<String, Object?>{}, '/unknown'),
      (<String, Object?>{}, '/box/s'),
      (<String, Object?>{'box': null}, '/box/s'),
      (<String, Object?>{'items': <Object?>[]}, '/items/0'),
    ]) {
      final s = d.startSession(valueExists: true, value: entry.$1);
      final p = s.prepareSecretFacts(_plan(d, entry.$1, [_fact(entry.$2, 'value')]));
      expect(p.accepted, isFalse, reason: entry.$2);
      expect(p.value, entry.$1);
      expect(p.receipts, hasLength(1));
    }
  });

  test('effective rules permission hidden blocked and derived sinks cannot be bypassed', () {
    final schemas = <Json>[
      {'type': 'string'},
      {
        ..._leaf(),
        'x-dsh-by': ['user'],
      },
      {..._leaf(), 'pattern': r'^x$'},
      {..._leaf(), 'x-dsh-derive': 'derived'},
      {'type': 'integer', 'x-dsh-hidden': true},
    ];
    for (final schema in schemas) {
      final d = _definition({'s': schema});
      final a = <String, Object?>{};
      final p = d.startSession(valueExists: true, value: a).prepareSecretFacts(_plan(d, a, [_fact('/s', 'value')]));
      expect(p.accepted, isFalse, reason: '$schema');
    }
    final ancestor = _definition({
      'box': {
        'type': 'object',
        'x-dsh-by': ['user'],
        'properties': {'s': _leaf()},
      },
    });
    final a = <String, Object?>{'box': <String, Object?>{}};
    expect(
      ancestor
          .startSession(valueExists: true, value: a)
          .prepareSecretFacts(_plan(ancestor, a, [_fact('/box/s', 'value')]))
          .accepted,
      isFalse,
    );
  });

  test('an actual derived side branch rejects the batch while unchanged unrelated derive is allowed', () {
    final d = _definition({
      's': _leaf(),
      'public': {
        'type': 'string',
        'x-dsh-derive': {
          'var': ['s', 'clean'],
        },
      },
    });
    final a = <String, Object?>{'public': 'clean'};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'leak')]));
    expect(p.accepted, isFalse);
    expect(_codes(p.issues), contains('secret_side_effect'));
    expect(p.receipts.first['accepted'], isTrue);
    expect(p.receipts.first['rolledBack'], isTrue);
    expect(s.finish(runRules: false).value, a);
    final unrelated = _definition({
      's': _leaf(),
      'seed': {'type': 'string'},
      'public': {
        'type': 'string',
        'x-dsh-derive': {'var': 'seed'},
      },
      'opaque': {'type': 'string', 'pattern': r'^x$'},
    });
    final b = <String, Object?>{'seed': 'same', 'public': 'same', 'opaque': 'preserved'};
    final allowed = unrelated
        .startSession(valueExists: true, value: b)
        .prepareSecretFacts(_plan(unrelated, b, [_fact('/s', 'private')]));
    expect(allowed.accepted, isTrue, reason: '${allowed.issues}');
    expect(allowed.changes.single['path'], '/s');
  });

  test('derived clamping rejects even when the final side value would be unchanged', () {
    final d = _definition({
      's': _leaf(),
      'n': {
        'type': 'integer',
        'x-dsh-step': 0,
        'x-dsh-derive': {
          'if': [
            {'var': 's'},
            9,
            0,
          ],
        },
      },
    });
    final a = <String, Object?>{'n': 0};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'value')]));
    expect(p.accepted, isFalse);
    expect(p.receipts.first['clamps'], isNotEmpty);
    expect(s.finish(runRules: false).value, a);
  });

  test('invalid saved state runtime or fingerprints refuse preparation and initialization stays compatible', () {
    final d = _definition({
      's': _leaf(),
      'n': {'type': 'integer'},
    });
    final invalid = <String, Object?>{'n': 'wrong'};
    expect(
      d
          .startSession(valueExists: true, value: invalid)
          .prepareSecretFacts(_plan(d, invalid, [_fact('/s', 'value')]))
          .accepted,
      isFalse,
    );
    final a = <String, Object?>{'n': 0};
    final badRuntime = d.startSession(valueExists: true, value: a, runtimeExists: true, runtime: {'version': 2});
    final refused = badRuntime.prepareSecretFacts(_plan(d, a, [_fact('/s', 'value')]));
    expect(refused.accepted, isFalse);
    expect(refused.runtime, {'version': 2});
    final plan = _plan(d, a, [_fact('/s', 'value')]);
    for (final wrong in [
      StateSecretPlan(
        id: plan.id,
        stateDefinitionFingerprint: 'wrong',
        baselineFingerprint: plan.baselineFingerprint,
        facts: plan.facts,
      ),
      _plan(d, {'n': 1}, plan.facts),
    ]) {
      final p = d.startSession(valueExists: true, value: a).prepareSecretFacts(wrong);
      expect(_codes(p.issues), contains('secret_fingerprint'));
    }
    final initialized = d.startSession(valueExists: false);
    final prepared = initialized.prepareSecretFacts(_plan(d, <String, Object?>{}, [_fact('/s', 'value')]));
    expect(prepared.accepted, isFalse);
    expect(prepared.valueExists, isTrue);
    expect(prepared.value, <String, Object?>{});
    final all = initialized.finish(runRules: false);
    expect(all.initialized, isTrue);
    expect(all.changed, isTrue);
    expect(initialized.secretTerminalPhase(prepared).changed, isFalse);
    expect(initialized.secretTerminalPhase(prepared).initialized, isFalse);
  });

  test('shape identity count and UTF8 limits fail before executing any fact', () {
    final d = _definition({'s': _leaf(), 't': _leaf()});
    final a = <String, Object?>{};
    final batches = <List<StateSecretFact>>[
      [],
      [_fact('/s', 'one'), _fact('/s', 'two', slot: 'different')],
      [_fact('/s', 'one', slot: 'same'), _fact('/t', 'two', slot: 'same')],
      [_fact('/s', 'v', slot: '')],
      [StateSecretFact(slotId: 's', entityId: '', path: '/s', expectedExists: false, value: 'v')],
      [_fact('/s', 'v', expected: 'old')],
      [for (var i = 0; i < 9; i++) _fact('/s$i', 'v')],
      [_fact('/s', '🐋' * 4097)],
    ];
    for (final facts in batches) {
      final p = d.startSession(valueExists: true, value: a).prepareSecretFacts(_plan(d, a, facts));
      expect(p.accepted, isFalse);
      expect(p.receipts, hasLength(1));
      expect(p.value, a);
    }
    final exact = d
        .startSession(valueExists: true, value: a)
        .prepareSecretFacts(_plan(d, a, [_fact('/s', '🐋' * 4096)]));
    expect(exact.accepted, isTrue);
  });

  test('identical plans are idempotent but changed content or a started public apply cannot prepare', () {
    final d = _definition({
      's': _leaf(),
      'n': {'type': 'integer'},
    });
    final a = <String, Object?>{'n': 0};
    final plan = _plan(d, a, [_fact('/s', 'B')]);
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(plan);
    expect(identical(s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'B')])), p), isTrue);
    s.apply([_op('add', '/n', 1)], actor: StateActor.user);
    expect(identical(s.prepareSecretFacts(plan), p), isTrue);
    expect(() => s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'C')])), throwsStateError);
    expect(() => s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'B')], id: 'other')), throwsStateError);
    s.finish(runRules: false);
    expect(() => s.prepareSecretFacts(plan), throwsStateError);
    for (final ops in [<Object?>[], 'bad shape']) {
      final used = d.startSession(valueExists: true, value: a);
      used.apply(ops, actor: StateActor.user);
      expect(() => used.prepareSecretFacts(plan), throwsStateError);
    }
    final foreign = d.startSession(valueExists: true, value: a)..finish(runRules: false);
    expect(() => foreign.secretTerminalPhase(p), throwsStateError);
  });

  test('terminal rules run once and B to C reports same secret path with the terminal writer', () {
    final d = _definition(
      {
        's': _leaf(),
        'n': {'type': 'integer', 'x-dsh-step': 5},
      },
      rules: [
        {
          'id': 'rewrite',
          'when': true,
          'once': false,
          'do': [
            {
              'type': 'state',
              'ops': [_op('set', '/s', 'C', 'card rewrite'), _op('add', '/n', 100, 'bounded terminal')],
            },
            {'type': 'notice', 'text': 'once per finish'},
          ],
        },
      ],
    );
    final a = <String, Object?>{'n': 0};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'B')]));
    expect(p.accepted, isTrue);
    expect(p.runtimeExists, isFalse);
    expect((p.value as Json)['n'], 0);
    s.apply([_op('add', '/n', 5)], actor: StateActor.model);
    s.apply([_op('add', '/n', -10)], actor: StateActor.model);
    final all = s.finish();
    final phase = s.secretTerminalPhase(p);
    expect(all.value, {'n': 5, 's': 'C'});
    final row = phase.changes.singleWhere((change) => change['path'] == '/s');
    expect(row, {
      'path': '/s',
      'oldExists': true,
      'old': 'B',
      'newExists': true,
      'new': 'C',
      'actor': 'rules',
      'why': 'card rewrite',
    });
    expect(all.changes.singleWhere((change) => change['path'] == '/s')['oldExists'], isFalse);
    expect(phase.receipts.every((receipt) => receipt['source'] != 'secret:batch'), isTrue);
    expect(phase.effects.single['text'], 'once per finish');
    expect(identical(s.secretTerminalPhase(p), phase), isTrue);
    expect(identical(s.finish(), all), isTrue);
    expect(s.finish().effects, hasLength(1));
  });

  test('terminal reversion to A and an array move require a real B to C difference', () {
    final d = _definition({
      's': _leaf(),
      'items': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
    });
    final a = <String, Object?>{
      'items': [1, 2],
    };
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'B')]));
    s.apply([_op('remove', '/s'), _op('move', '/items/1', '/items/0')], actor: StateActor.user);
    final all = s.finish(runRules: false);
    expect(all.changes.map((change) => change['path']), ['/items']);
    final phase = s.secretTerminalPhase(p);
    expect(phase.changes.map((change) => change['path']), unorderedEquals(['/s', '/items']));
    final removed = phase.changes.singleWhere((change) => change['path'] == '/s');
    expect(removed['old'], 'B');
    expect(removed['newExists'], isFalse);
    expect(removed['actor'], 'user');
    expect(removed['why'], 'terminal edit');
  });

  test('event settlement shares A limits and the sealed terminal phase includes its final writer once', () {
    final d = _definition(
      {
        's': _leaf(),
        'n': {'type': 'integer', 'x-dsh-step': 5},
      },
      rules: [
        {
          'id': 'ordinary',
          'when': true,
          'do': [
            {
              'type': 'state',
              'ops': [_op('add', '/n', 3)],
            },
          ],
        },
      ],
    );
    final events = CardEventDefinition.parse({
      'v': 1,
      'rules': [
        {
          'id': 'rewrite',
          'name': 'signal',
          'when': true,
          'once': true,
          'do': [
            {
              'type': 'state',
              'ops': [_op('set', '/s', 'C', 'event rewrite'), _op('add', '/n', 3)],
            },
            {'type': 'notice', 'text': 'one event'},
          ],
        },
      ],
    });
    final invocation = CardEventInvocation(
      definition: events,
      invocationId: 'turn',
      capabilityFingerprint: events.fingerprint,
      authorizedHandlerIds: events.handlerIds,
      proposals: [const CardEventProposal(eventId: 'run:event:0', runId: 'run', name: 'signal', data: 'literal')],
      runtimeExists: false,
      stateActionAllowed: true,
    );
    final a = <String, Object?>{'n': 0};
    final s = d.startSession(valueExists: true, value: a);
    final p = s.prepareSecretFacts(_plan(d, a, [_fact('/s', 'B')]));
    expect(p.accepted, isTrue);
    final all = s.finishWithEvents(invocation);
    final phase = s.secretTerminalPhase(p);
    expect(all.state.value, {'n': 5, 's': 'C'});
    expect(all.events.receipts.single['consumed'], isTrue);
    expect(phase.changes.singleWhere((row) => row['path'] == '/s'), {
      'path': '/s',
      'oldExists': true,
      'old': 'B',
      'newExists': true,
      'new': 'C',
      'actor': 'rules',
      'why': 'event rewrite',
    });
    expect(phase.receipts.where((row) => row['source'] == 'directorEvent:rewrite'), hasLength(2));
    expect(phase.receipts.every((row) => row['source'] != 'secret:batch'), isTrue);
    expect(phase.effects.single['text'], 'one event');
    expect(identical(s.finishWithEvents(invocation), all), isTrue);
    expect(identical(s.secretTerminalPhase(p), phase), isTrue);
    expect(s.secretTerminalPhase(p).effects, hasLength(1));
  });

  test('fact plan prepared getters and serialization do not share mutable descendants', () {
    final input = <String, Object?>{
      'nested': <Object?>[1],
    };
    final fact = _fact('/s', 'B', expected: input);
    (input['nested']! as List<Object?>).add(2);
    ((fact.expectedValue! as Json)['nested']! as List<Object?>).add(3);
    expect(fact.expectedValue, {
      'nested': [1],
    });
    final d = _definition({'s': _leaf()});
    final a = <String, Object?>{};
    final list = <StateSecretFact>[_fact('/s', 'B')];
    final plan = _plan(d, a, list);
    list.clear();
    expect(plan.facts, hasLength(1));
    expect(() => plan.facts.clear(), throwsUnsupportedError);
    ((plan.toJson()['facts']! as List<Object?>).single! as Json)['value'] = 'tampered';
    final runtime = <String, Object?>{
      'version': 1,
      'future': <String, Object?>{
        'items': <Object?>[1],
      },
    };
    final s = d.startSession(valueExists: true, value: a, runtimeExists: true, runtime: runtime);
    final p = s.prepareSecretFacts(plan);
    expect(p.accepted, isTrue);
    (p.value! as Json)['s'] = 'tampered';
    ((p.runtime! as Json)['future']! as Json)['items'] = 'tampered';
    p.changes.single['new'] = 'tampered';
    (p.receipts.first['operation']! as Json)['value'] = 'tampered';
    (p.toJson()['value']! as Json)['s'] = 'tampered';
    expect(p.value, {'s': 'B'});
    expect(p.runtime, runtime);
    expect(p.changes.single['new'], 'B');
    expect((p.receipts.first['operation']! as Json)['value'], 'B');
    expect(identical(s.prepareSecretFacts(plan), p), isTrue);
    final rejected = d.startSession(valueExists: true, value: a).prepareSecretFacts(_plan(d, a, [fact]));
    rejected.issues.first['code'] = 'tampered';
    expect(_codes(rejected.issues), isNot(contains('tampered')));
    expect(s.finish(runRules: false).value, {'s': 'B'});
  });
}
