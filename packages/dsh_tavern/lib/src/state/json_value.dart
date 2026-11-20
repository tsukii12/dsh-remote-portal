part of 'state_engine.dart';

Object? _copy(Object? value) {
  if (value is Map<Object?, Object?>) {
    return <String, Object?>{for (final entry in value.entries) (entry.key as String): _copy(entry.value)};
  }
  if (value is List<Object?>) return <Object?>[for (final item in value) _copy(item)];
  return value;
}

_Json _mapCopy(_Json value) => _copy(value)! as _Json;
List<_Json> _maps(List<_Json> values) => [for (final value in values) _mapCopy(value)];

// Rejected non-JSON caller input must not make its audit impossible to encode.
// Legal JSON is byte-for-value unchanged; markers explicitly identify values
// that have no JSON representation rather than treating them as null or zero.
Object? _auditCopy(Object? value) {
  if (value is num && !value.isFinite) return {'nonJsonNumber': _jsString(value)};
  if (value is _Json) {
    return <String, Object?>{for (final entry in value.entries) entry.key: _auditCopy(entry.value)};
  }
  if (value is List<Object?>) return [for (final item in value) _auditCopy(item)];
  if (_finiteJson(value)) return value;
  return {'nonJsonType': value.runtimeType.toString()};
}

_Json _issue(String code, String path, String message, {String kind = 'invalid'}) => {
  'code': code,
  'path': path,
  'message': message,
  'kind': kind,
};

class _StateError implements Exception {
  const _StateError(this.code, this.path, this.message);
  final String code;
  final String path;
  final String message;
  _Json get issue => _issue(code, path, message);
  @override
  String toString() => '$code at $path: $message';
}

class _Missing {
  const _Missing();
}

const _none = _Missing();

bool _isInteger(Object? value) =>
    value is int || (value is double && value.isFinite && value == value.truncateToDouble());

bool _finiteJson(Object? value) {
  if (value == null || value is String || value is bool) return true;
  if (value is num) return value.isFinite;
  if (value is List<Object?>) return value.every(_finiteJson);
  if (value is Map<Object?, Object?>) {
    return value.entries.every((e) => e.key is String && _finiteJson(e.value));
  }
  return false;
}

// State ranges and JSON value equality retain native integer precision. The VM's
// mixed int/double operators can round a large int; compareTo handles that case.
// Bounds have already rejected NaN. Both signed zeroes have the same state value.
int _compareStateNumbers(num a, num b) {
  if (a == 0 && b == 0) {
    return 0;
  }
  return a.compareTo(b);
}

num _minStateNumber(num a, num b) {
  final order = _compareStateNumbers(a, b);
  return order < 0 ? a : (order > 0 ? b : math.min(a, b));
}

num _maxStateNumber(num a, num b) {
  final order = _compareStateNumbers(a, b);
  return order > 0 ? a : (order < 0 ? b : math.max(a, b));
}

// JsonLogic deliberately keeps its separate JS Number comparison semantics.
// Derivation also observes zero signs, recursively, while all other state
// comparisons retain native numeric precision and the default change audit.
bool _equal(Object? a, Object? b, {bool distinguishZero = false}) {
  if (a is num && b is num) {
    return !a.isNaN &&
        !b.isNaN &&
        _compareStateNumbers(a, b) == 0 &&
        (!distinguishZero || a != 0 || a.isNegative == b.isNegative);
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i], distinguishZero: distinguishZero)) {
        return false;
      }
    }
    return true;
  }
  if (a is _Json && b is _Json) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_equal(a[key], b[key], distinguishZero: distinguishZero)) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

Object? _canonical(Object? value) {
  if (value is _Json) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List<Object?>) return value.map(_canonical).toList();
  if (value is double && value.isFinite && value == value.truncateToDouble() && value.abs() <= 9007199254740991) {
    return value.toInt();
  }
  return value;
}

String _fingerprint(Object? value) => sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
String _escape(String token) => token.replaceAll('~', '~0').replaceAll('/', '~1');
String _pointer(List<String> tokens) => tokens.isEmpty ? '' : '/${tokens.map(_escape).join('/')}';
String _childPath(String parent, String token) => '$parent/${_escape(token)}';

List<String> _tokens(Object? pointer) {
  if (pointer is! String || (pointer.isNotEmpty && !pointer.startsWith('/'))) {
    throw const _StateError('pointer', '', 'JSON Pointer must be empty or start with /.');
  }
  if (pointer.isEmpty) return [];
  final result = <String>[];
  for (final token in pointer.substring(1).split('/')) {
    for (var i = 0; i < token.length; i++) {
      if (token[i] != '~') continue;
      if (i + 1 >= token.length || (token[i + 1] != '0' && token[i + 1] != '1')) {
        throw _StateError('pointer_escape', pointer, 'Only ~0 and ~1 are JSON Pointer escapes.');
      }
      i++;
    }
    result.add(token.replaceAll('~1', '/').replaceAll('~0', '~'));
  }
  return result;
}

final _indexPattern = RegExp(r'^(?:0|[1-9][0-9]*)$');
int? _index(String token) => _indexPattern.hasMatch(token) ? int.tryParse(token) : null;
bool _prefix(List<String> ancestor, List<String> descendant) {
  if (ancestor.length > descendant.length) return false;
  for (var i = 0; i < ancestor.length; i++) {
    if (ancestor[i] != descendant[i]) return false;
  }
  return true;
}

({bool exists, Object? value}) _lookup(Object? root, List<String> path, {bool exists = true}) {
  Object? value = root;
  if (!exists) return (exists: false, value: null);
  for (final token in path) {
    if (value is _Json && value.containsKey(token)) {
      value = value[token];
    } else if (value is List<Object?>) {
      final i = _index(token);
      if (i == null || i >= value.length) return (exists: false, value: null);
      value = value[i];
    } else {
      return (exists: false, value: null);
    }
  }
  return (exists: true, value: value);
}

Object? _put(Object? root, List<String> path, Object? value, {bool insert = false}) {
  if (path.isEmpty) return value;
  final parent = _lookup(root, path.sublist(0, path.length - 1));
  final key = path.last;
  if (parent.exists && parent.value is _Json) {
    (parent.value! as _Json)[key] = value;
  } else if (parent.exists && parent.value is List<Object?>) {
    final array = parent.value! as List<Object?>;
    final index = insert && key == '-' ? array.length : _index(key);
    if (index == null || index > array.length || (!insert && index == array.length)) {
      throw _StateError('array_index', _pointer(path), 'Array index is not available for this operation.');
    }
    if (insert) {
      array.insert(index, value);
    } else {
      array[index] = value;
    }
  } else {
    throw _StateError('missing_parent', _pointer(path), 'The immediate parent must already be a container.');
  }
  return root;
}

({Object? root, Object? removed}) _remove(Object? root, List<String> path) {
  if (path.isEmpty) {
    throw const _StateError('remove_root', '', 'The document root cannot be removed.');
  }
  final found = _lookup(root, path);
  if (!found.exists) {
    throw _StateError('missing_source', _pointer(path), 'The value does not exist.');
  }
  final parent = _lookup(root, path.sublist(0, path.length - 1)).value;
  if (parent is _Json) {
    parent.remove(path.last);
  } else if (parent is List<Object?>) {
    parent.removeAt(_index(path.last)!);
  }
  return (root: root, removed: found.value);
}

List<_Json> _difference(
  Object? before,
  Object? after, {
  bool beforeExists = true,
  bool afterExists = true,
  String path = '',
  Set<String> containers = const {},
}) {
  if (beforeExists == afterExists && _equal(before, after)) return [];
  if (beforeExists && afterExists && !containers.contains(path)) {
    if (before is _Json && after is _Json) {
      return [
        for (final key in {...before.keys, ...after.keys})
          ..._difference(
            before[key],
            after[key],
            beforeExists: before.containsKey(key),
            afterExists: after.containsKey(key),
            path: _childPath(path, key),
            containers: containers,
          ),
      ];
    }
    if (before is List<Object?> && after is List<Object?> && before.length == after.length) {
      return [
        for (var i = 0; i < before.length; i++)
          ..._difference(before[i], after[i], path: _childPath(path, '$i'), containers: containers),
      ];
    }
  }
  return [
    {
      'path': path,
      'oldExists': beforeExists,
      'old': beforeExists ? _copy(before) : null,
      'newExists': afterExists,
      'new': afterExists ? _copy(after) : null,
    },
  ];
}
