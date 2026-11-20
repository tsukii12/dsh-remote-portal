part of 'state_engine.dart';

const _types = {'object', 'array', 'string', 'number', 'integer', 'boolean', 'null'};
const _schemaKeys = {
  'type',
  'properties',
  'items',
  'required',
  'additionalProperties',
  'minimum',
  'maximum',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'enum',
  'default',
  'description',
  'title',
  'minItems',
  'maxItems',
  'minLength',
  'maxLength',
  'x-dsh-step',
  'x-dsh-by',
  'x-dsh-hidden',
  'x-dsh-show',
  'x-dsh-pin',
  'x-dsh-derive',
};
const _unsupportedConstraints = {
  '\$ref',
  '\$dynamicRef',
  '\$recursiveRef',
  'allOf',
  'anyOf',
  'oneOf',
  'not',
  'if',
  'then',
  'else',
  'pattern',
  'patternProperties',
  'additionalItems',
  'prefixItems',
  'contains',
  'minContains',
  'maxContains',
  'uniqueItems',
  'multipleOf',
  'minProperties',
  'maxProperties',
  'propertyNames',
  'dependentRequired',
  'dependentSchemas',
  'dependencies',
  'unevaluatedProperties',
  'unevaluatedItems',
  'format',
  'contentSchema',
};

class _Schema {
  _Schema(this.raw, this.path, this.allowed, this.hidden, this.blocked);
  final _Json raw;
  final String path;
  final Set<StateActor> allowed;
  final bool hidden;
  bool blocked;
  Set<String> types = {};
  final Map<String, _Schema> properties = {};
  _Schema? items;
  Set<String> required = {};
  bool additional = true;
  num? minimum, maximum, exclusiveMinimum, exclusiveMaximum, step;
  num? minItems, maxItems, minLength, maxLength;
  List<Object?>? enumeration;
  _Logic? derive;
  bool get derived => raw.containsKey('x-dsh-derive');
  bool get pinned => raw['x-dsh-pin'] == true;
  bool accepts(Object? value) =>
      types.isEmpty ||
      types.any(
        (type) => switch (type) {
          'object' => value is _Json,
          'array' => value is List<Object?>,
          'string' => value is String,
          'number' => value is num && value.isFinite,
          'integer' => _isInteger(value),
          'boolean' => value is bool,
          'null' => value == null,
          _ => false,
        },
      );
}

class _SchemaCompiler {
  final List<_Json> issues = [];
  var nodes = 0;
  _Schema compile(
    Object? raw,
    String path, {
    int depth = 0,
    Set<StateActor> allowed = const {StateActor.model, StateActor.rules, StateActor.user},
    bool hidden = false,
    bool blocked = false,
  }) {
    if (++nodes > 2048 || depth > 64) {
      throw _StateError('schema_limit', path, 'Schema exceeds 2048 nodes or depth 64.');
    }
    if (raw is! _Json) {
      issues.add(_issue('schema_shape', path, 'A schema node must be an object.'));
      return _Schema({}, path, {}, hidden, true);
    }
    final by = raw['x-dsh-by'];
    var effective = allowed.toSet();
    if (raw.containsKey('x-dsh-by')) {
      if (by is! List<Object?> || by.any((x) => x is! String || !const {'model', 'rules', 'user'}.contains(x))) {
        issues.add(_issue('schema_permission', '$path/x-dsh-by', 'Permissions must be an array of actor names.'));
        blocked = true;
        effective = {};
      } else {
        effective = effective.where((actor) => by.contains(actor.name)).toSet();
      }
    }
    if (raw.containsKey('x-dsh-hidden') && raw['x-dsh-hidden'] is! bool) {
      blocked = true;
      hidden = true;
      issues.add(_issue('schema_hidden', '$path/x-dsh-hidden', 'Hidden must be boolean.'));
    }
    hidden = hidden || raw['x-dsh-hidden'] == true;
    final node = _Schema(raw, path, effective, hidden, blocked);
    void invalid(String key, String message) {
      node.blocked = true;
      issues.add(_issue('schema_definition', '$path/${_escape(key)}', message));
    }

    for (final key in raw.keys) {
      if (_unsupportedConstraints.contains(key)) {
        node.blocked = true;
        issues.add(
          _issue(
            'schema_unsupported',
            '$path/${_escape(key)}',
            'Constraint is preserved but not executed; this subtree is not writable.',
            kind: 'unsupported',
          ),
        );
      } else if (!_schemaKeys.contains(key)) {
        issues.add(
          _issue(
            'schema_unknown',
            '$path/${_escape(key)}',
            'Unknown annotation is preserved without execution.',
            kind: 'unknown',
          ),
        );
      }
    }
    if (raw.containsKey('type')) {
      final type = raw['type'];
      final list = type is String ? <Object?>[type] : type;
      if (list is! List<Object?> || list.isEmpty || list.any((x) => x is! String || !_types.contains(x))) {
        invalid('type', 'type must name one or more supported JSON types.');
      } else {
        node.types = list.cast<String>().toSet();
        if (node.types.length != list.length) invalid('type', 'Duplicate types are not valid.');
      }
    } else if (raw.containsKey('properties') && raw.containsKey('items')) {
      invalid('type', 'properties and items cannot infer two different root types.');
    } else if (raw.containsKey('properties')) {
      node.types = {'object'};
    } else if (raw.containsKey('items')) {
      node.types = {'array'};
    }
    if (raw.containsKey('required')) {
      final required = raw['required'];
      if (required is! List<Object?> ||
          required.any((x) => x is! String) ||
          required.toSet().length != required.length) {
        invalid('required', 'required must be an array of distinct strings.');
      } else {
        node.required = required.cast<String>().toSet();
      }
    }
    if (raw.containsKey('additionalProperties')) {
      final additional = raw['additionalProperties'];
      if (additional is! bool) {
        invalid('additionalProperties', 'Only boolean additionalProperties is supported.');
      } else {
        node.additional = additional;
      }
    }
    num? bound(String key) {
      if (!raw.containsKey(key)) return null;
      final value = raw[key];
      if (value is! num || !value.isFinite) {
        invalid(key, 'A finite number is required.');
        return null;
      }
      return value;
    }

    node.minimum = bound('minimum');
    node.maximum = bound('maximum');
    node.exclusiveMinimum = bound('exclusiveMinimum');
    node.exclusiveMaximum = bound('exclusiveMaximum');
    node.step = bound('x-dsh-step');
    if (node.step != null && node.step! < 0) invalid('x-dsh-step', 'Step must be nonnegative.');
    num? length(String key) {
      if (!raw.containsKey(key)) return null;
      final value = raw[key];
      if (value is! num || !value.isFinite || value < 0 || !_isInteger(value)) {
        invalid(key, 'A nonnegative integer is required.');
        return null;
      }
      return value;
    }

    node.minItems = length('minItems');
    node.maxItems = length('maxItems');
    node.minLength = length('minLength');
    node.maxLength = length('maxLength');
    if ((node.minItems ?? 0) > (node.maxItems ?? double.infinity)) {
      invalid('maxItems', 'Array length interval is empty.');
    }
    if ((node.minLength ?? 0) > (node.maxLength ?? double.infinity)) {
      invalid('maxLength', 'String length interval is empty.');
    }
    final lower = _maxStateNumber(
      node.minimum ?? double.negativeInfinity,
      node.exclusiveMinimum ?? double.negativeInfinity,
    );
    final upper = _minStateNumber(node.maximum ?? double.infinity, node.exclusiveMaximum ?? double.infinity);
    final order = _compareStateNumbers(lower, upper);
    if (order > 0 || (order == 0 && (_equal(node.exclusiveMinimum, lower) || _equal(node.exclusiveMaximum, upper)))) {
      invalid('minimum', 'Numeric interval is empty.');
    }
    if (node.types.contains('integer') && !node.types.contains('number')) {
      if (_compareStateNumbers(_integerLower(node), _integerUpper(node)) > 0) {
        invalid('minimum', 'Integer interval is empty.');
      }
    }
    if (raw.containsKey('enum')) {
      final values = raw['enum'];
      if (values is! List<Object?> || values.isEmpty || !_finiteJson(values)) {
        invalid('enum', 'enum must be a nonempty finite JSON array.');
      } else {
        node.enumeration = values;
        for (var i = 0; i < values.length; i++) {
          if (values.take(i).any((x) => _equal(x, values[i]))) {
            invalid('enum', 'enum entries must be distinct.');
            break;
          }
        }
      }
    }
    for (final key in ['description', 'title']) {
      if (raw.containsKey(key) && raw[key] is! String) {
        issues.add(
          _issue('schema_annotation', '$path/$key', 'Text annotation is preserved but not used.', kind: 'unknown'),
        );
      }
    }
    if (raw.containsKey('x-dsh-pin') && raw['x-dsh-pin'] is! bool) {
      issues.add(
        _issue('schema_pin', '$path/x-dsh-pin', 'Pin must be boolean; raw annotation is preserved.', kind: 'unknown'),
      );
    }
    if (raw.containsKey('x-dsh-show') &&
        !const {'bar', 'number', 'tags', 'inventory', 'list', 'line'}.contains(raw['x-dsh-show'])) {
      issues.add(
        _issue('schema_show', '$path/x-dsh-show', 'Unknown display hint is preserved for the UI.', kind: 'unknown'),
      );
    }
    if (node.derived) {
      try {
        node.derive = _Logic.compile(raw['x-dsh-derive'], '$path/x-dsh-derive');
      } on _StateError catch (e) {
        node.blocked = true;
        issues.add(e.issue);
      }
    }
    if (raw.containsKey('properties')) {
      final properties = raw['properties'];
      if (properties is! _Json) {
        invalid('properties', 'properties must be an object.');
      } else {
        for (final entry in properties.entries) {
          node.properties[entry.key] = compile(
            entry.value,
            '$path/properties/${_escape(entry.key)}',
            depth: depth + 1,
            allowed: effective,
            hidden: hidden,
            blocked: node.blocked,
          );
        }
      }
    }
    if (raw.containsKey('items')) {
      node.items = compile(
        raw['items'],
        '$path/items',
        depth: depth + 1,
        allowed: effective,
        hidden: hidden,
        blocked: node.blocked,
      );
    }
    return node;
  }
}

num _integerLower(_Schema node) {
  num value = node.minimum == null ? double.negativeInfinity : _integerEndpoint(node.minimum!, lower: true);
  if (node.exclusiveMinimum != null) {
    value = _maxStateNumber(value, _integerEndpoint(node.exclusiveMinimum!, lower: true, exclusive: true));
  }
  return value;
}

num _integerUpper(_Schema node) {
  num value = node.maximum == null ? double.infinity : _integerEndpoint(node.maximum!, lower: false);
  if (node.exclusiveMaximum != null) {
    value = _minStateNumber(value, _integerEndpoint(node.exclusiveMaximum!, lower: false, exclusive: true));
  }
  return value;
}

num _integerEndpoint(num value, {required bool lower, bool exclusive = false}) {
  final roundUp = lower != exclusive;
  var integer = value is int ? BigInt.from(value) : BigInt.from(roundUp ? value.ceilToDouble() : value.floorToDouble());
  if (exclusive) integer += lower ? BigInt.one : -BigInt.one;
  return _representableInteger(integer, lower: lower);
}

num _representableInteger(BigInt value, {required bool lower}) {
  if (value.isValidInt) return value.toInt();
  final number = value.toDouble();
  if (!number.isFinite) return number;
  final rounded = BigInt.from(number);
  if ((lower && rounded < value) || (!lower && rounded > value)) {
    return _adjacentDouble(number, up: lower);
  }
  return number;
}

// Only exact integer endpoints outside native int range use adjacent values.
// Floating-point exclusive constraints never receive an invented epsilon.
double _adjacentDouble(double value, {required bool up}) {
  if (value == 0) return up ? double.minPositive : -double.minPositive;
  final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
  var high = bytes.getUint32(0, Endian.big), low = bytes.getUint32(4, Endian.big);
  if ((value > 0) == up) {
    if (low == 0xffffffff) {
      low = 0;
      high++;
    } else {
      low++;
    }
  } else {
    if (low == 0) {
      low = 0xffffffff;
      high--;
    } else {
      low--;
    }
  }
  bytes.setUint32(0, high, Endian.big);
  bytes.setUint32(4, low, Endian.big);
  return bytes.getFloat64(0, Endian.big);
}

({num lower, num upper}) _stepInterval(num start, num step) {
  if (start is int && step is int) {
    return (
      lower: _representableInteger(BigInt.from(start) - BigInt.from(step), lower: true),
      upper: _representableInteger(BigInt.from(start) + BigInt.from(step), lower: false),
    );
  }
  return (lower: start.toDouble() - step.toDouble(), upper: start.toDouble() + step.toDouble());
}

List<_Json> _validate(_Schema node, Object? value, String path, {bool exists = true}) {
  if (!exists) return [_issue('value_missing', path, 'The state value is missing.')];
  if (!_finiteJson(value)) return [_issue('value_json', path, 'Values must be finite JSON.')];
  if (node.blocked) return [];
  final result = <_Json>[];
  void invalid(String code, String message) => result.add(_issue(code, path, message));
  if (!node.accepts(value)) {
    invalid('value_type', 'Value does not match the schema type.');
    return result;
  }
  if (node.enumeration != null && !node.enumeration!.any((x) => _equal(x, value))) {
    invalid('value_enum', 'Value is not in enum.');
  }
  if (value is num) {
    if (node.minimum != null && _compareStateNumbers(value, node.minimum!) < 0) {
      invalid('value_minimum', 'Value is below minimum.');
    }
    if (node.maximum != null && _compareStateNumbers(value, node.maximum!) > 0) {
      invalid('value_maximum', 'Value is above maximum.');
    }
    if (node.exclusiveMinimum != null && _compareStateNumbers(value, node.exclusiveMinimum!) <= 0) {
      invalid('value_exclusive_minimum', 'Value must exceed exclusiveMinimum.');
    }
    if (node.exclusiveMaximum != null && _compareStateNumbers(value, node.exclusiveMaximum!) >= 0) {
      invalid('value_exclusive_maximum', 'Value must be below exclusiveMaximum.');
    }
  }
  if (value is String) {
    final length = value.runes.length;
    if (node.minLength != null && length < node.minLength!) {
      invalid('value_min_length', 'String has too few Unicode scalar values.');
    }
    if (node.maxLength != null && length > node.maxLength!) {
      invalid('value_max_length', 'String has too many Unicode scalar values.');
    }
  }
  if (value is _Json) {
    for (final key in node.required) {
      if (!value.containsKey(key)) {
        result.add(_issue('value_required', _childPath(path, key), 'Required property is missing.'));
      }
    }
    for (final entry in value.entries) {
      final child = node.properties[entry.key];
      if (child != null) {
        result.addAll(_validate(child, entry.value, _childPath(path, entry.key)));
      } else if (!node.additional) {
        result.add(_issue('value_additional', _childPath(path, entry.key), 'Additional property is not permitted.'));
      }
    }
  }
  if (value is List<Object?>) {
    if (node.minItems != null && value.length < node.minItems!) {
      invalid('value_min_items', 'Array has too few items.');
    }
    if (node.maxItems != null && value.length > node.maxItems!) {
      invalid('value_max_items', 'Array has too many items.');
    }
    if (node.items != null) {
      for (var i = 0; i < value.length; i++) {
        result.addAll(_validate(node.items!, value[i], _childPath(path, '$i')));
      }
    }
  }
  return result;
}

Object? _defaults(_Schema node, Object? value) {
  if (node.blocked) return value;
  if (value is _Json) {
    for (final entry in node.properties.entries) {
      final child = entry.value;
      if (!value.containsKey(entry.key) && !child.blocked && child.raw.containsKey('default')) {
        value[entry.key] = _copy(child.raw['default']);
      }
      if (value.containsKey(entry.key)) value[entry.key] = _defaults(child, value[entry.key]);
    }
  } else if (value is List<Object?> && node.items != null) {
    for (var i = 0; i < value.length; i++) {
      value[i] = _defaults(node.items!, value[i]);
    }
  }
  return value;
}

class _Instance {
  _Instance(this.node, this.tokens, this.exists, this.value);
  final _Schema node;
  final List<String> tokens;
  final bool exists;
  final Object? value;
  String get path => _pointer(tokens);
}

List<_Instance> _instances(_Schema root, Object? value, {bool includeBlocked = false}) {
  final result = <_Instance>[];
  void visit(_Schema node, Object? current, List<String> path, bool exists) {
    result.add(_Instance(node, path, exists, current));
    if (node.blocked && !includeBlocked) return;
    if (current is _Json && exists) {
      for (final entry in node.properties.entries) {
        visit(entry.value, current[entry.key], [...path, entry.key], current.containsKey(entry.key));
      }
    } else if (current is List<Object?> && exists && node.items != null) {
      for (var i = 0; i < current.length; i++) {
        visit(node.items!, current[i], [...path, '$i'], true);
      }
    }
  }

  visit(root, value, [], true);
  return result;
}

_Schema? _schemaAt(_Schema root, List<String> path, Object? data) {
  var node = root;
  Object? current = data;
  for (final token in path) {
    _Schema? next;
    if (current is List<Object?> ||
        (current == null && node.types.contains('array') && !node.types.contains('object'))) {
      if (_index(token) == null && token != '-') return null;
      next = node.items;
      final index = _index(token);
      current = current is List<Object?> && index != null && index < current.length ? current[index] : null;
    } else {
      next = node.properties[token];
      current = current is _Json ? current[token] : null;
    }
    if (next == null) return null;
    node = next;
  }
  return node;
}

class StateDefinition {
  StateDefinition.parse(Object? rawState, {Object? version = 1}) : _raw = _copy(rawState), _version = _copy(version) {
    if (_raw is! _Json) {
      if (_raw != null) {
        _issues.add(_issue('state_shape', '', 'State definition must be an object.'));
      }
      return;
    }
    if (_version != 1) {
      _issues.add(_issue('state_version', '', 'This state definition version is preserved but not executable.'));
      return;
    }
    final raw = _raw;
    if (!raw.containsKey('schema')) return;
    final compiler = _SchemaCompiler();
    try {
      _root = compiler.compile(raw['schema'], '/schema');
    } on _StateError catch (e) {
      _issues.add(e.issue);
    }
    _issues.addAll(compiler.issues);
    if (_root == null || _root!.blocked) return;
    for (final key in raw.keys) {
      if (!const {'schema', 'init', 'rules', 'pin', 'summary', 'depth', 'role'}.contains(key)) {
        _issues.add(_issue('state_unknown', '/${_escape(key)}', 'Unknown state field is preserved.', kind: 'unknown'));
      }
    }
    _compileRules(this);
  }

  factory StateDefinition.compose(
    Object? state, {
    Object? version = 1,
    required String effectiveConfigId,
    required Iterable<StateRuleSource> sources,
    required bool compositionEligible,
  }) => _composeStateDefinition(
    state,
    version: version,
    effectiveConfigId: effectiveConfigId,
    sources: sources,
    compositionEligible: compositionEligible,
  );

  StateDefinition._uncompiled(Map<String, Object?> rawState) : _raw = _copy(rawState), _version = 1;

  final Object? _raw;
  final Object? _version;
  _Json? _compositionIdentity;
  bool _compositionEligible = true;
  final List<_Json> _issues = [];
  final List<_Rule> _rules = [];
  _Schema? _root;
  bool get hasSchema => _raw is _Json && _raw.containsKey('schema');
  Object? get schema => _raw is _Json ? _copy(_raw['schema']) : null;
  bool get executable => _compositionEligible && hasSchema && _version == 1 && _root != null && !_root!.blocked;
  String get fingerprint => _fingerprint({'version': _version, 'state': _raw, 'composition': ?_compositionIdentity});
  List<Map<String, Object?>> get issues => _maps(_issues);

  StateInitialPreview initialPreview() {
    final problems = issues;
    if (!executable) {
      return StateInitialPreview._(valueExists: false, value: null, valid: false, issues: problems);
    }
    final raw = _raw as _Json;
    Object? initial;
    if (raw.containsKey('init')) {
      initial = _copy(raw['init']);
    } else if (_root!.raw.containsKey('default')) {
      initial = _copy(_root!.raw['default']);
    } else if (_root!.types.contains('object')) {
      initial = <String, Object?>{};
    } else {
      problems.add(_issue('initial_missing', '', 'The root has no init or default value.'));
      return StateInitialPreview._(valueExists: false, value: null, valid: false, issues: problems);
    }
    try {
      if (!_finiteJson(initial)) {
        throw const _StateError('initial_json', '', 'Initial values must be finite JSON.');
      }
      initial = _defaults(_root!, initial);
      initial = _derive(this, initial, null, [], initial: true);
      final invalid = _validate(_root!, initial, '');
      if (invalid.isNotEmpty) {
        problems.addAll(invalid);
        return StateInitialPreview._(valueExists: false, value: null, valid: false, issues: problems);
      }
      return StateInitialPreview._(valueExists: true, value: initial, valid: true, issues: problems);
    } on _StateError catch (e) {
      problems.add(e.issue);
      return StateInitialPreview._(valueExists: false, value: null, valid: false, issues: problems);
    }
  }

  List<Map<String, Object?>> validate(Object? value, {bool valueExists = true}) {
    if (!executable) return issues;
    return _validate(_root!, _copy(value), '', exists: valueExists);
  }

  StateProjection project(Object? value, {bool valueExists = true}) => _project(this, _copy(value), valueExists);
  StateStrictTool strictTool({Object? value, bool valueExists = false}) => _strictTool(this, _copy(value), valueExists);
  StateSession startSession({
    required bool valueExists,
    Object? value,
    bool runtimeExists = false,
    Object? runtime,
    bool packRuntimeExists = false,
    Object? packRuntime,
  }) => StateSession._(
    this,
    valueExists: valueExists,
    value: value,
    runtimeExists: runtimeExists,
    runtime: runtime,
    packRuntimeExists: packRuntimeExists,
    packRuntime: packRuntime,
  );
}
