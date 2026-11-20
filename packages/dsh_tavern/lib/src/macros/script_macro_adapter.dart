// Scoped STscript substitution, ported from SillyTavern SlashCommandClosure
// and SlashCommandScope at 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// This part does not change the ordinary native macro path.
part of 'macro_engine.dart';

typedef _ScriptMacroResolver = _ScriptMacroValue? Function(String name, List<String> arguments);

// Callable identity stays out of the String macro protocol. The pure text
// projection is irreversible when an ordinary macro consumes this value.
class _ScriptMacroValue {
  const _ScriptMacroValue.text(this.text) : callable = null;
  const _ScriptMacroValue.callable(this.callable, this.text);
  final Object? callable;
  final String text;
}

/// Internal language bindings. Only a real scoped callable can produce a
/// private typed result; no ordinary text is ever decoded into a callable.
class ScriptMacroBindings {
  const ScriptMacroBindings({
    required this.pipe,
    required this.variable,
    required this.argument,
    required this.custom,
    required this.isCallable,
  });
  final Object? pipe;
  final Object? Function(String name, String? index) variable;
  final Object? Function(String name) argument;
  final Object? Function(String name) custom;
  final bool Function(Object? value) isCallable;
}

class ScriptMacroAdapter {
  const ScriptMacroAdapter();

  Object? expand(
    String text,
    MacroContext context, {
    required ScriptMacroBindings bindings,
    bool legacy = false,
    bool prepareCharacterFieldsOnDemand = false,
  }) {
    if (text.isEmpty) return '';
    if (legacy) {
      // Legacy's scoped wrapper expands each ordinary substring separately.
      // It deliberately asks lookup.index rather than its captured varIndex:
      // the selected fixed-source legacy contract therefore ignores the index.
      final pattern = RegExp(r'\{\{(pipe|var::([^\s]+?)(?:::(?!}})(.+))?|arg::([^{}]+)|timesIndex)\}\}');
      Object? legacyPart(String remaining) {
        final output = StringBuffer();
        while (true) {
          final match = pattern.firstMatch(remaining);
          if (match == null) {
            output.write(
              const LegacyMacroEngine().expand(
                remaining,
                context,
                prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
              ),
            );
            return output.toString();
          }
          final before = const LegacyMacroEngine().expand(
            remaining.substring(0, match.start),
            context,
            prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
          );
          final token = match[1]!;
          Object? replacement;
          if (token.toLowerCase() == 'pipe') {
            replacement = bindings.pipe;
          } else if (match[2] != null) {
            replacement = bindings.variable(match[2]!, null);
          } else if (match[4] != null) {
            replacement = bindings.argument(match[4]!);
          } else {
            replacement = bindings.custom(token);
            if (identical(replacement, _undefined)) replacement = match[0]!;
          }
          if (bindings.isCallable(replacement)) {
            final parts = <Object?>[];
            // Fixed legacy isList returns its current before/closure/tail
            // list, without the earlier scalar `done` accumulation.
            if (match.start > 0) parts.add(before);
            parts.add(replacement);
            if (match.end + 1 < remaining.length) {
              final tail = legacyPart(remaining.substring(match.end));
              if (tail is List<Object?>) {
                parts.addAll(tail);
              } else {
                parts.add(tail);
              }
            }
            return parts.length == 1 ? parts.single : parts;
          }
          output.write(before);
          output.write(_normalize(replacement));
          remaining = remaining.substring(match.end);
        }
      }

      return legacyPart(text);
    }
    _ScriptMacroValue value(Object? item) => bindings.isCallable(item)
        ? _ScriptMacroValue.callable(item, _jsString(item))
        : _ScriptMacroValue.text(_normalize(item));
    _ScriptMacroValue? resolve(String name, List<String> arguments) {
      switch (name.toLowerCase()) {
        case 'pipe':
          return arguments.isEmpty ? value(bindings.pipe) : null;
        case 'var':
          if (arguments.isEmpty || arguments.length > 2) return null;
          try {
            return value(bindings.variable(arguments[0], arguments.length > 1 ? arguments[1] : null));
          } on StateError {
            return const _ScriptMacroValue.text('');
          } on ArgumentError {
            return const _ScriptMacroValue.text('');
          }
        case 'arg':
          return arguments.length == 1 ? value(bindings.argument(arguments[0])) : null;
        default:
          if (arguments.isNotEmpty) return null;
          final item = bindings.custom(name);
          return identical(item, _undefined) ? null : value(item);
      }
    }

    try {
      return _Evaluation(context, text, const {}, scriptResolver: resolve).evaluateScript(text);
    } on _MacroDependencyFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
  }
}

/// Internal reuse of the actual JS-compatible macro coercion primitives.
/// Storage and callback exceptions never enter these pure compatibility catches.
abstract final class ScriptCoercion {
  static Object get undefined => _undefined;
  static bool isUndefined(Object? value) => identical(value, _undefined);
  static double number(Object? value) => _number(value);
  static bool truthy(Object? value) => _truthy(value);
  static String string(Object? value) => _jsString(value);
  static String normalize(Object? value) => _normalize(value);
  static bool falseBoolean(String value) => _falseBoolean(value);
  static bool trueBoolean(String value) => const {'true', 'on', '1'}.contains(trimJsWhitespace(value).toLowerCase());
  static Object? parseJson(Object? value) => _decodeJsJson(value);
  static Object? property(Object? value, String key) => _property(value, key);
  static int? arrayIndex(String key) => _arrayIndex(key);
  static String? json(Object? value) {
    if (identical(value, _undefined)) return null;
    Object? omitUndefined(Object? item) {
      if (item is Map<String, Object?>) {
        return {
          for (final entry in item.entries)
            if (!identical(entry.value, _undefined)) entry.key: omitUndefined(entry.value),
        };
      }
      if (item is List<Object?>) {
        return [for (final child in item) identical(child, _undefined) ? null : omitUndefined(child)];
      }
      return item;
    }

    return _jsJson(omitUndefined(value));
  }

  static double parseInt10(Object? value) {
    final match = RegExp(r'^[+-]?\d+').firstMatch(trimStartJsWhitespace(_jsString(value)));
    return match == null ? double.nan : double.tryParse(match[0]!) ?? double.nan;
  }

  static double parseFloat(Object? value) {
    final match = RegExp(
      r'^[+-]?(?:Infinity|(?:(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))',
    ).firstMatch(trimStartJsWhitespace(_jsString(value)));
    return match == null ? double.nan : _number(match[0]);
  }

  // Scope.getVariable catches JSON parse failure only; indexed values return
  // before the non-indexed Number conversion used by persistent getvar.
  static Object? lexicalVariable(Object? value, {String? index}) {
    if (index == null) return variable(value);
    try {
      value = _decodeJsJson(value);
    } on FormatException {
      /* Keep original value. */
    }
    if (identical(value, _undefined)) throw ArgumentError('Cannot index undefined');
    final number = _number(index);
    value = _property(value, number.isNaN ? index : _numberString(number));
    if (value == null || value is List<Object?> || value is Map<Object?, Object?>) {
      return _jsJson(value);
    }
    return identical(value, _undefined) ? '' : value;
  }

  static Object? variable(Object? value, {String? index}) {
    if (index != null) {
      try {
        value = _decodeJsJson(value);
        final number = _number(index);
        value = _property(value, number.isNaN ? index : _numberString(number));
        if (value == null || value is List<Object?> || value is Map<Object?, Object?>) {
          value = _jsJson(value);
        }
      } on FormatException {
        /* Keep the value reached by the fixed getter. */
      } on ArgumentError {
        /* Parsing null can succeed before property access fails. */
      }
    }
    final number = _number(value);
    if ((value is String && trimJsWhitespace(value).isEmpty) || number.isNaN) return _truthy(value) ? value : '';
    return number;
  }

  static bool setProperty(Object? target, String index, Object? value) {
    final number = _number(index);
    final key = number.isNaN ? index : _numberString(number);
    if (target is Map<String, Object?>) {
      target[key] = value;
      return true;
    }
    if (target is! List<Object?>) return false;
    if (key == 'length') {
      final length = _number(value);
      if (!length.isFinite || length < 0 || length >= 4294967296 || length != length.floorToDouble()) {
        throw ArgumentError('Invalid array length.');
      }
      target.length = length.toInt();
      return true;
    }
    final position = _arrayIndex(key);
    if (position != null) {
      if (target.length <= position) target.length = position + 1;
      target[position] = value;
    }
    // Non-index array properties do not appear in JSON.stringify.
    return true;
  }
}
