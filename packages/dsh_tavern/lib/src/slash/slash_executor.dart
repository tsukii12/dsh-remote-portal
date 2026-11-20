part of 'slash_language.dart';

abstract interface class SlashRuntimePort {
  void checkAlive();
  int enterCommand(SlashNode node, SlashFrame frame);
  void invocationReady(SlashInvocation invocation);
  void commandFinished(SlashInvocation invocation, Object? pipe, String publicPipe);
  void leaveCommand(SlashInvocation invocation);
  void abort(SlashInvocation invocation, {required bool quiet, required String reason});
  Future<Object?> expandPart(String text, SlashFrame frame, TavernScriptSourceSpan span, TavernSlashEffectStage phase);
  Future<bool> resolveCondition(SlashInvocation invocation);
  Future<Object?> invokeCommand(SlashInvocation invocation);
  Future<TavernResolvedSlash> resolveSource(SlashInvocation invocation, String? setName, String label);
}

class SlashRunOutcome {
  const SlashRunOutcome(this.pipe, {this.aborted = false});
  final Object? pipe;
  final bool aborted;
}

class SlashExecutor {
  SlashExecutor(this.port);
  final SlashRuntimePort port;
  bool _aborted = false;
  Future<void> _cooperate() async {
    port.checkAlive();
    await Future<void>.delayed(Duration.zero);
    port.checkAlive();
  }

  Future<SlashRunOutcome> execute(
    SlashProgram program, {
    String pipe = '',
    Map<String, String> arguments = const {},
  }) async {
    final value = await _program(program, pipe: pipe, arguments: arguments, provided: arguments, opaqueProvided: true);
    return SlashRunOutcome(_aborted ? '' : value, aborted: _aborted);
  }

  Future<Object?> invokeClosure(
    SlashInvocation invocation,
    SlashClosure closure, {
    Map<String, Object?> provided = const {},
    Object? pipe,
    bool opaqueProvided = false,
  }) => _program(
    closure.program,
    parent: invocation.frame,
    breakOwner: invocation.frame.breakOwner,
    provided: provided,
    pipe: pipe,
    opaqueProvided: opaqueProvided,
  );

  Future<Object?> _evaluate(SlashAssignment assignment, SlashFrame frame, TavernSlashEffectStage phase) async {
    port.checkAlive();
    final value = assignment.value;
    if (ScriptCoercion.isUndefined(value)) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        phase.name,
        'An assignment has no initializer.',
        assignment.span,
      );
    }
    Object? result;
    if (value is SlashProgram) {
      result = value.executeNow
          ? await _program(value, parent: frame, breakOwner: frame.breakOwner)
          : SlashClosure(value, parent: frame);
    } else if (value is SlashClosure) {
      result = value.executeNow
          ? await _program(value.program, parent: frame, breakOwner: frame.breakOwner)
          : SlashClosure(value.program, parent: frame);
    } else if (value is String) {
      result = await port.expandPart(value, frame, assignment.span, phase);
    } else {
      result = value;
    }
    return result;
  }

  Object? _unescapeText(Object? value) => value is String ? value.replaceAll(r'\{', '{').replaceAll(r'\}', '}') : value;
  Object? _unescapeUnnamed(Object? value) =>
      value is List<Object?> ? [for (final item in value) _unescapeText(item)] : _unescapeText(value);
  Future<Object?> _program(
    SlashProgram program, {
    SlashFrame? parent,
    Object? pipe,
    Map<String, Object?>? arguments,
    Map<String, Object?> provided = const {},
    bool opaqueProvided = false,
    SlashBreakOwner? breakOwner,
    Map<String, Object?> macros = const {},
  }) async {
    final frame = SlashFrame(
      parent: parent,
      pipe: pipe,
      arguments: arguments,
      breakOwner: breakOwner,
      source: program.source,
    )..macros.addAll(macros);
    for (final argument in program.defaults) {
      frame.declare(argument.name!, _unescapeText(await _evaluate(argument, frame, TavernSlashEffectStage.defaults)));
    }
    for (final declaration in program.defaults) {
      final name = declaration.name!;
      if (!provided.containsKey(name)) continue;
      final value = provided[name];
      if (opaqueProvided && value is String) {
        frame.set(name, value);
      } else {
        final assignment = SlashAssignment(name: name, value: value, span: declaration.span);
        frame.set(
          name,
          _unescapeText(
            await _evaluate(assignment, value is String ? parent ?? frame : frame, TavernSlashEffectStage.provided),
          ),
        );
      }
    }
    if (program.commands.isEmpty) frame.pipe = '';
    var first = true;
    for (final node in program.commands) {
      if (frame.breakOwner?.broken == true) break;
      await _cooperate();
      final commandIndex = port.enterCommand(node, frame);
      final descriptor = node.descriptor;
      if (descriptor == null) {
        throw _languageError(
          TavernScriptErrorCode.unsupportedCommand,
          node.name,
          'Unsupported Slash command: ${node.name}.',
          node.span,
        );
      }
      if (!descriptor.openNamed) {
        for (final assignment in node.named) {
          if (!descriptor.named.contains(assignment.name)) {
            throw _languageError(
              TavernScriptErrorCode.unsupportedOption,
              node.name,
              'Unsupported named argument: ${assignment.name}.',
              assignment.span,
            );
          }
        }
      }
      final named = <String, Object?>{};
      void assign(String name, Object? value) {
        if (value is List<Object?>) {
          for (final item in value) {
            assign(name, item);
          }
          return;
        }
        value = _unescapeText(value);
        if (descriptor.canonical == 'run' && name == 'args') {
          (named.putIfAbsent(name, () => <Object?>[])! as List<Object?>).add(value);
        } else {
          named[name] = value;
        }
      }

      for (final assignment in node.named) {
        assign(assignment.name!, await _evaluate(assignment, frame, TavernSlashEffectStage.named));
      }
      final incomingPipe = frame.pipe;
      final parts = <Object?>[];
      for (final assignment in node.unnamed) {
        parts.add(await _evaluate(assignment, frame, TavernSlashEffectStage.unnamed));
      }
      final implicit =
          node.unnamed.isEmpty &&
          !first &&
          node.injectPipe &&
          frame.pipe != null &&
          !ScriptCoercion.isUndefined(frame.pipe);
      Object? unnamed;
      if (node.unnamed.isEmpty) {
        unnamed = implicit ? frame.pipe : '';
      } else if (descriptor.splitUnnamed) {
        unnamed = parts;
      } else if (parts.length == 1) {
        unnamed = parts.single;
      } else if (!parts.any((part) => part is SlashClosure)) {
        unnamed = parts
            .map((part) => part == null || ScriptCoercion.isUndefined(part) ? '' : ScriptCoercion.string(part))
            .join();
      } else {
        unnamed = parts;
      }
      unnamed = _unescapeUnnamed(unnamed);
      if (unnamed == null || ScriptCoercion.isUndefined(unnamed)) unnamed = '';
      if (descriptor.splitUnnamed && unnamed is! List<Object?>) unnamed = [unnamed];
      final invocation = SlashInvocation(
        node: node,
        frame: frame,
        named: named,
        unnamed: unnamed,
        unnamedParts: parts,
        incomingPipe: incomingPipe,
        commandIndex: commandIndex,
        implicitPipe: implicit,
      );
      port.invocationReady(invocation);
      if (_aborted) {
        port.leaveCommand(invocation);
        break;
      }
      port.checkAlive();
      final result = await _command(invocation);
      frame.pipe = descriptor.canonical == 'break' ? result : _callbackPipe(result);
      final publicPipe = slashPublicPipe(frame.pipe);
      port.commandFinished(invocation, frame.pipe, publicPipe);
      port.leaveCommand(invocation);
      first = false;
      if (_aborted) break;
    }
    return _aborted ? '' : frame.pipe;
  }

  Future<Object?> _command(SlashInvocation invocation) async {
    switch (invocation.command) {
      case 'pass':
        return invocation.unnamed;
      case 'break':
        invocation.frame.breakOwner?.broken = true;
        return invocation.unnamed;
      case 'abort':
        final quiet = invocation.argument('quiet');
        if (!ScriptCoercion.isUndefined(quiet) && quiet is! String) {
          throw _languageError(
            TavernScriptErrorCode.invalidArgument,
            'abort',
            'quiet must be text.',
            invocation.sourceSpan,
          );
        }
        if (invocation.unnamed is! String) {
          throw _languageError(
            TavernScriptErrorCode.invalidArgument,
            'abort',
            'Abort reason must be text.',
            invocation.sourceSpan,
          );
        }
        final reason = invocation.unnamed! as String;
        _aborted = true;
        port.abort(
          invocation,
          quiet: !ScriptCoercion.falseBoolean(quiet is String ? quiet : 'true'),
          reason: reason.isEmpty ? '/abort command executed' : reason,
        );
        return '';
      case 'run':
        return _run(invocation);
      case 'if':
        final condition = await port.resolveCondition(invocation);
        final body = condition ? _body(invocation.unnamed) : invocation.argument('else');
        if (body == null || ScriptCoercion.isUndefined(body) || body == '') return '';
        return _bodyRun(invocation, body);
      case 'while':
        final count = _guardLimit(invocation);
        final body = _body(invocation.unnamed);
        Object? result = '';
        for (var i = 0; i < count; i++) {
          await _cooperate();
          if (!await port.resolveCondition(invocation) || body == '') break;
          final owner = body is SlashClosure ? SlashBreakOwner() : null;
          result = await _bodyRun(invocation, body, breakOwner: owner);
          if (_aborted || owner?.broken == true) break;
        }
        return result;
      case 'times':
        final values = invocation.unnamed is List<Object?>
            ? invocation.unnamed! as List<Object?>
            : [invocation.unnamed];
        if (values.isEmpty || values.first is! String || trimJsWhitespace(values.first! as String).isEmpty) {
          throw _languageError(
            TavernScriptErrorCode.invalidArgument,
            'times',
            'A nonempty count is required.',
            invocation.sourceSpan,
          );
        }
        final raw = ScriptCoercion.number(values.first);
        if (!raw.isFinite || raw < 0 || raw != raw.floorToDouble()) {
          throw _languageError(
            TavernScriptErrorCode.invalidArgument,
            'times',
            'Count must be a finite nonnegative integer.',
            invocation.sourceSpan,
          );
        }
        final maximum = _guardLimit(invocation);
        final count = raw > maximum ? maximum : raw.toInt();
        final body = _body(values.skip(1).toList());
        if (count > 0 && body == '') {
          throw _languageError(
            TavernScriptErrorCode.invalidArgument,
            'times',
            'A positive repetition count requires a body.',
            invocation.sourceSpan,
          );
        }
        Object? result = '';
        for (var i = 0; i < count; i++) {
          await _cooperate();
          final owner = body is SlashClosure ? SlashBreakOwner() : null;
          result = await _bodyRun(invocation, body, breakOwner: owner, timesIndex: i);
          if (_aborted || owner?.broken == true) break;
        }
        return result;
      default:
        return port.invokeCommand(invocation);
    }
  }

  int _guardLimit(SlashInvocation invocation) {
    final value = invocation.argument('guard');
    if (!ScriptCoercion.isUndefined(value) && value is! String) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        invocation.command,
        'guard must be text.',
        invocation.sourceSpan,
      );
    }
    return value is String && ScriptCoercion.falseBoolean(value) ? 9007199254740991 : 100;
  }

  Object? _body(Object? value) {
    if (value is! List<Object?>) return value ?? '';
    if (value.isNotEmpty && value.first is SlashClosure) return value.first;
    return value
        .map((part) => part == null || ScriptCoercion.isUndefined(part) ? '' : ScriptCoercion.string(part))
        .join(' ');
  }

  Future<Object?> _bodyRun(
    SlashInvocation invocation,
    Object? body, {
    SlashBreakOwner? breakOwner,
    int? timesIndex,
  }) async {
    if (body is SlashClosure) {
      return _program(
        body.program,
        parent: invocation.frame,
        breakOwner: breakOwner ?? invocation.frame.breakOwner,
        macros: {'timesIndex': ?timesIndex},
      );
    }
    if (body is! String) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        invocation.command,
        'A control body must be text or a closure.',
        invocation.sourceSpan,
      );
    }
    final text = timesIndex == null ? body : body.replaceAll('{{timesIndex}}', '$timesIndex');
    final source = SlashSource(
      text,
      id: '${invocation.frame.source?.id ?? 'source'}:body:${invocation.commandIndex}',
      callSite: invocation.sourceSpan,
    );
    final program = await SlashParser(source, checkCancelled: port.checkAlive).parse();
    return _program(program, parent: invocation.frame);
  }

  Future<Object?> _run(SlashInvocation invocation) async {
    final value = invocation.unnamed;
    if (value is SlashClosure) {
      return _program(value.program, parent: invocation.frame, breakOwner: SlashBreakOwner());
    }
    if (value is! String || value.isEmpty) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        'run',
        'run requires a closure or a nonempty reference.',
        invocation.sourceSpan,
      );
    }
    if (invocation.frame.has(value)) {
      final closure = invocation.frame.getVariable(value);
      if (closure is! SlashClosure) {
        throw _languageError(
          TavernScriptErrorCode.invalidArgument,
          'run',
          'The lexical value is not callable.',
          invocation.sourceSpan,
        );
      }
      return _program(
        closure.program,
        parent: invocation.frame,
        breakOwner: SlashBreakOwner(),
        provided: invocation.named,
      );
    }
    final reference = trimJsWhitespace(value);
    final split = reference.indexOf('.');
    final setName = split < 0 ? null : reference.substring(0, split);
    final label = split < 0 ? reference : reference.substring(split + 1);
    if (setName == '' || label.isEmpty) {
      throw _languageError(
        TavernScriptErrorCode.invalidArgument,
        'run',
        'The external reference contains an empty set or label.',
        invocation.sourceSpan,
      );
    }
    final arguments = <String, Object?>{};
    for (final entry in invocation.named.entries) {
      final item = entry.value;
      if (item is String || item is SlashClosure) {
        arguments[entry.key] = item;
      } else if (entry.key == 'args' && item is List<Object?> && item.every((value) => value is String)) {
        arguments[entry.key] = ScriptCoercion.string(item);
      } else {
        throw _languageError(
          TavernScriptErrorCode.invalidArgument,
          'run',
          'An external call argument is not text or a single closure.',
          invocation.sourceSpan,
        );
      }
    }
    final resolved = await port.resolveSource(invocation, setName, label);
    final source = SlashSource(
      resolved.source,
      id: '${resolved.assetId}@${resolved.version}',
      assetId: resolved.assetId,
      version: resolved.version,
      callSite: invocation.sourceSpan,
    );
    final program = await SlashParser(source, checkCancelled: port.checkAlive).parse();
    return _program(
      program,
      parent: invocation.frame,
      breakOwner: SlashBreakOwner(),
      arguments: arguments,
      provided: arguments,
      opaqueProvided: true,
    );
  }
}
