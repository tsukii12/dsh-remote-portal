// A bounded arithmetic language for view-v2 values. No eval, property calls,
// loops, strings, assignments or host objects.
import 'dart:math' as math;

import 'dsh_ui_bind.dart';

const dshUiFormulaLength = 256;
const dshUiFormulaTokens = 128;
const dshUiFormulaDepth = 16;

double? evaluateDshUiFormula(String source, Object? data) {
  if (source.isEmpty || source.length > dshUiFormulaLength) return null;
  try {
    final parser = _Formula(source, data);
    final value = parser.expression();
    parser.space();
    return parser.at == source.length && value.isFinite ? value : null;
  } on FormatException {
    return null;
  }
}

class _Formula {
  _Formula(this.source, this.data);
  final String source;
  final Object? data;
  int at = 0;
  int tokens = 0;
  int depth = 0;
  static final _number = RegExp(r'(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?');
  static final _path = RegExp(r'data(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[0-9]{1,6}\])+');
  static final _name = RegExp(r'[A-Za-z]+');

  Never fail() => throw const FormatException('Invalid bounded formula');
  void token() {
    if (++tokens > dshUiFormulaTokens) fail();
  }

  void space() {
    while (at < source.length && const [' ', '\t', '\n', '\r'].contains(source[at])) {
      at++;
    }
  }

  bool take(String text) {
    space();
    if (!source.startsWith(text, at)) return false;
    token();
    at += text.length;
    return true;
  }

  double finite(double n) {
    if (!n.isFinite) fail();
    return n;
  }

  double expression() {
    if (++depth > dshUiFormulaDepth) fail();
    var value = term();
    while (true) {
      if (take('+')) {
        value = finite(value + term());
      } else if (take('-')) {
        value = finite(value - term());
      } else {
        break;
      }
    }
    depth--;
    return value;
  }

  double term() {
    var value = factor();
    while (true) {
      if (take('*')) {
        value = finite(value * factor());
      } else if (take('/')) {
        value = finite(value / factor());
      } else if (take('%')) {
        final divisor = factor();
        if (divisor == 0) fail();
        value = finite(value % divisor);
      } else {
        break;
      }
    }
    return value;
  }

  double factor() {
    if (++depth > dshUiFormulaDepth) fail();
    final result = atom();
    depth--;
    return result;
  }

  double atom() {
    if (take('+')) return factor();
    if (take('-')) return -factor();
    if (take('(')) {
      final value = expression();
      if (!take(')')) fail();
      return value;
    }
    space();
    final numeric = _number.matchAsPrefix(source, at);
    if (numeric != null) {
      token();
      at = numeric.end;
      return finite(double.parse(numeric.group(0)!));
    }
    final path = _path.matchAsPrefix(source, at);
    if (path != null) {
      token();
      at = path.end;
      final parts = parseDshUiBindingPath(path.group(0)!);
      if (parts == null) fail();
      final value = dshUiLookup(data, parts);
      final n = value is num
          ? value.toDouble()
          : value is String
          ? double.tryParse(value)
          : null;
      if (n == null) fail();
      return finite(n);
    }
    final name = _name.matchAsPrefix(source, at);
    if (name == null) fail();
    token();
    at = name.end;
    final function = name.group(0)!;
    if (!const ['abs', 'min', 'max', 'clamp'].contains(function) || !take('(')) {
      fail();
    }
    final args = <double>[expression()];
    while (take(',')) {
      if (args.length == 3) fail();
      args.add(expression());
    }
    if (!take(')')) fail();
    return switch ((function, args.length)) {
      ('abs', 1) => args[0].abs(),
      ('min', 2) => math.min(args[0], args[1]),
      ('max', 2) => math.max(args[0], args[1]),
      ('clamp', 3) when args[1] <= args[2] => args[0].clamp(args[1], args[2]),
      _ => fail(),
    };
  }
}

Object? resolveDshUiFormulas(Object? value, Object? data, void Function(String) invalid) {
  Object? walk(Object? v, String path, int depth) {
    if (depth > 64) return dshUiMissing;
    // Values obtained through a binding stay data and are not reinterpreted.
    if (dshUiBindingPath(v) != null) return v;
    if (v is Map) {
      if (v.length == 1 && v.containsKey('=')) {
        final source = v['='];
        final result = source is String ? evaluateDshUiFormula(source, data) : null;
        if (result == null) invalid(path);
        return result ?? dshUiMissing;
      }
      return <String, Object?>{
        for (final entry in v.entries)
          '${entry.key}': entry.key == 'type' && entry.value is Map && (entry.value as Map).containsKey('=')
              ? dshUiMissing
              : walk(entry.value, '$path.${entry.key}', depth + 1),
      };
    }
    if (v is List) {
      return [for (final (i, item) in v.indexed) walk(item, '$path[$i]', depth + 1)];
    }
    return v;
  }

  return walk(value, 'view', 0);
}
