/// Pure, branch-local story progress. Callers publish a candidate only in the
/// same transaction as the successful main turn. Reading never settles a turn.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../state/state_engine.dart' show evaluateStateExpression;

typedef _Json = Map<String, Object?>;

/// A detached view for the user and director. It is not a main-model prompt.
class StorySnapshot {
  StorySnapshot._({
    required this.defined,
    required this.executable,
    required this.initialized,
    required this.valid,
    required this.fingerprint,
    required this.currentActId,
    required this.currentActIndex,
    required this.actTurns,
    required this.completed,
    required _Json? currentAct,
    required List<String> unlockedEndings,
    required List<_Json> issues,
  }) : _currentAct = currentAct == null ? null : _mapCopy(currentAct),
       _unlockedEndings = List.of(unlockedEndings),
       _issues = _maps(issues);

  final bool defined;
  final bool executable;
  final bool initialized;
  final bool valid;
  final String fingerprint;
  final String? currentActId;
  final int? currentActIndex;
  final int? actTurns;
  final bool? completed;
  final _Json? _currentAct;
  final List<String> _unlockedEndings;
  final List<_Json> _issues;

  Map<String, Object?>? get currentAct => _currentAct == null ? null : _mapCopy(_currentAct);
  List<String> get unlockedEndings => List.of(_unlockedEndings);
  List<Map<String, Object?>> get issues => _maps(_issues);

  Map<String, Object?> toJson() => {
    'defined': defined,
    'executable': executable,
    'initialized': initialized,
    'valid': valid,
    'fingerprint': fingerprint,
    'currentActId': currentActId,
    'currentActIndex': currentActIndex,
    'actTurns': actTurns,
    'completed': completed,
    'currentAct': currentAct,
    'unlockedEndings': unlockedEndings,
    'issues': issues,
  };
}

/// A candidate, never a storage command. [runtimeExists] distinguishes a
/// missing runtime from a preserved explicit null or otherwise invalid value.
class StoryResult {
  StoryResult._({
    required this.valid,
    required this.runtimeExists,
    required this.initialized,
    required this.changed,
    required Object? runtime,
    required this.snapshot,
    required List<_Json> changes,
    required List<_Json> effects,
    required List<_Json> issues,
  }) : _runtime = _copy(runtime),
       _changes = _maps(changes),
       _effects = _maps(effects),
       _issues = _maps(issues);

  final bool valid;
  final bool runtimeExists;
  final bool initialized;
  final bool changed;
  final StorySnapshot snapshot;
  final Object? _runtime;
  final List<_Json> _changes;
  final List<_Json> _effects;
  final List<_Json> _issues;

  Object? get runtime => _copy(_runtime);
  List<Map<String, Object?>> get changes => _maps(_changes);
  List<Map<String, Object?>> get effects => _maps(_effects);
  List<Map<String, Object?>> get issues => _maps(_issues);

  Map<String, Object?> toJson() => {
    'version': 1,
    'valid': valid,
    'runtimeExists': runtimeExists,
    'initialized': initialized,
    'changed': changed,
    'runtime': runtime,
    'snapshot': snapshot.toJson(),
    'changes': changes,
    'effects': effects,
    'issues': issues,
  };
}

class _Act {
  const _Act(this.id, this.title, this.goal, this.when, this.minTurns, this.maxTurns, this.index);
  final String id;
  final String title;
  final String goal;
  final Object? when;
  final int minTurns;
  final int? maxTurns;
  final int index;
}

class _Ending {
  const _Ending(this.id, this.title, this.when, this.index);
  final String id;
  final String title;
  final Object? when;
  final int index;
}

/// Compiles declarations without evaluating their conditions. Unknown JSON
/// annotations remain in [raw] and in the definition fingerprint.
class StoryDefinition {
  StoryDefinition.parse(Object? rawStory, {Object? version = 1}) : _raw = _copy(rawStory), _version = _copy(version) {
    final finite = _finiteJson(_raw) && _finiteJson(_version);
    fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode(
              _canonical({
                'version': _finiteJson(_version) ? _version : 'non-json-version',
                'story': finite ? _raw : 'non-json-story',
              }),
            ),
          ),
        )
        .toString();
    if (!defined) {
      return;
    }
    if (!finite || _raw is! _Json) {
      _issues.add(_issue('story_shape', '', 'Story definition must be a finite JSON object.'));
      return;
    }
    if (_version != 1) {
      _issues.add(_issue('story_version', '', 'This story version is preserved but not executable.'));
      return;
    }
    final object = _raw;
    if (utf8.encode(jsonEncode(object)).length > 1024 * 1024) {
      _issues.add(_issue('story_definition_limit', '', 'Story definition exceeds one MiB of encoded UTF-8 JSON.'));
      return;
    }
    for (final name in const ['acts', 'endings']) {
      final declarations = object[name];
      if (declarations is List<Object?> && declarations.length > 256) {
        _issues.add(
          _issue('story_declaration_limit', '/$name', 'At most 256 declarations are supported in this array.'),
        );
      }
    }
    if (_issues.isNotEmpty) {
      return;
    }
    if (object.containsKey('outline') && object['outline'] is! String) {
      _issues.add(_issue('story_outline', '/outline', 'Outline must be a string.'));
    }
    _parseActs(object);
    _parseEndings(object);
    if (object.containsKey('tension')) {
      final value = object['tension'];
      if (value is! List<Object?> ||
          value.length != _acts.length ||
          value.any((item) => item is! num || !item.isFinite)) {
        _issues.add(_issue('story_tension', '/tension', 'Tension must contain one finite number per act.'));
      } else {
        _tension = value.cast<num>().toList();
      }
    }
    _unknown(object, const {'outline', 'acts', 'tension', 'endings'}, '');
  }

  final Object? _raw;
  final Object? _version;
  late final String fingerprint;
  final List<_Json> _issues = [];
  final List<_Act> _acts = [];
  final List<_Ending> _endings = [];
  List<num>? _tension;

  bool get defined => _raw != null;
  bool get executable =>
      defined && _raw is _Json && _version == 1 && !_issues.any((issue) => issue['kind'] == 'invalid');
  Object? get raw => _copy(_raw);
  String? get outline => _raw is _Json && _raw['outline'] is String ? _raw['outline']! as String : null;
  List<num>? get tension => _tension == null ? null : List.of(_tension!);
  List<Map<String, Object?>> get issues => _maps(_issues);

  void _unknown(_Json object, Set<String> known, String path) {
    for (final key in object.keys) {
      if (!known.contains(key)) {
        _issues.add(
          _issue(
            'story_annotation',
            '$path/${_escape(key)}',
            'Unknown story annotation is preserved without execution.',
            kind: 'unknown',
          ),
        );
      }
    }
  }

  void _condition(Object? expression, String path) {
    // The shared compiler visits both branches, while evaluation chooses the
    // literal false branch. No user condition runs during parse or inspect.
    final check = evaluateStateExpression({
      'if': [false, expression, false],
    }, null);
    for (final issue in check.issues) {
      _issues.add(_conditionIssue(issue, path));
    }
  }

  void _parseActs(_Json object) {
    if (!object.containsKey('acts')) {
      return;
    }
    final list = object['acts'];
    if (list is! List<Object?>) {
      _issues.add(_issue('story_acts', '/acts', 'Acts must be an array.'));
      return;
    }
    final ids = <String>{};
    for (var i = 0; i < list.length; i++) {
      final value = list[i];
      final path = '/acts/$i';
      if (value is! _Json) {
        _issues.add(_issue('story_act', path, 'Each act must be an object.'));
        continue;
      }
      final id = value['id'];
      final title = value.containsKey('title') ? value['title'] : '';
      final goal = value.containsKey('goal') ? value['goal'] : '';
      final min = value.containsKey('minTurns') ? value['minTurns'] : 0;
      final max = value['maxTurns'];
      final hasMax = value.containsKey('maxTurns');
      var valid = true;
      if (id is! String || id.trim().isEmpty || !ids.add(id)) {
        _issues.add(_issue('story_act_id', '$path/id', 'Act id must be a unique nonempty string.'));
        valid = false;
      }
      if (title is! String || goal is! String) {
        _issues.add(_issue('story_act_text', path, 'Act title and goal must be strings when present.'));
        valid = false;
      }
      if (min is! int || min < 0 || (hasMax && (max is! int || max < 0 || max < min))) {
        _issues.add(
          _issue('story_act_turns', path, 'Turn bounds must be nonnegative integers with maxTurns >= minTurns.'),
        );
        valid = false;
      }
      final when = value.containsKey('when') ? value['when'] : false;
      _condition(when, '$path/when');
      _unknown(value, const {'id', 'title', 'goal', 'when', 'minTurns', 'maxTurns'}, path);
      if (valid) {
        _acts.add(_Act(id! as String, title! as String, goal! as String, when, min! as int, max as int?, i));
      }
    }
  }

  void _parseEndings(_Json object) {
    if (!object.containsKey('endings')) {
      return;
    }
    final list = object['endings'];
    if (list is! List<Object?>) {
      _issues.add(_issue('story_endings', '/endings', 'Endings must be an array.'));
      return;
    }
    final ids = <String>{};
    for (var i = 0; i < list.length; i++) {
      final value = list[i];
      final path = '/endings/$i';
      if (value is! _Json) {
        _issues.add(_issue('story_ending', path, 'Each ending must be an object.'));
        continue;
      }
      final id = value['id'];
      final title = value['title'];
      var valid = true;
      if (id is! String || id.trim().isEmpty || !ids.add(id)) {
        _issues.add(_issue('story_ending_id', '$path/id', 'Ending id must be a unique nonempty string.'));
        valid = false;
      }
      if (title is! String || title.trim().isEmpty) {
        _issues.add(_issue('story_ending_title', '$path/title', 'Ending title must be a nonempty string.'));
        valid = false;
      }
      if (!value.containsKey('when')) {
        _issues.add(_issue('story_ending_when', '$path/when', 'Ending condition must be explicitly declared.'));
        valid = false;
      }
      _condition(value['when'], '$path/when');
      _unknown(value, const {'id', 'title', 'when'}, path);
      if (valid) {
        _endings.add(_Ending(id! as String, title! as String, value['when'], i));
      }
    }
  }

  /// Reads the saved progress without evaluating any condition, initializing
  /// any runtime, or producing effects. Explicit invalid values stay invalid.
  StorySnapshot inspect({required bool runtimeExists, Object? runtime}) => _inspect(runtimeExists, runtime, const []);

  List<_Json> _runtimeIssues(bool exists, Object? runtime) {
    if (!exists) {
      return [];
    }
    if (!_finiteJson(runtime) || runtime is! _Json) {
      return [_issue('story_runtime_shape', '', 'Saved story runtime must be a finite JSON object.')];
    }
    final result = <_Json>[];
    if (runtime['version'] != 1) {
      result.add(_issue('story_runtime_version', '/version', 'Saved story runtime version is not supported.'));
    }
    if (runtime['definitionFingerprint'] != fingerprint) {
      result.add(
        _issue(
          'story_runtime_definition',
          '/definitionFingerprint',
          'Saved progress belongs to a different story definition and remains read-only.',
        ),
      );
    }
    final actId = runtime['actId'];
    final actTurns = runtime['actTurns'];
    final completed = runtime['completed'];
    if (actTurns is! int || actTurns < 0) {
      result.add(_issue('story_runtime_turns', '/actTurns', 'Saved act turns must be a nonnegative integer.'));
    }
    if (completed is! bool) {
      result.add(_issue('story_runtime_completed', '/completed', 'Saved completed flag must be a boolean.'));
    }
    if (!runtime.containsKey('actId') ||
        (_acts.isEmpty && (actId != null || actTurns != 0 || completed != true)) ||
        (_acts.isNotEmpty &&
            (actId is! String ||
                !_acts.any((act) => act.id == actId) ||
                (completed == true && actId != _acts.last.id)))) {
      result.add(_issue('story_runtime_act', '/actId', 'Saved current act is inconsistent with this definition.'));
    }
    final unlocked = runtime['unlockedEndings'];
    if (unlocked is! List<Object?> ||
        unlocked.any((id) => id is! String || !_endings.any((ending) => ending.id == id)) ||
        unlocked.toSet().length != unlocked.length) {
      result.add(_issue('story_runtime_endings', '/unlockedEndings', 'Saved ending ids must be unique declared ids.'));
    }
    final invocation = runtime['lastInvocationId'];
    if (!runtime.containsKey('lastInvocationId') ||
        (invocation != null && (invocation is! String || invocation.trim().isEmpty))) {
      result.add(
        _issue('story_runtime_invocation', '/lastInvocationId', 'Saved invocation must be null or a nonempty string.'),
      );
    }
    return result;
  }

  _Json _actView(_Act act) => {
    'id': act.id,
    'title': act.title,
    'goal': act.goal,
    'minTurns': act.minTurns,
    'maxTurns': act.maxTurns,
    if (_tension != null) 'tension': _tension![act.index],
  };

  StorySnapshot _inspect(bool runtimeExists, Object? runtime, List<_Json> extraIssues) {
    final allIssues = [..._issues, ..._runtimeIssues(runtimeExists, runtime), ...extraIssues];
    final valid = !allIssues.any((issue) => issue['kind'] == 'invalid');
    final saved = valid && runtimeExists && runtime is _Json
        ? runtime
        : valid && !runtimeExists && executable
        ? _initialRuntime()
        : null;
    final id = saved?['actId'];
    final index = id is String ? _acts.indexWhere((act) => act.id == id) : -1;
    return StorySnapshot._(
      defined: defined,
      executable: executable,
      initialized: runtimeExists,
      valid: valid,
      fingerprint: fingerprint,
      currentActId: id is String ? id : null,
      currentActIndex: index < 0 ? null : index,
      actTurns: saved?['actTurns'] as int?,
      completed: saved?['completed'] as bool?,
      currentAct: index < 0 ? null : _actView(_acts[index]),
      unlockedEndings: saved == null ? [] : (saved['unlockedEndings']! as List<Object?>).cast<String>(),
      issues: allIssues,
    );
  }

  _Json _initialRuntime() => {
    'version': 1,
    'definitionFingerprint': fingerprint,
    'actId': _acts.isEmpty ? null : _acts.first.id,
    'actTurns': 0,
    'completed': _acts.isEmpty,
    'unlockedEndings': <String>[],
    'lastInvocationId': null,
  };

  StoryResult _unchanged(bool runtimeExists, Object? runtime, {List<_Json> extraIssues = const []}) {
    final view = _inspect(runtimeExists, runtime, extraIssues);
    return StoryResult._(
      valid: view.valid,
      runtimeExists: runtimeExists,
      initialized: false,
      changed: false,
      runtime: runtime,
      snapshot: view,
      changes: const [],
      effects: const [],
      issues: view.issues,
    );
  }

  /// Settles exactly one successful, authorized main invocation. The owner
  /// supplies the final T17 state and sets [countTurn] false for every other
  /// path. This method never writes that state or evaluates T17 rules again.
  StoryResult settle({
    required Object? state,
    required bool runtimeExists,
    Object? runtime,
    required String invocationId,
    required bool countTurn,
  }) {
    final before = inspect(runtimeExists: runtimeExists, runtime: runtime);
    if (!countTurn || !executable || !before.valid) {
      return _unchanged(runtimeExists, runtime);
    }
    if (invocationId.trim().isEmpty) {
      return _unchanged(
        runtimeExists,
        runtime,
        extraIssues: [_issue('story_invocation', '', 'A settling invocation must have a nonempty id.')],
      );
    }
    final candidate = runtimeExists ? _mapCopy(runtime! as _Json) : _initialRuntime();
    if (candidate['lastInvocationId'] == invocationId) {
      return _unchanged(runtimeExists, runtime);
    }
    if (!_finiteJson(state)) {
      return _unchanged(
        runtimeExists,
        runtime,
        extraIssues: [_issue('story_state', '', 'Final state supplied to story conditions must be finite JSON.')],
      );
    }
    final conditionIssues = <_Json>[];
    bool matches(Object? expression, String path) {
      final result = evaluateStateExpression(expression, state);
      conditionIssues.addAll(result.issues.map((issue) => _conditionIssue(issue, path)));
      return result.valid && _truthy(result.value);
    }

    final effects = <_Json>[];
    if (candidate['completed'] != true && _acts.isNotEmpty) {
      final index = _acts.indexWhere((act) => act.id == candidate['actId']);
      final act = _acts[index];
      final oldTurns = candidate['actTurns']! as int;
      final turns = oldTurns + 1;
      if (turns <= oldTurns) {
        return _unchanged(
          runtimeExists,
          runtime,
          extraIssues: [_issue('story_turn_overflow', '/actTurns', 'Act turn counter cannot be incremented exactly.')],
        );
      }
      candidate['actTurns'] = turns;
      final forced = act.maxTurns != null && turns >= act.maxTurns!;
      final advance = turns >= act.minTurns && (forced || matches(act.when, '/acts/${act.index}/when'));
      if (advance) {
        final isLast = index + 1 == _acts.length;
        candidate['completed'] = isLast;
        if (!isLast) {
          candidate['actId'] = _acts[index + 1].id;
          candidate['actTurns'] = 0;
        }
        effects.add({
          'type': 'advance',
          'source': 'story',
          'fromActId': act.id,
          'toActId': isLast ? null : _acts[index + 1].id,
          'completed': isLast,
          'reason': forced ? 'maximum' : 'condition',
        });
      }
    }

    final unlocked = (candidate['unlockedEndings']! as List<Object?>).cast<String>().toList();
    for (final ending in _endings) {
      if (!unlocked.contains(ending.id) && matches(ending.when, '/endings/${ending.index}/when')) {
        unlocked.add(ending.id);
        effects.add({'type': 'unlock', 'kind': 'ending', 'source': 'story', 'id': ending.id, 'title': ending.title});
      }
    }
    if (conditionIssues.isNotEmpty) {
      return _unchanged(runtimeExists, runtime, extraIssues: conditionIssues);
    }
    candidate['unlockedEndings'] = unlocked;
    candidate['lastInvocationId'] = invocationId;
    for (var i = 0; i < effects.length; i++) {
      effects[i]['effectId'] = '$invocationId:story:$i';
    }
    final view = inspect(runtimeExists: true, runtime: candidate);
    return StoryResult._(
      valid: true,
      runtimeExists: true,
      initialized: !runtimeExists,
      changed: true,
      runtime: candidate,
      snapshot: view,
      changes: _changes(runtimeExists ? runtime! as _Json : const {}, candidate),
      effects: effects,
      issues: view.issues,
    );
  }
}

_Json _conditionIssue(_Json issue, String path) => {
  ..._issue('story_condition', path, 'Story condition is invalid.'),
  'cause': _mapCopy(issue),
};

List<_Json> _changes(_Json oldValue, _Json newValue) => [
  for (final key in {...oldValue.keys, ...newValue.keys})
    if (!oldValue.containsKey(key) || !newValue.containsKey(key) || !_equal(oldValue[key], newValue[key]))
      {
        'path': '/${_escape(key)}',
        'oldExists': oldValue.containsKey(key),
        'newExists': newValue.containsKey(key),
        if (oldValue.containsKey(key)) 'old': _copy(oldValue[key]),
        if (newValue.containsKey(key)) 'new': _copy(newValue[key]),
      },
];

bool _equal(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  if (a is _Json && b is _Json) {
    return a.length == b.length && a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
  }
  return a == b;
}

Object? _copy(Object? value) {
  if (value is _Json) {
    return <String, Object?>{for (final entry in value.entries) entry.key: _copy(entry.value)};
  }
  if (value is List<Object?>) {
    return <Object?>[for (final item in value) _copy(item)];
  }
  return value;
}

_Json _mapCopy(_Json value) => _copy(value)! as _Json;
List<_Json> _maps(List<_Json> values) => [for (final value in values) _mapCopy(value)];

bool _finiteJson(Object? value) {
  if (value == null || value is String || value is bool) {
    return true;
  }
  if (value is num) {
    return value.isFinite;
  }
  if (value is List<Object?>) {
    return value.every(_finiteJson);
  }
  if (value is _Json) {
    return value.values.every(_finiteJson);
  }
  return false;
}

Object? _canonical(Object? value) {
  if (value is _Json) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List<Object?>) {
    return value.map(_canonical).toList();
  }
  if (value is double && value.isFinite && value == value.truncateToDouble() && value.abs() <= 9007199254740991) {
    return value.toInt();
  }
  return value;
}

_Json _issue(String code, String path, String message, {String kind = 'invalid'}) => {
  'code': code,
  'path': path,
  'message': message,
  'kind': kind,
};

bool _truthy(Object? value) {
  if (value == null || value == false) {
    return false;
  }
  if (value is num) {
    return value != 0 && !value.isNaN;
  }
  if (value is String) {
    return value.isNotEmpty;
  }
  if (value is List<Object?>) {
    return value.isNotEmpty;
  }
  return true;
}

String _escape(String value) => value.replaceAll('~', '~0').replaceAll('/', '~1');
