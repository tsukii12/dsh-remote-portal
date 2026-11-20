part of 'state_engine.dart';

// Semantic reference: json-logic-js 2.0.5, Jeremy Wadhams, MIT.
// commit c5c73601c90b11e98f6846609bac4dec203d1c18, logic.js blob
// 3d238d5ffc7ef4997a6192aaf434eba5ecf88f4a. This interpreter has no custom code,
// host objects, clocks or random source. See JSONLOGIC-LICENSE.txt.
class StateLogicResult {
  StateLogicResult._(this.valid, Object? value, List<_Json> issues) : _value = _copy(value), _issues = _maps(issues);
  final bool valid;
  final Object? _value;
  final List<_Json> _issues;
  Object? get value => _copy(_value);
  List<Map<String, Object?>> get issues => _maps(_issues);
}

/// The same bounded expression evaluator used by derive and rule conditions.
/// The input document is JSON, and var returns references within one private
/// document so JS reference equality is not accidentally deep JSON equality.
StateLogicResult evaluateStateExpression(Object? expression, Object? data) {
  try {
    final logic = _Logic.compile(_copy(expression), '');
    if (!_finiteJson(data)) throw const _StateError('logic_data', '', 'Data must be finite JSON.');
    return StateLogicResult._(true, logic.evaluate(_copy(data)), []);
  } on _StateError catch (e) {
    return StateLogicResult._(false, null, [e.issue]);
  }
}

const _logicOperators = {
  'var',
  'if',
  'and',
  'or',
  '!',
  '!!',
  '==',
  '===',
  '!=',
  '!==',
  '>',
  '<',
  '>=',
  '<=',
  '+',
  '-',
  '*',
  '/',
  '%',
  'min',
  'max',
};

class _Logic {
  _Logic._(this.expression, this.path, this.dependencies);
  final Object? expression;
  final String path;
  final List<List<String>> dependencies;

  factory _Logic.compile(Object? expression, String path) {
    var nodes = 0;
    void count(Object? value, int depth) {
      if (++nodes > 4096 || depth > 64) {
        throw _StateError('logic_limit', path, 'Expression exceeds 4096 nodes or depth 64.');
      }
      if (value is _Json) {
        for (final item in value.values) {
          count(item, depth + 1);
        }
      } else if (value is List<Object?>) {
        for (final item in value) {
          count(item, depth + 1);
        }
      } else if (!_finiteJson(value)) {
        throw _StateError('logic_json', path, 'Expression must be finite JSON.');
      }
    }

    count(expression, 0);
    final dependencies = <List<String>>[];
    void walk(Object? expr) {
      if (expr is List<Object?>) {
        for (final item in expr) {
          walk(item);
        }
        return;
      }
      if (expr is! _Json || expr.length != 1) return;
      final op = expr.keys.single;
      if (!_logicOperators.contains(op)) {
        throw _StateError('logic_operator', path, 'Unsupported JsonLogic operator: $op.');
      }
      final raw = expr[op];
      final args = raw is List<Object?> ? raw : <Object?>[raw];
      if (op == 'var') {
        final key = args.isEmpty ? _none : args.first;
        if (key is! String && (key is! num || !key.isFinite)) {
          throw _StateError('logic_dynamic_var', path, 'var requires a static string or finite numeric path.');
        }
        final text = key is String ? key : _jsString(key);
        dependencies.add(text.isEmpty ? [] : text.split('.'));
        for (final arg in args.skip(1)) {
          walk(arg);
        }
      } else {
        for (final arg in args) {
          walk(arg);
        }
      }
    }

    walk(expression);
    return _Logic._(expression, path, dependencies);
  }

  Object? evaluate(Object? data) {
    final result = _eval(expression, data);
    if (!_finiteJson(result)) {
      throw _StateError('logic_result', path, 'JsonLogic returned undefined, a non-JSON value or a non-finite number.');
    }
    return result;
  }

  Object? _eval(Object? expr, Object? data) {
    if (expr is List<Object?>) return [for (final item in expr) _eval(item, data)];
    if (expr is! _Json || expr.length != 1) return expr;
    final op = expr.keys.single;
    final raw = expr[op];
    final args = raw is List<Object?> ? raw : <Object?>[raw];
    if (op == 'if') {
      var i = 0;
      for (; i + 1 < args.length; i += 2) {
        if (_truthy(_eval(args[i], data))) return _eval(args[i + 1], data);
      }
      return i < args.length ? _eval(args[i], data) : null;
    }
    if (op == 'and' || op == 'or') {
      Object? result = _none;
      for (final arg in args) {
        result = _eval(arg, data);
        if (_truthy(result) == (op == 'or')) return result;
      }
      return result;
    }
    final values = [for (final arg in args) _eval(arg, data)];
    Object? at(int index) => index < values.length ? values[index] : _none;
    final a = at(0);
    final b = at(1);
    if (op == 'var') {
      final key = _jsString(a);
      Object? value = data;
      if (key.isEmpty) return value;
      for (final token in key.split('.')) {
        if (value is _Json && value.containsKey(token)) {
          value = value[token];
        } else if (value is List<Object?> && token == 'length') {
          value = value.length;
        } else if (value is String && token == 'length') {
          value = value.length;
        } else if (value is List<Object?> && _index(token) != null && _index(token)! < value.length) {
          value = value[_index(token)!];
        } else if (value is String && _index(token) != null && _index(token)! < value.length) {
          final i = _index(token)!;
          value = value.substring(i, i + 1);
        } else {
          return identical(b, _none) ? null : b;
        }
      }
      return value;
    }
    switch (op) {
      case '!':
        return !_truthy(a);
      case '!!':
        return _truthy(a);
      case '===':
        return _jsStrictEqual(a, b);
      case '!==':
        return !_jsStrictEqual(a, b);
      case '==':
        return _jsEqual(a, b);
      case '!=':
        return !_jsEqual(a, b);
      case '>':
        return _relation(a, b, '>');
      case '>=':
        return _relation(a, b, '>=');
      case '<':
      case '<=':
        return _relation(a, b, op) && (identical(at(2), _none) || _relation(b, at(2), op));
      case '+':
        var result = 0.0;
        for (final value in values) {
          result = _parseFloat(result) + _parseFloat(value);
        }
        return result;
      case '*':
        if (values.isEmpty) throw _StateError('logic_arity', path, '* requires an argument.');
        Object? result = values.first;
        for (final value in values.skip(1)) {
          result = _parseFloat(result) * _parseFloat(value);
        }
        return result;
      case '-':
        return identical(b, _none) ? -_number(a) : _number(a) - _number(b);
      case '/':
        return _number(a) / _number(b);
      case '%':
        final x = _number(a), y = _number(b);
        if (!x.isFinite || y.isNaN || y == 0) return double.nan;
        if (y.isInfinite) return x;
        return x.remainder(y);
      case 'min':
      case 'max':
        var result = op == 'min' ? double.infinity : double.negativeInfinity;
        for (final value in values) {
          final n = _number(value);
          result = op == 'min' ? math.min(result, n) : math.max(result, n);
        }
        return result;
    }
    throw _StateError('logic_operator', path, 'Unsupported JsonLogic operator: $op.');
  }
}

bool _truthy(Object? value) {
  if (identical(value, _none) || value == null || value == false) return false;
  if (value is num) return value != 0 && !value.isNaN;
  if (value is String) return value.isNotEmpty;
  if (value is List<Object?>) return value.isNotEmpty;
  return true;
}

String _jsString(Object? value) {
  if (identical(value, _none)) return 'undefined';
  if (value == null) return 'null';
  if (value is String) return value;
  if (value is bool) return value ? 'true' : 'false';
  if (value is num) return _jsNumberString(value);
  if (value is List<Object?>) {
    return value.map((item) => item == null || identical(item, _none) ? '' : _jsString(item)).join(',');
  }
  if (value is _Json && value.containsKey('toString')) {
    throw const _StateError('logic_coercion', '', 'A JSON object shadows toString with a non-callable value.');
  }
  return '[object Object]';
}

String _jsNumberString(num value) {
  final number = value.toDouble();
  if (number.isNaN) return 'NaN';
  if (number == double.infinity) return 'Infinity';
  if (number == double.negativeInfinity) return '-Infinity';
  if (number == 0) return '0';
  var raw = number.toString();
  final e = raw.indexOf('e');
  if (e < 0) return raw.endsWith('.0') ? raw.substring(0, raw.length - 2) : raw;
  var mantissa = raw.substring(0, e);
  if (mantissa.endsWith('.0')) mantissa = mantissa.substring(0, mantissa.length - 2);
  final exponent = int.parse(raw.substring(e + 1));
  if (exponent >= 21 || exponent < -6) return '${mantissa}e${exponent >= 0 ? '+' : ''}$exponent';
  final negative = mantissa.startsWith('-');
  if (negative) mantissa = mantissa.substring(1);
  final point = mantissa.indexOf('.');
  final digits = mantissa.replaceAll('.', '');
  final decimal = (point < 0 ? mantissa.length : point) + exponent;
  if (decimal <= 0) {
    raw = '0.${''.padRight(-decimal, '0')}$digits';
  } else if (decimal >= digits.length) {
    raw = digits.padRight(decimal, '0');
  } else {
    raw = '${digits.substring(0, decimal)}.${digits.substring(decimal)}';
  }
  return negative ? '-$raw' : raw;
}

Object? _primitive(Object? value) => value is _Json || value is List<Object?> ? _jsString(value) : value;
final _decimalPattern = RegExp(r'^[+-]?(?:(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$');
final _floatPrefix = RegExp(r'^[+-]?(?:Infinity|(?:(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?))');

double _number(Object? value) {
  if (identical(value, _none)) return double.nan;
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  final text = trimJsWhitespace(_jsString(value));
  if (text.isEmpty) return 0;
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  for (final entry in const {'0x': 16, '0b': 2, '0o': 8}.entries) {
    if (text.toLowerCase().startsWith(entry.key)) {
      final digits = text.substring(2);
      final valid = switch (entry.value) {
        16 => RegExp(r'^[0-9a-fA-F]+$').hasMatch(digits),
        2 => RegExp(r'^[01]+$').hasMatch(digits),
        _ => RegExp(r'^[0-7]+$').hasMatch(digits),
      };
      final parsed = valid ? BigInt.tryParse(digits, radix: entry.value) : null;
      return parsed?.toDouble() ?? double.nan;
    }
  }
  return _decimalPattern.hasMatch(text) ? (double.tryParse(text) ?? double.nan) : double.nan;
}

double _parseFloat(Object? value) {
  final token = _floatPrefix.firstMatch(trimJsWhitespace(_jsString(value)))?.group(0);
  if (token == null) return double.nan;
  if (token == 'Infinity' || token == '+Infinity') return double.infinity;
  if (token == '-Infinity') return double.negativeInfinity;
  return double.tryParse(token) ?? double.nan;
}

bool _jsStrictEqual(Object? a, Object? b) {
  if (identical(a, _none) || identical(b, _none)) return identical(a, b);
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  if (a is _Json || a is List<Object?> || b is _Json || b is List<Object?>) return identical(a, b);
  return a == b;
}

bool _jsEqual(Object? a, Object? b) {
  if (_jsStrictEqual(a, b)) return true;
  if ((a == null && identical(b, _none)) || (b == null && identical(a, _none))) return true;
  if (a is bool) return _jsEqual(_number(a), b);
  if (b is bool) return _jsEqual(a, _number(b));
  if ((a is num && b is String) || (a is String && b is num)) return _number(a) == _number(b);
  if ((a is _Json || a is List<Object?>) && (b is String || b is num)) {
    return _jsEqual(_primitive(a), b);
  }
  if ((b is _Json || b is List<Object?>) && (a is String || a is num)) {
    return _jsEqual(a, _primitive(b));
  }
  return false;
}

bool _relation(Object? a, Object? b, String op) {
  final x = _primitive(a), y = _primitive(b);
  if (x is String && y is String) {
    final comparison = x.compareTo(y);
    return switch (op) {
      '<' => comparison < 0,
      '<=' => comparison <= 0,
      '>' => comparison > 0,
      _ => comparison >= 0,
    };
  }
  final nx = _number(x), ny = _number(y);
  return switch (op) {
    '<' => nx < ny,
    '<=' => nx <= ny,
    '>' => nx > ny,
    _ => nx >= ny,
  };
}
