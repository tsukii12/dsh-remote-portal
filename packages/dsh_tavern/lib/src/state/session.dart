part of 'state_engine.dart';

Object? _assigned(
  _Schema node,
  Object? value,
  List<String> path,
  Object? baseline,
  List<_Json> clamps, {
  bool initial = false,
}) {
  if (node.blocked) return value;
  if (!_finiteJson(value)) {
    throw _StateError('value_json', _pointer(path), 'Assigned values must be finite JSON.');
  }
  if (value is num) {
    if (!node.accepts(value)) {
      throw _StateError('value_type', _pointer(path), 'Numeric value has the wrong type; integers are not rounded.');
    }
    final integer = node.types.contains('integer') && !node.types.contains('number');
    num lower = integer
        ? _integerLower(node)
        : _maxStateNumber(node.minimum ?? double.negativeInfinity, node.exclusiveMinimum ?? double.negativeInfinity);
    num upper = integer
        ? _integerUpper(node)
        : _minStateNumber(node.maximum ?? double.infinity, node.exclusiveMaximum ?? double.infinity);
    if (!initial && node.step != null) {
      final original = _lookup(baseline, path);
      if (!original.exists || original.value is! num || !(original.value! as num).isFinite) {
        throw _StateError(
          'step_baseline',
          _pointer(path),
          'A finite numeric value at this fixed baseline path is required.',
        );
      }
      final start = original.value! as num;
      final interval = _stepInterval(start, node.step!);
      final lo = interval.lower, hi = interval.upper;
      lower = _maxStateNumber(lower, integer && lo.isFinite ? _integerEndpoint(lo, lower: true) : lo);
      upper = _minStateNumber(upper, integer && hi.isFinite ? _integerEndpoint(hi, lower: false) : hi);
    }
    if (_compareStateNumbers(lower, upper) > 0) {
      throw _StateError('numeric_interval', _pointer(path), 'Range and fixed-step intervals do not intersect.');
    }
    final adjusted = _compareStateNumbers(value, lower) < 0
        ? lower
        : (_compareStateNumbers(value, upper) > 0 ? upper : value);
    if (!adjusted.isFinite) {
      throw _StateError('numeric_overflow', _pointer(path), 'A numeric operation overflowed.');
    }
    if (!_equal(value, adjusted)) {
      clamps.add({'path': _pointer(path), 'requested': value, 'actual': adjusted});
    }
    value = adjusted;
  } else if (value is _Json) {
    for (final key in value.keys.toList()) {
      final child = node.properties[key];
      if (child != null) {
        value[key] = _assigned(child, value[key], [...path, key], baseline, clamps, initial: initial);
      }
    }
  } else if (value is List<Object?> && node.items != null) {
    for (var i = 0; i < value.length; i++) {
      value[i] = _assigned(node.items!, value[i], [...path, '$i'], baseline, clamps, initial: initial);
    }
  }
  return value;
}

void _steps(_Schema root, Object? candidate, Object? baseline) {
  for (final item in _instances(root, candidate)) {
    if (item.node.blocked || item.node.step == null || !item.exists || item.value is! num) continue;
    final base = _lookup(baseline, item.tokens);
    if (!base.exists || base.value is! num || !(base.value! as num).isFinite) {
      throw _StateError('step_baseline', item.path, 'A numeric baseline is required at the final path.');
    }
    final number = item.value! as num, start = base.value! as num, step = item.node.step!;
    final interval = _stepInterval(start, step);
    if (_compareStateNumbers(number, interval.lower) < 0 || _compareStateNumbers(number, interval.upper) > 0) {
      throw _StateError(
        'step_structural',
        item.path,
        'Structural changes must retain payloads within the fixed path step interval.',
      );
    }
  }
}

void _directPermission(_Schema node, StateActor actor, String path, {bool deriving = false}) {
  if (node.blocked) {
    throw _StateError('unsupported_subtree', path, 'This constrained subtree is not executable.');
  }
  if (!node.allowed.contains(actor)) {
    throw _StateError('permission', path, 'The actor is not permitted to write this path.');
  }
  if (actor == StateActor.model && node.hidden) {
    throw _StateError('hidden', path, 'The model cannot write hidden data.');
  }
  if (node.derived && !deriving) {
    throw _StateError('derived', path, 'Only derivation may write this value.');
  }
}

void _changedPermissions(_Schema root, Object? before, Object? after, StateActor actor, {bool deriving = false}) {
  void visit(_Schema? node, Object? old, Object? value, List<String> path, bool oldExists, bool exists) {
    if (oldExists == exists && _equal(old, value, distinguishZero: deriving)) {
      return;
    }
    if (node == null) {
      if (actor == StateActor.model) {
        throw _StateError('unknown_value', _pointer(path), 'The model cannot alter unknown preserved values.');
      }
      return;
    }
    _directPermission(node, actor, _pointer(path), deriving: deriving);
    if (old is _Json || value is _Json) {
      final a = old is _Json && oldExists ? old : <String, Object?>{};
      final b = value is _Json && exists ? value : <String, Object?>{};
      for (final key in {...a.keys, ...b.keys}) {
        visit(node.properties[key], a[key], b[key], [...path, key], a.containsKey(key), b.containsKey(key));
      }
    }
    if (old is List<Object?> || value is List<Object?>) {
      final a = old is List<Object?> && oldExists ? old : <Object?>[];
      final b = value is List<Object?> && exists ? value : <Object?>[];
      for (var i = 0; i < math.max(a.length, b.length); i++) {
        visit(
          node.items,
          i < a.length ? a[i] : null,
          i < b.length ? b[i] : null,
          [...path, '$i'],
          i < a.length,
          i < b.length,
        );
      }
    }
  }

  visit(root, before, after, [], true, true);
}

bool _dependencyKnown(_Schema root, List<String> path, Object? data) {
  if (_schemaAt(root, path, data) != null) return true;
  if (path.isNotEmpty && path.last == 'length') {
    final parent = _schemaAt(root, path.sublist(0, path.length - 1), data);
    return parent != null && (parent.types.contains('array') || parent.types.contains('string'));
  }
  if (path.isNotEmpty && _index(path.last) != null) {
    final parent = _schemaAt(root, path.sublist(0, path.length - 1), data);
    return parent != null && parent.types.contains('string');
  }
  return false;
}

bool _missingArrayDependency(Object? data, List<String> path) {
  Object? cursor = data;
  for (final token in path) {
    if (cursor is List<Object?>) {
      if (token == 'length') return false;
      final index = _index(token);
      if (index == null || index >= cursor.length) return true;
      cursor = cursor[index];
    } else if (cursor is _Json) {
      cursor = cursor[token];
    } else {
      return false;
    }
  }
  return false;
}

Object? _derive(
  StateDefinition definition,
  Object? candidate,
  Object? baseline,
  List<_Json> clamps, {
  bool initial = false,
  List<List<String>>? written,
}) {
  final root = definition._root!;
  final done = <String>{};
  // Rebuild concrete instances after each producer. A derived container can
  // create item instances; its consumers must wait for those descendants too.
  while (true) {
    final all = _instances(root, candidate).where((x) => !x.node.blocked && x.node.derive != null).toList();
    final pending = all.where((x) => !done.contains(x.path)).toList();
    if (pending.isEmpty) return candidate;
    _Instance? ready;
    for (final item in pending) {
      var waits = false;
      for (final dependency in item.node.derive!.dependencies) {
        if (!_dependencyKnown(root, dependency, candidate)) {
          throw _StateError(
            'derive_dependency',
            item.path,
            'Expression refers to an undefined schema path ${_pointer(dependency)}.',
          );
        }
        for (final producer in all) {
          if ((_prefix(dependency, producer.tokens) || _prefix(producer.tokens, dependency)) &&
              !done.contains(producer.path)) {
            waits = true;
          }
        }
      }
      for (final producer in all) {
        if (producer.path != item.path && _prefix(producer.tokens, item.tokens) && !done.contains(producer.path)) {
          waits = true;
        }
      }
      if (!waits) {
        ready = item;
        break;
      }
    }
    if (ready == null) {
      throw const _StateError('derive_cycle', '', 'Derived instance dependencies contain a cycle.');
    }
    for (final dependency in ready.node.derive!.dependencies) {
      if (_missingArrayDependency(candidate, dependency)) {
        throw _StateError(
          'derive_array_dependency',
          ready.path,
          'A referenced array index cannot be resolved in this candidate.',
        );
      }
    }
    _directPermission(ready.node, StateActor.rules, ready.path, deriving: true);
    final raw = ready.node.derive!.evaluate(candidate);
    final old = _lookup(candidate, ready.tokens);
    if (!old.exists || !_equal(old.value, raw, distinguishZero: true)) {
      final value = _assigned(ready.node, _copy(raw), ready.tokens, baseline, clamps, initial: initial);
      final previous = _copy(candidate);
      candidate = _put(candidate, ready.tokens, value);
      _changedPermissions(root, previous, candidate, StateActor.rules, deriving: true);
      if (!_equal(previous, candidate)) written?.add(ready.tokens);
    }
    done.add(ready.path);
  }
}

class _Rule {
  _Rule(
    this.key,
    this.index,
    this.once,
    this.condition,
    this.actions, {
    this.source = const StateExecutionSource.legacy(),
    this.localId,
    this.actionTargets = const {},
  });
  final StateExecutionSource source;
  final String? localId;
  final Map<int, StateEventTarget> actionTargets;
  final String key;
  final int index;
  final bool once;
  final _Logic condition;
  final List<_Json> actions;
}

void _compileRules(
  StateDefinition definition, {
  int slotLimit = 256,
  StateExecutionSource source = const StateExecutionSource.legacy(),
  Map<(int, int), StateEventTarget> actionTargets = const {},
}) {
  final raw = definition._raw as _Json;
  if (!raw.containsKey('rules')) return;
  final rules = raw['rules'];
  if (rules is! List<Object?>) {
    definition._issues.add(_issue('rules_shape', '/rules', 'rules must be an array.'));
    return;
  }
  if (rules.length > 256) {
    definition._issues.add(_issue('rules_limit', '/rules', 'Rules after index 255 are not executed.'));
  }
  final idCounts = <String, int>{};
  for (final rule in rules) {
    if (rule is _Json && rule['id'] is String) {
      final id = rule['id']! as String;
      idCounts[id] = (idCounts[id] ?? 0) + 1;
    }
  }
  final occurrences = <String, int>{};
  for (var i = 0; i < rules.length && i < slotLimit; i++) {
    final path = '/rules/$i', rule = rules[i];
    try {
      if (rule is! _Json ||
          !rule.containsKey('when') ||
          rule['do'] is! List<Object?> ||
          (rule.containsKey('id') && rule['id'] is! String) ||
          (rule.containsKey('once') && rule['once'] is! bool)) {
        throw _StateError(
          'rule_shape',
          path,
          'A rule requires when, an action array, and valid optional id/once fields.',
        );
      }
      final id = rule['id'] as String?;
      if (id != null && idCounts[id]! > 1) {
        throw _StateError('rule_duplicate_id', path, 'Every rule sharing this explicit id is disabled.');
      }
      if (source.isPack && id == null) {
        throw _StateError(
          'rule_source_id',
          path,
          'A pack rule requires its original explicit string id as local identity.',
        );
      }
      final hash = _fingerprint(rule);
      final occurrence = occurrences[hash] ?? 0;
      occurrences[hash] = occurrence + 1;
      final condition = _Logic.compile(rule['when'], '$path/when');
      final actions = <_Json>[];
      final rawActions = rule['do']! as List<Object?>;
      for (var j = 0; j < rawActions.length; j++) {
        final action = rawActions[j];
        if (action is! _Json || !_finiteJson(action)) {
          throw _StateError('rule_action', '$path/do/$j', 'Action must be a finite JSON object.');
        }
        final type = action['type'];
        final valid = switch (type) {
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
        if (!valid) {
          throw _StateError('rule_action', '$path/do/$j', 'Unsupported or malformed action disables this rule.');
        }
        actions.add(action);
      }
      definition._rules.add(
        _Rule(
          id == null ? 'auto:$hash:$occurrence' : 'id:$id',
          i,
          rule['once'] == true,
          condition,
          actions,
          source: source,
          localId: id,
          actionTargets: {
            for (final entry in actionTargets.entries)
              if (entry.key.$1 == i) entry.key.$2: entry.value,
          },
        ),
      );
      for (final key in rule.keys) {
        if (!const {'id', 'when', 'once', 'do'}.contains(key)) {
          definition._issues.add(
            _issue('rule_unknown', '$path/${_escape(key)}', 'Unknown rule metadata is preserved.', kind: 'unknown'),
          );
        }
      }
    } on _StateError catch (e) {
      definition._issues.add(e.issue);
    }
  }
}

List<_Json> _runtimeIssues(bool exists, Object? runtime) {
  if (!exists) return [];
  if (runtime is! _Json || runtime['version'] != 1) {
    return [
      _issue(
        'runtime_version',
        '/dshgoStateRuntime',
        'Existing runtime must be an object with version 1; the session is read-only.',
      ),
    ];
  }
  if (!_finiteJson(runtime)) {
    return [
      _issue('runtime_json', '/dshgoStateRuntime', 'Runtime must contain finite JSON; the session is read-only.'),
    ];
  }
  if (runtime.containsKey('firedRules')) {
    final fired = runtime['firedRules'];
    if (fired is! List<Object?> || fired.any((x) => x is! String)) {
      return [
        _issue(
          'runtime_fired_rules',
          '/dshgoStateRuntime/firedRules',
          'Existing firedRules must be an array of strings; the session is read-only.',
        ),
      ];
    }
  }
  if (runtime.containsKey('pendingPrompts')) {
    final prompts = runtime['pendingPrompts'];
    final ids = <String>{};
    if (prompts is! List<Object?>) {
      return [
        _issue(
          'runtime_pending_prompts',
          '/dshgoStateRuntime/pendingPrompts',
          'Existing pendingPrompts must be an array; the session is read-only.',
        ),
      ];
    }
    for (final item in prompts) {
      if (item is! _Json || item['id'] is! String || item['text'] is! String || !ids.add(item['id']! as String)) {
        return [
          _issue(
            'runtime_pending_prompts',
            '/dshgoStateRuntime/pendingPrompts',
            'Pending prompts require unique string ids and string text; the session is read-only.',
          ),
        ];
      }
    }
  }
  return [];
}

class _Write {
  _Write(this.path, this.actor, this.why);
  final List<String> path;
  final StateActor actor;
  final String why;
}

class StateSession {
  StateSession._(
    this._definition, {
    required bool valueExists,
    Object? value,
    required bool runtimeExists,
    Object? runtime,
    required bool packRuntimeExists,
    Object? packRuntime,
  }) : _exists = valueExists,
       _value = _copy(value),
       _runtimeExists = runtimeExists,
       _runtime = _copy(runtime),
       _originalExists = valueExists,
       _original = _copy(value),
       _originalRuntimeExists = runtimeExists,
       _originalRuntime = _copy(runtime),
       _pack = _PackRuntime(exists: packRuntimeExists, raw: packRuntime) {
    _issues.addAll(_definition.issues);
    final runtimeProblems = _runtimeIssues(runtimeExists, _runtime);
    _issues.addAll(runtimeProblems);
    _readOnly = runtimeProblems.isNotEmpty || !_definition.executable;
    if (!_exists && !_readOnly) {
      final preview = _definition.initialPreview();
      if (preview.valueExists && preview.valid) {
        _value = preview.value;
        _exists = true;
        _initialized = true;
      } else {
        for (final issue in preview.issues) {
          if (!_issues.any((x) => _equal(x, issue))) _issues.add(issue);
        }
      }
    }
    _baselineExists = _exists;
    _baseline = _copy(_value);
    _capabilities = _modelPlan(_definition, _baseline, _baselineExists).capabilities;
  }
  final StateDefinition _definition;
  final _PackRuntime _pack;
  bool _exists;
  Object? _value;
  bool _runtimeExists;
  Object? _runtime;
  final bool _originalExists;
  final Object? _original;
  final bool _originalRuntimeExists;
  final Object? _originalRuntime;
  late final bool _baselineExists;
  late final Object? _baseline;
  late final List<_Capability> _capabilities;
  late final bool _readOnly;
  bool _initialized = false;
  bool _finishing = false;
  StateResult? _finished;
  bool? _finishedRules;
  StateEventFinishResult? _eventFinish;
  CardEventResult? _finishedEvents;
  CardEventInvocation? _eventBatch;
  var _operationCount = 0;
  var _receiptIndex = 0;
  var _actionCount = 0;
  var _effectBytes = 0;
  bool _ruleLimit = false;
  bool _settlementFailed = false;
  bool _publicApplyStarted = false;
  StateSecretPrepared? _secretPrepared;
  final List<_Json> _receipts = [], _issues = [], _effects = [];
  final List<_Write> _writes = [];
  final Set<String> _structural = {};

  /// Incorporates finalized WI before model operations or event settlement.
  /// The secret B receipt remains immutable; only this session's external
  /// pack baseline advances, with the original rule/event candidate retained.
  ({bool exists, Object? raw, List<Map<String, Object?>> issues}) adoptPackWorldInfo(StatePackWorldInfoDelta delta) {
    if (_publicApplyStarted || _eventBatch != null || _finishing || _finished != null) {
      throw StateError('World info must be adopted before state/event settlement.');
    }
    return _pack._adoptWorldInfo(delta);
  }

  StateApplyResult apply(Object? ops, {required StateActor actor, String? source}) {
    if (_finished != null || _finishing) {
      throw StateError('The state session is already finished.');
    }
    _publicApplyStarted = true;
    return _apply(ops, actor, source);
  }

  /// Acceptance is an atomic candidate on the original baseline, not a claim
  /// of durable binding. The host must commit it before publishing facts.
  StateSecretPrepared prepareSecretFacts(StateSecretPlan plan) => _secretPrepare(this, plan);

  /// Reads the sealed B-to-C phase without applying or finishing again.
  StateResult secretTerminalPhase(StateSecretPrepared prepared) => _secretTerminal(this, prepared);

  StateApplyResult _apply(
    Object? ops,
    StateActor actor,
    String? source, {
    StateExecutionSource? executionSource,
    String? localId,
  }) {
    final receipts = <_Json>[], issues = <_Json>[];
    var accepted = 0, rejected = 0;
    if (ops is! List<Object?>) {
      final issue = _issue('operations_shape', '', 'Operations must be an array.');
      issues.add(issue);
      _issues.add(issue);
      return StateApplyResult._(acceptedCount: 0, rejectedCount: 1, receipts: [], issues: issues);
    }
    for (var i = 0; i < ops.length; i++) {
      if (_operationCount >= 256) {
        final remaining = ops.length - i;
        final issue = _issue(
          'operations_limit',
          '',
          '$remaining remaining operations were not executed; invocation limit is 256.',
        );
        final receipt = <String, Object?>{
          'index': _receiptIndex++,
          'source': source,
          'executionSource': ?executionSource?.toJson(),
          'localId': ?localId,
          'actor': actor.name,
          'operation': null,
          'accepted': false,
          'changed': false,
          'conflict': null,
          'clamps': <Object?>[],
          'issues': [issue],
          'skippedCount': remaining,
        };
        receipts.add(receipt);
        _receipts.add(receipt);
        issues.add(issue);
        _issues.add(issue);
        rejected += remaining;
        break;
      }
      _operationCount++;
      final operation = _copy(ops[i]);
      final clamps = <_Json>[], problems = <_Json>[];
      Object? conflict;
      var changed = false, ok = false;
      try {
        if (_readOnly) {
          throw const _StateError(
            'session_read_only',
            '',
            'Definition or runtime is not executable; the original state is preserved.',
          );
        }
        if (operation is! _Json || !_finiteJson(operation)) {
          throw const _StateError('operation_shape', '', 'An operation must be a finite JSON object.');
        }
        final op = operation['op'], why = operation['why'];
        if (!const {'set', 'add', 'push', 'remove', 'move'}.contains(op) ||
            why is! String ||
            operation['path'] is! String ||
            !operation.keys.every(const {'op', 'path', 'value', 'why', 'from'}.contains) ||
            (op == 'remove' ? operation.containsKey('value') : !operation.containsKey('value'))) {
          throw const _StateError(
            'operation_shape',
            '',
            'Operation requires exact op/path/why/value fields for its operation kind.',
          );
        }
        final tokens = _tokens(operation['path']), path = _pointer(tokens);
        final old = _lookup(_value, tokens, exists: _exists);
        if (operation.containsKey('from') && (!old.exists || !_equal(old.value, operation['from']))) {
          conflict = {'expected': _copy(operation['from']), 'actualExists': old.exists, 'actual': _copy(old.value)};
        }
        if (!_exists && tokens.isNotEmpty) {
          throw _StateError('value_missing', path, 'The root must exist before editing a descendant.');
        }
        final root = _definition._root!;
        final node = _schemaAt(root, tokens, _value);
        if (node == null) {
          throw _StateError('unknown_path', path, 'The target must have a defined schema path.');
        }
        _directPermission(node, actor, path);
        if (actor == StateActor.model && !_capabilities.any((x) => x.matches(op! as String, path))) {
          throw _StateError(
            'model_capability',
            path,
            'The captured strict capability set does not include this operation.',
          );
        }
        if (actor == StateActor.model && !_modelOperationAllowed(node, op! as String, old.value)) {
          throw _StateError(
            'model_capability',
            path,
            'This operation is excluded from the compiled model capabilities.',
          );
        }
        Object? candidate = _copy(_value);
        final containers = <String>{};
        switch (op) {
          case 'set':
            if (actor == StateActor.model && !_modelValue(node, operation['value'])) {
              throw _StateError('model_value', path, 'Value is outside the supported non-null strict branches.');
            }
            final next = _assigned(node, _copy(operation['value']), tokens, _baseline, clamps);
            candidate = _put(candidate, tokens, next);
            break;
          case 'add':
            final delta = operation['value'];
            if (!old.exists || old.value is! num || delta is! num || !delta.isFinite || !(old.value! as num).isFinite) {
              throw _StateError(
                'add_number',
                path,
                'add requires an existing finite number and a finite numeric delta.',
              );
            }
            final num number;
            if (old.value is int && delta is int) {
              final sum = BigInt.from(old.value! as int) + BigInt.from(delta);
              number = sum.isValidInt ? sum.toInt() : sum.toDouble();
              if (number.isFinite && BigInt.from(number) != sum) {
                throw _StateError('numeric_precision', path, 'Integer sum cannot be represented without loss.');
              }
            } else {
              number = (old.value! as num).toDouble() + delta.toDouble();
            }
            if (!number.isFinite) {
              throw _StateError('numeric_overflow', path, 'Addition overflowed.');
            }
            candidate = _put(candidate, tokens, _assigned(node, number, tokens, _baseline, clamps));
            break;
          case 'push':
            if (!old.exists || old.value is! List<Object?> || node.items == null) {
              throw _StateError('push_array', path, 'push requires an existing array and a defined items schema.');
            }
            final array = _lookup(candidate, tokens).value! as List<Object?>;
            if (actor == StateActor.model && !_modelValue(node.items!, operation['value'])) {
              throw _StateError('model_value', path, 'New item is outside the supported non-null strict branches.');
            }
            final item = _assigned(
              node.items!,
              _copy(operation['value']),
              [...tokens, '${array.length}'],
              _baseline,
              clamps,
            );
            array.add(item);
            containers.add(path);
            break;
          case 'remove':
            if (tokens.isEmpty) {
              throw const _StateError('remove_root', '', 'The document root cannot be removed.');
            }
            final parent = _lookup(candidate, tokens.sublist(0, tokens.length - 1)).value;
            if (parent is List<Object?>) {
              containers.add(_pointer(tokens.sublist(0, tokens.length - 1)));
            }
            candidate = _remove(candidate, tokens).root;
            break;
          case 'move':
            final sourceTokens = _tokens(operation['value']);
            final sourcePath = _pointer(sourceTokens);
            final sourceValue = _lookup(candidate, sourceTokens, exists: _exists);
            if (!sourceValue.exists) {
              throw _StateError('missing_source', sourcePath, 'Move source does not exist.');
            }
            final sourceNode = _schemaAt(root, sourceTokens, candidate);
            if (sourceNode == null) {
              throw _StateError('unknown_path', sourcePath, 'Move source must have a defined schema path.');
            }
            _directPermission(sourceNode, actor, sourcePath);
            if (actor == StateActor.model && !_modelWhole(sourceNode, sourceValue.value)) {
              throw _StateError(
                'model_capability',
                sourcePath,
                'Move cannot remove protected or unknown source descendants.',
              );
            }
            if (_equal(sourceTokens, tokens)) break;
            if (_prefix(sourceTokens, tokens)) {
              throw _StateError('move_ancestor', path, 'A source cannot move inside its own descendant.');
            }
            final sourceParentTokens = sourceTokens.sublist(0, sourceTokens.length - 1);
            if (_lookup(candidate, sourceParentTokens).value is List<Object?>) {
              containers.add(_pointer(sourceParentTokens));
            }
            final removed = _remove(candidate, sourceTokens);
            candidate = removed.root;
            final targetNode = _schemaAt(root, tokens, candidate);
            if (targetNode == null) {
              throw _StateError('unknown_path', path, 'Move destination has no schema after removal.');
            }
            _directPermission(targetNode, actor, path);
            final targetParentTokens = tokens.isEmpty ? <String>[] : tokens.sublist(0, tokens.length - 1);
            if (tokens.isNotEmpty && _lookup(candidate, targetParentTokens).value is List<Object?>) {
              containers.add(_pointer(targetParentTokens));
            }
            candidate = _put(candidate, tokens, removed.removed, insert: true);
            break;
        }
        _changedPermissions(root, _value, candidate, actor);
        final direct = _copy(candidate);
        final derived = <List<String>>[];
        candidate = _derive(_definition, candidate, _baseline, clamps, written: derived);
        final validation = _validate(root, candidate, '');
        if (validation.isNotEmpty) {
          problems.addAll(validation);
          throw const _StateError(
            'candidate_invalid',
            '',
            'The complete candidate does not satisfy the supported schema.',
          );
        }
        _steps(root, candidate, _baseline);
        changed = !_exists || !_equal(_value, candidate);
        for (final row in _difference(_value, direct, beforeExists: _exists)) {
          _writes.add(_Write(_tokens(row['path']), actor, why));
        }
        for (final path in derived) {
          _writes.add(_Write(path, StateActor.rules, 'derive'));
        }
        _value = candidate;
        _exists = true;
        _structural.addAll(containers);
        ok = true;
        accepted++;
      } on _StateError catch (e) {
        problems.add(e.issue);
        rejected++;
      }
      final receipt = <String, Object?>{
        'index': _receiptIndex++,
        'source': source,
        'executionSource': ?executionSource?.toJson(),
        'localId': ?localId,
        'actor': actor.name,
        'operation': _auditCopy(operation),
        'accepted': ok,
        'changed': changed,
        'conflict': conflict,
        'clamps': clamps,
        'issues': problems,
      };
      receipts.add(receipt);
      _receipts.add(receipt);
      issues.addAll(problems);
      _issues.addAll(problems);
    }
    return StateApplyResult._(acceptedCount: accepted, rejectedCount: rejected, receipts: receipts, issues: issues);
  }

  _Json _ensureRuntime() {
    if (!_runtimeExists) {
      _runtimeExists = true;
      _runtime = <String, Object?>{'version': 1};
    }
    return _runtime! as _Json;
  }

  _Json _ruleReceipt(_Rule rule, String status, {bool? matched, List<_Json> issues = const []}) {
    final result = <String, Object?>{
      'index': _receiptIndex++,
      'source': rule.key,
      if (rule.source.isPack) ...{
        'executionSource': rule.source.toJson(),
        'localId': ?rule.localId,
        'sourceIndex': rule.index,
      },
      'actor': 'rules',
      'operation': {'op': 'rule', 'id': rule.key},
      'accepted': status != 'condition_error' && status != 'runtime_error',
      'changed': false,
      'conflict': null,
      'clamps': <Object?>[],
      'issues': issues,
      'status': status,
      'matched': matched,
      'consumedOnce': false,
    };
    _receipts.add(result);
    return result;
  }

  void _deriveFailure(List<_Json> problems) {
    _settlementFailed = true;
    _issues.addAll(problems);
    _receipts.add({
      'index': _receiptIndex++,
      'source': 'rules',
      'actor': 'rules',
      'operation': {'op': 'derive'},
      'accepted': false,
      'changed': false,
      'conflict': null,
      'clamps': <Object?>[],
      'issues': problems,
    });
  }

  void _runRules() {
    if (!_exists || _readOnly) return;
    final validation = _validate(_definition._root!, _value, '');
    if (validation.isNotEmpty) {
      _deriveFailure(validation);
      return;
    }
    for (final rule in _definition._rules) {
      if (_ruleLimit) break;
      if (rule.once) {
        if (rule.source.isPack) {
          final problems = _pack.issues(rule.source, _PackDomain.rules);
          if (problems.isNotEmpty) {
            _issues.addAll(problems);
            _ruleReceipt(rule, 'runtime_error', issues: problems);
            continue;
          }
          if (_pack.ruleFired(rule.source, rule.localId!)) {
            _ruleReceipt(rule, 'once_skipped');
            continue;
          }
        } else {
          final runtime = _runtime is _Json ? _runtime! as _Json : null;
          final fired = runtime?['firedRules'];
          if (fired is List<Object?> && fired.contains(rule.key)) {
            _ruleReceipt(rule, 'once_skipped');
            continue;
          }
        }
      }
      try {
        if (!_truthy(rule.condition.evaluate(_value))) {
          _ruleReceipt(rule, 'not_matched', matched: false);
          continue;
        }
      } on _StateError catch (e) {
        _issues.add(e.issue);
        _ruleReceipt(rule, 'condition_error', issues: [e.issue]);
        continue;
      }
      final judgment = _ruleReceipt(rule, 'matched', matched: true);
      var successful = false;
      for (var j = 0; j < rule.actions.length; j++) {
        if (_actionCount >= 256) {
          _issues.add(
            _issue(
              'rule_actions_limit',
              '/rules/${rule.index}/do/$j',
              'Remaining rule actions are not executed; invocation limit is 256.',
            ),
          );
          _ruleLimit = true;
          break;
        }
        _actionCount++;
        final action = rule.actions[j];
        if (action['type'] == 'state') {
          final result = _apply(
            action['ops'],
            StateActor.rules,
            rule.key,
            executionSource: rule.source.isPack ? rule.source : null,
            localId: rule.source.isPack ? rule.localId : null,
          );
          successful = successful || result.acceptedCount > 0;
        } else {
          final target = action['type'] == 'event' ? rule.actionTargets[j] : null;
          final effect = <String, Object?>{
            ..._mapCopy(action),
            'ruleId': rule.key,
            'source': 'rules',
            if (target != null) 'eventTarget': {'source': target.source.toJson(), 'name': target.name},
            if (rule.source.isPack) ...{
              'executionSource': rule.source.toJson(),
              'localId': ?rule.localId,
              'sourceIndex': rule.index,
              'actionIndex': j,
            },
          };
          final size = utf8.encode(jsonEncode(effect)).length;
          if (_effectBytes + size > 256 * 1024) {
            _issues.add(
              _issue(
                'rule_effects_limit',
                '/rules/${rule.index}/do/$j',
                'Remaining actions are not executed; effect UTF-8 limit is 256 KiB.',
              ),
            );
            _ruleLimit = true;
            break;
          }
          _effectBytes += size;
          _effects.add(effect);
          successful = true;
          if (!rule.source.isPack) {
            _ensureRuntime();
          }
        }
      }
      if (rule.once && successful) {
        if (rule.source.isPack) {
          _pack.consumeRule(rule.source, rule.localId!);
        } else {
          final ledger = _ensureRuntime();
          final old = ledger['firedRules'];
          final list = old is List<Object?> ? List<Object?>.of(old) : <Object?>[];
          if (!list.contains(rule.key)) {
            list.add(rule.key);
          }
          ledger['firedRules'] = list;
        }
        judgment['consumedOnce'] = true;
      }
      judgment['actionAccepted'] = successful;
    }
  }

  StateResult finish({bool runRules = true}) => _finish(runRules: runRules);

  /// One irreversible settlement: model operations already applied, ordinary
  /// derive/rules once, then authorized named handlers on the same baseline and
  /// counters. Calling this again with an identical detached batch is idempotent.
  /// A prior plain finish cannot be reopened, nor can a second batch be appended.
  StateEventFinishResult finishWithEvents(CardEventInvocation invocation) {
    if (_eventFinish != null) {
      if (!_eventBatch!._sameBatch(invocation)) {
        throw StateError('finishWithEvents cannot change its admitted batch after completion.');
      }
      return _eventFinish!;
    }
    if (_finished != null || _finishing) {
      throw StateError('A finished state session cannot accept an event batch.');
    }
    _eventBatch = invocation;
    final state = _finish(runRules: true, events: invocation);
    _eventFinish = StateEventFinishResult._(state: state, events: _finishedEvents!);
    return _eventFinish!;
  }

  StateResult _finish({required bool runRules, CardEventInvocation? events}) {
    if (_finished != null) {
      if (_finishedRules != runRules) {
        throw StateError('finish cannot change its rule policy after completion.');
      }
      return _finished!;
    }
    _finishing = true;
    if (runRules && !_readOnly && _exists) {
      // A no-tool successful reply can still recalculate derived fields. The
      // full candidate is checked before publishing these automatic writes.
      try {
        final clamps = <_Json>[], written = <List<String>>[];
        final candidate = _derive(_definition, _copy(_value), _baseline, clamps, written: written);
        final invalid = _validate(_definition._root!, candidate, '');
        if (invalid.isNotEmpty) {
          _deriveFailure(invalid);
        } else {
          _steps(_definition._root!, candidate, _baseline);
          _value = candidate;
          for (final path in written) {
            _writes.add(_Write(path, StateActor.rules, 'derive'));
          }
          if (clamps.isNotEmpty || written.isNotEmpty) {
            _receipts.add({
              'index': _receiptIndex++,
              'source': 'rules',
              'actor': 'rules',
              'operation': {'op': 'derive'},
              'accepted': true,
              'changed': written.isNotEmpty,
              'conflict': null,
              'clamps': clamps,
              'issues': <Object?>[],
            });
          }
          _runRules();
        }
      } on _StateError catch (e) {
        _deriveFailure([e.issue]);
      }
    }
    if (events != null) {
      final stateValid =
          !_readOnly && !_settlementFailed && _exists && _definition.validate(_value, valueExists: _exists).isEmpty;
      _finishedEvents = _CardEventSettlement(events, session: this, stateValid: stateValid).run();
    }
    final changes = _difference(
      _baseline,
      _value,
      beforeExists: _baselineExists,
      afterExists: _exists,
      containers: _structural,
    );
    for (final row in changes) {
      final tokens = _tokens(row['path']);
      _Write? writer;
      for (final item in _writes) {
        if (_prefix(item.path, tokens) || _prefix(tokens, item.path)) writer = item;
      }
      row['actor'] = writer?.actor.name ?? 'rules';
      row['why'] = writer?.why ?? 'initialization';
    }
    final validation = _definition.validate(_value, valueExists: _exists);
    for (final issue in validation) {
      if (!_issues.any((x) => _equal(x, issue))) _issues.add(issue);
    }
    _finishedRules = runRules;
    _finished = StateResult._(
      valueExists: _exists,
      value: _value,
      runtimeExists: _runtimeExists,
      runtime: _runtime,
      packRuntimeExists: _pack.exists,
      packRuntime: _pack.raw,
      initialized: _initialized,
      valid: !_readOnly && !_settlementFailed && _exists && validation.isEmpty,
      changed:
          _originalExists != _exists ||
          !_equal(_original, _value) ||
          _originalRuntimeExists != _runtimeExists ||
          !_equal(_originalRuntime, _runtime) ||
          _pack.changed,
      changes: changes,
      receipts: _receipts,
      effects: _effects,
      issues: _issues,
    );
    return _finished!;
  }
}
