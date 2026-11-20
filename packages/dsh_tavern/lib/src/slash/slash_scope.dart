part of 'slash_language.dart';

class SlashBreakOwner {
  bool broken = false;
}

class SlashFrame {
  SlashFrame({this.parent, Map<String, Object?>? arguments, this.breakOwner, Object? pipe, this.source})
    : arguments = Map.unmodifiable(arguments ?? parent?.arguments ?? const {}),
      _pipe = pipe;
  final SlashFrame? parent;
  final Map<String, Object?> arguments;
  final SlashBreakOwner? breakOwner;
  final SlashSource? source;
  final variables = <String, Object?>{};
  final macros = <String, Object?>{};
  Object? _pipe;
  Object? get pipe => _pipe ?? parent?.pipe;
  set pipe(Object? value) {
    _pipe = value;
  }

  bool has(String name) => variables.containsKey(name) || parent?.has(name) == true;
  Object? raw(String name) {
    if (variables.containsKey(name)) return variables[name];
    if (parent != null) return parent!.raw(name);
    throw StateError('Variable not found: $name');
  }

  Object? getVariable(String name, {String? index}) => ScriptCoercion.lexicalVariable(raw(name), index: index);
  void declare(String name, Object? value) {
    if (variables.containsKey(name)) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        'defaults',
        'The closure declares a duplicate variable: $name.',
        null,
      );
    }
    variables[name] = value;
  }

  void set(String name, Object? value) {
    if (variables.containsKey(name)) {
      variables[name] = value;
      return;
    }
    if (parent != null) {
      parent!.set(name, value);
      return;
    }
    throw StateError('Variable not found: $name');
  }

  Object? custom(String name) {
    for (final entry in macros.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return parent?.custom(name) ?? ScriptCoercion.undefined;
  }

  ScriptMacroBindings get bindings => ScriptMacroBindings(
    pipe: pipe,
    variable: (name, index) => getVariable(name, index: index),
    argument: (name) => arguments.containsKey(name) ? arguments[name] : '',
    custom: custom,
    isCallable: (value) => value is SlashClosure,
  );
}
