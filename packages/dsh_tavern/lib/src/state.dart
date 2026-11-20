import 'dart:convert';

/// A saved leaf's state panel. Reading never initializes or runs card rules.
/// Schema and values are separate: [initialValues] is only a read-only preview
/// when no saved DSH value exists. JSON getters return detached copies.
class TavernStateSnapshot {
  TavernStateSnapshot({
    required this.chatId,
    required this.nodeId,
    required this.legacy,
    required this.initialized,
    required this.valueExists,
    required this.automaticEnabled,
    Object? schema,
    Object? values,
    this.initialValuesAvailable = false,
    Object? initialValues,
    List<String> hiddenPaths = const [],
    List<String> pinPaths = const [],
    List<Map<String, Object?>> changes = const [],
    List<Map<String, Object?>> effects = const [],
    List<Map<String, Object?>> issues = const [],
  }) : _schema = _clone(schema),
       _values = _clone(values),
       _initialValues = _clone(initialValues),
       hiddenPaths = List.unmodifiable(hiddenPaths),
       pinPaths = List.unmodifiable(pinPaths),
       _changes = _rows(changes),
       _effects = _rows(effects),
       _issues = _rows(issues);

  final String chatId;
  final String? nodeId;

  /// True only when the card has no state schema. Values then describe the
  /// saved ST local variables; global variables are never part of this view.
  final bool legacy;
  final bool initialized;
  final bool valueExists;
  final bool automaticEnabled;
  final bool initialValuesAvailable;
  final Object? _schema;
  final Object? _values;
  final Object? _initialValues;
  final List<String> hiddenPaths;
  final List<String> pinPaths;
  final List<Map<String, Object?>> _changes;
  final List<Map<String, Object?>> _effects;
  final List<Map<String, Object?>> _issues;

  Object? get schema => _clone(_schema);
  Object? get values => _clone(_values);
  Object? get initialValues => _clone(_initialValues);

  /// Own invocation changes, never inherited from the parent message. Each
  /// entry has a JSON Pointer path, old/new existence flags and values, and
  /// the final actor. Detailed operation receipts are in [TavernAgentRun].
  List<Map<String, Object?>> get changes => _rows(_changes);
  List<Map<String, Object?>> get effects => _rows(_effects);
  List<Map<String, Object?>> get issues => _rows(_issues);
}

/// A manual edit can be accepted without changing a value. Rejected edits do
/// not erase the leaf's previous successful changes/effects panel.
class TavernStateEditResult {
  TavernStateEditResult({
    required this.applied,
    required this.changed,
    required this.snapshot,
    List<Map<String, Object?>> receipts = const [],
    List<Map<String, Object?>> issues = const [],
  }) : _receipts = _rows(receipts),
       _issues = _rows(issues);

  final bool applied;
  final bool changed;
  final TavernStateSnapshot snapshot;
  final List<Map<String, Object?>> _receipts;
  final List<Map<String, Object?>> _issues;
  List<Map<String, Object?>> get receipts => _rows(_receipts);
  List<Map<String, Object?>> get issues => _rows(_issues);
}

/// Persistent execution audit. A permanently deleted node leaves [nodeId]
/// null; such rows are not silently reassigned to the current leaf.
class TavernAgentRun {
  TavernAgentRun({
    required this.id,
    required this.chatId,
    required this.nodeId,
    required this.kind,
    required this.at,
    Map<String, Object?>? usage,
    required Map<String, Object?> result,
  }) : _usage = usage == null ? null : _map(usage),
       _result = _map(result);

  final String id;
  final String chatId;
  final String? nodeId;
  final String kind;
  final DateTime at;
  final Map<String, Object?>? _usage;
  final Map<String, Object?> _result;
  Map<String, Object?>? get usage => _usage == null ? null : _map(_usage);
  Map<String, Object?> get result => _map(_result);
}

Object? _clone(Object? value) => jsonDecode(jsonEncode(value));
Map<String, Object?> _map(Map<String, Object?> value) => _clone(value) as Map<String, Object?>;
List<Map<String, Object?>> _rows(List<Map<String, Object?>> value) => [for (final row in value) _map(row)];
