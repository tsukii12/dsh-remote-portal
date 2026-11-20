part of 'state_engine.dart';

class StateSecretFact {
  StateSecretFact({
    required this.slotId,
    required this.entityId,
    required this.path,
    required this.expectedExists,
    Object? expectedValue,
    required this.value,
  }) : _expectedValue = _copy(expectedValue);
  final String slotId, entityId, path, value;
  final bool expectedExists;
  final Object? _expectedValue;
  Object? get expectedValue => _copy(_expectedValue);
  Map<String, Object?> toJson() => {
    'slotId': slotId,
    'entityId': entityId,
    'path': path,
    'expectedExists': expectedExists,
    'expectedValue': expectedValue,
    'value': value,
  };
  StateSecretFact _detached() => StateSecretFact(
    slotId: slotId,
    entityId: entityId,
    path: path,
    expectedExists: expectedExists,
    expectedValue: _expectedValue,
    value: value,
  );
}

class StateSecretPlan {
  StateSecretPlan({
    required this.id,
    required this.stateDefinitionFingerprint,
    required this.baselineFingerprint,
    required Iterable<StateSecretFact> facts,
  }) : _facts = List.unmodifiable(facts.map((fact) => fact._detached()));
  final String id, stateDefinitionFingerprint, baselineFingerprint;
  final List<StateSecretFact> _facts;
  List<StateSecretFact> get facts => List.unmodifiable(_facts.map((fact) => fact._detached()));
  Map<String, Object?> toJson() => {
    'id': id,
    'stateDefinitionFingerprint': stateDefinitionFingerprint,
    'baselineFingerprint': baselineFingerprint,
    'facts': [for (final fact in _facts) fact.toJson()],
  };
}

class StateSecretPrepared {
  StateSecretPrepared._(
    this._session,
    StateSecretPlan plan, {
    required this.accepted,
    required this.valueExists,
    required Object? value,
    required this.runtimeExists,
    required Object? runtime,
    required this.packRuntimeExists,
    required Object? packRuntime,
    required List<_Json> changes,
    required List<_Json> receipts,
    required List<_Json> issues,
  }) : planId = plan.id,
       _plan = _mapCopy(plan.toJson()),
       _value = _copy(value),
       _runtime = _copy(runtime),
       _packRuntime = _eventCopy(packRuntime),
       _changes = _maps(changes),
       _receipts = _maps(receipts),
       _issues = _maps(issues),
       _receiptBoundary = _session._receipts.length,
       _issueBoundary = _session._issues.length,
       _effectBoundary = _session._effects.length,
       _writeBoundary = _session._writes.length,
       _structural = Set.of(_session._structural);
  final StateSession _session;
  final _Json _plan;
  final String planId;
  final bool accepted, valueExists, runtimeExists, packRuntimeExists;
  final Object? _value, _runtime, _packRuntime;
  final List<_Json> _changes, _receipts, _issues;
  final int _receiptBoundary, _issueBoundary, _effectBoundary, _writeBoundary;
  final Set<String> _structural;
  StateResult? _terminal;
  Object? get value => _copy(_value);
  String get valueFingerprint => _fingerprint({'exists': valueExists, 'value': _value});
  Object? get runtime => _copy(_runtime);
  Object? get packRuntime => _eventCopy(_packRuntime);
  List<Map<String, Object?>> get changes => _maps(_changes);
  List<Map<String, Object?>> get receipts => _maps(_receipts);
  List<Map<String, Object?>> get issues => _maps(_issues);
  Map<String, Object?> toJson() => {
    'planId': planId,
    'accepted': accepted,
    'valueExists': valueExists,
    'value': value,
    'valueFingerprint': valueFingerprint,
    'runtimeExists': runtimeExists,
    'runtime': runtime,
    if (packRuntimeExists) ...{'packRuntimeExists': true, 'packRuntime': _auditCopy(_packRuntime)},
    'changes': changes,
    'receipts': receipts,
    'issues': issues,
  };
}

_Schema _secretPrepareLeaf(StateDefinition definition, Object? value, StateSecretFact fact) {
  final tokens = _tokens(fact.path);
  if (tokens.isEmpty) throw const _StateError('secret_path', '', 'A secret must target a non-root property.');
  var node = definition._root!;
  Object? parent = value;
  for (final token in tokens) {
    if (node.blocked || node.derived || !node.allowed.contains(StateActor.rules)) {
      throw _StateError('secret_permission', fact.path, 'Every target ancestor must allow ordinary rules writes.');
    }
    if (!node.types.contains('object') || node.types.contains('array') || parent is! _Json) {
      throw _StateError(
        'secret_parent',
        fact.path,
        'Every parent must be an existing object on a fixed property chain.',
      );
    }
    final child = node.properties[token];
    if (child == null) throw _StateError('secret_path', fact.path, 'The property must have a declared schema.');
    parent = parent[token];
    node = child;
  }
  if (node.blocked ||
      node.derived ||
      !node.hidden ||
      !node.allowed.contains(StateActor.rules) ||
      !node.types.contains('string') ||
      node.types.any((type) => type != 'string' && type != 'null')) {
    throw _StateError(
      'secret_sink',
      fact.path,
      'The sink must be a hidden writable non-derived string, optionally nullable.',
    );
  }
  return node;
}

List<_Json> _secretPrepareChanges(
  Object? before,
  Object? after, {
  required bool beforeExists,
  required bool afterExists,
  required Iterable<_Write> writes,
  Set<String> containers = const {},
}) {
  final changes = _difference(
    before,
    after,
    beforeExists: beforeExists,
    afterExists: afterExists,
    containers: containers,
  );
  for (final row in changes) {
    final tokens = _tokens(row['path']);
    _Write? writer;
    for (final item in writes) {
      if (_prefix(item.path, tokens) || _prefix(tokens, item.path)) writer = item;
    }
    row['actor'] = writer?.actor.name ?? 'rules';
    row['why'] = writer?.why ?? 'initialization';
  }
  return changes;
}

StateSecretPrepared _secretPrepare(StateSession session, StateSecretPlan plan) {
  if (session._finished != null || session._finishing) throw StateError('A sealed session cannot prepare secrets.');
  final previous = session._secretPrepared;
  if (previous != null) {
    if (!_equal(previous._plan, plan.toJson())) {
      throw StateError('A session cannot change its secret preparation batch.');
    }
    return previous;
  }
  if (session._publicApplyStarted) throw StateError('Secret preparation must precede every public apply call.');
  final before = _copy(session._value);
  final beforeExists = session._exists;
  final writeStart = session._writes.length,
      receiptStart = session._receipts.length,
      issueStart = session._issues.length;
  final structural = Set<String>.of(session._structural);
  final facts = plan._facts;
  var accepted = false;
  final problems = <_Json>[];
  try {
    if (!session._originalExists ||
        session._initialized ||
        !beforeExists ||
        session._readOnly ||
        !session._definition.executable) {
      throw const _StateError(
        'secret_baseline',
        '',
        'Preparation requires an existing uninitialized executable state and runtime.',
      );
    }
    final invalid = session._definition.validate(before);
    if (invalid.isNotEmpty) {
      problems.addAll(invalid);
      throw const _StateError('secret_baseline', '', 'The complete saved baseline must already be valid.');
    }
    if (plan.stateDefinitionFingerprint != session._definition.fingerprint ||
        plan.baselineFingerprint != _fingerprint({'exists': true, 'value': before})) {
      throw const _StateError('secret_fingerprint', '', 'Definition and complete baseline fingerprints must match.');
    }
    if (plan.id.isEmpty || facts.isEmpty || facts.length > 8) {
      throw const _StateError('secret_batch_shape', '', 'A named batch requires one to eight facts.');
    }
    final slots = <String>{}, paths = <String>{};
    for (final fact in facts) {
      if (fact.slotId.isEmpty || fact.entityId.isEmpty || !slots.add(fact.slotId) || !paths.add(fact.path)) {
        throw _StateError(
          'secret_batch_shape',
          fact.path,
          'Slot/entity identities must be nonempty and slots/paths unique.',
        );
      }
      final node = _secretPrepareLeaf(session._definition, before, fact);
      if (fact._expectedValue != null || (fact.expectedExists && !node.types.contains('null'))) {
        throw _StateError('secret_unbound', fact.path, 'Only absence or schema-permitted explicit null can be bound.');
      }
      final old = _lookup(before, _tokens(fact.path));
      if (old.exists != fact.expectedExists || (old.exists && !_equal(old.value, fact._expectedValue))) {
        throw _StateError('secret_cas', fact.path, 'The expected existence and value must match before any operation.');
      }
      if (utf8.encode(fact.value).length > 16 * 1024) {
        throw _StateError('secret_value_limit', fact.path, 'A secret string must be at most 16 KiB of UTF-8.');
      }
    }
    final source = 'secret:${plan.id}';
    final attempted = session._apply(
      [
        for (final fact in facts) {'op': 'set', 'path': fact.path, 'value': fact.value, 'why': source},
      ],
      StateActor.rules,
      source,
    );
    if (attempted.acceptedCount != facts.length ||
        attempted.rejectedCount != 0 ||
        attempted.receipts.any((receipt) => (receipt['clamps']! as List<Object?>).isNotEmpty)) {
      throw const _StateError(
        'secret_batch_operations',
        '',
        'Every fact must be accepted exactly, without clamping or truncation.',
      );
    }
    for (final fact in facts) {
      final actual = _lookup(session._value, _tokens(fact.path), exists: session._exists);
      if (!actual.exists || !_equal(actual.value, fact.value)) {
        throw _StateError('secret_value_changed', fact.path, 'The prepared value must equal the proposed string.');
      }
    }
    final finalIssues = session._definition.validate(session._value, valueExists: session._exists);
    if (finalIssues.isNotEmpty) {
      problems.addAll(finalIssues);
      throw const _StateError('secret_candidate', '', 'The complete prepared state must be valid.');
    }
    final changed = _difference(before, session._value, beforeExists: beforeExists, afterExists: session._exists);
    if (changed.length != paths.length || changed.any((row) => !paths.contains(row['path']))) {
      throw const _StateError('secret_side_effect', '', 'Actual changes must be exactly the approved secret leaves.');
    }
    accepted = true;
  } on _StateError catch (error) {
    problems.add(error.issue);
  } finally {
    if (!accepted) {
      session._value = before;
      session._exists = beforeExists;
      session._writes.removeRange(writeStart, session._writes.length);
      session._structural
        ..clear()
        ..addAll(structural);
      for (final receipt in session._receipts.skip(receiptStart)) {
        receipt['rolledBack'] = true;
      }
    }
  }
  session._issues.addAll(problems);
  session._receipts.add({
    'index': session._receiptIndex++,
    'source': 'secret:${plan.id}',
    'actor': 'rules',
    'operation': {'op': 'secret_batch', 'id': plan.id},
    'accepted': accepted,
    'changed': accepted,
    'status': accepted ? 'prepared' : 'rejected',
    'rolledBack': !accepted,
    'conflict': null,
    'clamps': <Object?>[],
    'issues': problems,
  });
  final prepared = StateSecretPrepared._(
    session,
    plan,
    accepted: accepted,
    valueExists: session._exists,
    value: session._value,
    runtimeExists: session._runtimeExists,
    runtime: session._runtime,
    packRuntimeExists: session._pack.exists,
    packRuntime: session._pack.raw,
    changes: accepted
        ? _secretPrepareChanges(
            before,
            session._value,
            beforeExists: beforeExists,
            afterExists: session._exists,
            writes: session._writes.skip(writeStart),
          )
        : [],
    receipts: session._receipts.sublist(receiptStart),
    issues: session._issues.sublist(issueStart),
  );
  session._secretPrepared = prepared;
  return prepared;
}

StateResult _secretTerminal(StateSession session, StateSecretPrepared prepared) {
  if (!identical(prepared._session, session) || !identical(session._secretPrepared, prepared)) {
    throw StateError('The preparation belongs to another state session.');
  }
  final finished = session._finished;
  if (finished == null) throw StateError('A terminal phase can only be read after the session is sealed.');
  return prepared._terminal ??= StateResult._(
    valueExists: finished.valueExists,
    value: finished._value,
    runtimeExists: finished.runtimeExists,
    runtime: finished._runtime,
    packRuntimeExists: finished.packRuntimeExists,
    packRuntime: finished._packRuntime,
    initialized: false,
    valid: finished.valid,
    changed:
        prepared.valueExists != finished.valueExists ||
        !_equal(prepared._value, finished._value) ||
        prepared.runtimeExists != finished.runtimeExists ||
        !_equal(prepared._runtime, finished._runtime) ||
        session._pack._packOriginalExists != finished.packRuntimeExists ||
        !_eventEqual(session._pack._packOriginal, finished._packRuntime),
    changes: _secretPrepareChanges(
      prepared._value,
      finished._value,
      beforeExists: prepared.valueExists,
      afterExists: finished.valueExists,
      writes: session._writes.skip(prepared._writeBoundary),
      containers: session._structural.difference(prepared._structural),
    ),
    receipts: session._receipts.sublist(prepared._receiptBoundary),
    effects: session._effects.sublist(prepared._effectBoundary),
    issues: session._issues.sublist(prepared._issueBoundary),
  );
}
