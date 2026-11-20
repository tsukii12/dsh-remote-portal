import 'dart:convert';

import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

String _repeat(String value, int count) => List<String>.filled(count, value).join();
Json _op(String op, String path, [Object? value]) => {
  'op': op,
  'path': path,
  if (op != 'remove') 'value': value,
  'why': 'fixed event',
};
Json _stateAction(List<Object?> ops) => {'type': 'state', 'ops': ops};
Json _notice([String text = 'notice']) => {'type': 'notice', 'text': text};
Json _handler(
  String id, {
  String name = 'signal',
  Object? when = true,
  bool once = false,
  List<Object?>? expectations,
  List<Object?> actions = const [],
}) => {'id': id, 'name': name, 'when': when, 'once': once, 'expect': ?expectations, 'do': actions};
CardEventDefinition _definition(List<Object?> rules) => CardEventDefinition.parse({'v': 1, 'rules': rules});
CardEventProposal _proposal([String id = 'run:event:0', String name = 'signal', String data = 'literal']) =>
    CardEventProposal(eventId: id, runId: 'run', name: name, data: data);
CardEventInvocation _invocation(
  CardEventDefinition definition, {
  List<CardEventProposal>? proposals,
  Iterable<String>? authorized,
  bool runtimeExists = false,
  Object? runtime,
  bool stateAllowed = true,
  String invocationId = 'turn',
  String? fingerprint,
}) => CardEventInvocation(
  definition: definition,
  invocationId: invocationId,
  capabilityFingerprint: fingerprint ?? definition.fingerprint,
  authorizedHandlerIds: authorized ?? definition.handlerIds,
  proposals: proposals ?? [_proposal()],
  runtimeExists: runtimeExists,
  runtime: runtime,
  stateActionAllowed: stateAllowed,
);

StateDefinition _state({Json? properties, Object? init, List<Object?> rules = const []}) => StateDefinition.parse({
  'schema': {
    'type': 'object',
    'properties':
        properties ??
        {
          'n': {'type': 'integer', 'default': 0},
        },
  },
  'init': ?init,
  'rules': rules,
});
List<Object?> _codes(List<Json> issues) => issues.map((issue) => issue['code']).toList();
List<Json> _handlers(CardEventResult result, [int proposalIndex = 0]) =>
    (result.receipts[proposalIndex]['handlers']! as List<Object?>).cast<Json>();
Json _ledger(CardEventResult result) => result.runtime! as Json;
List<Object?> _pairs(CardEventResult result) => _ledger(result)['consumed']! as List<Object?>;

void main() {
  test('missing and empty registries inspect without evaluating or initializing', () {
    final missing = CardEventDefinition.parse(null);
    expect(missing.defined, isFalse);
    expect(missing.inspect(runtimeExists: false).toJson(), containsPair('initialized', false));
    final missingResult = settleCardEventsEffectsOnly(_invocation(missing));
    expect(missingResult.valid, isTrue);
    expect(missingResult.receipts.single['outcome'], 'no-handler');
    expect(missingResult.runtimeExists, isFalse);
    expect(missingResult.effects, isEmpty);
    final empty = _definition([]);
    expect(empty.executable, isTrue);
    final result = settleCardEventsEffectsOnly(_invocation(empty));
    expect(result.valid, isTrue);
    expect(result.runtimeExists, isFalse);
    expect(result.changed, isFalse);
    expect(result.receipts.single['outcome'], 'no-handler');
  });

  test('outer and registry versions and malformed root remain preserved without execution', () {
    for (final raw in <Object?>[
      false,
      [],
      {'v': 2, 'rules': []},
      {'v': 1, 'rules': null},
    ]) {
      final definition = CardEventDefinition.parse(raw);
      expect(definition.defined, isTrue);
      expect(definition.executable, isFalse);
      expect(definition.raw, raw);
      expect(settleCardEventsEffectsOnly(_invocation(definition)).effects, isEmpty);
    }
    for (final version in <Object?>[null, 0, 2, '1', true]) {
      final definition = CardEventDefinition.parse({'v': 1, 'rules': []}, version: version);
      expect(definition.executable, isFalse);
      expect(_codes(definition.issues), contains('card_events_version'));
    }
  });

  test('registry limits count UTF-8 bytes and reject the entire over-limit registry', () {
    final raw = <String, Object?>{'v': 1, 'rules': <Object?>[], 'note': ''};
    final room = 1024 * 1024 - utf8.encode(jsonEncode(raw)).length;
    raw['note'] = _repeat('x', room);
    expect(CardEventDefinition.parse(raw).executable, isTrue);
    raw['note'] = '${raw['note']}界';
    expect(_codes(CardEventDefinition.parse(raw).issues), contains('card_events_size'));
    final rules = [for (var i = 0; i < 256; i++) _handler('h$i')];
    expect(_definition(rules).handlerIds.length, 256);
    rules.add(_handler('overflow'));
    final oversized = _definition(rules);
    expect(oversized.executable, isFalse);
    expect(oversized.handlerIds, isEmpty);
  });

  test('all duplicate ids are disabled while distinct same-name handlers keep declaration order', () {
    final definition = _definition([
      _handler('duplicate', actions: [_notice('never')]),
      {'id': 'duplicate', 'name': null, 'when': true, 'do': []},
      _handler('first', actions: [_notice('one')]),
      _handler('second', actions: [_notice('two')]),
    ]);
    expect(definition.handlerIds, ['first', 'second']);
    final result = settleCardEventsEffectsOnly(_invocation(definition));
    expect(result.effects.map((effect) => effect['text']), ['one', 'two']);
    expect(_pairs(result), [
      {'eventId': 'run:event:0', 'handlerId': 'first'},
      {'eventId': 'run:event:0', 'handlerId': 'second'},
    ]);
  });

  test('when is mandatory and malformed actions or expectations disable only their handler', () {
    final definition = _definition([
      {
        'id': 'missing',
        'name': 'signal',
        'do': [_notice()],
      },
      _handler(
        'bad-action',
        actions: [
          {'type': 'notice', 'text': 'x', 'dynamic': true},
        ],
      ),
      _handler(
        'bad-expect',
        expectations: [
          {'path': '/n', 'exists': true},
        ],
      ),
      _handler(
        'bad-absent',
        expectations: [
          {'path': '/n', 'exists': false, 'value': null},
        ],
      ),
      _handler('good', actions: [_notice()]),
    ]);
    expect(definition.executable, isTrue);
    expect(definition.handlerIds, ['good']);
    expect(settleCardEventsEffectsOnly(_invocation(definition)).effects, hasLength(1));
  });

  test('unknown metadata and source JSON are detached and preserved', () {
    final raw = <String, Object?>{
      'v': 1,
      'annotation': {'language': '中'},
      'rules': [
        {
          ..._handler('h', actions: [_notice()]),
          'creator': {
            'opaque': [1, null],
          },
        },
      ],
    };
    final before = jsonDecode(jsonEncode(raw));
    final definition = CardEventDefinition.parse(raw);
    final fingerprint = definition.fingerprint;
    (raw['annotation']! as Json)['language'] = 'changed';
    expect(definition.raw, before);
    expect(definition.fingerprint, fingerprint);
    expect(definition.handlerIds, ['h']);
    expect(definition.issues.where((issue) => issue['kind'] == 'unknown'), hasLength(2));
  });

  test('literal data and names never expand macros, parse JSON or normalize spelling', () {
    const literal = '{"ops":[{"op":"set"}]} {{setvar::x::1}} <script>x</script>';
    final definition = _definition([
      _handler(
        'h',
        name: ' signal ',
        actions: [
          {'type': 'prompt', 'text': literal},
          {
            'type': 'event',
            'name': 'static',
            'data': {'literal': literal},
          },
        ],
      ),
    ]);
    final result = settleCardEventsEffectsOnly(
      _invocation(definition, proposals: [_proposal('a', 'signal', literal), _proposal('b', ' signal ', literal)]),
    );
    expect(result.receipts.first['outcome'], 'no-handler');
    expect(result.receipts.last['data'], literal);
    expect(result.effects.first['text'], literal);
    expect(result.effects.last['data'], {'literal': literal});
    expect(_ledger(result).containsKey('pendingPrompts'), isFalse);
  });

  test('inspect is read-only even for true once handlers and preserves pending metadata', () {
    final definition = _definition([
      _handler('h', once: true, actions: [_notice()]),
    ]);
    final runtime = <String, Object?>{
      'version': 1,
      'unknown': [1],
      'pendingPrompts': [
        {'id': 'old', 'text': '{{literal}}', 'origin': 'retained'},
      ],
    };
    final before = jsonEncode(runtime);
    final view = definition.inspect(runtimeExists: true, runtime: runtime);
    expect(view.valid, isTrue);
    expect(view.consumed, isEmpty);
    expect(view.firedHandlers, isEmpty);
    view.pendingPrompts.single['text'] = 'mutated copy';
    expect(view.pendingPrompts.single['text'], '{{literal}}');
    expect(jsonEncode(runtime), before);
    expect(definition.inspect(runtimeExists: false).initialized, isFalse);
  });

  test('bad future and malformed event ledgers block only the bridge, not valid T17 work', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final invalid = <Object?>[
      null,
      {'version': 2},
      {'version': 1, 'consumed': false},
      {
        'version': 1,
        'consumed': [
          {'eventId': 'x', 'handlerId': 'h'},
          {'eventId': 'x', 'handlerId': 'h'},
        ],
      },
      {
        'version': 1,
        'firedHandlers': ['h', 'h'],
      },
      {
        'version': 1,
        'pendingPrompts': [
          {'id': 'x', 'text': 1},
        ],
      },
      {'version': 1, 'unknown': double.infinity},
      {'version': 1, 'unknown': double.nan},
    ];
    for (final runtime in invalid) {
      final session = _state().startSession(valueExists: true, value: {'n': 0});
      session.apply([_op('set', '/n', 1)], actor: StateActor.model);
      final result = session.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: runtime));
      expect(result.state.valid, isTrue);
      expect(result.state.value, {'n': 1});
      expect(result.events.valid, isFalse);
      if (runtime is Json && runtime['unknown'] is double && (runtime['unknown']! as double).isNaN) {
        expect((result.events.runtime! as Json)['unknown'], isNaN);
      } else {
        expect(result.events.runtime, runtime);
      }
      expect(result.events.changed, isFalse);
      expect(result.events.effects, isEmpty);
      expect(() => jsonEncode(result.events.toJson()), returnsNormally);
    }
  });

  test('consumption is branch-local and an inherited pair cannot run twice', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final parent = <String, Object?>{
      'version': 1,
      'opaque': {'keep': true},
    };
    final a = settleCardEventsEffectsOnly(_invocation(definition, runtimeExists: true, runtime: parent));
    final child = settleCardEventsEffectsOnly(_invocation(definition, runtimeExists: true, runtime: a.runtime));
    final b = settleCardEventsEffectsOnly(_invocation(definition, runtimeExists: true, runtime: parent));
    expect(a.effects, hasLength(1));
    expect(child.effects, isEmpty);
    expect(child.receipts.single['outcome'], 'already-consumed');
    expect(child.changed, isFalse);
    expect(b.effects, hasLength(1));
    expect(parent, {
      'version': 1,
      'opaque': {'keep': true},
    });
    expect(_ledger(a)['opaque'], parent['opaque']);
  });

  test('failed ordinary derive or invalid saved state prevents every late event write and effect', () {
    final definition = _definition([
      _handler(
        'mixed',
        once: true,
        actions: [
          _notice('never'),
          _stateAction([_op('set', '/n', 2)]),
        ],
      ),
      _handler(
        'effect-only',
        once: true,
        actions: [
          {'type': 'prompt', 'text': 'never queued'},
        ],
      ),
    ]);
    final cases = <({StateDefinition definition, Json value, String code})>[
      (
        definition: _state(
          properties: {
            'n': {'type': 'integer'},
            'd': {
              'type': 'number',
              'x-dsh-derive': {
                '/': [
                  1,
                  {'var': 'n'},
                ],
              },
            },
          },
        ),
        value: {'n': 0, 'd': 9},
        code: 'logic_result',
      ),
      (definition: _state(), value: {'n': 'invalid saved value'}, code: 'value_type'),
    ];
    final runtime = <String, Object?>{
      'version': 1,
      'consumed': [
        {'eventId': 'older', 'handlerId': 'historical'},
      ],
      'firedHandlers': ['historical'],
      'pendingPrompts': [
        {'id': 'old-prompt', 'text': 'retain', 'unknown': 3},
      ],
      'opaque': {
        'retained': [null, 1],
      },
    };
    for (final scenario in cases) {
      final session = scenario.definition.startSession(valueExists: true, value: scenario.value);
      final result = session.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: runtime));
      expect(result.state.valid, isFalse);
      expect(result.state.value, scenario.value);
      expect(_codes(result.state.issues), contains(scenario.code));
      expect(
        result.state.receipts,
        contains(allOf(containsPair('operation', {'op': 'derive'}), containsPair('accepted', false))),
      );
      expect(result.events.valid, isFalse);
      expect(_codes(result.events.issues), contains('card_event_condition_state'));
      expect(result.state.effects, isEmpty);
      expect(result.events.effects, isEmpty);
      expect(result.events.runtime, runtime);
      expect(result.events.changed, isFalse);
      expect(result.events.initialized, isFalse);
      expect(result.events.receipts.every((receipt) => receipt['consumed'] == false), isTrue);
    }
  });

  test('structured pairs avoid delimiter collisions and unknown historical ids stay preserved', () {
    final definition = _definition([
      _handler('b|c', actions: [_notice()]),
    ]);
    final runtime = <String, Object?>{
      'version': 1,
      'consumed': [
        {'eventId': 'a|b', 'handlerId': 'c', 'old': true},
      ],
      'firedHandlers': ['removed-handler'],
    };
    final result = settleCardEventsEffectsOnly(
      _invocation(definition, proposals: [_proposal('a')], runtimeExists: true, runtime: runtime),
    );
    expect(result.effects, hasLength(1));
    expect(_pairs(result).first, (runtime['consumed']! as List<Object?>).first);
    expect(_pairs(result).last, {'eventId': 'a', 'handlerId': 'b|c'});
    expect(_ledger(result)['firedHandlers'], ['removed-handler']);
  });

  test('once uses stable handler id across new events and registry fingerprints', () {
    final first = _definition([
      _handler('h', once: true, actions: [_notice('old')]),
    ]);
    final settled = settleCardEventsEffectsOnly(_invocation(first));
    final edited = _definition([
      _handler('h', once: true, actions: [_notice('new')]),
    ]);
    expect(edited.fingerprint, isNot(first.fingerprint));
    final again = settleCardEventsEffectsOnly(
      _invocation(edited, proposals: [_proposal('run:event:1')], runtimeExists: true, runtime: settled.runtime),
    );
    expect(again.effects, isEmpty);
    expect(_handlers(again).single['outcome'], 'once-skipped');
    expect(again.runtime, settled.runtime);
  });

  test('invalid capability fields reject the whole batch without changing its ledger', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final runtime = <String, Object?>{'version': 1, 'opaque': true};
    for (final invocation in [
      _invocation(definition, fingerprint: '', runtimeExists: true, runtime: runtime),
      _invocation(definition, authorized: ['h', 'unknown'], runtimeExists: true, runtime: runtime),
      _invocation(definition, invocationId: '', runtimeExists: true, runtime: runtime),
    ]) {
      final result = settleCardEventsEffectsOnly(invocation);
      expect(result.valid, isFalse);
      expect(_codes(result.issues), contains('card_event_capability'));
      expect(result.effects, isEmpty);
      expect(result.runtime, runtime);
      expect(result.changed, isFalse);
    }
  });

  test('empty terminal authorization executes nothing and creates no runtime', () {
    final definition = _definition([
      _handler('h', once: true, actions: [_notice()]),
    ]);
    final result = settleCardEventsEffectsOnly(_invocation(definition, authorized: []));
    expect(result.valid, isTrue);
    expect(result.runtimeExists, isFalse);
    expect(_handlers(result).single['outcome'], 'not-authorized');
  });

  test('state authorization gates the whole mixed handler before any effect', () {
    final definition = _definition([
      _handler(
        'mixed',
        actions: [
          _notice('must stay pending'),
          _stateAction([_op('add', '/n', 1)]),
        ],
      ),
      _handler('effects', actions: [_notice('allowed')]),
    ]);
    final session = _state().startSession(valueExists: true, value: {'n': 0});
    final result = session.finishWithEvents(_invocation(definition, stateAllowed: false));
    expect(result.state.value, {'n': 0});
    expect(result.events.effects.map((effect) => effect['text']), ['allowed']);
    expect(_handlers(result.events).first['outcome'], 'state-not-authorized');
    expect(_pairs(result.events), [
      {'eventId': 'run:event:0', 'handlerId': 'effects'},
    ]);
  });

  test('effectsOnly reads a detached actual DSH guard but cannot create a state session', () {
    final definition = _definition([
      _handler(
        'read',
        when: {
          '==': [
            {'var': 'n'},
            2,
          ],
        },
        expectations: [
          {'path': '/n', 'exists': true, 'value': 2},
        ],
        actions: [_notice('guard')],
      ),
      _handler(
        'mixed',
        actions: [
          _notice('never'),
          _stateAction([_op('set', '/n', 3)]),
        ],
      ),
    ]);
    final value = <String, Object?>{'n': 2, 'uncomputed': 99};
    final result = settleCardEventsEffectsOnly(_invocation(definition), conditionState: value);
    expect(result.effects.map((effect) => effect['text']), ['guard']);
    expect(value, {'n': 2, 'uncomputed': 99});
    expect(_handlers(result).last['outcome'], 'state-not-authorized');
    expect(settleCardEventsEffectsOnly(_invocation(definition)).effects, isEmpty);
  });

  test('no-schema effectsOnly sees null and a nonfinite supplied carrier is rejected', () {
    final definition = _definition([
      _handler(
        'null',
        when: {
          '===': [
            {'var': ''},
            null,
          ],
        },
        actions: [_notice('null root')],
      ),
    ]);
    final result = settleCardEventsEffectsOnly(_invocation(definition));
    expect(result.effects.single['text'], 'null root');
    final invalid = settleCardEventsEffectsOnly(_invocation(definition), conditionState: {'n': double.nan});
    expect(invalid.valid, isFalse);
    expect(invalid.effects, isEmpty);
    expect(_codes(invalid.issues), contains('card_event_condition_state'));
  });

  test('duplicate ids malformed proposals and count overflow reject every proposal in their batch', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final invalid = <List<CardEventProposal>>[
      [_proposal('same'), _proposal('same')],
      [_proposal('')],
      [const CardEventProposal(eventId: 'x', runId: '', name: 'signal', data: '')],
      [_proposal('x'), const CardEventProposal(eventId: 'y', runId: 'other', name: 'signal', data: '')],
      [_proposal('x', '')],
      [_proposal('x', _repeat('界', 342))],
      [_proposal('x', 'signal', _repeat('界', 5462))],
      [for (var i = 0; i < 33; i++) _proposal('e$i')],
      [for (var i = 0; i < 16; i++) _proposal('e$i', 'signal', _repeat('x', 16 * 1024))],
    ];
    for (final proposals in invalid) {
      final result = settleCardEventsEffectsOnly(_invocation(definition, proposals: proposals));
      expect(result.valid, isFalse);
      expect(result.effects, isEmpty);
      expect(result.runtimeExists, isFalse);
      expect(result.changed, isFalse);
    }
  });

  test('32 distinct valid proposals can run the same non-once handler independently', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final result = settleCardEventsEffectsOnly(
      _invocation(definition, proposals: [for (var i = 0; i < 32; i++) _proposal('e$i')]),
    );
    expect(result.valid, isTrue);
    expect(result.effects, hasLength(32));
    expect(_pairs(result), hasLength(32));
    expect(_ledger(result).containsKey('firedHandlers'), isFalse);
  });

  test('model then one ordinary pass then ordered handlers share current derive values', () {
    final definition = _definition([
      _handler(
        'add',
        when: {
          '==': [
            {'var': 'double'},
            4,
          ],
        },
        actions: [
          _stateAction([_op('add', '/n', 1)]),
        ],
      ),
      _handler(
        'observe',
        when: {
          '==': [
            {'var': 'double'},
            6,
          ],
        },
        actions: [_notice('final')],
      ),
    ]);
    final state = _state(
      properties: {
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
        {
          'id': 'never-revisit',
          'when': {
            '==': [
              {'var': 'n'},
              3,
            ],
          },
          'do': [_notice('wrong second pass')],
        },
        {
          'id': 'ordinary',
          'when': true,
          'once': false,
          'do': [
            _stateAction([_op('add', '/n', 1)]),
          ],
        },
      ],
    );
    final session = state.startSession(valueExists: false);
    session.apply([_op('set', '/n', 1)], actor: StateActor.model);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.valid, isTrue);
    expect(result.state.value, {'n': 3, 'double': 6});
    expect(result.state.effects.map((effect) => effect['text']), ['final']);
    expect(result.state.effects, result.events.effects);
    expect(result.state.changes.singleWhere((row) => row['path'] == '/n')['actor'], 'rules');
  });

  test('model ordinary rules and named handlers use one fixed step baseline', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          _stateAction([_op('add', '/n', 3)]),
        ],
      ),
    ]);
    final state = _state(
      properties: {
        'n': {'type': 'integer', 'x-dsh-step': 5},
      },
      init: {'n': 0},
      rules: [
        {
          'id': 'r',
          'when': true,
          'do': [
            _stateAction([_op('add', '/n', 3)]),
          ],
        },
      ],
    );
    final session = state.startSession(valueExists: false);
    session.apply([_op('add', '/n', 3)], actor: StateActor.model);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.value, {'n': 5});
    expect(result.events.receipts.single['consumed'], isTrue);
    final action = (_handlers(result.events).single['actions']! as List<Object?>).single! as Json;
    final operation = (action['receipts']! as List<Object?>).single! as Json;
    expect(operation['accepted'], isTrue);
    expect(operation['changed'], isFalse);
    expect(operation['clamps'], [containsPair('actual', 5)]);
  });

  test('derived step limits retain their original baseline through late event writes', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          _stateAction([_op('set', '/n', 5)]),
        ],
      ),
    ]);
    final state = _state(
      properties: {
        'n': {'type': 'integer'},
        'd': {
          'type': 'integer',
          'x-dsh-step': 5,
          'x-dsh-derive': {
            '*': [
              {'var': 'n'},
              10,
            ],
          },
        },
      },
      init: {'n': 2},
      rules: [
        {
          'id': 'ordinary',
          'when': true,
          'do': [
            _stateAction([_op('set', '/n', 4)]),
          ],
        },
      ],
    );
    final session = state.startSession(valueExists: false);
    session.apply([_op('set', '/n', 3)], actor: StateActor.model);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.valid, isTrue);
    expect(result.state.value, {'n': 5, 'd': 25});
  });

  test('expect distinguishes missing from null while from remains conflict-only', () {
    final definition = _definition([
      _handler(
        'missing',
        expectations: [
          {'path': '/slot', 'exists': false},
        ],
        actions: [
          _stateAction([_op('set', '/slot', null)]),
        ],
      ),
      _handler(
        'null',
        expectations: [
          {'path': '/slot', 'exists': true, 'value': null},
        ],
        actions: [
          _stateAction([_op('set', '/n', 1)]),
        ],
      ),
      _handler(
        'not-missing',
        expectations: [
          {'path': '/slot', 'exists': false},
        ],
        actions: [_notice('never')],
      ),
      _handler(
        'from',
        actions: [
          _stateAction([
            {..._op('set', '/n', 2), 'from': 999},
          ]),
        ],
      ),
    ]);
    final session = _state(
      properties: {
        'n': {'type': 'integer'},
        'slot': {
          'type': ['null', 'integer'],
        },
      },
      init: {'n': 0},
    ).startSession(valueExists: false);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.value, {'n': 2, 'slot': null});
    expect(_handlers(result.events).map((row) => row['outcome']), [
      'accepted',
      'accepted',
      'precondition-failed',
      'accepted',
    ]);
    final action = (_handlers(result.events).last['actions']! as List<Object?>).single! as Json;
    final operation = (action['receipts']! as List<Object?>).single! as Json;
    expect(operation['accepted'], isTrue);
    expect(operation['conflict'], isNotNull);
    expect(result.state.effects, isEmpty);
  });

  test('expect uses JSON equality and once-decoded JSON Pointers without data bindings', () {
    final definition = _definition([
      _handler(
        'h',
        expectations: [
          {'path': '/a~1b/~0key', 'exists': true, 'value': null},
          {'path': '/n', 'exists': true, 'value': 1.0},
        ],
        actions: [_notice()],
      ),
    ]);
    final result = settleCardEventsEffectsOnly(
      _invocation(definition),
      conditionState: {
        'a/b': {'~key': null},
        'n': 1,
      },
    );
    expect(result.effects, hasLength(1));
    expect(_handlers(result).single['expect'], hasLength(2));
  });

  test('named state actions use rules permissions without granting the model hidden writes', () {
    final definition = _definition([
      _handler(
        'secret',
        actions: [
          _stateAction([_op('set', '/secret', 7)]),
        ],
      ),
      _handler(
        'parent',
        actions: [
          _stateAction([
            _op('set', '', {'secret': 8, 'userOnly': 1}),
          ]),
        ],
      ),
    ]);
    final state = _state(
      properties: {
        'secret': {
          'type': 'integer',
          'x-dsh-hidden': true,
          'x-dsh-by': ['rules'],
        },
        'userOnly': {
          'type': 'integer',
          'x-dsh-by': ['user'],
        },
      },
    );
    final session = state.startSession(valueExists: true, value: {'secret': 0, 'userOnly': 0});
    expect(session.apply([_op('set', '/secret', 3)], actor: StateActor.model).rejectedCount, 1);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.value, {'secret': 7, 'userOnly': 0});
    expect(_handlers(result.events).map((row) => row['outcome']), ['accepted', 'all-rejected']);
    expect(_codes(result.events.issues), contains('permission'));
  });

  test('partial accepted actions consume the pair and once, but every rejected op is retained', () {
    final definition = _definition([
      _handler(
        'h',
        once: true,
        actions: [
          _stateAction([_op('add', '/n', 1), _op('set', '/n', 'bad')]),
          _notice('after rejection'),
        ],
      ),
    ]);
    final result = _state().startSession(valueExists: false).finishWithEvents(_invocation(definition));
    expect(result.state.value, {'n': 1});
    expect(result.state.valid, isTrue);
    expect(_handlers(result.events).single, containsPair('outcome', 'partial'));
    expect(_handlers(result.events).single['consumedOnce'], isTrue);
    expect(_ledger(result.events)['firedHandlers'], ['h']);
    expect(result.events.effects.single['text'], 'after rejection');
    expect(result.state.receipts.where((row) => row['accepted'] == false), hasLength(1));
  });

  test('all-rejected and empty actions stay pending, while an accepted no-op consumes', () {
    final definition = _definition([
      _handler(
        'bad',
        once: true,
        actions: [
          _stateAction([_op('set', '/n', 'bad')]),
        ],
      ),
      _handler('empty', once: true),
      _handler(
        'noop',
        once: true,
        actions: [
          _stateAction([_op('set', '/n', 0)]),
        ],
      ),
    ]);
    final result = _state().startSession(valueExists: true, value: {'n': 0}).finishWithEvents(_invocation(definition));
    expect(result.state.value, {'n': 0});
    expect(result.state.changed, isFalse);
    expect(_pairs(result.events), [
      {'eventId': 'run:event:0', 'handlerId': 'noop'},
    ]);
    expect(_ledger(result.events)['firedHandlers'], ['noop']);
    expect(_handlers(result.events).map((row) => row['outcome']), ['all-rejected', 'all-rejected', 'accepted']);
  });

  test('false and error conditions remain pending without blocking a valid sibling', () {
    final definition = _definition([
      _handler('false', when: false, actions: [_notice('never')]),
      _handler(
        'error',
        when: {
          '/': [1, 0],
        },
        actions: [_notice('never')],
      ),
      _handler('good', actions: [_notice('ok')]),
    ]);
    final result = settleCardEventsEffectsOnly(_invocation(definition));
    expect(result.valid, isTrue);
    expect(_handlers(result).map((row) => row['outcome']), ['not-matched', 'condition-error', 'accepted']);
    expect(_codes(result.issues), contains('logic_result'));
    expect(_pairs(result), [
      {'eventId': 'run:event:0', 'handlerId': 'good'},
    ]);
  });

  test('once is enforced within a proposal batch while non-once handlers run for each event', () {
    final definition = _definition([
      _handler('once', once: true, actions: [_notice('one')]),
      _handler('repeat', actions: [_notice('repeat')]),
    ]);
    final result = settleCardEventsEffectsOnly(
      _invocation(definition, proposals: [_proposal('first'), _proposal('second')]),
    );
    expect(result.effects.map((effect) => effect['text']), ['one', 'repeat', 'repeat']);
    expect(_handlers(result, 1).first['outcome'], 'once-skipped');
    expect(_pairs(result), hasLength(3));
  });

  test('handler judgment budget stops at 256 even when every condition is false', () {
    final definition = _definition([
      for (var i = 0; i < 256; i++) _handler('h$i', when: false, actions: [_notice()]),
    ]);
    final result = settleCardEventsEffectsOnly(
      _invocation(definition, proposals: [_proposal('first'), _proposal('second')]),
    );
    expect(_handlers(result).length, 256);
    expect(_handlers(result, 1).single['outcome'], 'handler-limit');
    expect(_handlers(result, 1).single['skippedCount'], 256);
    expect(_codes(result.issues), contains('card_event_handlers_limit'));
    expect(result.runtimeExists, isFalse);
  });

  test('model ordinary and event ops share 256 attempts despite inert budget metadata', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          _stateAction([_op('add', '/n', 1)]),
        ],
      ),
    ]);
    final state = _state(
      rules: [
        {
          'id': 'ordinary',
          'when': true,
          'do': [
            _stateAction([_op('add', '/n', 1)]),
          ],
        },
      ],
    );
    final session = state.startSession(valueExists: false);
    session.apply([for (var i = 0; i < 255; i++) _op('add', '/n', 1)], actor: StateActor.model);
    final runtime = <String, Object?>{'version': 1, 'operationCount': 0, 'budget': 999999};
    final result = session.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: runtime));
    expect(result.state.value, {'n': 256});
    expect(_codes(result.events.issues), contains('operations_limit'));
    expect(result.events.runtime, runtime);
    expect(result.events.changed, isFalse);
  });

  test('a partially exhausted event operation list consumes only after an accepted prefix', () {
    final definition = _definition([
      _handler(
        'h',
        once: true,
        actions: [
          _stateAction([_op('add', '/n', 1), _op('add', '/n', 1)]),
        ],
      ),
    ]);
    final session = _state().startSession(valueExists: false);
    session.apply([for (var i = 0; i < 255; i++) _op('add', '/n', 1)], actor: StateActor.model);
    final result = session.finishWithEvents(_invocation(definition));
    expect(result.state.value, {'n': 256});
    expect(_handlers(result.events).single['outcome'], 'partial');
    expect(_ledger(result.events)['firedHandlers'], ['h']);
    expect(_codes(result.events.issues), contains('operations_limit'));
  });

  test('ordinary and event actions share their budget and keep accepted partial once', () {
    final definition = _definition([
      _handler('h', once: true, actions: [_notice('first'), _notice('overflow')]),
    ]);
    final state = _state(
      rules: [
        {
          'id': 'many',
          'when': true,
          'do': [for (var i = 0; i < 255; i++) _notice('ordinary $i')],
        },
      ],
    );
    final result = state.startSession(valueExists: false).finishWithEvents(_invocation(definition));
    expect(result.state.effects, hasLength(256));
    expect(result.events.effects, hasLength(1));
    expect(result.events.effects.single['text'], 'first');
    expect(_codes(result.events.issues), contains('card_event_actions_limit'));
    expect(_handlers(result.events).single['consumedOnce'], isTrue);
    final action = (_handlers(result.events).single['actions']! as List<Object?>).first! as Json;
    expect(action['stateEffectIndex'], 255);
    expect(action['effectIndex'], 0);
  });

  test('ordinary and event effects share UTF-8 bytes and do not restart after exhaustion', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          _notice(_repeat('x', 100 * 1024)),
          _stateAction([_op('set', '/n', 9)]),
        ],
      ),
    ]);
    final state = _state(
      rules: [
        {
          'id': 'bytes',
          'when': true,
          'do': [_notice(_repeat('x', 200 * 1024))],
        },
      ],
    );
    final result = state.startSession(valueExists: false).finishWithEvents(_invocation(definition));
    expect(result.state.effects, hasLength(1));
    expect(result.state.value, {'n': 0});
    expect(result.events.effects, isEmpty);
    expect(result.events.runtimeExists, isFalse);
    expect(_codes(result.events.issues), contains('card_event_effects_limit'));
  });

  test('effect byte boundary includes provenance and rejects an extra multibyte character', () {
    final wire = <String, Object?>{
      ..._notice(''),
      'source': 'directorEvent',
      'eventId': 'run:event:0',
      'runId': 'run',
      'handlerId': 'h',
      'actionIndex': 0,
    };
    final room = 256 * 1024 - utf8.encode(jsonEncode(wire)).length;
    final exact = _definition([
      _handler('h', actions: [_notice(_repeat('x', room))]),
    ]);
    final accepted = settleCardEventsEffectsOnly(_invocation(exact));
    expect(accepted.effects, hasLength(1));
    expect(utf8.encode(jsonEncode(accepted.effects.single)).length, 256 * 1024);
    final tooLarge = _definition([
      _handler('h', actions: [_notice('${_repeat('x', room)}界')]),
    ]);
    final rejected = settleCardEventsEffectsOnly(_invocation(tooLarge));
    expect(rejected.effects, isEmpty);
    expect(rejected.runtimeExists, isFalse);
    expect(_codes(rejected.issues), contains('card_event_effects_limit'));
  });

  test('effect action id is distinct from host effectId and event prompts are not double queued', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          {'type': 'unlock', 'kind': 'ending', 'id': 'ending-one', 'title': '结局'},
          {'type': 'prompt', 'text': '{{literal}}'},
        ],
      ),
    ]);
    final runtime = <String, Object?>{
      'version': 1,
      'pendingPrompts': [
        {'id': 'prior-effect', 'text': 'keep', 'opaque': 7},
      ],
    };
    final result = _state()
        .startSession(valueExists: false)
        .finishWithEvents(_invocation(definition, runtimeExists: true, runtime: runtime));
    expect(result.state.effects, result.events.effects);
    expect(result.state.effects, hasLength(2));
    expect(result.events.effects.first['id'], 'ending-one');
    expect(result.events.effects.first.containsKey('effectId'), isFalse);
    expect(result.state.runtimeExists, isFalse);
    expect(_ledger(result.events)['pendingPrompts'], runtime['pendingPrompts']);
    expect(result.events.effects.last['source'], 'directorEvent');
  });

  test('finished event sessions return one cached candidate and cannot accept a new batch', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          _stateAction([_op('add', '/n', 1)]),
        ],
      ),
    ]);
    final session = _state().startSession(valueExists: false);
    final result = session.finishWithEvents(_invocation(definition));
    expect(identical(session.finishWithEvents(_invocation(definition)), result), isTrue);
    expect(identical(session.finish(), result.state), isTrue);
    expect(() => session.finishWithEvents(_invocation(definition, authorized: [])), throwsStateError);
    expect(() => session.finishWithEvents(_invocation(definition, proposals: [_proposal('new')])), throwsStateError);
    expect(() => session.finish(runRules: false), throwsStateError);
    expect(() => session.apply([_op('add', '/n', 1)], actor: StateActor.rules), throwsStateError);
    expect(result.state.value, {'n': 1});
  });

  test('plain finish cannot be reopened and no-event serialization stays unchanged', () {
    final definition = _definition([]);
    final plain = _state().startSession(valueExists: true, value: {'n': 0});
    final original = plain.finish();
    expect(() => plain.finishWithEvents(_invocation(definition)), throwsStateError);
    final withEmpty = _state()
        .startSession(valueExists: true, value: {'n': 0})
        .finishWithEvents(_invocation(definition, proposals: []));
    expect(withEmpty.state.toJson(), original.toJson());
    expect(original.toJson().keys.toSet(), {
      'version',
      'valueExists',
      'value',
      'runtimeExists',
      'runtime',
      'initialized',
      'valid',
      'changed',
      'changes',
      'receipts',
      'effects',
      'issues',
    });
    expect(withEmpty.events.runtimeExists, isFalse);
  });

  test('sealed runtime identity distinguishes a literal audit marker from rejected NaN', () {
    final definition = _definition([
      _handler('h', actions: [_notice()]),
    ]);
    final legal = <String, Object?>{
      'version': 1,
      'opaque': {'nonJsonNumber': 'NaN'},
    };
    final invalid = <String, Object?>{'version': 1, 'opaque': double.nan};
    final session = _state().startSession(valueExists: false);
    final result = session.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: legal));
    expect(result.events.valid, isTrue);
    expect(
      () => session.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: invalid)),
      throwsStateError,
    );
    final reverse = _state().startSession(valueExists: false);
    final failed = reverse.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: invalid));
    expect(failed.events.valid, isFalse);
    expect(
      identical(reverse.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: invalid)), failed),
      isTrue,
    );
    expect(
      () => reverse.finishWithEvents(_invocation(definition, runtimeExists: true, runtime: legal)),
      throwsStateError,
    );
  });

  test('definition identity cannot collide a legal annotation marker with nonfinite JSON', () {
    final legal = CardEventDefinition.parse({
      'v': 1,
      'rules': [
        _handler('h', actions: [_notice()]),
      ],
      'annotation': {'nonJsonNumber': 'NaN'},
    });
    final invalid = CardEventDefinition.parse({
      'v': 1,
      'rules': [
        _handler('h', actions: [_notice()]),
      ],
      'annotation': double.nan,
    });
    expect(legal.executable, isTrue);
    expect(invalid.executable, isFalse);
    expect(legal.fingerprint, isNot(invalid.fingerprint));
    final session = _state().startSession(valueExists: false);
    expect(session.finishWithEvents(_invocation(legal)).events.valid, isTrue);
    expect(() => session.finishWithEvents(_invocation(invalid)), throwsStateError);
    final reverse = _state().startSession(valueExists: false);
    expect(reverse.finishWithEvents(_invocation(invalid)).events.valid, isFalse);
    expect(() => reverse.finishWithEvents(_invocation(legal)), throwsStateError);
  });

  test('invocation and every returned receipt effect and ledger are detached copies', () {
    final definition = _definition([
      _handler(
        'h',
        actions: [
          {
            'type': 'event',
            'name': 'literal',
            'data': {
              'nested': [1],
            },
          },
        ],
      ),
    ]);
    final ids = ['h'], proposals = [_proposal()];
    final runtime = <String, Object?>{
      'version': 1,
      'opaque': [1],
    };
    final invocation = _invocation(
      definition,
      authorized: ids,
      proposals: proposals,
      runtimeExists: true,
      runtime: runtime,
    );
    ids.clear();
    proposals.clear();
    (runtime['opaque']! as List<Object?>).add(2);
    final result = settleCardEventsEffectsOnly(invocation);
    expect(result.effects, hasLength(1));
    expect(_ledger(result)['opaque'], [1]);
    ((result.effects.single['data']! as Json)['nested']! as List<Object?>).add(2);
    expect(result.effects.single['data'], {
      'nested': [1],
    });
    (_ledger(result)['consumed']! as List<Object?>).clear();
    expect(_pairs(result), hasLength(1));
    _handlers(result).single['outcome'] = 'changed';
    expect(_handlers(result).single['outcome'], 'accepted');
  });
}
