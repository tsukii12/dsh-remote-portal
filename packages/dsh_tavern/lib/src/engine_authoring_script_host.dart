part of 'engine.dart';

typedef _AuthoringScriptNode = ({StoredNode node, Map<String, Object?> state, Map<String, Object?> rawExtra});

/// Mutable local carriers, with original capture evidence kept elsewhere.
/// The only live reader is removed at seal; all writes below are synchronous
/// calculations and adoption into these owned values.
final class _AuthoringScriptWorkspace {
  _AuthoringScriptWorkspace({
    required this.turn,
    required this.scripts,
    required this.history,
    required List<StoredNode> currentPath,
    required Map<String, Object?> global,
    required this.storedGlobal,
    required this.groupInitial,
    required this.liveLocal,
    required this.rawHostData,
    required this.prospectiveGameplay,
    required this.settingsForMetadata,
    required _AuthoringScriptNode Function(String)? readNode,
  }) : path = currentPath,
       globals = _NativeGlobals(global),
       _readNode = readNode;

  final _Turn turn;
  final _AuthoringScriptCapture scripts;
  final List<StoredNode> history, path;
  final _NativeGlobals globals;
  _ScriptRawVariable storedGlobal;
  Map<String, Object?> groupInitial;
  ({String? leaf, Map<String, Object?> values})? liveLocal;
  final Map<String, Object?> rawHostData;
  final _GameplayRuntime? prospectiveGameplay;
  final Map<String, Object?> Function(StoredChat, Map<String, Object?>) settingsForMetadata;
  _AuthoringScriptNode Function(String)? _readNode;
  final nodes = <String, _AuthoringScriptNode>{};
  final _versions = <String, ({String fingerprint, int revision})>{};
  final effects = <Map<String, Object?>>[];
  var stopped = false;

  StoredChat get chat => turn.chat;

  void stop() {
    stopped = true;
    _readNode = null;
  }

  void seal() {
    _readNode = null;
  }

  _AuthoringScriptNode node(String id) => nodes.putIfAbsent(id, () {
    final read = _readNode;
    if (read == null) {
      throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'The message was not captured.');
    }
    return read(id);
  });

  Map<String, Object?> stateAt(String? id) => id == null ? groupInitial : node(id).state;

  void _adoptNode(String id, Map<String, Object?> state, Map<String, Object?> rawExtra) {
    final old = node(id).node;
    final updated = StoredNode(
      message: old.message,
      depth: old.depth,
      selectedChildId: old.selectedChildId,
      extra: rawExtra,
      original: old.original,
    );
    nodes[id] = (node: updated, state: state, rawExtra: rawExtra);
    for (final values in [history, if (!identical(history, path)) path]) {
      final index = values.indexWhere((value) => value.message.nodeId == id);
      if (index >= 0) {
        values[index] = updated;
      }
    }
  }

  void adoptGroupUser() {
    final user = history.last;
    final state = _copy(turn.state);
    nodes[user.message.nodeId] = (node: user, state: state, rawExtra: user.extra);
    if (!identical(path, history)) {
      path.add(user);
    }
    liveLocal = (leaf: user.message.nodeId, values: _runtimeCopy(turn.variables));
  }

  void saveGroupGlobals(int before) {
    if (!globals.changedSince(before)) {
      return;
    }
    final through = globals.revision;
    final runtime = globals.project(through);
    storedGlobal = _ScriptRawVariable(true, _copy(runtime));
    globals.commit(runtime, through);
    effects.add({'operation': 'groupUserGlobals', 'scope': 'preview'});
  }

  void _adoptChat({Map<String, Object?>? variables, Map<String, Object?>? metadata}) {
    final before = chat;
    turn.chat = StoredChat(
      id: before.id,
      characterId: before.characterId,
      title: before.title,
      createdAt: before.createdAt,
      updatedAt: before.updatedAt,
      metadata: metadata ?? before.metadata,
      variables: variables ?? before.variables,
      settings: before.settings,
      personaId: before.personaId,
      presetId: before.presetId,
      currentLeafId: before.currentLeafId,
      selectedRootId: before.selectedRootId,
    );
  }

  Map<String, Object?> metadataFor(String? nodeId) {
    if (nodeId == null) {
      return {..._copy(chat.metadata), 'variables': _copy(chat.variables)};
    }
    return ChatJsonlCodec().metadataForState(chat, stateAt(nodeId));
  }

  TavernVariableTarget resolve(TavernScriptContext context, TavernVariableTarget target) {
    if (target.characterId != null ||
        target.scriptOwner != null ||
        target.scope != TavernVariableScope.message && (target.messageId != null || target.messageRef != null) ||
        target.scope == TavernVariableScope.global && target.chatId != null) {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'variables', 'Unexpected variable target fields.');
    }
    if (target.scope == TavernVariableScope.global) {
      return const TavernVariableTarget(scope: TavernVariableScope.global);
    }
    final chatId = target.chatId ?? target.messageRef?.chatId ?? context.chatId;
    if (chatId != chat.id) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedCapability,
        'variables',
        'Only the captured preview chat is available.',
      );
    }
    if (target.messageRef != null && target.messageRef!.chatId != chatId) {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'variables', 'Message and chat identities disagree.');
    }
    if (target.scope == TavernVariableScope.chat) {
      return TavernVariableTarget(scope: target.scope, chatId: chatId);
    }
    var ref = target.messageRef;
    if (ref == null || target.messageId != null) {
      final requested = target.messageId ?? -1;
      final index = requested < 0 ? path.length + requested : requested;
      if (index < 0 || index >= path.length) {
        throw _scriptError(TavernScriptErrorCode.range, 'variables', 'The message is outside the captured path.');
      }
      final numbered = TavernScriptMessageRef(chatId: chatId!, nodeId: path[index].message.nodeId);
      if (ref != null && ref != numbered) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'variables',
          'Message number and reference disagree.',
        );
      }
      ref = numbered;
    }
    node(ref.nodeId);
    return TavernVariableTarget(scope: target.scope, chatId: chatId, messageRef: ref);
  }

  _ScriptRawVariable raw(TavernVariableTarget target) => switch (target.scope) {
    TavernVariableScope.global => storedGlobal,
    TavernVariableScope.chat => _ScriptRawVariable(true, chat.variables),
    TavernVariableScope.message => _fieldVariable(stateAt(target.messageRef!.nodeId), 'messageVariables'),
    _ => throw StateError('Unsupported scope entered the local variable adapter.'),
  };

  String version(TavernVariableTarget target) {
    final key = _targetKey(target);
    final value = raw(target);
    final fingerprint = _variableFingerprint(value);
    final old = _versions[key];
    final revision = old == null ? 0 : old.revision + (old.fingerprint == fingerprint ? 0 : 1);
    _versions[key] = (fingerprint: fingerprint, revision: revision);
    return '${scripts.captureId}:variable:$key:$revision';
  }

  TavernVariableSnapshot read(TavernVariableTarget target) =>
      TavernVariableSnapshot(resolvedTarget: target, version: version(target), value: _variableObject(raw(target)));

  TavernVariableSnapshot write(
    TavernVariableTarget target,
    Map<String, Object?> Function(_ScriptRawVariable) transform, {
    required TavernAuthoringRuntimeOperation operation,
    String? expectedVersion,
    bool mergeRuntime = false,
  }) {
    final before = version(target);
    if (expectedVersion != null && expectedVersion != before) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'variables', 'The local variable version changed.');
    }
    final current = raw(target);
    Map<String, Object?> value;
    final Map<String, Object?>? runtime;
    if (target.scope == TavernVariableScope.global && mergeRuntime) {
      _variableObject(current);
      runtime = _runtimeCopy(transform(_ScriptRawVariable(true, globals.project(globals.revision))));
      value = _copy(runtime);
    } else {
      runtime = null;
      value = _captureScriptObject(transform(current));
    }
    TavernStateEditResult? stateEdit;
    switch (target.scope) {
      case TavernVariableScope.global:
        storedGlobal = _ScriptRawVariable(true, value);
        globals.commit(runtime ?? value, globals.revision);
      case TavernVariableScope.chat:
        final leaf = chat.currentLeafId;
        if (leaf != null) {
          final old = node(leaf);
          final state = _copy(old.state)..['variables'] = value;
          final extra = {
            ...old.rawExtra,
            'dshgo': {..._map(old.rawExtra['dshgo']), 'tavernState': _copy(state)},
          };
          _adoptNode(leaf, state, extra);
        } else if (turn.groupView != null) {
          groupInitial = _copy(groupInitial)..['variables'] = value;
        }
        _adoptChat(variables: value);
        liveLocal = (leaf: leaf, values: _copy(value));
      case TavernVariableScope.message:
        final id = target.messageRef!.nodeId;
        final old = node(id);
        final gameplay = turn.gameplayAdmission!.hasActivePacks || old.state.containsKey('dshgoPackDefinitionConfigId')
            ? prospectiveGameplay
            : null;
        final context = _ScriptDataContext(
          chat.id,
          chat.characterId,
          0,
          rawHostData,
          gameplay?.state ?? _stateDefinition(rawHostData),
          settingsForMetadata(chat, metadataFor(chat.currentLeafId)),
          gameplay: gameplay,
          gameplayAdmission: turn.gameplayAdmission,
        );
        final prepared = _prepareScriptMessageData(
          context,
          nodeId: id,
          baseline: old.state,
          data: value,
          extra: old.rawExtra,
          createInvocation: () => scripts.identity('message-state'),
        );
        final extra = {
          ...old.rawExtra,
          'dshgo': {..._map(old.rawExtra['dshgo']), ...?prepared.audit, 'tavernState': _copy(prepared.state)},
        };
        final selected = id == chat.currentLeafId ? prepared.state : stateAt(chat.currentLeafId);
        final variables = _map(selected['variables']);
        final metadata = _runtimeMetadata(chat.metadata, selected);
        value = _captureScriptObject(prepared.state['messageVariables']);
        // All validation is complete before any of this physical node or the
        // current chat carrier changes. Descendants keep their own old state.
        _adoptNode(id, prepared.state, extra);
        _adoptChat(variables: variables, metadata: metadata);
        liveLocal = null;
        stateEdit = prepared.stateEdit;
      default:
        throw StateError('Unsupported scope entered the local variable adapter.');
    }
    final after = version(target);
    effects.add({
      'operation': operation.name,
      'scope': 'preview',
      'target': _targetKey(target),
      'beforeVersion': before,
      'afterVersion': after,
    });
    return TavernVariableSnapshot(resolvedTarget: target, version: after, value: value, stateEdit: stateEdit);
  }

  Map<String, Object?> publicView() => _copy({
    'chatId': chat.id,
    'currentLeafId': chat.currentLeafId,
    'generationType': turn.generationType,
    'operationTargetNodeId': turn.nodeId,
    'messages': [
      for (final node in path)
        {
          'nodeId': node.message.nodeId,
          'parentId': node.message.parentId,
          'role': node.message.role.name,
          'speaker': node.message.speaker,
          'text': node.message.text,
          'reasoning': node.message.reasoning,
          'hidden': node.message.hidden,
          'at': node.message.at.toIso8601String(),
        },
    ],
  });
}

/// A callback can retain this object, but cannot use it after its own stage.
/// Pending operation Futures are observed even when a host forgot to await.
final class _AuthoringPromptRuntime implements TavernAuthoringPromptRuntime {
  _AuthoringPromptRuntime(this.workspace, this.context, this.binding, this.cancellation);
  final _AuthoringScriptWorkspace workspace;
  final TavernScriptContext context;
  final TavernAuthoringScriptBinding binding;
  final ModelCancellation cancellation;
  final _pending = <Future<void>>[];
  var closed = false;
  bool unsupported = false;

  void stop() {
    closed = true;
  }

  Future<void> drain() async {
    await Future.wait(_pending);
  }

  Future<T> _call<T>(TavernAuthoringRuntimeOperation operation, T Function() action) {
    final future = Future<T>.sync(() {
      cancellation.check();
      if (closed || workspace.stopped) {
        throw _scriptError(TavernScriptErrorCode.closedContext, operation.name, 'The preview invocation has ended.');
      }
      if (!binding.runtimeOperations.contains(operation)) {
        unsupported = true;
        throw _scriptError(
          TavernScriptErrorCode.unsupportedCapability,
          operation.name,
          'The isolated host did not declare this local operation.',
        );
      }
      try {
        return action();
      } on TavernScriptException catch (error) {
        if (error.code == TavernScriptErrorCode.unsupportedCapability) {
          unsupported = true;
        }
        rethrow;
      } on TavernAuthoringException {
        rethrow;
      } on TavernModelException {
        rethrow;
      } on StateError {
        throw _scriptError(TavernScriptErrorCode.notFound, operation.name, 'The captured target is unavailable.');
      } on ArgumentError {
        throw _scriptError(TavernScriptErrorCode.invalidArgument, operation.name, 'An argument is invalid.');
      } on FormatException {
        throw _scriptError(TavernScriptErrorCode.invalidJson, operation.name, 'Stored JSON is invalid.');
      } catch (error) {
        throw _scriptError(
          TavernScriptErrorCode.storage,
          operation.name,
          'Bridge storage failed (${error.runtimeType}).',
        );
      }
    });
    _pending.add(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  TavernVariableTarget _target(TavernVariableTarget target) {
    if (!const {
      TavernVariableScope.global,
      TavernVariableScope.chat,
      TavernVariableScope.message,
    }.contains(target.scope)) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedCapability,
        'variables',
        'Only global, chat and message scopes have an isolated adapter.',
      );
    }
    return workspace.resolve(context, target);
  }

  @override
  Future<TavernVariableSnapshot> getVariables(TavernVariableTarget target) =>
      _call(TavernAuthoringRuntimeOperation.getVariables, () => workspace.read(_target(target)));

  @override
  Future<TavernVariableSnapshot> replaceVariables(
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) => _call(TavernAuthoringRuntimeOperation.replaceVariables, () {
    final captured = _captureScriptObject(value);
    return workspace.write(
      _target(target),
      (_) => captured,
      operation: TavernAuthoringRuntimeOperation.replaceVariables,
      expectedVersion: expectedVersion,
    );
  });

  @override
  Future<TavernVariableMutation> mutateVariables(
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) => _call(TavernAuthoringRuntimeOperation.mutateVariables, () {
    final captured = List<TavernVariableChange>.of(changes);
    for (final change in captured) {
      if (change.pathTokens.isEmpty ||
          change.pathTokens.any((token) => token is! String && (token is! int || token < 0)) ||
          change.kind != TavernVariableChangeKind.remove && !change.hasValue ||
          change.kind == TavernVariableChangeKind.remove && change.hasValue) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'mutateVariables',
          'Invalid path tokens or value presence.',
        );
      }
    }
    final resolved = _target(target);
    final global = resolved.scope == TavernVariableScope.global;
    final results = <TavernVariableChangeResult>[];
    final snapshot = workspace.write(
      resolved,
      (raw) {
        final next = global ? _runtimeCopy(raw.value! as Map<String, Object?>) : _variableObject(raw);
        for (final change in captured) {
          results.add(_applyVariableChange(next, change, jsonComparison: global));
        }
        return next;
      },
      operation: TavernAuthoringRuntimeOperation.mutateVariables,
      expectedVersion: expectedVersion,
      mergeRuntime: global,
    );
    return TavernVariableMutation(snapshot: snapshot, results: results);
  });

  @override
  Future<TavernScriptInjectionLease> injectPrompts(List<TavernScriptInjection> prompts, {bool once = false}) =>
      _call(TavernAuthoringRuntimeOperation.injectPrompts, () {
        final scripts = workspace.scripts;
        final ids = <String>{};
        final captured = <TavernScriptInjection>[];
        for (final prompt in prompts) {
          if (!ids.add(prompt.id)) {
            throw _scriptError(TavernScriptErrorCode.duplicateId, 'injectPrompts', 'A batch contains a duplicate id.');
          }
          final ref = prompt.filter;
          if (ref != null &&
              (ref.contextId != context.id || ref.instanceId != context.instanceId || ref.callbackId.isEmpty)) {
            throw _scriptError(
              TavernScriptErrorCode.callbackUnavailable,
              'injectPrompts',
              'The filter must belong to this captured owner instance.',
            );
          }
          captured.add(_copyInjection(prompt));
        }
        final leaseId = scripts.identity('lease');
        final registrations = <TavernScriptInjectionRegistration>[];
        for (final injection in captured) {
          final version = scripts.identity('registration');
          scripts._localRegistrations[injection.id] = _ScriptInjectionRegistration(
            chatId: workspace.chat.id,
            ownerContextId: context.id,
            ownerInstanceId: context.instanceId,
            version: version,
            leaseId: leaseId,
            injection: injection,
            once: once,
          );
          registrations.add(TavernScriptInjectionRegistration(id: injection.id, registrationVersion: version));
        }
        workspace.effects.add({'operation': 'injectPrompts', 'scope': 'preview', 'leaseId': leaseId});
        return TavernScriptInjectionLease(
          leaseId: leaseId,
          chatId: workspace.chat.id,
          ownerContextId: context.id,
          ownerInstanceId: context.instanceId,
          registrations: registrations,
        );
      });

  @override
  Future<void> uninjectPrompts(List<String> ids) => _call(TavernAuthoringRuntimeOperation.uninjectPrompts, () {
    final captured = List<String>.of(ids);
    if (captured.any((id) => id.isEmpty)) {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'uninjectPrompts', 'Injection ids must be nonempty.');
    }
    for (final id in captured) {
      workspace.scripts._localRegistrations.remove(id);
    }
    workspace.effects.add({'operation': 'uninjectPrompts', 'scope': 'preview', 'ids': captured});
  });

  @override
  Future<void> releaseInjectionLease(String leaseId) =>
      _call(TavernAuthoringRuntimeOperation.releaseInjectionLease, () {
        workspace.scripts._localRegistrations.removeWhere((_, value) => value.leaseId == leaseId);
        workspace.effects.add({'operation': 'releaseInjectionLease', 'scope': 'preview', 'leaseId': leaseId});
      });

  @override
  Future<List<TavernScriptInjectionView>> listInjections() => _call(TavernAuthoringRuntimeOperation.listInjections, () {
    final result = <TavernScriptInjectionView>[];
    final scripts = workspace.scripts;
    for (final entry in _persistentScriptInjections(
      workspace.chat.id,
      workspace.metadataFor(workspace.chat.currentLeafId),
    ).entries) {
      final raw = _captureScriptJson(entry.value);
      final parsed = _parsePersistentScriptInjection(workspace.chat.id, entry.key, raw);
      result.add(
        TavernScriptInjectionView(
          source: TavernScriptInjectionSource.persistent,
          sourceRef: parsed.sourceRef,
          raw: raw,
          injection: parsed.injection,
          filterStatus: parsed.filterStatus,
          issues: parsed.issues,
        ),
      );
    }
    for (final registration in scripts._localRegistrations.values) {
      final candidate = _transientScriptInjection(registration, assemblerId: scripts.identity('view'));
      result.add(
        TavernScriptInjectionView(
          source: TavernScriptInjectionSource.transient,
          sourceRef: candidate.sourceRef,
          raw: candidate.raw,
          injection: candidate.injection,
          filterStatus: candidate.filterStatus,
          ownerContextId: registration.ownerContextId,
          ownerInstanceId: registration.ownerInstanceId,
          registrationVersion: registration.version,
          once: registration.once,
          claimed: registration.claimed,
          leaseId: registration.leaseId,
        ),
      );
    }
    return List.unmodifiable(result);
  });
}

/// Owns actual host work. A failed close deliberately remains an engine
/// operation; it must never be reported as a successfully drained cancel.
final class _AuthoringPromptHostOwner {
  _AuthoringPromptHostOwner(this.host, this.cancellation) {
    unawaited(
      cancellation.whenCancelled.then<void>((_) {
        stop();
      }),
    );
  }
  final TavernAuthoringPromptHost host;
  final ModelCancellation cancellation;
  TavernAuthoringPromptSession? session;
  TavernAuthoringScriptBinding? binding;
  TavernScriptCancellation? sourceInvalidated;
  _AuthoringRenderReader? reader;
  _AuthoringScriptWorkspace? workspace;
  _AuthoringPromptRuntime? active;
  Future<void>? closing;
  bool closeFailed = false;
  final calls = <Map<String, Object?>>[];

  void stop() {
    active?.stop();
    workspace?.stop();
    reader?.stop();
    startClose();
  }

  void startClose() {
    final current = session;
    if (current == null || closing != null) {
      return;
    }
    final completed = Completer<void>();
    final future = closing = completed.future;
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(
      Future<void>.sync(current.close).then<void>(
        (_) {
          completed.complete();
        },
        onError: (Object error, StackTrace stack) {
          completed.completeError(error, stack);
        },
      ),
    );
  }

  Future<void> open(TavernAuthoringPromptHostCapture capture, _AuthoringScriptWorkspace local) async {
    workspace = local;
    cancellation.check();
    session = await Future<TavernAuthoringPromptSession>.sync(
      () => host.openPromptPreview(capture, _AuthoringRenderToken(cancellation)),
    );
    if (cancellation.isCancelled) {
      startClose();
    }
    cancellation.check();
    final declared = binding = session!.binding;
    sourceInvalidated = session!.sourceInvalidated;
    final contexts = <String>{};
    final filters = <String>{};
    if (declared.hostEpoch.isEmpty) {
      _unsupportedAuthoringScript('The isolated host has no source epoch.');
    }
    for (final source in declared.lifecycleSources) {
      if (source.contextId.isEmpty ||
          source.instanceId.isEmpty ||
          source.manifestVersion.isEmpty ||
          !contexts.add('${source.contextId}\u0000${source.instanceId}') ||
          source.handlers.any((name) => name != 'GENERATION_STARTED' && name != 'GENERATION_AFTER_COMMANDS')) {
        _unsupportedAuthoringScript('The isolated lifecycle manifest is incomplete or ambiguous.');
      }
    }
    for (final source in declared.filterSources) {
      if (source.ref.contextId.isEmpty ||
          source.ref.instanceId.isEmpty ||
          source.ref.callbackId.isEmpty ||
          source.sourceVersion.isEmpty ||
          !filters.add(_authoringCallbackKey(source.ref))) {
        _unsupportedAuthoringScript('The isolated callback manifest is incomplete or ambiguous.');
      }
    }
    if (local.scripts.hasLiveHost &&
        local.scripts.activeContexts.any((context) => !contexts.contains('${context.id}\u0000${context.instanceId}'))) {
      _unsupportedAuthoringScript('Every active preparation context needs an explicit source inventory.');
    }
  }

  Future<T> _invoke<T>(TavernScriptContext context, Future<T> Function(_AuthoringPromptRuntime runtime) action) async {
    cancellation.check();
    final runtime = active = _AuthoringPromptRuntime(workspace!, context, binding!, cancellation);
    try {
      return await Future<T>.sync(() => action(runtime));
    } finally {
      runtime.stop();
      await runtime.drain();
      active = null;
      cancellation.check();
      if (runtime.unsupported) {
        _unsupportedAuthoringScript('A handler used an undeclared or unsupported local operation.');
      }
    }
  }

  void _issues(Iterable<TavernAuthoringIssue> values, TavernScriptContext context, String stage) {
    workspace!.turn.hookIssues.addAll(
      values.map(
        (issue) => TavernScriptIssue(
          code: issue.type,
          message: issue.message,
          committed: false,
          contextId: context.id,
          generationId: workspace!.turn.generationId,
          stage: stage,
          details: const {'scope': 'preview'},
        ),
      ),
    );
  }

  Future<void> prepare(String requestId, String captureId) async {
    final local = workspace!;
    if (!local.scripts.hasLiveHost) {
      return;
    }
    for (final lifecycle in const ['GENERATION_STARTED', 'GENERATION_AFTER_COMMANDS']) {
      for (final context in local.scripts.activeContexts) {
        final source = binding!.lifecycleSources.firstWhere(
          (value) => value.contextId == context.id && value.instanceId == context.instanceId,
        );
        if (!source.handlers.contains(lifecycle)) {
          continue;
        }
        final id = local.scripts.identity('prepare');
        var status = 'failed';
        try {
          final result = await _invoke(
            context,
            (runtime) => session!.prepare(
              TavernAuthoringPreparationRequest(
                requestId: requestId,
                captureId: captureId,
                invocationId: id,
                context: context,
                lifecycle: lifecycle,
                runtime: runtime,
              ),
            ),
          );
          if (result.requestId != requestId ||
              result.captureId != captureId ||
              result.invocationId != id ||
              result.contextId != context.id ||
              result.instanceId != context.instanceId ||
              result.lifecycle != lifecycle) {
            _issues(
              [
                const TavernAuthoringIssue(
                  type: 'hookFailure',
                  message: 'The isolated handler returned a different invocation identity.',
                ),
              ],
              context,
              lifecycle,
            );
            continue;
          }
          _issues(result.issues, context, lifecycle);
          status = result.status.name;
          if (result.status == TavernAuthoringCallbackStatus.unsupported) {
            _unsupportedAuthoringScript('The isolated preparation handler requires an unavailable capability.');
          }
          if (result.status != TavernAuthoringCallbackStatus.completed) {
            _issues(
              [
                TavernAuthoringIssue(
                  type: result.status == TavernAuthoringCallbackStatus.cancelled ? 'cancelled' : 'hookFailure',
                  message: 'The isolated preparation handler did not complete.',
                ),
              ],
              context,
              lifecycle,
            );
          }
        } on TavernAuthoringException {
          rethrow;
        } catch (error) {
          cancellation.check();
          if (error is TavernScriptException) {
            _issues(
              [for (final issue in error.issues) TavernAuthoringIssue(type: issue.code, message: issue.message)],
              context,
              lifecycle,
            );
          }
          _issues(
            [
              TavernAuthoringIssue(
                type: 'hookFailure',
                message: 'The isolated preparation callback failed (${error.runtimeType}).',
              ),
            ],
            context,
            lifecycle,
          );
        } finally {
          calls.add({
            'invocationId': id,
            'contextId': context.id,
            'instanceId': context.instanceId,
            'lifecycle': lifecycle,
            'status': status,
          });
        }
      }
    }
  }

  Future<void> filter(
    String requestId,
    String captureId,
    Map<String, Object?> metadata,
    ChatJsonlMetadataSource? source,
  ) async {
    final local = workspace!;
    final used = <_ScriptInjectionCandidate>[];
    // This is the single post-preparation snapshot. Registrations created by
    // a filter cannot join it; replacement still invalidates a later claim.
    final candidates = local.scripts.candidates(metadata, source);
    for (final candidate in candidates) {
      cancellation.check();
      if (candidate.injection == null) {
        throw _scriptInjectionFailure(
          TavernScriptErrorCode.shapeMismatch,
          'A captured persistent injection cannot be prepared.',
          candidate,
          local.turn.generationId,
          issues: candidate.issues,
        );
      }
      if (candidate.filterStatus == 'unsupportedPersistent') {
        _unsupportedAuthoringScript('Serialized persistent filters have no isolated execution adapter.');
      }
      final ref = candidate.injection!.filter;
      if (ref == null) {
        used.add(candidate);
        continue;
      }
      final context = local.scripts.activeContexts
          .where((value) => value.id == ref.contextId && value.instanceId == ref.instanceId)
          .firstOrNull;
      if (context == null) {
        throw _scriptInjectionFailure(
          TavernScriptErrorCode.callbackUnavailable,
          'The filter owner is absent from this capture.',
          candidate,
          local.turn.generationId,
        );
      }
      if (!binding!.filterSources.any((value) => _authoringSameCallback(value.ref, ref))) {
        _unsupportedAuthoringScript('The filter has no complete isolated source and closure inventory.');
      }
      final id = local.scripts.identity('filter');
      final TavernAuthoringFilterResult result;
      try {
        result = await _invoke(
          context,
          (runtime) => session!.filter(
            TavernAuthoringFilterRequest(
              requestId: requestId,
              captureId: captureId,
              invocationId: id,
              ref: ref,
              runtime: runtime,
            ),
          ),
        );
      } on TavernAuthoringException {
        rethrow;
      } catch (error) {
        cancellation.check();
        if (error is TavernScriptException && error.code == TavernScriptErrorCode.cancelled) {
          throw const TavernAuthoringException('cancelled', 'The isolated filter was cancelled.');
        }
        throw _scriptInjectionFailure(
          TavernScriptErrorCode.hookFailure,
          'The isolated filter failed (${error.runtimeType}).',
          candidate,
          local.turn.generationId,
          issues: error is TavernScriptException ? error.issues : const [],
        );
      }
      if (result.requestId != requestId ||
          result.captureId != captureId ||
          result.invocationId != id ||
          !_authoringSameCallback(result.ref, ref)) {
        throw _scriptInjectionFailure(
          TavernScriptErrorCode.hookFailure,
          'The isolated filter returned a different invocation identity.',
          candidate,
          local.turn.generationId,
        );
      }
      _issues(result.issues, context, 'injectionFilter');
      calls.add({
        'invocationId': id,
        'callback': _authoringCallbackKey(ref),
        'status': result.status.name,
        'value': result.value,
      });
      if (result.status == TavernAuthoringCallbackStatus.unsupported) {
        _unsupportedAuthoringScript('The isolated filter requires an unavailable capability.');
      }
      if (result.status == TavernAuthoringCallbackStatus.cancelled) {
        throw const TavernAuthoringException('cancelled', 'The isolated filter was cancelled.');
      }
      if (result.status != TavernAuthoringCallbackStatus.completed || result.value == null) {
        throw _scriptInjectionFailure(
          result.status == TavernAuthoringCallbackStatus.completed
              ? TavernScriptErrorCode.shapeMismatch
              : TavernScriptErrorCode.hookFailure,
          'A completed isolated filter must return a boolean.',
          candidate,
          local.turn.generationId,
        );
      }
      if (result.value!) {
        used.add(candidate);
      }
    }
    local.scripts.uses = _ScriptInjectionUseSet(used);
    local.turn.scriptInjectionUses = local.scripts.uses;
  }

  void checkSource() {
    cancellation.check();
    if (sourceInvalidated!.isCancelled) {
      _authoringScriptConflict();
    }
    workspace!.seal();
  }

  Future<void> closeAndDrain() async {
    stop();
    Object? readError;
    StackTrace? readStack;
    try {
      await reader?.drain();
      await active?.drain();
    } catch (error, stack) {
      readError = error;
      readStack = stack;
    }
    try {
      await closing;
    } catch (_) {
      closeFailed = true;
      rethrow;
    }
    if (readError != null) {
      Error.throwWithStackTrace(readError, readStack!);
    }
  }
}

String _authoringCallbackKey(TavernScriptCallbackRef ref) =>
    jsonEncode([ref.contextId, ref.instanceId, ref.callbackId]);
bool _authoringSameCallback(TavernScriptCallbackRef a, TavernScriptCallbackRef b) =>
    a.contextId == b.contextId && a.instanceId == b.instanceId && a.callbackId == b.callbackId;

Never _unsupportedAuthoringScript(String message) => throw TavernAuthoringException('unsupported_preview', message);
