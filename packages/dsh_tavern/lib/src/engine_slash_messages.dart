// Native message consumers of SillyTavern slash-commands.js and script.js,
// fixed commit 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// Text effects and message storage are separate adopted units. Numeric slots
// are interpreted once against the captured path, before the text unit.
part of 'engine.dart';

String _slashWithoutMacros(String text) =>
    trimJsWhitespace(text.replaceAll(RegExp(r'\{\{[\s\S]*?\}\}', multiLine: true), ''));

int _slashInsertion(_SlashInvocation invocation, int count) {
  if (!invocation.has('at')) return count;
  final value = ScriptCoercion.number(_slashNamed(invocation, 'at'));
  if (!value.isFinite || value != value.truncateToDouble()) {
    throw _slashArgument(invocation, 'at', 'The insertion slot must be a finite integer.');
  }
  // double.isNegative includes negative zero; positive zero remains slot 0.
  final slot = value.isNegative ? count + value : value;
  if (slot < 0 || slot > count) {
    throw _slashArgument(
      invocation,
      'at',
      'The insertion slot is outside this path.',
      code: TavernScriptErrorCode.range,
    );
  }
  return slot.toInt();
}

({int start, int end}) _slashMessageRange(
  _SlashInvocation invocation,
  String value,
  int count, {
  bool emptyLast = false,
}) {
  if (emptyLast && value.isEmpty) {
    if (count == 0) {
      throw _slashArgument(
        invocation,
        'unnamed',
        'An empty chat has no last message.',
        code: TavernScriptErrorCode.range,
      );
    }
    return (start: count - 1, end: count - 1);
  }
  final match = RegExp(r'^([0-9]+)(?:-([0-9]+))?$').firstMatch(trimJsWhitespace(value));
  if (match == null) {
    throw _slashArgument(invocation, 'unnamed', 'Expected a message index or an inclusive i-j range.');
  }
  final start = BigInt.parse(match[1]!);
  final end = match[2] == null ? start : BigInt.parse(match[2]!);
  if (start > end || end >= BigInt.from(count)) {
    throw _slashArgument(
      invocation,
      'unnamed',
      'The message range is outside this path.',
      code: TavernScriptErrorCode.range,
    );
  }
  return (start: start.toInt(), end: end.toInt());
}

bool _slashIsSystem(StoredNode node) => node.message.hidden || node.message.role == TavernRole.system;

void _checkSlashToolDeletion(_SlashInvocation invocation, List<StoredNode> path, List<StoredNode> selected) {
  if (invocation.has('toolcalls')) {
    if (!ScriptCoercion.falseBoolean(_slashNamed(invocation, 'toolcalls'))) {
      throw _slashArgument(
        invocation,
        'toolcalls',
        'Only explicit false disables the unavailable tool-cascade deletion.',
        code: TavernScriptErrorCode.unsupportedOption,
      );
    }
    return;
  }
  final ids = {for (final node in selected) node.message.nodeId};
  final remaining = List<StoredNode>.of(path);
  for (final chosen in selected) {
    final index = remaining.indexWhere((node) => node.message.nodeId == chosen.message.nodeId);
    if (index < 0) continue;
    var start = index;
    final node = remaining[index];
    if (node.message.role != TavernRole.user && !_slashIsSystem(node)) {
      while (start > 0) {
        final previous = remaining[start - 1];
        if (!_slashIsSystem(previous) || previous.extra['tool_invocations'] is! List) break;
        if (!ids.contains(previous.message.nodeId)) {
          throw _slashArgument(
            invocation,
            'toolcalls',
            'The fixed deletion would also remove an unselected tool message.',
            code: TavernScriptErrorCode.unsupportedCapability,
          );
        }
        start--;
      }
    }
    // Earlier selected removals change the adjacency for the next selected
    // message, exactly as the fixed sequential deletion consumer does.
    remaining.removeRange(start, index + 1);
  }
}

extension _SlashMessageOperations on _ScriptCoordinator {
  Future<String> _executeSlashMessageEdit(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    final command = invocation.command;
    final body = _slashBody(invocation);
    final includeNames = !_slashFalse(invocation, 'names');
    final includeHidden = _slashTrue(invocation, 'hidden');
    final role = _slashNamed(invocation, 'role');
    if (command == 'messages' && !const {'', 'system', 'assistant', 'user'}.contains(role)) {
      throw _slashArgument(invocation, 'role', 'Message role must be system, assistant, or user.');
    }
    final nameFilter = command == 'hide' || command == 'unhide'
        ? trimJsWhitespace(_slashNamed(invocation, 'name'))
        : '';
    if ((command == 'cut' || command == 'del') &&
        invocation.has('toolcalls') &&
        !ScriptCoercion.falseBoolean(_slashNamed(invocation, 'toolcalls'))) {
      throw _slashArgument(
        invocation,
        'toolcalls',
        'Only an explicit false toolcalls option is supported.',
        code: TavernScriptErrorCode.unsupportedOption,
      );
    }
    if (command == 'del' && body.isEmpty) {
      throw _slashArgument(
        invocation,
        'unnamed',
        'Interactive deletion is outside the supported UI commands.',
        code: TavernScriptErrorCode.unsupportedOption,
      );
    }
    final admission = await _captureSlashChat(owner);
    owner.checkAlive();
    final path = admission.capture.path;
    final int start, end;
    if (command == 'del') {
      final count = ScriptCoercion.number(body);
      if (!count.isFinite || count != count.truncateToDouble() || count <= 0) {
        throw _slashArgument(invocation, 'unnamed', 'The delete count must be a positive finite integer.');
      }
      if (count > path.length) {
        throw _slashArgument(
          invocation,
          'unnamed',
          'The delete count exceeds the captured path.',
          code: TavernScriptErrorCode.range,
        );
      }
      start = path.length - count.toInt();
      end = path.length - 1;
    } else {
      final range = _slashMessageRange(
        invocation,
        body,
        path.length,
        emptyLast: command == 'hide' || command == 'unhide',
      );
      start = range.start;
      end = range.end;
    }
    final selected = path.sublist(start, end + 1);
    if (command == 'messages') {
      final result = <String>[];
      for (final node in selected) {
        final message = node.message;
        final roleMatches = switch (role) {
          'system' => message.role == TavernRole.narrator,
          'assistant' => message.role != TavernRole.narrator && message.role != TavernRole.user,
          'user' => message.role == TavernRole.user,
          _ => true,
        };
        if (!roleMatches || !includeHidden && _slashIsSystem(node)) continue;
        result.add(includeNames ? '${message.speaker}: ${message.text}' : message.text);
      }
      owner.checkAlive();
      return result.join('\n\n');
    }
    final chatId = admission.capture.chatId;
    if (command == 'hide' || command == 'unhide') {
      final refs = [
        for (final node in selected)
          if (nameFilter.isEmpty || node.message.speaker == nameFilter)
            TavernScriptMessageRef(chatId: chatId, nodeId: node.message.nodeId),
      ];
      await _setSlashHidden(owner, admission, refs, command == 'hide');
      owner.checkAlive();
      return '';
    }
    _checkSlashToolDeletion(invocation, path, selected);
    final result = [for (final node in selected) '${node.message.text}\n'].join();
    await _deleteSlashMessages(owner, admission, [
      for (final node in selected) TavernScriptMessageRef(chatId: chatId, nodeId: node.message.nodeId),
    ]);
    owner.checkAlive();
    return result;
  }

  Future<String> _executeSlashMessage(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    final command = invocation.command;
    final mode = _slashReturnMode(invocation, fallback: 'none');
    final body = _slashBody(invocation);
    final compact = _slashTrue(invocation, 'compact');
    final suppliedName = invocation.has('name') ? _slashNamed(invocation, 'name') : null;
    final admission = await _captureSlashChat(owner);
    owner.checkAlive();
    final insertion = _slashInsertion(invocation, admission.capture.path.length);
    final chatId = admission.capture.chatId;
    final chat = engine._store.chat(chatId);
    String? actor;
    var speakers = <String, _ScriptSpeakerCapture>{};
    final TavernRole role;
    final String name;
    if (command == 'sendas') {
      final selector = trimJsWhitespace(suppliedName ?? '');
      actor = selector.isEmpty
          ? owner.context.value.characterId ?? (engine._store.groupChat(chatId) == null ? chat.characterId : null)
          : await _slashGenerationActor(invocation, selector);
      if (actor == null) {
        throw _slashArgument(
          invocation,
          'name',
          selector.isEmpty
              ? 'An unnamed sendas needs an explicit actor in a group.'
              : 'No character has this identity or name.',
          code: selector.isEmpty ? TavernScriptErrorCode.noContext : TavernScriptErrorCode.notFound,
        );
      }
      speakers = await owner.wait(
        _bridgeOperation(() => _messageSpeakers(admission.capture, [actor!], 'sendas')),
        TavernSlashWaitKind.storage,
      );
      owner.checkAlive();
      name = speakers[actor]!.name;
      role = TavernRole.character;
    } else if (command == 'send') {
      final settings = _personaSettings(
        engine._effectiveSettings(chat, admission.metadata),
        engine._personas.resolve(personaId: chat.personaId),
      );
      name = suppliedName ?? (settings['userName'] is String ? settings['userName']! as String : 'User');
      role = TavernRole.user;
    } else if (command == 'sys') {
      final originalName = admission.metadata['narrator_name'];
      if (suppliedName == null && ScriptCoercion.truthy(originalName) && originalName is! String) {
        throw _slashArgument(
          invocation,
          'metadata.narrator_name',
          'The selected narrator name must be a string.',
          code: TavernScriptErrorCode.shapeMismatch,
        );
      }
      name = suppliedName ?? (originalName is String && originalName.isNotEmpty ? originalName : 'System');
      role = TavernRole.narrator;
    } else {
      name = 'Note';
      role = TavernRole.system;
    }
    _checkSlashChatAdmission(owner, admission);
    final unit = await _captureMacroUnit(owner);
    late final String text;
    late final Map<String, Object?> extra;
    var hidden = false;
    try {
      owner.checkAlive();
      final environment = unit.environment;
      var prepared = trimJsWhitespace(body);
      var bias = '';
      if (command == 'send') bias = _slashExtractMessageBias(prepared);
      if (command == 'send' || command == 'sendas') {
        final placement = command == 'send' ? RegexPlacement.userInput : RegexPlacement.slashCommand;
        final rendered = environment.regex.applyWithDiagnostics(
          prepared,
          placement: placement,
          phase: RegexPhase.writeBack,
          characterOverride: command == 'sendas' ? name : null,
          expand: environment.regexExpand,
        );
        prepared = rendered.text;
        if (rendered.warnings.isNotEmpty) {
          owner.observeIssues([
            TavernScriptIssue(
              code: 'slashMessageRegex',
              message: 'Some message regex rules were skipped.',
              committed: false,
              contextId: owner.context.value.id,
              sourceSpan: invocation.sourceSpan,
              stage: 'handler',
              details: {
                'placement': placement,
                'replacements': rendered.replacements,
                'warnings': [
                  for (final warning in rendered.warnings)
                    {
                      'ruleId': warning.ruleId,
                      'ruleName': warning.ruleName,
                      'ruleIndex': warning.ruleIndex,
                      'reason': warning.reason,
                      'message': warning.message,
                    },
                ],
              },
            ),
          ]);
        }
      }
      if (command == 'sendas' || command == 'sys') {
        final biasSource = command == 'sys' ? body : prepared;
        bias = _slashExtractMessageBias(biasSource);
        hidden = bias.isNotEmpty && _slashWithoutMacros(biasSource).isEmpty;
      }
      var expanded = environment.expand(prepared, const {});
      if (command == 'send' && bias.isNotEmpty) expanded = _slashWithoutMacros(expanded);
      unit.checkDependencies();
      text = expanded;
      extra = {
        'isSmallSys': compact,
        if (command == 'send' && bias.isNotEmpty) 'bias': bias,
        if (command != 'send') ...{
          'gen_id': environment.now.millisecondsSinceEpoch,
          'api': 'manual',
          'model': 'slash command',
          if (command == 'sendas' || command == 'sys') 'bias': trimJsWhitespace(bias).isEmpty ? null : bias,
          if (command == 'sys') 'type': 'narrator',
          if (command == 'comment') 'type': 'comment',
        },
      };
      owner.checkAlive();
      await _commitMacroUnit(owner, unit, stage: TavernSlashEffectStage.handler, operation: command);
    } catch (_) {
      unit.checkDependencies();
      rethrow;
    } finally {
      _discardMacroUnit(owner, unit);
    }
    owner.checkAlive();
    final receipt = await _createSlashMessage(
      owner,
      admission,
      insertion: insertion,
      role: role,
      name: name,
      text: text,
      hidden: hidden,
      speakerCharacterId: actor,
      speakers: speakers,
      extra: extra,
      lifecycleName: command == 'sendas' ? 'MESSAGE_RECEIVED' : 'MESSAGE_SENT',
    );
    owner.checkAlive();
    return _returnSlashValue(invocation, mode, text: receipt.text, object: receipt.object);
  }
}
