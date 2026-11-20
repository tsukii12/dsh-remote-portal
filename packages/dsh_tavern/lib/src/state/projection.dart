part of 'state_engine.dart';

Object? _publicValue(_Schema node, Object? value) {
  if (node.hidden || !node.accepts(value) || (node.blocked && node.types.isEmpty && !node.derived)) {
    return _none;
  }
  if (value is _Json) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final child = node.properties[entry.key];
      if (child == null) continue;
      final projected = _publicValue(child, entry.value);
      if (!identical(projected, _none)) result[entry.key] = projected;
    }
    return result;
  }
  if (value is List<Object?>) {
    if (node.items == null) return [for (final _ in value) null];
    return [
      for (final item in value)
        switch (_publicValue(node.items!, item)) {
          _Missing() => null,
          final projected => projected,
        },
    ];
  }
  return _copy(value);
}

StateProjection _project(StateDefinition definition, Object? value, bool exists) {
  final issues = definition.issues;
  final raw = definition._raw is _Json ? definition._raw : <String, Object?>{};
  final root = definition._root;
  final hidden = <String>{}, pins = <String>{};
  final descriptions = <String>[];
  if (root != null) {
    for (final instance in _instances(root, value, includeBlocked: true)) {
      if (instance.node.hidden) hidden.add(instance.path);
      if (instance.node.pinned) pins.add(instance.path);
      final description = instance.node.raw['description'];
      if (!instance.node.hidden && description is String && description.isNotEmpty) {
        descriptions.add('${instance.path.isEmpty ? "/" : instance.path}: $description');
      }
    }
  }
  if (raw.containsKey('pin')) {
    final rawPins = raw['pin'];
    if (rawPins is! List<Object?>) {
      issues.add(_issue('state_pin', '/pin', 'pin must be an array of JSON Pointers.'));
    } else {
      for (var i = 0; i < rawPins.length; i++) {
        try {
          final tokens = _tokens(rawPins[i]);
          if (root == null || _schemaAt(root, tokens, value) == null) {
            issues.add(_issue('state_pin', '/pin/$i', 'Pin does not identify a defined schema path.'));
          } else {
            pins.add(_pointer(tokens));
          }
        } on _StateError catch (e) {
          issues.add(e.issue);
        }
      }
    }
  }
  var depth = 1;
  if (raw.containsKey('depth')) {
    final candidate = raw['depth'];
    if (candidate is int && candidate >= 0 && candidate <= 10000) {
      depth = candidate;
    } else {
      issues.add(_issue('summary_depth', '/depth', 'Depth must be an integer in 0..10000; default 1 is used.'));
    }
  }
  var role = 'system';
  if (raw.containsKey('role')) {
    final candidate = raw['role'];
    if (candidate is String && const {'system', 'user', 'assistant'}.contains(candidate)) {
      role = candidate;
    } else {
      issues.add(_issue('summary_role', '/role', 'Role must be system, user or assistant; default system is used.'));
    }
  }
  final projected = exists && root != null && _finiteJson(value) ? _publicValue(root, value) : _none;
  final publicExists = !identical(projected, _none);
  final publicValue = publicExists ? projected : null;
  String format(Object? item) => item is String ? item : jsonEncode(item);
  final template = raw['summary'];
  String summary;
  if (template is String) {
    summary = template.replaceAllMapped(RegExp(r'\{\{state(?::([^}]*))?\}\}'), (match) {
      final pointer = match.group(1);
      if (pointer == null) return publicExists ? jsonEncode(publicValue) : '';
      try {
        final tokens = _tokens(pointer);
        final source = _lookup(value, tokens, exists: exists);
        final target = _lookup(publicValue, tokens, exists: publicExists);
        final node = root == null ? null : _schemaAt(root, tokens, value);
        if (!source.exists || !target.exists || node == null || node.hidden || !node.accepts(source.value)) {
          issues.add(_issue('summary_pointer', pointer, 'Summary pointer is missing, unknown or hidden.'));
          return '';
        }
        return format(target.value);
      } on _StateError catch (e) {
        issues.add(e.issue);
        return '';
      }
    });
  } else {
    if (raw.containsKey('summary')) {
      issues.add(_issue('summary_template', '/summary', 'summary must be a string; the public default is used.'));
    }
    summary = publicExists ? jsonEncode(publicValue) : '';
    if (summary.isNotEmpty && descriptions.isNotEmpty) {
      summary = '$summary\n${descriptions.join('\n')}';
    }
  }
  return StateProjection._(
    valueExists: publicExists,
    value: publicValue,
    summary: summary,
    depth: depth,
    role: role,
    hiddenPaths: hidden.toList(),
    pinPaths: pins.toList(),
    issues: issues,
  );
}

bool _modelWhole(_Schema node, Object? value) {
  if (node.blocked ||
      node.hidden ||
      node.derived ||
      !node.allowed.contains(StateActor.model) ||
      node.types.where((x) => x != 'null').isEmpty) {
    return false;
  }
  if (node.types.contains('object')) {
    if (node.required.any((key) => !node.properties.containsKey(key))) return false;
    if (value is _Json && value.keys.any((key) => !node.properties.containsKey(key))) return false;
    for (final entry in node.properties.entries) {
      if (!_modelWhole(entry.value, value is _Json ? value[entry.key] : null)) return false;
    }
  }
  if (node.types.contains('array')) {
    if (node.items == null || !_modelWhole(node.items!, null)) return false;
    if (value is List<Object?> && value.any((item) => !_modelWhole(node.items!, item))) {
      return false;
    }
  }
  return true;
}

bool _modelOperationAllowed(_Schema node, String op, Object? value) {
  if (!_modelWhole(node, value)) return false;
  if (op == 'add') return node.types.contains('number') || node.types.contains('integer');
  if (op == 'push') return node.types.contains('array') && node.items != null;
  return true;
}

bool _modelValue(_Schema node, Object? value) {
  if (value == null || !node.accepts(value)) return false;
  if (value is _Json) {
    if (value.length != node.properties.length || value.keys.any((key) => !node.properties.containsKey(key))) {
      return false;
    }
    return node.properties.entries.every(
      (entry) => value.containsKey(entry.key) && _modelValue(entry.value, value[entry.key]),
    );
  }
  if (value is List<Object?>) {
    return node.items != null && value.every((x) => _modelValue(node.items!, x));
  }
  return _finiteJson(value);
}

_Json? _wireValue(_Schema node, {bool guard = false}) {
  if (node.blocked || node.hidden) return null;
  final branches = <_Json>[];
  for (final type in node.types.where((x) => x != 'null')) {
    final branch = <String, Object?>{'type': type};
    if (type == 'object') {
      if (node.required.any((key) => !node.properties.containsKey(key))) continue;
      final properties = <String, Object?>{};
      var valid = true;
      for (final entry in node.properties.entries) {
        final child = _wireValue(entry.value, guard: guard);
        if (child == null) {
          valid = false;
          break;
        }
        properties[entry.key] = child;
      }
      if (!valid) continue;
      branch.addAll({'properties': properties, 'required': properties.keys.toList(), 'additionalProperties': false});
    } else if (type == 'array') {
      if (node.items == null) continue;
      final item = _wireValue(node.items!, guard: guard);
      if (item == null) continue;
      branch['items'] = item;
    }
    // Ranges/lengths/step are enforced by the local validator. Guard values
    // deliberately receive no new-value enum or numeric/length constraints.
    if (!guard && node.enumeration != null && type != 'object' && type != 'array') {
      final values = node.enumeration!
          .where(
            (x) =>
                x != null &&
                switch (type) {
                  'string' => x is String,
                  'boolean' => x is bool,
                  'integer' => _isInteger(x),
                  'number' => x is num,
                  _ => false,
                },
          )
          .toList();
      if (values.isEmpty) continue;
      branch['enum'] = _copy(values);
    }
    branches.add(branch);
  }
  if (branches.isEmpty) return null;
  final result = branches.length == 1 ? branches.single : <String, Object?>{'anyOf': branches};
  final description = _publicDescription(node);
  if (description.isNotEmpty) result['description'] = description;
  return result;
}

String _publicDescription(_Schema node) {
  if (node.hidden) return '';
  return [node.raw['title'], node.raw['description']].whereType<String>().where((x) => x.isNotEmpty).toSet().join('\n');
}

class _Capability {
  _Capability(this.node, this.op, this.segments, this.pattern, this.literal);
  final _Schema node;
  final String op;
  final List<String?> segments;
  final RegExp pattern;
  final String? literal;
  bool matches(String op, String path) => this.op == op && pattern.hasMatch(path);
}

class _ModelPlan {
  _ModelPlan(this.capabilities, this.tool, this.issues);
  final List<_Capability> capabilities;
  final _Json? tool;
  final List<_Json> issues;
}

_ModelPlan _modelPlan(StateDefinition definition, Object? value, bool exists) {
  final issues = <_Json>[], branches = <_Json>[], capabilities = <_Capability>[];
  if (!definition.executable) return _ModelPlan([], null, definition.issues);
  final root = definition._root!;
  final currentInstances = exists ? _instances(root, value) : <_Instance>[];
  void visit(_Schema node, List<String?> segments) {
    if (node.blocked || node.hidden || node.derived || !node.allowed.contains(StateActor.model)) {
      return;
    }
    if (node.types.contains('null')) {
      issues.add(
        _issue(
          'strict_nullable',
          node.path,
          'Strict tools expose only supported non-null branches; null remains available to explicit local edits.',
          kind: 'unsupported',
        ),
      );
    }
    final pathPattern = segments.isEmpty
        ? ''
        : segments.map((x) => '/${x == null ? r"(?:0|[1-9][0-9]*)" : RegExp.escape(_escape(x))}').join();
    final pattern = RegExp('^$pathPattern\$');
    final instances = currentInstances.where((item) => pattern.hasMatch(item.path));
    final whole = _modelWhole(node, null) && instances.every((item) => _modelWhole(node, item.value));
    final valueWire = whole ? _wireValue(node) : null;
    final guardWire = whole ? _wireValue(node, guard: true) : null;
    final literal = segments.contains(null) ? null : _pointer(segments.cast<String>());
    if (valueWire != null) {
      for (final op in ['set', 'add', 'push', 'remove', 'move']) {
        if (op == 'remove' && segments.isEmpty) continue;
        if (!_modelOperationAllowed(node, op, null)) continue;
        _Json? wire;
        if (op == 'set') wire = valueWire;
        if (op == 'add') wire = {'type': 'number'};
        if (op == 'push') wire = _wireValue(node.items!);
        if (op == 'move') wire = {'type': 'string', 'pattern': r'^(?:/(?:[^~/]|~[01])*)*$'};
        if (op == 'push' && wire == null) continue;
        var operationPattern = pathPattern;
        if (op == 'move' && segments.isNotEmpty && segments.last == null) {
          operationPattern =
              '${segments.take(segments.length - 1).map((x) => '/${x == null ? r"(?:0|[1-9][0-9]*)" : RegExp.escape(_escape(x))}').join()}/(?:0|[1-9][0-9]*|-)';
        }
        final pathWire = literal == null
            ? <String, Object?>{'type': 'string', 'pattern': '^$operationPattern\$'}
            : <String, Object?>{
                'type': 'string',
                'enum': [literal],
              };
        final description = _publicDescription(node);
        if (description.isNotEmpty) pathWire['description'] = description;
        for (final guarded in [false, true]) {
          if (guarded && guardWire == null) continue;
          final properties = <String, Object?>{
            'op': {
              'type': 'string',
              'enum': [op],
            },
            'path': pathWire,
            if (op != 'remove') 'value': wire,
            'why': {'type': 'string'},
            if (guarded) 'from': guardWire,
          };
          branches.add({
            'type': 'object',
            'properties': properties,
            'required': properties.keys.toList(),
            'additionalProperties': false,
          });
          if (branches.length > 2048) {
            throw const _StateError(
              'strict_limit',
              '',
              'Strict tool exceeds 2048 operation branches; no partial tool is exposed.',
            );
          }
        }
        capabilities.add(_Capability(node, op, segments, RegExp('^$operationPattern\$'), literal));
      }
    }
    if (node.types.contains('object')) {
      for (final entry in node.properties.entries) {
        visit(entry.value, [...segments, entry.key]);
      }
    }
    if (node.types.contains('array') && node.items != null) visit(node.items!, [...segments, null]);
  }

  try {
    visit(root, []);
    if (branches.isEmpty) return _ModelPlan([], null, issues);
    final tool = <String, Object?>{
      'type': 'function',
      'function': {
        'name': 'update_state',
        'description': 'Apply explicit state operations. Each operation is validated atomically.',
        'strict': true,
        'parameters': {
          'type': 'object',
          'properties': {
            'ops': {
              'type': 'array',
              'items': {'anyOf': branches},
            },
          },
          'required': ['ops'],
          'additionalProperties': false,
        },
      },
    };
    if (utf8.encode(jsonEncode(tool)).length > 256 * 1024) {
      throw const _StateError('strict_limit', '', 'Strict tool exceeds 256 KiB UTF-8; no partial tool is exposed.');
    }
    return _ModelPlan(capabilities, tool, issues);
  } on _StateError catch (e) {
    issues.add(e.issue);
    return _ModelPlan([], null, issues);
  }
}

StateStrictTool _strictTool(StateDefinition definition, Object? value, bool exists) {
  final result = _modelPlan(definition, value, exists);
  return StateStrictTool._(result.tool, [...definition.issues, ...result.issues]);
}
