import 'package:dsh_tavern/src/state/state_engine.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

const legacy = StateExecutionSource.legacy();
const a = StateExecutionSource.pack(installedPackId: 'installed', bindingId: 'a', onceEpoch: 1);
const b = StateExecutionSource.pack(installedPackId: 'installed', bindingId: 'b', onceEpoch: 1);
const a2 = StateExecutionSource.pack(installedPackId: 'installed', bindingId: 'a', onceEpoch: 2);

void main() {
  test('composed once stays in the physical binding epoch and preserves legacy keys', () {
    final legacyRaw = {
      ..._countState(),
      'rules': [_rule('same', 1)],
    };
    final legacyDefinition = StateDefinition.parse(legacyRaw);
    final legacyResult = legacyDefinition.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(_map(legacyResult.runtime)['firedRules'], ['id:same']);
    expect(legacyResult.toJson().containsKey('packRuntime'), isFalse);

    final definition = _compose([
      StateRuleSource(source: legacy, state: legacyRaw),
      _rules(a, [_rule('same', 1)]),
      _rules(b, [_rule('same', 1)]),
    ], config: 'first');
    final first = definition.startSession(valueExists: true, value: {'n': 0}).finish();
    expect(first.valid, isTrue);
    expect(_map(first.value)['n'], 3);
    expect(first.runtime, legacyResult.runtime);
    expect(_row(first.packRuntime, 'a')['rules'], ['same']);
    expect(_row(first.packRuntime, 'b')['rules'], ['same']);
    expect(
      first.receipts
          .where((row) => row['operation'] is Json && _map(row['operation'])['op'] == 'rule')
          .first
          .containsKey('executionSource'),
      isFalse,
    );
    final saved = _map(first.packRuntime);
    _row(saved, 'a')['foreign'] = {'kept': true};
    _row(saved, 'b')['worldInfo'] = {
      'opaque': [7],
    };
    final savedBefore = _copy(saved);

    // A changed body and order preserve the same per-binding consumption.
    final upgraded = _compose([
      _rules(b, [_rule('same', 10)]),
      StateRuleSource(source: legacy, state: legacyRaw),
      _rules(a, [_rule('same', 100)]),
    ], config: 'second');
    expect(upgraded.fingerprint, isNot(definition.fingerprint));
    final repeated = upgraded
        .startSession(
          valueExists: true,
          value: first.value,
          runtimeExists: true,
          runtime: first.runtime,
          packRuntimeExists: true,
          packRuntime: saved,
        )
        .finish();
    expect(_map(repeated.value)['n'], 3);
    expect(repeated.changed, isFalse);

    final reset =
        _compose([
              _rules(a2, [_rule('same', 100)]),
              _rules(b, [_rule('same', 10)]),
              StateRuleSource(source: legacy, state: legacyRaw),
            ], config: 'third')
            .startSession(
              valueExists: true,
              value: first.value,
              runtimeExists: true,
              runtime: first.runtime,
              packRuntimeExists: true,
              packRuntime: saved,
            )
            .finish();
    expect(_map(reset.value)['n'], 103);
    expect(_row(reset.packRuntime, 'a')['onceEpoch'], 2);
    expect(_row(reset.packRuntime, 'a')['foreign'], {'kept': true});
    expect(_row(reset.packRuntime, 'b')['worldInfo'], {
      'opaque': [7],
    });
    expect(saved, savedBefore);
    expect(_row(first.packRuntime, 'a')['onceEpoch'], 1);

    // An unrelated malformed pack carrier is inert on a legacy invocation.
    final untouched = legacyDefinition
        .startSession(valueExists: true, value: {'n': 0}, packRuntimeExists: true, packRuntime: const [])
        .finish();
    expect(untouched.valid, isTrue);
    expect(_map(untouched.value)['n'], 1);
    expect(untouched.packRuntime, isEmpty);
    final blocked = _compose([
      _rules(a, [_rule('same', 1)]),
    ]).startSession(valueExists: true, value: {'n': 0}, packRuntimeExists: true, packRuntime: const []).finish();
    expect(_map(blocked.value)['n'], 0);
    expect(blocked.packRuntime, isEmpty);
    expect(blocked.receipts.map((row) => row['status']), contains('runtime_error'));

    // The core does not turn an invalid old value into a permanent repair lock.
    final repair = _compose(const []).startSession(valueExists: true, value: {'n': 'old'});
    expect(
      repair.apply([
        {'op': 'set', 'path': '/n', 'value': 4, 'why': 'explicit repair'},
      ], actor: StateActor.user).acceptedCount,
      1,
    );
    expect(repair.finish().valid, isTrue);
  });

  test('full source duplicate checks and declaration slots feed one shared finish budget', () {
    final declarations = <Object?>[
      for (var i = 0; i < 257; i++)
        if (i == 0 || i == 256) _rule('duplicate', 1) else null,
    ];
    final limited = _compose([
      _rules(legacy, declarations),
      _rules(a, [_rule('tail', 9)]),
    ]).startSession(valueExists: true, value: {'n': 0}).finish();
    expect(_map(limited.value)['n'], 0);
    expect(limited.issues.map((row) => row['code']), contains('rule_duplicate_id'));
    expect(limited.issues.map((row) => row['code']), contains('rules_composition_limit'));
    expect(limited.packRuntimeExists, isFalse);

    final noticeRules = <Object?>[
      for (var i = 0; i < 128; i++)
        {
          'id': '$i',
          'when': true,
          'do': [
            {'type': 'notice', 'text': '$i'},
          ],
        },
    ];
    final state = _compose([_rules(legacy, noticeRules), _rules(a, noticeRules)]);
    final events = CardEventDefinition.compose(
      [
        CardEventRegistrySource(source: a, raw: _registry([_handler('h', 'next', 1)])),
      ],
      effectiveConfigId: 'configuration',
      compositionEligible: true,
    );
    final invocation = _invocation(events, const [
      CardEventProposal(eventId: 'event', runId: 'run', name: 'next', data: '', source: a),
    ]);
    final session = state.startSession(valueExists: true, value: {'n': 0});
    final result = session.finishWithEvents(invocation);
    expect(result.state.effects, hasLength(256));
    expect(_map(result.state.value)['n'], 0);
    expect(result.events.issues.map((row) => row['code']), contains('card_event_actions_limit'));
    expect(result.state.packRuntimeExists, isFalse);
    expect(identical(session.finishWithEvents(invocation), result), isTrue);
    expect(
      () => session.finishWithEvents(
        _invocation(events, const [
          CardEventProposal(eventId: 'different', runId: 'run', name: 'next', data: '', source: a),
        ]),
      ),
      throwsStateError,
    );

    final ineligible = StateDefinition.compose(
      _countState(),
      effectiveConfigId: 'bad-source',
      sources: [
        _rules(a, [_rule('x', 1)]),
      ],
      compositionEligible: false,
    );
    expect(ineligible.executable, isFalse);
    final preserved = ineligible.startSession(valueExists: true, value: {'n': 7}).finish();
    expect(_map(preserved.value)['n'], 7);
    expect(preserved.packRuntimeExists, isFalse);
  });

  test('typed event targets keep owner consumption and share the already updated rule candidate', () {
    final rawA = _registry([
      _handler('same', 'original-a', 1),
      {
        'id': 'bad',
        'name': 'original-a',
        'when': true,
        'do': [
          {'type': 'not-supported'},
        ],
      },
    ]);
    (_map((rawA['rules']! as List<Object?>).first)['do']! as List<Object?>).add({
      'type': 'event',
      'name': 'untouched-handler-name',
      'data': 'literal',
    });
    final definition = CardEventDefinition.compose(
      [
        CardEventRegistrySource(source: legacy, raw: _registry([_handler('same', 'shared', 100)])),
        CardEventRegistrySource(
          source: a,
          raw: rawA,
          eventTargets: const {0: (source: b, name: 'shared')},
          actionTargets: const {(0, 1): (source: legacy, name: 'handled-target')},
        ),
        CardEventRegistrySource(source: b, raw: _registry([_handler('same', 'shared', 2)])),
      ],
      effectiveConfigId: 'events-1',
      compositionEligible: true,
    );
    expect(definition.executable, isTrue);
    expect(definition.issues.map((row) => row['code']), contains('card_event_action'));
    expect(definition.eventTargets, contains((source: b, name: 'shared')));
    expect(_map((rawA['rules']! as List<Object?>).first)['name'], 'original-a');
    final rule = _rule('same', 10);
    (rule['do']! as List<Object?>).add({'type': 'event', 'name': 'untouched-rule-name', 'data': 'literal'});
    final state = _compose([
      StateRuleSource(
        source: a,
        state: {
          'rules': [rule],
        },
        actionTargets: const {(0, 1): (source: b, name: 'rule-target')},
      ),
    ], config: 'events-1');
    final invocation = _invocation(definition, const [
      CardEventProposal(eventId: 'e', runId: 'r', name: 'shared', data: 'literal', source: b),
    ]);
    final mismatched = _compose(
      const [],
      config: 'other-configuration',
    ).startSession(valueExists: true, value: {'n': 0}).finishWithEvents(invocation);
    expect(mismatched.events.valid, isFalse);
    expect(mismatched.events.issues.map((row) => row['code']), contains('card_event_composition'));
    expect(_map(mismatched.state.value)['n'], 0);
    final session = state.startSession(valueExists: true, value: {'n': 0});
    final finished = session.finishWithEvents(invocation);
    expect(_map(finished.state.value)['n'], 13);
    final eventEffects = finished.state.effects.where((effect) => effect['type'] == 'event').toList();
    expect(eventEffects.map((effect) => effect['name']), ['untouched-rule-name', 'untouched-handler-name']);
    expect(eventEffects.map((effect) => effect['eventTarget']), [
      {'source': b.toJson(), 'name': 'rule-target'},
      {'source': legacy.toJson(), 'name': 'handled-target'},
    ]);
    expect((rule['do']! as List<Object?>).last, {'type': 'event', 'name': 'untouched-rule-name', 'data': 'literal'});
    expect(_row(finished.state.packRuntime, 'a')['rules'], ['same']);
    expect(_map(_row(finished.state.packRuntime, 'a')['events'])['consumed'], [
      {'eventId': 'e', 'handlerId': 'same'},
    ]);
    expect(_map(_row(finished.state.packRuntime, 'b')['events'])['consumed'], [
      {'eventId': 'e', 'handlerId': 'same'},
    ]);
    expect(finished.events.packRuntime, finished.state.packRuntime);
    expect(finished.events.runtimeExists, isFalse);
    expect(identical(session.finishWithEvents(invocation), finished), isTrue);

    final wrongAuthorization = CardEventInvocation(
      definition: definition,
      invocationId: 'i',
      capabilityFingerprint: definition.fingerprint,
      authorizedHandlerIds: ['same'],
      proposals: invocation.proposals,
      runtimeExists: false,
      stateActionAllowed: false,
    );
    expect(settleCardEventsEffectsOnly(wrongAuthorization).valid, isFalse);
    final otherDefinition = CardEventDefinition.compose(
      [CardEventRegistrySource(source: a2, raw: rawA)],
      effectiveConfigId: 'events-2',
      compositionEligible: true,
    );
    expect(
      () => session.finishWithEvents(
        _invocation(otherDefinition, const [
          CardEventProposal(eventId: 'e', runId: 'r', name: 'original-a', data: 'literal', source: a2),
        ]),
      ),
      throwsStateError,
    );

    const c = StateExecutionSource.pack(installedPackId: 'installed', bindingId: 'c', onceEpoch: 1);
    final effectsOnly = CardEventDefinition.compose(
      [
        CardEventRegistrySource(
          source: c,
          raw: _registry([
            {
              'id': 'notice',
              'name': 'show',
              'once': true,
              'when': true,
              'do': [
                {'type': 'notice', 'text': 'literal'},
              ],
            },
          ]),
        ),
      ],
      effectiveConfigId: 'effects',
      compositionEligible: true,
    );
    final oldPack = _map(finished.state.packRuntime);
    _row(oldPack, 'a')['worldInfo'] = {'kept': true};
    final oldCopy = _copy(oldPack);
    final eventResult = settleCardEventsEffectsOnly(
      _invocation(
        effectsOnly,
        const [CardEventProposal(eventId: 'show-1', runId: 'r', name: 'show', data: '', source: c)],
        packRuntime: oldPack,
        packRuntimeExists: true,
      ),
    );
    expect(eventResult.effects, hasLength(1));
    expect(_row(eventResult.packRuntime, 'a'), _row(oldPack, 'a'));
    expect(_row(eventResult.packRuntime, 'b'), _row(oldPack, 'b'));
    expect(_map(_row(eventResult.packRuntime, 'c')['events'])['once'], ['notice']);
    expect(oldPack, oldCopy);
    final snapshot = effectsOnly.inspect(
      runtimeExists: false,
      packRuntimeExists: true,
      packRuntime: eventResult.packRuntime,
    );
    expect(snapshot.valid, isTrue);
    expect(snapshot.packRuntime, eventResult.packRuntime);
    final absent = CardEventDefinition.compose(
      [CardEventRegistrySource(source: a, raw: null)],
      effectiveConfigId: 'absent',
      compositionEligible: true,
    );
    expect(absent.defined, isFalse);
    expect(absent.executable, isFalse);
    final preserved = absent.inspect(
      runtimeExists: false,
      packRuntimeExists: true,
      packRuntime: eventResult.packRuntime,
      activeSources: [c],
    );
    expect(preserved.valid, isTrue);
    expect(preserved.packRuntime, eventResult.packRuntime);
    final broken = _map(_copy(eventResult.packRuntime));
    _row(broken, 'c')['events'] = 'invalid';
    expect(
      absent.inspect(runtimeExists: false, packRuntimeExists: true, packRuntime: broken, activeSources: [c]).valid,
      isFalse,
    );
  });

  test('secret keys survive epoch reset while capabilities and terminal pack facts stay source-bound', () {
    final stateRaw = <String, Object?>{
      'schema': {
        'type': 'object',
        'required': ['entity', 'secret', 'n'],
        'properties': {
          'entity': {'type': 'string'},
          'secret': {
            'type': ['string', 'null'],
            'x-dsh-hidden': true,
          },
          'n': {'type': 'integer'},
        },
      },
    };
    StateDefinition stateFor(String config, StateExecutionSource source) => StateDefinition.compose(
      stateRaw,
      effectiveConfigId: config,
      sources: [
        _rules(source, [_rule('count', 1)]),
      ],
      compositionEligible: true,
    );
    final state = stateFor('secret-1', a);
    final raw = <String, Object?>{
      'v': 1,
      'slots': [
        {
          'id': 'slot',
          'path': '/secret',
          'entityPath': '/entity',
          'unbound': {'exists': true, 'value': null},
          'bindWhen': true,
          'release': {'id': 'tell', 'audience': 'currentCharacter', 'when': true, 'template': '{{fact}}'},
        },
      ],
    };
    final definition = SecretDefinition.parse(raw, state: state, source: a, effectiveConfigId: 'secret-1');
    final baseline = <String, Object?>{'entity': 'E', 'secret': null, 'n': 0};
    final key = secretBindingKey('slot', 'E', source: a);
    expect(secretBindingKey('slot', 'E'), secretBindingKey('slot', 'E', source: legacy));
    expect(key, isNot(secretBindingKey('slot', 'E')));
    expect(key, secretBindingKey('slot', 'E', source: a2));
    expect(key, isNot(secretBindingKey('slot', 'E', source: b)));
    expect(
      definition.capture(value: baseline, valueExists: true, boundKeys: [key], characterId: 'character').slotIds,
      isEmpty,
    );
    final capability = definition.capture(
      value: baseline,
      valueExists: true,
      boundKeys: [secretBindingKey('slot', 'E')],
      characterId: 'character',
    );
    expect(capability.slotIds, ['slot']);
    final proposal = capability.parseProposal({
      'notes': '',
      'facts': [
        {'slotId': 'slot', 'value': 'fact'},
      ],
    });
    final nextDefinition = SecretDefinition.parse(
      raw,
      state: stateFor('secret-2', a2),
      source: a2,
      effectiveConfigId: 'secret-2',
    );
    final nextCapability = nextDefinition.capture(
      value: baseline,
      valueExists: true,
      boundKeys: const [],
      characterId: 'character',
    );
    expect(nextCapability.fingerprint, isNot(capability.fingerprint));
    expect(() => nextCapability.plan(proposal, id: 'other'), throwsFormatException);

    final savedPack = <String, Object?>{
      'v': 1,
      'bindings': {
        'b': {
          'installedPackId': 'installed',
          'onceEpoch': 1,
          'worldInfo': {'kept': true},
        },
      },
    };
    final session = state.startSession(
      valueExists: true,
      value: baseline,
      packRuntimeExists: true,
      packRuntime: savedPack,
    );
    final prepared = session.prepareSecretFacts(capability.plan(proposal, id: 'bind'));
    expect(prepared.accepted, isTrue);
    expect(prepared.packRuntime, savedPack);
    expect(_map(prepared.value)['secret'], 'fact');
    final finished = session.finish();
    final terminal = session.secretTerminalPhase(prepared);
    expect(_map(finished.value)['n'], 1);
    expect(terminal.packRuntime, finished.packRuntime);
    expect(_row(terminal.packRuntime, 'a')['rules'], ['count']);
    expect(_row(terminal.packRuntime, 'b')['worldInfo'], {'kept': true});
    expect(prepared.packRuntime, savedPack);
    expect(_map(savedPack['bindings']).containsKey('a'), isFalse);
  });
}

Json _countState() => {
  'schema': {
    'type': 'object',
    'required': ['n'],
    'properties': {
      'n': {'type': 'integer'},
    },
  },
};

StateDefinition _compose(List<StateRuleSource> sources, {String config = 'configuration'}) =>
    StateDefinition.compose(_countState(), effectiveConfigId: config, sources: sources, compositionEligible: true);

StateRuleSource _rules(StateExecutionSource source, List<Object?> rules) =>
    StateRuleSource(source: source, state: {'rules': rules});

Json _rule(String id, int amount) => {
  'id': id,
  'once': true,
  'when': true,
  'do': [
    {
      'type': 'state',
      'ops': [
        {'op': 'add', 'path': '/n', 'value': amount, 'why': 'rule'},
      ],
    },
  ],
};

Json _handler(String id, String name, int amount) => {
  'id': id,
  'name': name,
  'once': true,
  'when': true,
  'do': [
    {
      'type': 'state',
      'ops': [
        {'op': 'add', 'path': '/n', 'value': amount, 'why': 'event'},
      ],
    },
  ],
};

Json _registry(List<Object?> handlers) => {'v': 1, 'rules': handlers};

CardEventInvocation _invocation(
  CardEventDefinition definition,
  List<CardEventProposal> proposals, {
  bool packRuntimeExists = false,
  Object? packRuntime,
}) => CardEventInvocation.composed(
  definition: definition,
  invocationId: 'invocation',
  capabilityFingerprint: definition.fingerprint,
  authorizedHandlers: definition.handlerRefs,
  proposals: proposals,
  runtimeExists: false,
  packRuntimeExists: packRuntimeExists,
  packRuntime: packRuntime,
  stateActionAllowed: true,
);

Json _map(Object? value) => value! as Json;
Json _row(Object? runtime, String id) => _map(_map(_map(runtime)['bindings'])[id]);
Object? _copy(Object? value) => switch (value) {
  final Map<String, Object?> value => {for (final entry in value.entries) entry.key: _copy(entry.value)},
  final List<Object?> value => [for (final item in value) _copy(item)],
  _ => value,
};
