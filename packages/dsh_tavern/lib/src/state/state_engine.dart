/// Pure DSH state definitions and one-invocation candidates. No storage or
/// model transport lives here; callers publish a result only after SQL commit.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../js_string.dart';

part 'json_value.dart';
part 'json_logic.dart';
part 'schema.dart';
part 'session.dart';
part 'composition.dart';
part 'execution_sources.dart';
part 'projection.dart';
part 'card_events.dart';
part 'secret_prepare.dart';
part 'secret_slots.dart';

enum StateActor { model, rules, user }

typedef _Json = Map<String, Object?>;

class StateInitialPreview {
  StateInitialPreview._({
    required this.valueExists,
    required Object? value,
    required this.valid,
    required List<_Json> issues,
  }) : _value = _copy(value),
       _issues = _maps(issues);
  final bool valueExists;
  final bool valid;
  final Object? _value;
  final List<_Json> _issues;
  Object? get value => _copy(_value);
  List<Map<String, Object?>> get issues => _maps(_issues);
}

class StateProjection {
  StateProjection._({
    required this.valueExists,
    required Object? value,
    required this.summary,
    required this.depth,
    required this.role,
    required List<String> hiddenPaths,
    required List<String> pinPaths,
    required List<_Json> issues,
  }) : _value = _copy(value),
       _hiddenPaths = List.of(hiddenPaths),
       _pinPaths = List.of(pinPaths),
       _issues = _maps(issues);
  final bool valueExists;
  final Object? _value;
  final String summary;
  final int depth;
  final String role;
  final List<String> _hiddenPaths;
  final List<String> _pinPaths;
  final List<_Json> _issues;
  Object? get value => _copy(_value);
  List<String> get hiddenPaths => List.of(_hiddenPaths);
  List<String> get pinPaths => List.of(_pinPaths);
  List<Map<String, Object?>> get issues => _maps(_issues);
}

class StateStrictTool {
  StateStrictTool._(_Json? tool, List<_Json> issues)
    : _tool = tool == null ? null : _mapCopy(tool),
      _issues = _maps(issues);
  final _Json? _tool;
  final List<_Json> _issues;
  Map<String, Object?>? get tool => _tool == null ? null : _mapCopy(_tool);
  List<Map<String, Object?>> get issues => _maps(_issues);
}

class StateApplyResult {
  StateApplyResult._({
    required this.acceptedCount,
    required this.rejectedCount,
    required List<_Json> receipts,
    required List<_Json> issues,
  }) : _receipts = _maps(receipts),
       _issues = _maps(issues);
  final int acceptedCount;
  final int rejectedCount;
  final List<_Json> _receipts;
  final List<_Json> _issues;
  List<Map<String, Object?>> get receipts => _maps(_receipts);
  List<Map<String, Object?>> get issues => _maps(_issues);
  Map<String, Object?> toJson() => {
    'acceptedCount': acceptedCount,
    'rejectedCount': rejectedCount,
    'receipts': receipts,
    'issues': issues,
  };
}

class StateResult {
  StateResult._({
    required this.valueExists,
    required Object? value,
    required this.runtimeExists,
    required Object? runtime,
    this.packRuntimeExists = false,
    Object? packRuntime,
    required this.initialized,
    required this.valid,
    required this.changed,
    required List<_Json> changes,
    required List<_Json> receipts,
    required List<_Json> effects,
    required List<_Json> issues,
  }) : _value = _copy(value),
       _runtime = _copy(runtime),
       _packRuntime = _eventCopy(packRuntime),
       _changes = _maps(changes),
       _receipts = _maps(receipts),
       _effects = _maps(effects),
       _issues = _maps(issues);
  final bool valueExists;
  final bool runtimeExists;
  final bool packRuntimeExists;
  final bool initialized;
  final bool valid;
  final bool changed;
  final Object? _value;
  final Object? _runtime;
  final Object? _packRuntime;
  final List<_Json> _changes;
  final List<_Json> _receipts;
  final List<_Json> _effects;
  final List<_Json> _issues;
  Object? get value => _copy(_value);
  Object? get runtime => _copy(_runtime);
  Object? get packRuntime => _eventCopy(_packRuntime);
  List<Map<String, Object?>> get changes => _maps(_changes);
  List<Map<String, Object?>> get receipts => _maps(_receipts);
  List<Map<String, Object?>> get effects => _maps(_effects);
  List<Map<String, Object?>> get issues => _maps(_issues);
  Map<String, Object?> toJson() => {
    'version': 1,
    'valueExists': valueExists,
    'value': value,
    'runtimeExists': runtimeExists,
    'runtime': runtime,
    if (packRuntimeExists) ...{'packRuntimeExists': true, 'packRuntime': _auditCopy(_packRuntime)},
    'initialized': initialized,
    'valid': valid,
    'changed': changed,
    'changes': changes,
    'receipts': receipts,
    'effects': effects,
    'issues': issues,
  };
}
