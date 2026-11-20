part of 'state_engine.dart';

/// Inert proposal text. data is never parsed as JSON, an expression or an op.
class CardEventProposal {
  const CardEventProposal({
    required this.eventId,
    required this.runId,
    required this.name,
    required this.data,
    this.source = const StateExecutionSource.legacy(),
  });
  final StateExecutionSource source;
  final String eventId;
  final String runId;
  final String name;
  final String data;
  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'name': name,
    'data': data,
    if (source.isPack) 'executionSource': source.toJson(),
  };
}

/// Detached admission. The host authenticates persisted capability, source
/// and branch; pure settlement rechecks its fingerprint, handler ids and ledger.
class CardEventInvocation {
  CardEventInvocation({
    required this.definition,
    required this.invocationId,
    required this.capabilityFingerprint,
    required Iterable<String> authorizedHandlerIds,
    required Iterable<CardEventProposal> proposals,
    required this.runtimeExists,
    Object? runtime,
    required this.stateActionAllowed,
  }) : _authorizedHandlerIds = List<String>.unmodifiable(authorizedHandlerIds),
       _proposals = List<CardEventProposal>.unmodifiable(proposals),
       _runtime = _eventCopy(runtime),
       _authorizedHandlers = null,
       packRuntimeExists = false,
       _packRuntime = null;

  CardEventInvocation.composed({
    required this.definition,
    required this.invocationId,
    required this.capabilityFingerprint,
    required Iterable<CardEventHandlerRef> authorizedHandlers,
    required Iterable<CardEventProposal> proposals,
    required this.runtimeExists,
    Object? runtime,
    required this.packRuntimeExists,
    Object? packRuntime,
    required this.stateActionAllowed,
  }) : _authorizedHandlerIds = const [],
       _authorizedHandlers = List.unmodifiable(authorizedHandlers),
       _proposals = List.unmodifiable(proposals),
       _runtime = _eventCopy(runtime),
       _packRuntime = _eventCopy(packRuntime);

  final CardEventDefinition definition;
  final String invocationId;
  final String capabilityFingerprint;
  final bool runtimeExists;
  final bool stateActionAllowed;
  final List<String> _authorizedHandlerIds;
  final List<CardEventHandlerRef>? _authorizedHandlers;
  final bool packRuntimeExists;
  final Object? _packRuntime;
  final List<CardEventProposal> _proposals;
  final Object? _runtime;
  List<String> get authorizedHandlerIds => List.of(_authorizedHandlerIds);
  List<CardEventHandlerRef> get authorizedHandlers => _authorizedHandlers == null
      ? [
          for (final id in _authorizedHandlerIds)
            CardEventHandlerRef(source: const StateExecutionSource.legacy(), localId: id),
        ]
      : List.of(_authorizedHandlers);
  Object? get packRuntime => _eventCopy(_packRuntime);
  List<CardEventProposal> get proposals => List.of(_proposals);
  Object? get runtime => _eventCopy(_runtime);
  bool _sameBatch(CardEventInvocation other) =>
      identical(this, other) ||
      (invocationId == other.invocationId &&
          capabilityFingerprint == other.capabilityFingerprint &&
          _eventEqual(definition._raw, other.definition._raw) &&
          _eventEqual(definition._version, other.definition._version) &&
          _eventEqual(definition._compositionIdentity, other.definition._compositionIdentity) &&
          _eventEqual(
            [for (final ref in authorizedHandlers) ref.toJson()],
            [for (final ref in other.authorizedHandlers) ref.toJson()],
          ) &&
          packRuntimeExists == other.packRuntimeExists &&
          _eventEqual(_packRuntime, other._packRuntime) &&
          _eventEqual(_authorizedHandlerIds, other._authorizedHandlerIds) &&
          _eventEqual(
            [for (final proposal in _proposals) proposal.toJson()],
            [for (final proposal in other._proposals) proposal.toJson()],
          ) &&
          runtimeExists == other.runtimeExists &&
          _eventEqual(_runtime, other._runtime) &&
          stateActionAllowed == other.stateActionAllowed);
}

/// Reading does not evaluate conditions, consume proposals or create runtime.
class CardEventSnapshot {
  CardEventSnapshot._({
    required this.defined,
    required this.executable,
    required this.initialized,
    required this.valid,
    required this.fingerprint,
    required this.packRuntimeExists,
    required Object? packRuntime,
    required List<_Json> consumed,
    required List<String> firedHandlers,
    required List<_Json> pendingPrompts,
    required List<_Json> issues,
  }) : _packRuntime = _eventCopy(packRuntime),
       _consumed = _maps(consumed),
       _firedHandlers = List.of(firedHandlers),
       _pendingPrompts = _maps(pendingPrompts),
       _issues = _maps(issues);
  final bool defined;
  final bool executable;
  final bool initialized;
  final bool valid;
  final String fingerprint;
  final bool packRuntimeExists;
  final Object? _packRuntime;
  Object? get packRuntime => _eventCopy(_packRuntime);
  final List<_Json> _consumed;
  final List<String> _firedHandlers;
  final List<_Json> _pendingPrompts;
  final List<_Json> _issues;
  List<Map<String, Object?>> get consumed => _maps(_consumed);
  List<String> get firedHandlers => List.of(_firedHandlers);
  List<Map<String, Object?>> get pendingPrompts => _maps(_pendingPrompts);
  List<Map<String, Object?>> get issues => _maps(_issues);
  Map<String, Object?> toJson() => {
    'defined': defined,
    'executable': executable,
    'initialized': initialized,
    'valid': valid,
    'fingerprint': fingerprint,
    if (packRuntimeExists) ...{'packRuntimeExists': true, 'packRuntime': _auditCopy(_packRuntime)},
    'consumed': consumed,
    'firedHandlers': firedHandlers,
    'pendingPrompts': pendingPrompts,
    'issues': issues,
  };
}

/// Candidate only. effects is the event subset already present in the combined
/// StateResult.effects. The host assigns effectId and queues {id, text}; pure
/// settlement preserves existing pendingPrompts and never inserts a prompt.
class CardEventResult {
  CardEventResult._({
    required this.valid,
    required this.runtimeExists,
    required this.initialized,
    required this.changed,
    required Object? runtime,
    required this.packRuntimeExists,
    required Object? packRuntime,
    required List<_Json> receipts,
    required List<_Json> effects,
    required List<_Json> issues,
  }) : _runtime = _eventCopy(runtime),
       _packRuntime = _eventCopy(packRuntime),
       _receipts = _maps(receipts),
       _effects = _maps(effects),
       _issues = _maps(issues);
  final bool valid;
  final bool runtimeExists;
  final bool packRuntimeExists;

  /// True only when this candidate creates a previously absent ledger.
  final bool initialized;
  final bool changed;
  final Object? _runtime;
  final Object? _packRuntime;
  final List<_Json> _receipts;
  final List<_Json> _effects;
  final List<_Json> _issues;
  Object? get runtime => _eventCopy(_runtime);
  Object? get packRuntime => _eventCopy(_packRuntime);
  List<Map<String, Object?>> get receipts => _maps(_receipts);
  List<Map<String, Object?>> get effects => _maps(_effects);
  List<Map<String, Object?>> get issues => _maps(_issues);
  Map<String, Object?> toJson() => {
    'version': 1,
    'valid': valid,
    'runtimeExists': runtimeExists,
    'initialized': initialized,
    'changed': changed,
    'runtime': _auditCopy(_runtime),
    if (packRuntimeExists) ...{'packRuntimeExists': true, 'packRuntime': _auditCopy(_packRuntime)},
    'receipts': receipts,
    'effects': effects,
    'issues': issues,
  };
}

class StateEventFinishResult {
  StateEventFinishResult._({required this.state, required this.events});
  final StateResult state;
  final CardEventResult events;
  Map<String, Object?> toJson() => {'state': state.toJson(), 'events': events.toJson()};
}

/// Compiles extensions.dshgo.director.eventRules without evaluating anything.
/// [version] is the enclosing dshgo.v, separate from the registry's own v.
class CardEventDefinition {
  CardEventDefinition.parse(Object? rawRegistry, {Object? version = 1})
    : _raw = _eventCopy(rawRegistry),
      _version = _eventCopy(version),
      _defined = rawRegistry != null {
    if (!defined) {
      return;
    }
    if (_version != 1) {
      _issues.add(_issue('card_events_version', '', 'Only enclosing dshgo version 1 is executable.'));
      return;
    }
    if (_raw is! _Json || !_finiteJson(_raw)) {
      _issues.add(_issue('card_events_shape', '', 'The event registry must be a finite JSON object.'));
      return;
    }
    final raw = _raw;
    if (utf8.encode(jsonEncode(raw)).length > 1024 * 1024) {
      _issues.add(_issue('card_events_size', '', 'The event registry exceeds 1 MiB of UTF-8 JSON.'));
      return;
    }
    if (raw['v'] != 1) {
      _issues.add(_issue('card_events_version', '/v', 'Only event registry version 1 is executable.'));
      return;
    }
    final rules = raw['rules'];
    if (rules is! List<Object?>) {
      _issues.add(_issue('card_events_rules', '/rules', 'The registry requires a rules array.'));
      return;
    }
    if (rules.length > 256) {
      _issues.add(
        _issue(
          'card_events_rules_limit',
          '/rules',
          'A registry has at most 256 handlers; this definition is preserved without execution.',
        ),
      );
      return;
    }
    _executable = true;
    final counts = <String, int>{};
    for (final rule in rules) {
      if (rule is _Json && rule['id'] is String) {
        final id = rule['id']! as String;
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    for (var i = 0; i < rules.length; i++) {
      final path = '/rules/$i', rule = rules[i];
      try {
        if (rule is! _Json ||
            rule['id'] is! String ||
            (rule['id']! as String).isEmpty ||
            rule['name'] is! String ||
            (rule['name']! as String).isEmpty ||
            !rule.containsKey('when') ||
            rule['do'] is! List<Object?> ||
            (rule.containsKey('once') && rule['once'] is! bool)) {
          throw _StateError(
            'card_event_rule',
            path,
            'A handler requires nonempty id/name, when, do, and an optional boolean once.',
          );
        }
        final id = rule['id']! as String;
        if (counts[id]! > 1) {
          throw _StateError('card_event_duplicate_id', '$path/id', 'All handlers sharing this id are disabled.');
        }
        final condition = _Logic.compile(rule['when'], '$path/when');
        final expectations = <_EventExpectation>[];
        if (rule.containsKey('expect')) {
          final expect = rule['expect'];
          if (expect is! List<Object?>) {
            throw _StateError('card_event_expect', '$path/expect', 'expect must be an array.');
          }
          for (var j = 0; j < expect.length; j++) {
            final item = expect[j], location = '$path/expect/$j';
            if (item is! _Json ||
                item['path'] is! String ||
                item['exists'] is! bool ||
                (item['exists'] == true) != item.containsKey('value') ||
                !item.keys.every(const {'path', 'exists', 'value'}.contains)) {
              throw _StateError(
                'card_event_expect',
                location,
                'An expectation requires path/exists and value exactly when exists is true.',
              );
            }
            expectations.add(_EventExpectation(_tokens(item['path']), item['exists'] == true, _copy(item['value'])));
          }
        }
        final actions = <_Json>[];
        final rawActions = rule['do']! as List<Object?>;
        for (var j = 0; j < rawActions.length; j++) {
          final action = rawActions[j];
          if (action is! _Json || !_eventActionValid(action)) {
            throw _StateError(
              'card_event_action',
              '$path/do/$j',
              'An unsupported or malformed literal action disables this handler.',
            );
          }
          actions.add(_mapCopy(action));
        }
        _handlers.add(
          _EventHandler(id, rule['name']! as String, i, rule['once'] == true, condition, expectations, actions),
        );
        for (final key in rule.keys) {
          if (!const {'id', 'name', 'when', 'once', 'expect', 'do'}.contains(key)) {
            _issues.add(
              _issue(
                'card_event_unknown',
                '$path/${_escape(key)}',
                'Unknown handler metadata is preserved.',
                kind: 'unknown',
              ),
            );
          }
        }
      } on _StateError catch (error) {
        _issues.add(error.issue);
      }
    }
    for (final key in raw.keys) {
      if (!const {'v', 'rules'}.contains(key)) {
        _issues.add(
          _issue('card_events_unknown', '/${_escape(key)}', 'Unknown registry metadata is preserved.', kind: 'unknown'),
        );
      }
    }
  }

  factory CardEventDefinition.compose(
    Iterable<CardEventRegistrySource> sources, {
    required String effectiveConfigId,
    required bool compositionEligible,
  }) => _composeCardEventDefinition(
    sources,
    effectiveConfigId: effectiveConfigId,
    compositionEligible: compositionEligible,
  );

  CardEventDefinition._composed(this._raw, {required bool defined}) : _version = 1, _defined = defined;
  final Object? _raw;
  final Object? _version;
  final bool _defined;
  _Json? _compositionIdentity;
  final List<_Json> _issues = [];
  final List<_EventHandler> _handlers = [];
  bool _executable = false;
  bool get defined => _defined;
  bool get executable => _executable;
  Object? get raw => _eventCopy(_raw);
  String get fingerprint =>
      _fingerprint(_eventIdentity({'version': _version, 'eventRules': _raw, 'composition': ?_compositionIdentity}));
  List<Map<String, Object?>> get issues => _maps(_issues);
  List<String> get handlerIds => [for (final handler in _handlers) handler.id];
  List<StateEventTarget> get eventTargets => {for (final handler in _handlers) handler.target}.toList();
  List<CardEventHandlerRef> get handlerRefs => [
    for (final handler in _handlers) CardEventHandlerRef(source: handler.source, localId: handler.id),
  ];

  CardEventSnapshot inspect({
    required bool runtimeExists,
    Object? runtime,
    bool packRuntimeExists = false,
    Object? packRuntime,
    Iterable<StateExecutionSource> activeSources = const [],
  }) {
    final problems = _eventRuntimeIssues(runtimeExists, runtime);
    final pack = _PackRuntime(exists: packRuntimeExists, raw: packRuntime);
    final packProblems = <_Json>[];
    for (final source in {
      for (final handler in _handlers)
        if (handler.source.isPack) handler.source,
      for (final source in activeSources)
        if (source.isPack) source,
    }) {
      packProblems.addAll(pack.issues(source, _PackDomain.events));
    }
    final valid = problems.isEmpty && packProblems.isEmpty && (!defined || executable);
    final ledger = problems.isEmpty && runtimeExists ? runtime! as _Json : null;
    return CardEventSnapshot._(
      defined: defined,
      executable: executable,
      initialized: runtimeExists,
      valid: valid,
      fingerprint: fingerprint,
      packRuntimeExists: packRuntimeExists,
      packRuntime: pack.raw,
      consumed: [
        if (ledger?['consumed'] case final List<Object?> rows)
          for (final row in rows) _mapCopy(row! as _Json),
      ],
      firedHandlers: [
        if (ledger?['firedHandlers'] case final List<Object?> ids)
          for (final id in ids) id! as String,
      ],
      pendingPrompts: [
        if (ledger?['pendingPrompts'] case final List<Object?> rows)
          for (final row in rows) _mapCopy(row! as _Json),
      ],
      issues: [...issues, ...problems, ...packProblems],
    );
  }
}

class _EventExpectation {
  _EventExpectation(this.path, this.exists, this.value);
  final List<String> path;
  final bool exists;
  final Object? value;
}

class _EventHandler {
  _EventHandler(
    this.id,
    this.name,
    this.index,
    this.once,
    this.condition,
    this.expectations,
    this.actions, {
    this.source = const StateExecutionSource.legacy(),
    this.eventTarget,
    this.actionTargets = const {},
  });
  final StateExecutionSource source;
  final Map<int, StateEventTarget> actionTargets;
  final StateEventTarget? eventTarget;
  StateEventTarget get target => eventTarget ?? (source: source, name: name);
  final String id;
  final String name;
  final int index;
  final bool once;
  final _Logic condition;
  final List<_EventExpectation> expectations;
  final List<_Json> actions;
  bool get hasState => actions.any((action) => action['type'] == 'state');
}

// Exactly the literal action wire used by ordinary T17 rules.
bool _eventActionValid(_Json action) {
  if (!_finiteJson(action)) {
    return false;
  }
  return switch (action['type']) {
    'state' => action['ops'] is List<Object?> && action.keys.every(const {'type', 'ops'}.contains),
    'prompt' || 'notice' => action['text'] is String && action.keys.every(const {'type', 'text'}.contains),
    'event' =>
      action['name'] is String &&
          action.containsKey('data') &&
          action.keys.every(const {'type', 'name', 'data'}.contains),
    'unlock' =>
      const {'ending', 'achievement'}.contains(action['kind']) &&
          action['id'] is String &&
          (!action.containsKey('title') || action['title'] is String) &&
          action.keys.every(const {'type', 'kind', 'id', 'title'}.contains),
    _ => false,
  };
}

Object? _eventCopy(Object? value) {
  if (value is Map<Object?, Object?>) {
    if (value.keys.every((key) => key is String)) {
      return <String, Object?>{for (final entry in value.entries) (entry.key! as String): _eventCopy(entry.value)};
    }
    return <Object?, Object?>{for (final entry in value.entries) entry.key: _eventCopy(entry.value)};
  }
  if (value is List<Object?>) {
    return [for (final item in value) _eventCopy(item)];
  }
  return value;
}

// Audit markers are deliberately not an identity representation: a legal
// object {nonJsonNumber: 'NaN'} must differ from an actual rejected NaN.
// Every node is tagged, so no literal JSON annotation can impersonate a tag.
Object? _eventIdentity(Object? value) {
  if (value == null) {
    return ['null'];
  }
  if (value is String) {
    return ['string', value];
  }
  if (value is bool) {
    return ['boolean', value];
  }
  if (value is num) {
    return value.isFinite ? ['number', value] : ['nonfinite-number', _jsString(value)];
  }
  if (value is _Json) {
    return [
      'object',
      <String, Object?>{for (final entry in value.entries) entry.key: _eventIdentity(entry.value)},
    ];
  }
  if (value is List<Object?>) {
    return [
      'array',
      [for (final item in value) _eventIdentity(item)],
    ];
  }
  return ['non-json-object', value.runtimeType.toString()];
}

// Sealing compares the detached original values, not a digest or a lossy audit
// copy. Unsupported host objects are equal only by identity; no custom == runs.
bool _eventEqual(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is num && right is num) {
    return (left.isNaN && right.isNaN) || left == right;
  }
  if (left is String && right is String) {
    return left == right;
  }
  if (left is bool && right is bool) {
    return left == right;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!_eventEqual(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is _Json && right is _Json) {
    return left.length == right.length &&
        left.keys.every((key) => right.containsKey(key) && _eventEqual(left[key], right[key]));
  }
  return false;
}

const _eventRuntimePath = '/dshgoDirectorEventRuntime';

List<_Json> _eventRuntimeIssues(bool exists, Object? runtime) {
  if (!exists) {
    return [];
  }
  if (runtime is! _Json || runtime['version'] != 1) {
    return [
      _issue(
        'card_event_runtime_version',
        _eventRuntimePath,
        'Existing event runtime must be an object with version 1; it is preserved without execution.',
      ),
    ];
  }
  if (!_finiteJson(runtime)) {
    return [_issue('card_event_runtime_json', _eventRuntimePath, 'Existing event runtime must contain finite JSON.')];
  }
  if (runtime.containsKey('consumed')) {
    final rows = runtime['consumed'];
    final pairs = <(String, String)>{};
    if (rows is! List<Object?>) {
      return [
        _issue(
          'card_event_runtime_consumed',
          '$_eventRuntimePath/consumed',
          'Consumed event/handler pairs must be an array.',
        ),
      ];
    }
    for (final row in rows) {
      if (row is! _Json ||
          row['eventId'] is! String ||
          row['handlerId'] is! String ||
          !pairs.add((row['eventId']! as String, row['handlerId']! as String))) {
        return [
          _issue(
            'card_event_runtime_consumed',
            '$_eventRuntimePath/consumed',
            'Consumed pairs require unique string eventId/handlerId pairs.',
          ),
        ];
      }
    }
  }
  if (runtime.containsKey('firedHandlers')) {
    final ids = runtime['firedHandlers'];
    final seen = <String>{};
    if (ids is! List<Object?> || ids.any((id) => id is! String || !seen.add(id))) {
      return [
        _issue(
          'card_event_runtime_fired',
          '$_eventRuntimePath/firedHandlers',
          'firedHandlers must contain unique strings.',
        ),
      ];
    }
  }
  if (runtime.containsKey('pendingPrompts')) {
    final rows = runtime['pendingPrompts'];
    final ids = <String>{};
    if (rows is! List<Object?>) {
      return [
        _issue('card_event_runtime_pending', '$_eventRuntimePath/pendingPrompts', 'pendingPrompts must be an array.'),
      ];
    }
    for (final row in rows) {
      if (row is! _Json || row['id'] is! String || row['text'] is! String || !ids.add(row['id']! as String)) {
        return [
          _issue(
            'card_event_runtime_pending',
            '$_eventRuntimePath/pendingPrompts',
            'Pending prompts require unique string ids and literal string text.',
          ),
        ];
      }
    }
  }
  return [];
}

/// Runs effect-only handlers against detached, read-only [conditionState].
/// Without a state schema the host passes null. No state session, schema,
/// derivation or ordinary rule pass is created; mixed state handlers stay pending.
CardEventResult settleCardEventsEffectsOnly(CardEventInvocation invocation, {Object? conditionState}) =>
    _CardEventSettlement(invocation, conditionState: conditionState).run();

class _CardEventSettlement {
  _CardEventSettlement(this.invocation, {this.session, Object? conditionState, this.stateValid = true})
    : _conditionState = _eventCopy(conditionState),
      _runtimeExists = invocation.runtimeExists,
      _runtime = invocation.runtime,
      _pack = session?._pack ?? _PackRuntime(exists: invocation.packRuntimeExists, raw: invocation._packRuntime);
  final CardEventInvocation invocation;
  final StateSession? session;
  final Object? _conditionState;
  final bool stateValid;
  final _PackRuntime _pack;
  bool _runtimeExists;
  Object? _runtime;
  final List<_Json> _receipts = [], _effects = [], _issues = [];
  final Set<(String, String)> _consumed = {};
  final Set<String> _fired = {};
  var _handlerCount = 0;
  var _ownActionCount = 0;
  var _ownEffectBytes = 0;
  var _ownLimit = false;
  var _ledgerChanged = false;

  Object? get _data => session == null ? _conditionState : session!._value;
  bool get _dataExists => session?._exists ?? true;
  int get _actionCount => session?._actionCount ?? _ownActionCount;
  int get _effectBytes => session?._effectBytes ?? _ownEffectBytes;
  bool get _limited => session?._ruleLimit ?? _ownLimit;

  CardEventResult run() {
    final definition = invocation.definition;
    _issues.addAll(definition.issues);
    final invalid = _eventRuntimeIssues(_runtimeExists, _runtime);
    if (definition.defined && !definition.executable) {
      invalid.add(_issue('card_event_definition', '', 'The current event registry is not executable.'));
    }
    final allowed = invocation.authorizedHandlers.toSet();
    final known = definition.handlerRefs.toSet();
    if (invocation.invocationId.isEmpty ||
        invocation.capabilityFingerprint != definition.fingerprint ||
        allowed.any((ref) => !known.contains(ref)) ||
        definition._compositionIdentity != null && invocation._authorizedHandlers == null) {
      invalid.add(
        _issue(
          'card_event_capability',
          '',
          'Invocation id, definition fingerprint or authorized handler set is invalid.',
        ),
      );
    }
    if (session != null &&
        definition._compositionIdentity != null &&
        session!._definition._compositionIdentity?['effectiveConfigId'] !=
            definition._compositionIdentity!['effectiveConfigId']) {
      invalid.add(
        _issue(
          'card_event_composition',
          '',
          'State and event settlement must use the same admitted effective configuration.',
        ),
      );
    }
    if (session != null &&
        definition._compositionIdentity != null &&
        (invocation.packRuntimeExists != session!._pack._packOriginalExists ||
            !_eventEqual(invocation._packRuntime, session!._pack._packOriginal))) {
      invalid.add(
        _issue(
          'card_event_pack_baseline',
          '/dshgoPackRuntime',
          'The admitted event batch must use the state session original pack carrier.',
        ),
      );
    }
    if (!stateValid || (session == null && !_finiteJson(_conditionState))) {
      invalid.add(
        _issue('card_event_condition_state', '', 'The state carrier is unavailable; no event handler is executed.'),
      );
    }
    final proposals = invocation._proposals;
    if (proposals.length > 32) {
      invalid.add(
        _issue(
          'card_event_proposals_limit',
          '/proposals',
          'The whole proposal batch is rejected: at most 32 events are supported.',
        ),
      );
    } else {
      final ids = <String>{};
      final runs = <String>{};
      for (var i = 0; i < proposals.length; i++) {
        final proposal = proposals[i];
        runs.add(proposal.runId);
        if (proposal.eventId.isEmpty ||
            proposal.runId.isEmpty ||
            !ids.add(proposal.eventId) ||
            proposal.name.isEmpty ||
            utf8.encode(proposal.name).length > 1024 ||
            utf8.encode(proposal.data).length > 16 * 1024) {
          invalid.add(
            _issue(
              'card_event_proposal',
              '/proposals/$i',
              'Event ids must be unique and nonempty, run ids nonempty, names 1–1024 UTF-8 bytes and data at most 16 KiB.',
            ),
          );
        }
      }
      if (runs.length > 1) {
        invalid.add(
          _issue(
            'card_event_proposal_runs',
            '/proposals',
            'The admitted batch must come from one original director run.',
          ),
        );
      }
      final wire = [
        for (final proposal in proposals) {'name': proposal.name, 'data': proposal.data},
      ];
      if (utf8.encode(jsonEncode(wire)).length > 256 * 1024) {
        invalid.add(
          _issue('card_event_proposals_size', '/proposals', 'The whole proposal batch exceeds 256 KiB of UTF-8 JSON.'),
        );
      }
    }
    if (invalid.isNotEmpty) {
      _issues.addAll(invalid);
      if (proposals.length > 32) {
        _receipts.add({
          'outcome': 'rejected',
          'consumed': false,
          'proposalCount': proposals.length,
          'issues': _maps(invalid),
        });
      } else {
        for (final proposal in proposals) {
          _receipts.add({
            ...proposal.toJson(),
            'invocationId': invocation.invocationId,
            'capabilityFingerprint': invocation.capabilityFingerprint,
            'outcome': 'rejected',
            'consumed': false,
            'handlers': <Object?>[],
            'issues': _maps(invalid),
          });
        }
      }
      return _result(false);
    }
    if (_runtimeExists && _runtime is _Json) {
      final ledger = _runtime! as _Json;
      if (ledger['consumed'] case final List<Object?> rows) {
        for (final item in rows) {
          final row = item! as _Json;
          _consumed.add((row['eventId']! as String, row['handlerId']! as String));
        }
      }
      if (ledger['firedHandlers'] case final List<Object?> ids) {
        _fired.addAll(ids.cast<String>());
      }
    }
    for (final proposal in proposals) {
      final handlers = definition._handlers
          .where((handler) => handler.target.name == proposal.name && handler.target.source == proposal.source)
          .toList();
      final judgments = <_Json>[];
      for (var i = 0; i < handlers.length; i++) {
        if (_handlerCount >= 256) {
          final issue = _issue(
            'card_event_handlers_limit',
            '/proposals',
            'Remaining handler judgments stay pending; invocation limit is 256.',
          );
          _issues.add(issue);
          judgments.add({
            'handlerId': handlers[i].id,
            if (handlers[i].source.isPack) ...{
              'executionSource': handlers[i].source.toJson(),
              'localId': handlers[i].id,
              'sourceIndex': handlers[i].index,
            },
            'outcome': 'handler-limit',
            'consumed': false,
            'consumedOnce': false,
            'skippedCount': handlers.length - i,
            'actions': <Object?>[],
            'issues': [issue],
          });
          break;
        }
        _handlerCount++;
        judgments.add(_runHandler(proposal, handlers[i], allowed));
      }
      final consumed = judgments.any((row) => row['consumed'] == true);
      final pending = judgments.any(
        (row) => !const {'accepted', 'already-consumed', 'once-skipped'}.contains(row['outcome']),
      );
      _receipts.add({
        ...proposal.toJson(),
        'invocationId': invocation.invocationId,
        'capabilityFingerprint': invocation.capabilityFingerprint,
        'consumed': consumed,
        'outcome': consumed
            ? (pending ? 'partial' : 'accepted')
            : (judgments.isEmpty ? 'no-handler' : (pending ? 'pending' : 'already-consumed')),
        'handlers': judgments,
        'issues': <Object?>[],
      });
    }
    return _result(true);
  }

  _Json _runHandler(CardEventProposal proposal, _EventHandler handler, Set<CardEventHandlerRef> allowed) {
    final actions = <_Json>[], problems = <_Json>[];
    final judgment = <String, Object?>{
      'handlerId': handler.id,
      if (handler.source.isPack) ...{
        'executionSource': handler.source.toJson(),
        'localId': handler.id,
        'sourceIndex': handler.index,
      },
      'outcome': 'pending',
      'consumed': false,
      'consumedOnce': false,
      'actionAccepted': false,
      'actions': actions,
      'issues': problems,
    };
    if (handler.source.isPack) {
      final invalid = _pack.issues(handler.source, _PackDomain.events);
      if (invalid.isNotEmpty) {
        problems.addAll(invalid);
        _issues.addAll(invalid);
        judgment['outcome'] = 'runtime-error';
        return judgment;
      }
    }
    final consumed = handler.source.isPack
        ? _pack.eventConsumed(handler.source, proposal.eventId, handler.id)
        : _consumed.contains((proposal.eventId, handler.id));
    if (consumed) {
      judgment['outcome'] = 'already-consumed';
      return judgment;
    }
    final fired = handler.source.isPack ? _pack.eventFired(handler.source, handler.id) : _fired.contains(handler.id);
    if (handler.once && fired) {
      judgment['outcome'] = 'once-skipped';
      return judgment;
    }
    if (!allowed.contains(CardEventHandlerRef(source: handler.source, localId: handler.id))) {
      judgment['outcome'] = 'not-authorized';
      return judgment;
    }
    if (handler.hasState && (session == null || !invocation.stateActionAllowed)) {
      judgment['outcome'] = 'state-not-authorized';
      return judgment;
    }
    try {
      final matched = _truthy(handler.condition.evaluate(_data));
      judgment['matched'] = matched;
      if (!matched) {
        judgment['outcome'] = 'not-matched';
        return judgment;
      }
    } on _StateError catch (error) {
      problems.add(error.issue);
      _issues.add(error.issue);
      judgment['outcome'] = 'condition-error';
      return judgment;
    }
    final expectations = <_Json>[];
    var guardsMatch = true;
    for (final expectation in handler.expectations) {
      final actual = _lookup(_data, expectation.path, exists: _dataExists);
      final matches =
          actual.exists == expectation.exists && (!expectation.exists || _equal(actual.value, expectation.value));
      guardsMatch = guardsMatch && matches;
      expectations.add({
        'path': _pointer(expectation.path),
        'expectedExists': expectation.exists,
        if (expectation.exists) 'expectedValue': _copy(expectation.value),
        'actualExists': actual.exists,
        if (actual.exists) 'actualValue': _copy(actual.value),
        'matched': matches,
      });
    }
    judgment['expect'] = expectations;
    if (!guardsMatch) {
      judgment['outcome'] = 'precondition-failed';
      return judgment;
    }
    var accepted = false, rejected = false;
    for (var i = 0; i < handler.actions.length; i++) {
      final path = '/rules/${handler.index}/do/$i';
      if (_limited || _actionCount >= 256) {
        final issue = _issue(
          'card_event_actions_limit',
          path,
          'Remaining actions stay pending; the shared invocation action budget is exhausted.',
        );
        problems.add(issue);
        _issues.add(issue);
        actions.add({
          'index': i,
          'accepted': false,
          'skippedCount': handler.actions.length - i,
          'issues': [issue],
        });
        _stop();
        rejected = true;
        break;
      }
      if (session == null) {
        _ownActionCount++;
      } else {
        session!._actionCount++;
      }
      final action = handler.actions[i];
      if (action['type'] == 'state') {
        final result = session!._apply(
          action['ops'],
          StateActor.rules,
          'directorEvent:${handler.id}',
          executionSource: handler.source.isPack ? handler.source : null,
          localId: handler.source.isPack ? handler.id : null,
        );
        actions.add({'index': i, 'type': 'state', ...result.toJson()});
        problems.addAll(result.issues);
        _issues.addAll(result.issues);
        accepted = accepted || result.acceptedCount > 0;
        rejected = rejected || result.rejectedCount > 0;
      } else {
        final target = action['type'] == 'event' ? handler.actionTargets[i] : null;
        final effect = <String, Object?>{
          ..._mapCopy(action),
          if (target != null) 'eventTarget': {'source': target.source.toJson(), 'name': target.name},
          'source': 'directorEvent',
          'eventId': proposal.eventId,
          'runId': proposal.runId,
          'handlerId': handler.id,
          if (handler.source.isPack) ...{
            'executionSource': handler.source.toJson(),
            'localId': handler.id,
            'sourceIndex': handler.index,
          },
          'actionIndex': i,
        };
        final bytes = utf8.encode(jsonEncode(effect)).length;
        if (_effectBytes + bytes > 256 * 1024) {
          final issue = _issue(
            'card_event_effects_limit',
            path,
            'Remaining actions stay pending; the shared effect budget is 256 KiB of UTF-8 JSON.',
          );
          problems.add(issue);
          _issues.add(issue);
          actions.add({
            'index': i,
            'accepted': false,
            'issues': [issue],
          });
          _stop();
          rejected = true;
          break;
        }
        actions.add({
          'index': i,
          'accepted': true,
          'effectIndex': _effects.length,
          if (session != null) 'stateEffectIndex': session!._effects.length,
          'effect': _mapCopy(effect),
          'issues': <Object?>[],
        });
        _effects.add(effect);
        if (session == null) {
          _ownEffectBytes += bytes;
        } else {
          session!._effectBytes += bytes;
          session!._effects.add(effect);
        }
        accepted = true;
      }
    }
    judgment['actionAccepted'] = accepted;
    judgment['outcome'] = accepted ? (rejected ? 'partial' : 'accepted') : 'all-rejected';
    if (accepted) {
      _consume(proposal, handler);
      judgment['consumed'] = true;
      judgment['consumedOnce'] = handler.once;
    }
    return judgment;
  }

  void _stop() {
    if (session == null) {
      _ownLimit = true;
    } else {
      session!._ruleLimit = true;
    }
  }

  void _consume(CardEventProposal proposal, _EventHandler handler) {
    if (handler.source.isPack) {
      _pack.consumeEvent(handler.source, proposal.eventId, handler.id, once: handler.once);
      _ledgerChanged = true;
      return;
    }
    if (!_runtimeExists) {
      _runtimeExists = true;
      _runtime = <String, Object?>{'version': 1};
    }
    final ledger = _runtime! as _Json;
    final old = ledger['consumed'];
    final rows = old is List<Object?> ? List<Object?>.of(old) : <Object?>[];
    rows.add({'eventId': proposal.eventId, 'handlerId': handler.id});
    ledger['consumed'] = rows;
    _consumed.add((proposal.eventId, handler.id));
    _ledgerChanged = true;
    if (handler.once) {
      final fired = ledger['firedHandlers'];
      final ids = fired is List<Object?> ? List<Object?>.of(fired) : <Object?>[];
      if (!ids.contains(handler.id)) {
        ids.add(handler.id);
      }
      ledger['firedHandlers'] = ids;
      _fired.add(handler.id);
    }
  }

  CardEventResult _result(bool valid) => CardEventResult._(
    valid: valid,
    runtimeExists: _runtimeExists,
    initialized: !invocation.runtimeExists && _runtimeExists,
    changed: _ledgerChanged,
    runtime: _runtime,
    packRuntimeExists: _pack.exists,
    packRuntime: _pack.raw,
    receipts: _receipts,
    effects: _effects,
    issues: _issues,
  );
}
