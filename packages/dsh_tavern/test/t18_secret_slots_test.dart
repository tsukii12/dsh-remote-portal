import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('missing malformed and future registries stay inert without dropping recoverable protection', () {
    final missing = SecretDefinition.parse(null, state: _state());
    expect(missing.defined, isFalse);
    expect(missing.executable, isFalse);
    expect(missing.protectedPaths, isEmpty);
    expect(_capture(missing).strictTool(), isNull);
    for (final raw in <Object?>[
      false,
      [],
      {'v': 1},
      {'v': 1, 'slots': null},
    ]) {
      final definition = SecretDefinition.parse(raw, state: _state());
      expect(definition.defined, isTrue);
      expect(definition.executable, isFalse);
      expect(definition.raw, raw);
      expect(_codes(definition.issues), contains('secret_protection_unknown'));
    }
    final future = SecretDefinition.parse({
      'v': 2,
      'slots': [_slot()],
    }, state: _state());
    expect(future.executable, isFalse);
    expect(future.protectedPaths, ['/vault/fact']);
    for (final version in <Object?>[null, 2, '1', true]) {
      final definition = SecretDefinition.parse(
        {
          'v': 1,
          'slots': [_slot()],
        },
        state: _state(),
        version: version,
      );
      expect(definition.executable, isFalse);
      expect(definition.protectedPaths, ['/vault/fact']);
      expect(_codes(definition.issues), contains('secret_version'));
    }
    final broken = _definition(
      slots: [
        _slot(),
        4,
        {'path': '/bad~2escape'},
        {'path': ''},
      ],
    );
    expect(broken.executable, isFalse);
    expect(broken.protectedPaths, ['/vault/fact', '']);
    expect(_codes(broken.issues).where((code) => code == 'secret_protection_unknown'), hasLength(2));
    final nonfinite = SecretDefinition.parse({'v': 1, 'slots': [], 'opaque': double.nan}, state: _state());
    expect(nonfinite.executable, isFalse);
    expect((nonfinite.raw! as Json)['opaque'], isNaN);
    expect(nonfinite.fingerprint, isNotEmpty);
  });

  test('unknown declaration metadata is preserved diagnosed inert and deeply detached', () {
    final slot = _slot()
      ..['vendor'] = <String, Object?>{
        'nested': <Object?>['kept'],
      };
    (slot['release']! as Json)['annotation'] = <String, Object?>{'value': 'release note'};
    final raw = <String, Object?>{
      'v': 1,
      'slots': <Object?>[slot],
      'opaque': <Object?>['root'],
    };
    final before = jsonDecode(jsonEncode(raw));
    final definition = SecretDefinition.parse(raw, state: _state());
    final fingerprint = definition.fingerprint;
    expect(definition.executable, isTrue);
    expect(definition.issues.where((issue) => issue['kind'] == 'unknown'), hasLength(3));
    (raw['opaque']! as List<Object?>).clear();
    ((slot['vendor']! as Json)['nested']! as List<Object?>).clear();
    final copy = definition.raw! as Json;
    (copy['slots']! as List<Object?>).clear();
    definition.protectedPaths.clear();
    definition.issues.first['code'] = 'mutated';
    expect(definition.raw, before);
    expect(definition.fingerprint, fingerprint);
    expect(definition.protectedPaths, ['/vault/fact']);
    expect(_codes(definition.issues), everyElement('secret_unknown'));
    expect(_capture(definition).slotIds, ['slot']);
  });

  test('one bad slot or a duplicate id or path disables the whole registry', () {
    final state = _state(
      parent: {
        'properties': <String, Object?>{'fact': _leaf(), 'other': _leaf()},
      },
    );
    final examples = <List<Object?>>[
      [_slot(), _slot(id: 'bad', path: '/unknown')],
      [_slot(), _slot(path: '/vault/other')],
      [_slot(), _slot(id: 'different')],
      [
        _slot(),
        {'id': 'malformed', 'path': '/vault/other'},
      ],
    ];
    for (final slots in examples) {
      final definition = _definition(state: state, slots: slots);
      expect(definition.executable, isFalse);
      expect(definition.protectedPaths, contains('/vault/fact'));
      expect(_capture(definition).slotIds, isEmpty);
      expect(_capture(definition).strictTool(), isNull);
    }
    expect(_codes(_definition(state: state, slots: examples[1]).issues), contains('secret_duplicate_id'));
    expect(_codes(_definition(state: state, slots: examples[2]).issues), contains('secret_duplicate_path'));
  });

  test('sink schema and every ancestor enforce fixed object hidden rules and nonderived boundaries', () {
    final states = <StateDefinition>[
      StateDefinition.parse(null),
      _state(fact: {'type': 'string'}),
      _state(fact: {..._leaf(), 'pattern': '.*'}),
      _state(fact: {..._leaf(), 'x-dsh-derive': 'fixed'}),
      _state(
        fact: {
          ..._leaf(),
          'x-dsh-by': ['user'],
        },
      ),
      _state(
        fact: {
          ..._leaf(),
          'type': ['string', 'integer', 'null'],
        },
      ),
      _state(
        parent: {
          'x-dsh-by': ['user'],
        },
      ),
      _state(parent: {'x-dsh-derive': <String, Object?>{}}),
      _state(parent: {'patternProperties': <String, Object?>{}}),
      _state(
        parent: {
          'type': ['object', 'array'],
        },
      ),
    ];
    for (final state in states) {
      final definition = _definition(state: state);
      expect(definition.executable, isFalse);
      expect(definition.protectedPaths, ['/vault/fact']);
      expect(_capture(definition).slotIds, isEmpty);
    }
    final array = _state(
      parent: {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {'fact': _leaf()},
        },
      },
    );
    expect(
      _definition(
        state: array,
        slots: [_slot(path: '/vault/0/fact')],
      ).executable,
      isFalse,
    );
  });

  test('inherited hidden permits a slot while unrelated blocked and derived state remains preserved', () {
    final state = _state(
      fact: {
        'type': ['string', 'null'],
        'x-dsh-hidden': false,
      },
      parent: {'x-dsh-hidden': true},
      extra: {
        'opaque': {'type': 'string', 'pattern': '^A'},
        'derived': {'type': 'integer', 'x-dsh-derive': 2},
      },
    );
    final definition = _definition(state: state);
    final value = _value()..addAll({'opaque': 'uninterpreted', 'derived': 2});
    expect(definition.executable, isTrue);
    expect(_capture(definition, value: value).slotIds, ['slot']);
    expect(value['opaque'], 'uninterpreted');
  });

  test('capture requires complete valid saved state and real object parents without initialization', () {
    final definition = _definition();
    expect(_state().initialPreview().valid, isTrue);
    expect(_capture(definition, exists: false).slotIds, isEmpty);
    final wrongElsewhere = _value()..['public'] = 'wrong type';
    expect(_capture(definition, value: wrongElsewhere).slotIds, isEmpty);
    final missingParent = _value()..remove('vault');
    final missing = _capture(definition, value: missingParent);
    expect(missing.slotIds, isEmpty);
    expect(_codes(missing.issues), contains('secret_parent'));
    expect(missingParent.containsKey('vault'), isFalse);
    final nullableParent = _definition(
      state: _state(
        parent: {
          'type': ['object', 'null'],
        },
      ),
    );
    expect(_capture(nullableParent, value: _value()..['vault'] = null).slotIds, isEmpty);
    final nonfinite = _value()..['extra'] = double.infinity;
    expect(_capture(definition, value: nonfinite).slotIds, isEmpty);
    expect(_capture(definition, characterId: '').slotIds, isEmpty);
    expect(_capture(definition, value: _value(entity: '')).slotIds, isEmpty);
  });

  test('absent and explicit nullable unbound values authorize distinct CAS plans', () {
    final absent = _definition();
    final nullable = _definition(slots: [_slot(nullable: true)]);
    expect(_capture(absent).slotIds, ['slot']);
    expect(_capture(absent, value: _value(factExists: true)).slotIds, isEmpty);
    expect(_capture(nullable).slotIds, isEmpty);
    expect(_capture(nullable, value: _value(factExists: true)).slotIds, ['slot']);
    for (final definition in [absent, nullable]) {
      expect(_capture(definition, value: _value(factExists: true, fact: 'already bound')).slotIds, isEmpty);
    }
    final stringOnly = _state(fact: {'type': 'string', 'x-dsh-hidden': true});
    expect(_definition(state: stringOnly, slots: [_slot(nullable: true)]).executable, isFalse);
    final extraUnbound = _slot()..['unbound'] = <String, Object?>{'exists': false, 'value': null};
    expect(_definition(slots: [extraUnbound]).executable, isFalse);
    final required = _definition(
      state: _state(
        parent: {
          'required': ['fact'],
        },
      ),
    );
    expect(_capture(required).slotIds, isEmpty);
  });
  test('pointer escapes are exact and entity chains never cross arrays or overlap the fact', () {
    final state = StateDefinition.parse({
      'schema': {
        'type': 'object',
        'properties': {
          'entity': {'type': 'string'},
          'a/b': {
            'type': 'object',
            'properties': {'~secret': _leaf()},
          },
        },
      },
    });
    final escaped = _definition(
      state: state,
      slots: [_slot(path: '/a~1b/~0secret')],
    );
    final capability = _capture(escaped, value: {'entity': 'entity-A', 'a/b': <String, Object?>{}});
    expect(escaped.protectedPaths, ['/a~1b/~0secret']);
    expect(capability.plan(capability.parseProposal(_proposal()), id: 'escaped').facts.single.path, '/a~1b/~0secret');
    for (final entityPath in ['/vault', '/vault/fact', '/vault/fact/entity']) {
      expect(_definition(slots: [_slot(entityPath: entityPath)]).executable, isFalse);
    }
    final arrayEntity = _definition(
      state: _state(
        extra: {
          'entities': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
      ),
      slots: [_slot(entityPath: '/entities/0')],
    );
    expect(_capture(arrayEntity, value: _value()..['entities'] = <Object?>['entity-A']).slotIds, isEmpty);
    final numericProperty = _definition(
      state: _state(
        parent: {
          'properties': {'0': _leaf()},
        },
      ),
      slots: [_slot(path: '/vault/0')],
    );
    expect(_capture(numericProperty).slotIds, ['slot'], reason: 'A numeric object key is not an array path.');
  });

  test('binding keys are unambiguous and definition edits cannot reopen the same slot entity', () {
    expect(secretBindingKey('a:b', 'c'), _hash(['a:b', 'c']));
    expect(secretBindingKey('a:b', 'c'), isNot(secretBindingKey('a', 'b:c')));
    final state = _state(
      parent: {
        'properties': {'fact': _leaf(), 'other': _leaf()},
      },
    );
    final first = _definition(state: state);
    final changed = _definition(
      state: state,
      slots: [_slot(path: '/vault/other', template: 'new {{fact}}')],
    );
    expect(first.fingerprint, isNot(changed.fingerprint));
    final bound = [secretBindingKey('slot', 'entity-A')];
    expect(_capture(first, boundKeys: bound).slotIds, isEmpty);
    expect(_capture(changed, boundKeys: bound).slotIds, isEmpty);
    expect(
      _capture(
        changed,
        boundKeys: bound,
        value: _value(entity: 'entity-B'),
      ).slotIds,
      ['slot'],
    );
    expect(_capture(first, boundKeys: [secretBindingKey('unrelated', 'entity-A')]).slotIds, ['slot']);
  });

  test('capability freezes complete state definition recipient and catalog identities with detached getters', () {
    final rawState = _stateRaw();
    final state = StateDefinition.parse(rawState);
    final slot = _slot()
      ..['vendor'] = <String, Object?>{
        'nested': <Object?>['kept'],
      };
    final definition = _definition(state: state, slots: [slot]);
    final value = _value();
    final capability = _capture(definition, value: value);
    final fingerprint = capability.fingerprint;
    expect(capability.definitionFingerprint, definition.fingerprint);
    expect(capability.stateDefinitionFingerprint, state.fingerprint);
    expect(
      capability.baselineFingerprint,
      _hash({
        'exists': true,
        'value': {'entity': 'entity-A', 'public': 1, 'vault': <String, Object?>{}},
      }),
    );
    value['public'] = 2;
    ((rawState['schema']! as Json)['properties']! as Json).clear();
    capability.slotIds.clear();
    capability.issues.first['code'] = 'mutated';
    final catalog = capability.catalog;
    catalog.single['entityId'] = 'forged';
    final declaration = catalog.single['declaration']! as Json;
    ((declaration['vendor']! as Json)['nested']! as List<Object?>).clear();
    expect(capability.fingerprint, fingerprint);
    expect(capability.slotIds, ['slot']);
    expect(capability.catalog.single['entityId'], 'entity-A');
    expect(((capability.catalog.single['declaration']! as Json)['vendor']! as Json)['nested'], ['kept']);
    expect(_codes(capability.issues), ['secret_unknown']);
    expect(_capture(definition, value: value).fingerprint, isNot(fingerprint));
    expect(_capture(definition, characterId: 'character-B').fingerprint, isNot(fingerprint));
    expect(_capture(definition, value: _value()..['unrelated'] = 1).fingerprint, isNot(fingerprint));
    expect(_capture(definition, boundKeys: [secretBindingKey('slot', 'entity-A')]).fingerprint, isNot(fingerprint));
    final changedDefinition = _definition(state: state, slots: [_slot()..['vendor'] = 'different']);
    expect(_capture(changedDefinition).fingerprint, isNot(fingerprint));
    final changedState = _state(
      extra: {
        'another': {'type': 'integer'},
      },
    );
    expect(_capture(_definition(state: changedState, slots: [slot])).fingerprint, isNot(fingerprint));
  });

  test('strict tool exposes only captured slot ids and closed notes facts shapes', () {
    final capability = _capture(_definition());
    final tool = capability.strictTool()!;
    expect(tool['type'], 'function');
    final function = tool['function']! as Json;
    expect(function['name'], 'propose_secrets');
    expect(function['strict'], isTrue);
    final parameters = function['parameters']! as Json;
    expect(parameters['required'], ['notes', 'facts']);
    expect(parameters['additionalProperties'], isFalse);
    final properties = parameters['properties']! as Json;
    expect(properties.keys, unorderedEquals(['notes', 'facts']));
    final item = (properties['facts']! as Json)['items']! as Json;
    expect(item['required'], ['slotId', 'value']);
    expect(item['additionalProperties'], isFalse);
    final fields = item['properties']! as Json;
    expect(fields.keys, unorderedEquals(['slotId', 'value']));
    expect((fields['slotId']! as Json)['enum'], ['slot']);
    expect(fields['value'], {'type': 'string'});
    expect((properties['facts']! as Json).keys, unorderedEquals(['type', 'items']));
    ((fields['slotId']! as Json)['enum']! as List<Object?>).clear();
    expect(jsonEncode(capability.strictTool()), contains('"enum":["slot"]'));
    final unavailable = _capture(_definition(), boundKeys: [secretBindingKey('slot', 'entity-A')]);
    expect(unavailable.strictTool(), isNull);
    expect(() => unavailable.parseProposal(_proposal()), throwsFormatException);
    expect(unavailable.parseProposal(_proposal(facts: [])).facts, isEmpty);
  });

  test('proposal parser rejects added authority fields wrong shapes duplicate or unauthorized slots', () {
    final capability = _capture(_definition());
    final invalid = <Object?>[
      null,
      [],
      '{"notes":"","facts":[]}',
      {'notes': '', 'facts': [], 'path': '/vault/fact'},
      {'notes': null, 'facts': []},
      {'notes': '', 'facts': {}},
      {
        'notes': '',
        'facts': [null],
      },
      _proposal(
        facts: [
          {'slotId': 'not-captured', 'value': 'v'},
        ],
      ),
      _proposal(
        facts: [
          {'slotId': 'slot', 'value': 1},
        ],
      ),
      _proposal(
        facts: [
          {'slotId': 'slot', 'value': 'a'},
          {'slotId': 'slot', 'value': 'b'},
        ],
      ),
      {'notes': double.nan, 'facts': []},
    ];
    for (final field in ['path', 'entityId', 'when', 'release', 'ops']) {
      invalid.add(
        _proposal(
          facts: [
            {'slotId': 'slot', 'value': 'v', field: 'model supplied'},
          ],
        ),
      );
    }
    for (final raw in invalid) {
      expect(() => capability.parseProposal(raw), throwsFormatException);
    }
    final empty = capability.parseProposal(_proposal(notes: 'no suggestion', facts: []));
    expect(empty.notes, 'no suggestion');
    expect(empty.facts, isEmpty);
    expect(() => capability.plan(empty, id: 'empty'), throwsFormatException);
  });
  test('proposal count and value limits accept exact boundaries and count UTF8 bytes', () {
    final capability = _capture(_many(9));
    final eight = <Json>[
      for (var i = 0; i < 8; i++) {'slotId': 's$i', 'value': ''},
    ];
    expect(capability.parseProposal(_proposal(facts: eight)).facts, hasLength(8));
    expect(
      () => capability.parseProposal(
        _proposal(
          facts: [
            ...eight,
            {'slotId': 's8', 'value': ''},
          ],
        ),
      ),
      throwsFormatException,
    );
    final exact = _repeat('🐋', 4096);
    expect(utf8.encode(exact), hasLength(16 * 1024));
    final accepted = capability.parseProposal(
      _proposal(
        facts: [
          {'slotId': 's0', 'value': exact},
        ],
      ),
    );
    expect(accepted.facts.single['value'], exact);
    expect(
      () => capability.parseProposal(
        _proposal(
          facts: [
            {'slotId': 's0', 'value': '${exact}x'},
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('whole proposal size includes notes and encoded JSON at exactly 256 KiB', () {
    final capability = _capture(_definition());
    final raw = _proposal(
      facts: [
        {'slotId': 'slot', 'value': 'fact'},
      ],
    );
    final room = 256 * 1024 - utf8.encode(jsonEncode(raw)).length;
    raw['notes'] = '${_repeat('界', room ~/ 3)}${_repeat('x', room % 3)}';
    expect(utf8.encode(jsonEncode(raw)), hasLength(256 * 1024));
    expect(capability.parseProposal(raw).notes, raw['notes']);
    raw['notes'] = '${raw['notes']}!';
    expect(() => capability.parseProposal(raw), throwsFormatException);
  });

  test('registry size and slot count preserve exact inclusive boundaries', () {
    final raw = <String, Object?>{'v': 1, 'slots': <Object?>[], 'note': ''};
    final room = 1024 * 1024 - utf8.encode(jsonEncode(raw)).length;
    raw['note'] = '${_repeat('界', room ~/ 3)}${_repeat('x', room % 3)}';
    expect(utf8.encode(jsonEncode(raw)), hasLength(1024 * 1024));
    expect(SecretDefinition.parse(raw, state: _state()).executable, isTrue);
    raw['note'] = '${raw['note']}!';
    final oversized = SecretDefinition.parse(raw, state: _state());
    expect(oversized.executable, isFalse);
    expect(_codes(oversized.issues), contains('secret_size'));
    final exact = _many(256);
    expect(exact.executable, isTrue);
    expect(_capture(exact).slotIds, hasLength(256));
    final tooMany = _many(257);
    expect(tooMany.executable, isFalse);
    expect(tooMany.protectedPaths, hasLength(257));
    expect(_capture(tooMany).slotIds, isEmpty);
    expect(_codes(tooMany.issues), contains('secret_slots_limit'));
  });

  test('conditions reuse existing JsonLogic node depth and evaluation failure boundaries', () {
    final nodes = List<Object?>.filled(4095, true);
    final exact = _definition(
      slots: [_slot(bindWhen: nodes, releaseWhen: nodes)],
    );
    expect(exact.executable, isTrue);
    expect(_capture(exact).slotIds, ['slot']);
    final overNodes = _definition(
      slots: [
        _slot(bindWhen: [...nodes, true]),
      ],
    );
    expect(overNodes.executable, isFalse);
    expect(_codes(overNodes.issues), contains('logic_limit'));
    Object? nested = true;
    for (var i = 0; i < 64; i++) {
      nested = <Object?>[nested];
    }
    expect(_definition(slots: [_slot(releaseWhen: nested)]).executable, isTrue);
    final overDepth = _definition(
      slots: [
        _slot(releaseWhen: <Object?>[nested]),
      ],
    );
    expect(overDepth.executable, isFalse);
    expect(_codes(overDepth.issues), contains('logic_limit'));
    final condition = _definition(
      slots: [
        _slot(
          bindWhen: {
            '==': [
              {'var': 'public'},
              1,
            ],
          },
        ),
      ],
    );
    expect(_capture(condition).slotIds, ['slot']);
    expect(_capture(condition, value: _value(publicValue: 2)).slotIds, isEmpty);
    final failed = _definition(
      slots: [
        _slot(
          bindWhen: {
            '/': [1, 0],
          },
        ),
      ],
    );
    expect(failed.executable, isTrue);
    expect(_capture(failed).slotIds, isEmpty);
    expect(_codes(_capture(failed).issues), contains('logic_result'));
    expect(
      _definition(
        slots: [
          _slot(bindWhen: {'hostAction': 'forbidden operator'}),
        ],
      ).executable,
      isFalse,
    );
  });

  test('plan uses frozen host entity path and CAS data and composes with one real StateSession', () {
    for (final nullable in [false, true]) {
      final state = _state();
      final definition = _definition(
        state: state,
        slots: [_slot(nullable: nullable)],
      );
      final value = _value(factExists: nullable);
      final capability = _capture(definition, value: value);
      final raw = _proposal(notes: '{{setvar::x::y}} is literal');
      final proposal = capability.parseProposal(raw);
      (raw['facts']! as List<Json>).single['value'] = 'caller mutation';
      proposal.facts.single['value'] = 'getter mutation';
      (proposal.toJson()['facts']! as List<Object?>).clear();
      expect(proposal.notes, '{{setvar::x::y}} is literal');
      expect(proposal.facts, [
        {'slotId': 'slot', 'value': 'chosen'},
      ]);
      final plan = capability.plan(proposal, id: 'plan-$nullable');
      expect(plan.id, 'plan-$nullable');
      expect(plan.stateDefinitionFingerprint, state.fingerprint);
      expect(plan.baselineFingerprint, capability.baselineFingerprint);
      final fact = plan.facts.single;
      expect(
        [fact.slotId, fact.entityId, fact.path, fact.expectedExists, fact.expectedValue, fact.value],
        ['slot', 'entity-A', '/vault/fact', nullable, null, 'chosen'],
      );
      final other = _capture(definition, value: value, characterId: 'character-B');
      expect(() => other.plan(proposal, id: 'wrong-capture'), throwsFormatException);
      final session = state.startSession(valueExists: true, value: value);
      final prepared = session.prepareSecretFacts(plan);
      expect(prepared.accepted, isTrue);
      expect(prepared.value, _value(factExists: true, fact: 'chosen'));
      expect(value, _value(factExists: nullable), reason: 'Preparing never mutates the caller state.');
      final result = session.finish(runRules: false);
      expect(result.value, _value(factExists: true, fact: 'chosen'));
      expect(result.effects, isEmpty);
      expect(session.secretTerminalPhase(prepared).changes, isEmpty);
    }
  });

  test('release rechecks current entity full state value and condition with literal one-pass substitution', () {
    final definition = _definition(
      slots: [
        _slot(
          bindWhen: false,
          releaseWhen: {
            '==': [
              {'var': 'public'},
              1,
            ],
          },
          template: '公开 {{fact}} / {{fact}}; {{user}} {{setvar::x::y}}',
        ),
      ],
    );
    const fact = '鲸{{fact}}\u0000';
    final value = _value(factExists: true, fact: fact);
    final release = _release(definition, value)!;
    expect(
      [release.slotId, release.entityId, release.path, release.releaseId, release.characterId],
      ['slot', 'entity-A', '/vault/fact', 'reveal-slot', 'character-A'],
    );
    expect(release.definitionFingerprint, definition.fingerprint);
    expect(release.valueHash, _hash(fact));
    expect(release.text, '公开 $fact / $fact; {{user}} {{setvar::x::y}}');
    release.toJson()['text'] = 'changed';
    expect(release.text, '公开 $fact / $fact; {{user}} {{setvar::x::y}}');
    expect(_capture(definition).slotIds, isEmpty, reason: 'Release does not reuse the earlier bindWhen condition.');
    expect(_release(definition, _value(factExists: true, fact: fact, publicValue: 0)), isNull);
    expect(_release(definition, _value(factExists: true, fact: fact, entity: 'entity-B')), isNull);
    expect(_release(definition, _value()), isNull);
    expect(_release(definition, _value(factExists: true)), isNull);
    expect(_release(definition, _value(factExists: true, fact: fact)..['public'] = 'invalid'), isNull);
    expect(
      definition.releaseFor(
        slotId: 'unknown',
        entityId: 'entity-A',
        characterId: 'character-A',
        value: value,
        valueExists: true,
      ),
      isNull,
    );
    expect(
      definition.releaseFor(
        slotId: 'slot',
        entityId: 'entity-A',
        characterId: 'character-A',
        value: value,
        valueExists: false,
      ),
      isNull,
    );
    expect(_release(definition, value, characterId: ''), isNull);
    expect(_release(definition, _value(factExists: true, fact: _repeat('x', 16 * 1024 + 1))), isNull);
    final changed = _release(definition, _value(factExists: true, fact: 'current value'))!;
    expect(changed.valueHash, isNot(release.valueHash));
    expect(changed.text, '公开 current value / current value; {{user}} {{setvar::x::y}}');
    // This pure function does not claim a persisted bind record. A different
    // recipient/value is returned as such; the host must authenticate both.
    expect(_release(definition, value, characterId: 'character-B')!.characterId, 'character-B');
    expect(_release(_definition(slots: []), value), isNull);
    expect(_release(_definition(state: _state(fact: {'type': 'string'})), value), isNull);
    final badCondition = _definition(
      slots: [
        _slot(
          releaseWhen: {
            '/': [1, 0],
          },
        ),
      ],
    );
    expect(_release(badCondition, value), isNull);
  });
}

Json _leaf() => {
  'type': ['string', 'null'],
  'x-dsh-hidden': true,
};
Json _value({bool factExists = false, Object? fact, String entity = 'entity-A', int publicValue = 1}) => {
  'entity': entity,
  'public': publicValue,
  'vault': <String, Object?>{if (factExists) 'fact': fact},
};
Json _stateRaw({Json? fact, Json? parent, Json? extra}) => {
  'schema': <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'entity': <String, Object?>{'type': 'string'},
      'public': <String, Object?>{'type': 'integer'},
      'vault': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{'fact': fact ?? _leaf()},
        ...?parent,
      },
      ...?extra,
    },
  },
  'init': _value(),
};
StateDefinition _state({Json? fact, Json? parent, Json? extra}) =>
    StateDefinition.parse(_stateRaw(fact: fact, parent: parent, extra: extra));
Json _slot({
  String id = 'slot',
  String path = '/vault/fact',
  String entityPath = '/entity',
  bool nullable = false,
  Object? bindWhen = true,
  Object? releaseWhen = true,
  String template = '{{fact}}',
}) => {
  'id': id,
  'path': path,
  'entityPath': entityPath,
  'unbound': <String, Object?>{'exists': nullable, if (nullable) 'value': null},
  'bindWhen': bindWhen,
  'release': <String, Object?>{
    'id': 'reveal-$id',
    'audience': 'currentCharacter',
    'when': releaseWhen,
    'template': template,
  },
};
SecretDefinition _definition({StateDefinition? state, List<Object?>? slots}) => SecretDefinition.parse({
  'v': 1,
  'slots': slots ?? [_slot()],
}, state: state ?? _state());
SecretCapability _capture(
  SecretDefinition definition, {
  Json? value,
  bool exists = true,
  Iterable<String> boundKeys = const [],
  String characterId = 'character-A',
}) => definition.capture(value: value ?? _value(), valueExists: exists, boundKeys: boundKeys, characterId: characterId);
Json _proposal({String notes = '', List<Json>? facts}) => {
  'notes': notes,
  'facts':
      facts ??
      <Json>[
        {'slotId': 'slot', 'value': 'chosen'},
      ],
};
List<Object?> _codes(List<Json> issues) => issues.map((issue) => issue['code']).toList();
String _repeat(String value, int count) => List<String>.filled(count, value).join();
String _hash(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();
SecretDefinition _many(int count) => _definition(
  state: _state(
    parent: {
      'properties': <String, Object?>{for (var i = 0; i < count; i++) 'f$i': _leaf()},
    },
  ),
  slots: [for (var i = 0; i < count; i++) _slot(id: 's$i', path: '/vault/f$i')],
);
SecretRelease? _release(SecretDefinition definition, Json value, {String characterId = 'character-A'}) => definition
    .releaseFor(slotId: 'slot', entityId: 'entity-A', characterId: characterId, value: value, valueExists: true);
