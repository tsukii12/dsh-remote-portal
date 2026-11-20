// Business consumers of the fixed STscript subset, based on SillyTavern
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0). The parser has already
// evaluated each supplied AST part once; no handler repeats that phase.
part of 'engine.dart';

TavernScriptException _slashArgument(
  _SlashInvocation invocation,
  String field,
  String message, {
  TavernScriptErrorCode code = TavernScriptErrorCode.invalidArgument,
}) => TavernScriptException(
  code: code,
  operation: invocation.command,
  message: message,
  contextId: invocation.owner.context.value.id,
  executionId: invocation.owner.id,
  fieldPath: field,
  sourceSpan: invocation.sourceSpan,
);

String _slashString(_SlashInvocation invocation, Object? value, String field) {
  if (value is String) return value;
  throw _slashArgument(invocation, field, 'This argument must be a string.');
}

String _slashNamed(_SlashInvocation invocation, String name, {String fallback = ''}) =>
    invocation.has(name) ? _slashString(invocation, invocation.argument(name), name) : fallback;
String _slashBody(_SlashInvocation invocation) =>
    invocation.hasUnnamed ? _slashString(invocation, invocation.unnamed, 'unnamed') : '';
bool _slashTrue(_SlashInvocation invocation, String name) =>
    invocation.has(name) && ScriptCoercion.trueBoolean(_slashNamed(invocation, name));
bool _slashFalse(_SlashInvocation invocation, String name) =>
    invocation.has(name) && ScriptCoercion.falseBoolean(_slashNamed(invocation, name));

extension _SlashNativeHandlers on _ScriptCoordinator {
  Future<Object?> _executeSlashHandler(_SlashInvocation invocation) {
    invocation.owner.checkAlive();
    return switch (invocation.command) {
      'setvar' ||
      'setglobalvar' ||
      'getvar' ||
      'getglobalvar' ||
      'addvar' ||
      'incvar' ||
      'flushvar' => _executeSlashVariable(invocation),
      'gen' || 'genraw' => _executeSlashGeneration(invocation),
      'trigger' => _executeSlashTrigger(invocation),
      'send' || 'sendas' || 'sys' || 'comment' => _executeSlashMessage(invocation),
      'messages' || 'hide' || 'unhide' || 'cut' || 'del' => _executeSlashMessageEdit(invocation),
      'inject' || 'listinjects' || 'flushinject' => _executeSlashPersistentInjection(invocation),
      'input' || 'buttons' || 'popup' || 'echo' || 'setinput' => _executeSlashUi(invocation),
      'getchatbook' || 'findentry' || 'createentry' || 'setentryfield' => _executeSlashBook(invocation),
      _ => Future<Object?>.error(
        _slashArgument(
          invocation,
          'command',
          'The command has no native handler.',
          code: TavernScriptErrorCode.unsupportedOption,
        ),
      ),
    };
  }

  String _setterName(_SlashInvocation invocation) {
    final key = _slashNamed(invocation, 'key');
    final name = key.isNotEmpty ? key : _slashNamed(invocation, 'name');
    if (name.isEmpty) throw _slashArgument(invocation, 'key', 'A variable name must not be empty.');
    return name;
  }

  Future<String> _executeSlashVariable(_SlashInvocation invocation) async {
    final command = invocation.command;
    final global = command == 'setglobalvar' || command == 'getglobalvar';
    if (command == 'getvar' || command == 'getglobalvar') {
      final name = invocation.has('key') ? _slashNamed(invocation, 'key') : _slashBody(invocation);
      final index = invocation.has('index') ? _slashNamed(invocation, 'index') : null;
      final pair = await _readSlashVariables(invocation.owner, chat: !global, global: global);
      final values = global ? pair.global! : pair.chat!;
      final value = values.containsKey(name) ? values[name] : ScriptCoercion.undefined;
      return ScriptCoercion.string(ScriptCoercion.variable(value, index: index));
    }
    if (command == 'flushvar') {
      var value = invocation.unnamed;
      if (value is SlashClosure) value = await _invokeSlashClosure(invocation, value);
      final name = _slashString(invocation, value ?? '', 'unnamed');
      return _transformSlashVariables<String>(
        invocation.owner,
        global: false,
        operation: command,
        transform: (current) {
          final exists = current.containsKey(name);
          if (exists) current.remove(name);
          return (changed: exists, value: '');
        },
      );
    }
    final name = command == 'incvar' ? _slashBody(invocation) : _setterName(invocation);
    if (name.isEmpty) throw _slashArgument(invocation, 'unnamed', 'A variable name must not be empty.');
    final Object incoming = command == 'incvar' ? 1 : _slashBody(invocation);
    if (command == 'addvar' || command == 'incvar') {
      return _transformSlashVariables<String>(
        invocation.owner,
        global: false,
        operation: command,
        transform: (current) => _addSlashVariable(current, name, incoming),
      );
    }
    final text = incoming as String;
    final hasIndex = invocation.has('index');
    final index = hasIndex ? _slashNamed(invocation, 'index') : '';
    final type = hasIndex ? _slashNamed(invocation, 'as') : '';
    return _transformSlashVariables<String>(
      invocation.owner,
      global: global,
      operation: command,
      transform: (current) {
        if (!hasIndex) {
          current[name] = text;
          return (changed: true, value: text);
        }
        // Only this pure JS compatibility phase is allowed to become a no-op.
        // No carrier/CAS/cancellation/schema error enters this catch.
        try {
          var container = ScriptCoercion.parseJson(current[name] ?? 'null');
          container ??= ScriptCoercion.number(index).isNaN ? <String, Object?>{} : <Object?>[];
          final converted = _slashConvertedValue(text, type);
          if (!ScriptCoercion.setProperty(container, index, converted)) return (changed: false, value: text);
          final encoded = ScriptCoercion.json(container);
          if (encoded == null) return (changed: false, value: text);
          current[name] = encoded;
          return (changed: true, value: text);
        } on FormatException {
          return (changed: false, value: text);
        } on ArgumentError {
          return (changed: false, value: text);
        }
      },
    );
  }

  ({bool changed, String value}) _addSlashVariable(Map<String, Object?> current, String name, Object? incoming) {
    final getter = ScriptCoercion.variable(current.containsKey(name) ? current[name] : ScriptCoercion.undefined);
    final value = ScriptCoercion.truthy(getter) ? getter : 0;
    try {
      final parsed = ScriptCoercion.parseJson(value);
      if (parsed is List<Object?>) {
        parsed.add(incoming);
        current[name] = ScriptCoercion.json(parsed)!;
        return (changed: true, value: ScriptCoercion.string(parsed));
      }
    } on FormatException {
      // The fixed command next tries numeric addition/string concatenation.
    }
    final increment = ScriptCoercion.number(incoming);
    final number = ScriptCoercion.number(value);
    if (increment.isNaN || number.isNaN) {
      final text =
          '${ScriptCoercion.string(ScriptCoercion.truthy(value) ? value : '')}${ScriptCoercion.string(incoming)}';
      current[name] = text;
      return (changed: true, value: text);
    }
    final result = number + increment;
    if (result.isNaN) return (changed: false, value: '');
    current[name] = result;
    return (changed: true, value: ScriptCoercion.string(result));
  }

  Object? _slashConvertedValue(String value, String type) {
    switch (trimJsWhitespace(type).toLowerCase()) {
      case 'string':
      case 'str':
        return ScriptCoercion.string(value);
      case 'null':
        return null;
      case 'undefined':
      case 'none':
        return ScriptCoercion.undefined;
      case 'number':
        return ScriptCoercion.number(value);
      case 'int':
        return ScriptCoercion.parseInt10(value);
      case 'float':
        return ScriptCoercion.parseFloat(value);
      case 'boolean':
      case 'bool':
        return ScriptCoercion.trueBoolean(value);
      case 'list':
      case 'array':
        try {
          final parsed = ScriptCoercion.parseJson(value);
          return parsed is List<Object?> ? parsed : <Object?>[];
        } on FormatException {
          return <Object?>[];
        }
      case 'object':
      case 'dict':
      case 'dictionary':
        try {
          final parsed = ScriptCoercion.parseJson(value);
          return parsed == null || parsed is Map<String, Object?> || parsed is List<Object?>
              ? parsed
              : <String, Object?>{};
        } on FormatException {
          return <String, Object?>{};
        }
      default:
        return value;
    }
  }

  Future<Object?> _slashResolveTextValue(_SlashInvocation invocation, String literal) async {
    // This handler resolver deliberately has no lexical-frame lookup.
    final hasChat = invocation.owner.context.value.chatId != null;
    var pair = await _readSlashVariables(invocation.owner, chat: hasChat);
    if (pair.chat?.containsKey(literal) == true) return ScriptCoercion.variable(pair.chat![literal]);
    pair = await _readSlashVariables(invocation.owner, chat: hasChat, global: true);
    if (pair.chat?.containsKey(literal) == true) return ScriptCoercion.variable(pair.chat![literal]);
    if (pair.global!.containsKey(literal)) return ScriptCoercion.variable(pair.global![literal]);
    return literal;
  }

  Future<bool> _evaluateSlashCondition(_SlashInvocation invocation) async {
    Object? select(List<String> names) {
      for (final name in names) {
        if (invocation.has(name)) {
          final value = invocation.argument(name);
          if (value != null && !ScriptCoercion.isUndefined(value)) return value;
        }
      }
      return ScriptCoercion.undefined;
    }

    final inputs = [
      select(const ['a', 'left', 'first', 'x']),
      select(const ['b', 'right', 'second', 'y']),
    ];
    final resolved = <Object?>[ScriptCoercion.undefined, ScriptCoercion.undefined];
    final lookup = <int, String>{};
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      if (ScriptCoercion.isUndefined(input)) continue;
      final text = _slashString(invocation, input, i == 0 ? 'a' : 'b');
      if (text.isEmpty) {
        resolved[i] = '';
        continue;
      }
      final numeric = trimJsWhitespace(text).isNotEmpty ? ScriptCoercion.number(text) : double.nan;
      if (!numeric.isNaN) {
        resolved[i] = numeric;
        continue;
      }
      if (invocation.frame.has(text)) {
        final value = invocation.frame.getVariable(text);
        if (value is SlashClosure || value is List<Object?> && value.any((item) => item is SlashClosure)) {
          throw _slashArgument(
            invocation,
            i == 0 ? 'a' : 'b',
            'A condition cannot compare a callable.',
            code: TavernScriptErrorCode.shapeMismatch,
          );
        }
        resolved[i] = value ?? '';
      } else {
        lookup[i] = text;
      }
    }
    if (lookup.isNotEmpty) {
      final hasChat = invocation.owner.context.value.chatId != null;
      var pair = await _readSlashVariables(invocation.owner, chat: hasChat);
      if (lookup.values.any((key) => pair.chat?.containsKey(key) != true)) {
        pair = await _readSlashVariables(invocation.owner, chat: hasChat, global: true);
      }
      for (final entry in lookup.entries) {
        final key = entry.value;
        resolved[entry.key] = pair.chat?.containsKey(key) == true
            ? ScriptCoercion.variable(pair.chat![key])
            : pair.global?.containsKey(key) == true
            ? ScriptCoercion.variable(pair.global![key])
            : key;
      }
    }
    final a = resolved[0], b = resolved[1];
    if (ScriptCoercion.isUndefined(a)) throw _slashArgument(invocation, 'a', 'The left condition operand is missing.');
    final rule = invocation.has('rule') ? _slashNamed(invocation, 'rule') : null;
    if (ScriptCoercion.isUndefined(b)) {
      if (rule != null && rule != 'not') {
        throw _slashArgument(invocation, 'rule', 'A unary condition only accepts not.');
      }
      final text = ScriptCoercion.string(a);
      final truth = ScriptCoercion.trueBoolean(text)
          ? true
          : ScriptCoercion.falseBoolean(text)
          ? false
          : ScriptCoercion.truthy(a);
      return rule == 'not' ? !truth : truth;
    }
    final comparison = rule ?? 'eq';
    if (a is num && b is num) {
      switch (comparison) {
        case 'gt':
          return a > b;
        case 'gte':
          return a >= b;
        case 'lt':
          return a < b;
        case 'lte':
          return a <= b;
        case 'eq':
          return a == b;
        case 'neq':
          return a != b;
        case 'in':
        case 'nin':
          break;
        default:
          throw _slashArgument(invocation, 'rule', 'The numeric condition rule is unsupported.');
      }
    }
    final left = _slashDefaultLowercase(a is String ? a : ScriptCoercion.json(a) ?? '');
    final right = _slashDefaultLowercase(b is String ? b : ScriptCoercion.json(b) ?? '');
    return switch (comparison) {
      'eq' => left == right,
      'neq' => left != right,
      'in' => left.contains(right),
      'nin' => !left.contains(right),
      _ => throw _slashArgument(invocation, 'rule', 'The text condition rule is unsupported.'),
    };
  }
}
