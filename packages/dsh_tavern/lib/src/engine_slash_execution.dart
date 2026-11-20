part of 'engine.dart';

/// Hot, identity-owned Slash execution. This record never owns an App Future;
/// actual storage ownership is acquired by the effect ports when they start I/O.
class _SlashExecutionRecord implements TavernSlashExecution {
  _SlashExecutionRecord(this.owner, this.sourceText, this.initialPipe, Map<String, String> arguments)
    : arguments = Map.unmodifiable(arguments),
      _safePipe = initialPipe {
    owner.record = this;
    // Preserve the caller's original Future while observing a rejection even
    // when the caller does not subscribe or await result immediately.
    unawaited(_result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  final _SlashExecutionOwner owner;
  final String sourceText, initialPipe;
  final Map<String, String> arguments;
  final _result = Completer<TavernSlashResult>();
  final _observers = <MultiStreamController<TavernSlashExecutionEvent>>{};
  final _resolvedSources = <int, _SlashResolvedSourceUse>{};
  SlashSource? source;
  SlashFrame? evaluationFrame;
  late final _EngineSlashRuntime runtime;
  late final SlashExecutor executor;
  TavernSlashStatus status = TavernSlashStatus.parsing;
  TavernSlashExecutionEvent? terminal;
  TavernScriptGenerationResult? partialGeneration;
  TavernSlashWaitKind? _waitKind;
  SlashInvocation? _lastInvocation;
  SlashInvocation? _abortInvocation;
  String _safePipe;
  int seq = 0;
  bool _started = false;
  bool runtimeReady = false;

  @override
  String get id => owner.id;
  @override
  Future<TavernSlashResult> get result => _result.future;

  TavernSlashExecutionEvent _event(
    TavernSlashExecutionEventKind kind, {
    SlashInvocation? invocation,
    String? pipe,
    TavernScriptException? error,
    TavernSlashCompletion? completion,
    TavernSlashEffects? effects,
    List<TavernScriptIssue>? issues,
    TavernScriptGenerationResult? partial,
    bool snapshot = false,
  }) {
    final current = invocation ?? owner.current ?? _lastInvocation;
    return TavernSlashExecutionEvent(
      id: id,
      context: owner.context.value,
      seq: seq,
      kind: kind,
      status: status,
      effects: effects ?? owner.summary,
      pipe: pipe,
      commandIndex: current?.commandIndex,
      command: current?.spelling,
      sourceSpan: error?.sourceSpan ?? current?.sourceSpan ?? owner.currentSpan,
      waitKind: status == TavernSlashStatus.waiting ? _waitKind : null,
      completion: completion,
      error: error,
      partialGeneration: partial,
      lastSeq: snapshot ? seq : null,
      issues: issues ?? owner.issues,
    );
  }

  TavernSlashExecutionEvent _snapshot() {
    final ended = terminal;
    if (ended != null) {
      // Read the frozen terminal projection, not mutable owner collections.
      return TavernSlashExecutionEvent(
        id: id,
        context: ended.context,
        seq: ended.seq,
        kind: TavernSlashExecutionEventKind.snapshot,
        status: ended.status,
        effects: ended.effects,
        pipe: _safePipe,
        commandIndex: ended.commandIndex,
        command: ended.command,
        sourceSpan: ended.sourceSpan,
        completion: ended.completion,
        error: ended.error,
        partialGeneration: ended.partialGeneration,
        lastSeq: ended.seq,
        issues: ended.issues,
      );
    }
    return _event(TavernSlashExecutionEventKind.snapshot, pipe: _safePipe, snapshot: true);
  }

  @override
  Stream<TavernSlashExecutionEvent> get events => Stream<TavernSlashExecutionEvent>.multi((observer) {
    // Snapshot capture and observer registration are one synchronous section.
    // Each observer gets exactly one private snapshot and then later seq values.
    final snapshot = _snapshot();
    if (terminal != null) {
      observer.add(snapshot);
      observer.close();
      return;
    }
    _observers.add(observer);
    observer.onCancel = () {
      _observers.remove(observer);
    };
    observer.add(snapshot);
  }, isBroadcast: true);

  void _publish(TavernSlashExecutionEvent event) {
    for (final observer in _observers.toList()) {
      observer.add(event);
    }
  }

  void started() {
    if (_started || terminal != null) return;
    _started = true;
    status = TavernSlashStatus.parsing;
    seq++;
    _publish(_event(TavernSlashExecutionEventKind.started, pipe: _safePipe));
  }

  void waiting(TavernSlashWaitKind kind) {
    if (terminal != null) return;
    status = TavernSlashStatus.waiting;
    _waitKind = kind;
    seq++;
    _publish(_event(TavernSlashExecutionEventKind.waiting, pipe: _safePipe));
  }

  void commandFinished(SlashInvocation invocation, String publicPipe) {
    if (terminal != null) return;
    _lastInvocation = invocation;
    _safePipe = publicPipe;
    status = TavernSlashStatus.running;
    _waitKind = null;
    // A successful command consumes its partial child attribution. A later
    // unrelated failure must not inherit that earlier generation result.
    partialGeneration = null;
    seq++;
    _publish(_event(TavernSlashExecutionEventKind.command, invocation: invocation, pipe: publicPipe));
  }

  void recordAbort(SlashInvocation invocation, {required bool quiet, required String reason}) {
    if (terminal != null || _abortInvocation != null) return;
    _abortInvocation = invocation;
    owner.observeIssues([
      TavernScriptIssue(
        code: 'slashAbort',
        message: 'Script execution was aborted.',
        committed: owner.committed,
        contextId: owner.context.value.id,
        sourceSpan: invocation.sourceSpan,
        stage: TavernSlashEffectStage.handler.name,
        details: {'executionId': id, 'quiet': quiet, 'reason': reason},
      ),
    ]);
    // The language observes its abort signal at the selected fixed boundaries.
    // Do not complete result in the middle of a defaults/parameter phase.
  }

  void complete(SlashRunOutcome outcome) {
    if (terminal != null) return;
    final pipe = outcome.aborted ? '' : slashPublicPipe(outcome.pipe);
    _safePipe = pipe;
    partialGeneration = null;
    final completion = outcome.aborted ? TavernSlashCompletion.aborted : TavernSlashCompletion.completed;
    status = outcome.aborted ? TavernSlashStatus.aborted : TavernSlashStatus.completed;
    _waitKind = null;
    final effects = owner.summary;
    final issues = List<TavernScriptIssue>.of(owner.issues);
    seq++;
    terminal = _event(
      TavernSlashExecutionEventKind.finished,
      invocation: outcome.aborted ? _abortInvocation : _lastInvocation,
      pipe: pipe,
      completion: completion,
      effects: effects,
      issues: issues,
    );
    _retire();
    _result.complete(
      TavernSlashResult(
        id: id,
        context: owner.context.value,
        pipe: pipe,
        completion: completion,
        effects: effects,
        issues: issues,
      ),
    );
  }

  void fail(TavernScriptException error, StackTrace stack) {
    if (terminal != null) return;
    status = error.code == TavernScriptErrorCode.cancelled ? TavernSlashStatus.cancelled : TavernSlashStatus.failed;
    _waitKind = null;
    seq++;
    // A failed live event never retries projection of a rejected composite pipe.
    // A later snapshot retains the last successfully projected _safePipe.
    terminal = _event(
      TavernSlashExecutionEventKind.failed,
      error: error,
      effects: owner.summary,
      issues: error.issues,
      partial: partialGeneration,
    );
    _retire();
    _result.completeError(error, stack);
  }

  void _retire() {
    if (identical(owner.coordinator._slashExecutions[id], this)) {
      owner.coordinator._slashExecutions.remove(id);
    }
    final ended = terminal!;
    for (final observer in _observers.toList()) {
      observer.add(ended);
      observer.close();
    }
    _observers.clear();
  }
}

class _SlashResolvedSourceUse {
  const _SlashResolvedSourceUse({
    required this.sourceId,
    required this.assetId,
    required this.version,
    required this.callSite,
  });
  final String sourceId, assetId, version;
  final TavernScriptSourceSpan callSite;
}

/// Adapts the pure language to the actual coordinator. No handler, callback,
/// macro fragment or model generation is replayed to obtain a receipt.
class _EngineSlashRuntime implements SlashRuntimePort {
  _EngineSlashRuntime(this.owner);
  final _SlashExecutionOwner owner;
  final _active = <SlashInvocation>[];
  int _nextCommandIndex = 0;
  _ScriptCoordinator get coordinator => owner.coordinator;
  _SlashExecutionRecord get record => owner.record;

  @override
  void checkAlive() => owner.checkAlive();

  void _select(SlashInvocation invocation) {
    owner.current = invocation;
    owner.currentSpan = invocation.sourceSpan;
    owner.stage = TavernSlashEffectStage.handler;
    record.evaluationFrame = invocation.frame;
  }

  @override
  int enterCommand(SlashNode node, SlashFrame frame) {
    owner.checkAlive();
    final invocation = SlashInvocation(
      node: node,
      frame: frame,
      named: const {},
      unnamed: ScriptCoercion.undefined,
      unnamedParts: const [],
      incomingPipe: frame.pipe,
      commandIndex: _nextCommandIndex++,
      implicitPipe: false,
    );
    _active.add(invocation);
    _select(invocation);
    record.status = TavernSlashStatus.running;
    return invocation.commandIndex;
  }

  @override
  void invocationReady(SlashInvocation invocation) {
    final index = _active.lastIndexWhere((current) => current.commandIndex == invocation.commandIndex);
    if (index < 0) throw StateError('The Slash invocation is not active.');
    _active[index] = invocation;
    _select(invocation);
  }

  @override
  void commandFinished(SlashInvocation invocation, Object? pipe, String publicPipe) {
    record.commandFinished(invocation, publicPipe);
  }

  @override
  void leaveCommand(SlashInvocation invocation) {
    final index = _active.lastIndexWhere((current) => current.commandIndex == invocation.commandIndex);
    if (index >= 0) _active.removeAt(index);
    record._resolvedSources.remove(invocation.commandIndex);
    if (_active.isNotEmpty) {
      _select(_active.last);
    } else {
      owner.current = null;
      owner.currentSpan = invocation.sourceSpan;
      record.evaluationFrame = invocation.frame;
    }
  }

  @override
  void abort(SlashInvocation invocation, {required bool quiet, required String reason}) =>
      record.recordAbort(invocation, quiet: quiet, reason: reason);

  void _observeFailure(Object error) {
    if (error is TavernScriptException) owner.observeIssues(error.issues, committed: error.committed);
  }

  @override
  Future<Object?> expandPart(
    String text,
    SlashFrame frame,
    TavernScriptSourceSpan span,
    TavernSlashEffectStage phase,
  ) async {
    owner.checkAlive();
    owner.stage = phase;
    owner.currentSpan = span;
    record.evaluationFrame = frame;
    if (text.isEmpty) return '';
    try {
      final capture = await coordinator._captureMacroUnit(owner);
      try {
        owner.checkAlive();
        final environment = capture.environment;
        late final Object? value;
        try {
          value = const ScriptMacroAdapter().expand(
            text,
            environment._context,
            bindings: frame.bindings,
            legacy: environment.legacy,
            prepareCharacterFieldsOnDemand: environment.prepareCharacterFieldsOnDemand,
          );
        } catch (_) {
          capture.checkDependencies();
          rethrow;
        }
        capture.checkDependencies();
        owner.checkAlive();
        await coordinator._commitMacroUnit(owner, capture, stage: phase, operation: 'substituteMacros');
        owner.checkAlive();
        return value;
      } finally {
        coordinator._discardMacroUnit(owner, capture);
      }
    } catch (error) {
      _observeFailure(error);
      rethrow;
    }
  }

  @override
  Future<bool> resolveCondition(SlashInvocation invocation) async {
    owner.checkAlive();
    _select(invocation);
    try {
      final result = await coordinator._evaluateSlashCondition(_SlashInvocation(owner, invocation));
      owner.checkAlive();
      return result;
    } catch (error) {
      _observeFailure(error);
      rethrow;
    }
  }

  @override
  Future<Object?> invokeCommand(SlashInvocation invocation) async {
    owner.checkAlive();
    _select(invocation);
    try {
      final result = await coordinator._executeSlashHandler(_SlashInvocation(owner, invocation));
      owner.checkAlive();
      return result;
    } catch (error) {
      _observeFailure(error);
      rethrow;
    }
  }

  @override
  Future<TavernResolvedSlash> resolveSource(SlashInvocation invocation, String? setName, String label) async {
    owner.checkAlive();
    _select(invocation);
    try {
      final resolved = await coordinator._resolveSlashSource(
        _SlashInvocation(owner, invocation),
        TavernSlashReference(
          contextId: owner.context.value.id,
          label: label,
          setName: setName,
          sourceSpan: invocation.sourceSpan,
        ),
      );
      owner.checkAlive();
      final captured = TavernResolvedSlash(
        assetId: resolved.assetId,
        version: resolved.version,
        source: resolved.source,
      );
      record._resolvedSources[invocation.commandIndex] = _SlashResolvedSourceUse(
        sourceId: '${captured.assetId}@${captured.version}',
        assetId: captured.assetId,
        version: captured.version,
        callSite: invocation.sourceSpan,
      );
      return captured;
    } catch (error) {
      _observeFailure(error);
      rethrow;
    }
  }

  _SlashResolvedSourceUse? _resolvedUse(TavernScriptSourceSpan? span) {
    final sourceId = span?.sourceId;
    if (sourceId == null) return null;
    for (final invocation in _active.reversed) {
      final use = record._resolvedSources[invocation.commandIndex];
      if (use != null && use.sourceId == sourceId) return use;
    }
    return null;
  }

  List<TavernScriptSourceSpan> callSites(TavernScriptSourceSpan? failureSpan) {
    final result = <TavernScriptSourceSpan>[];
    void add(TavernScriptSourceSpan span) {
      if (!result.any((other) => _slashSameSpan(other, span))) result.add(span);
    }

    final resolved = _resolvedUse(failureSpan);
    if (resolved != null) add(resolved.callSite);
    for (final invocation in _active.reversed) {
      if (identical(invocation, _active.last) &&
          (failureSpan == null || failureSpan.sourceId == invocation.sourceSpan.sourceId)) {
        continue;
      }
      add(invocation.sourceSpan);
    }
    var frame = record.evaluationFrame;
    while (frame != null) {
      final site = frame.source?.callSite;
      if (site != null) add(site);
      frame = frame.parent;
    }
    return result;
  }

  TavernJsonObject? sourceDetails(TavernScriptSourceSpan? failureSpan) {
    final current = record.evaluationFrame?.source;
    if (current != null &&
        current.assetId != null &&
        current.version != null &&
        (failureSpan == null || failureSpan.sourceId == current.id)) {
      return {'assetId': current.assetId, 'version': current.version};
    }
    final resolved = _resolvedUse(failureSpan);
    return resolved == null ? null : {'assetId': resolved.assetId, 'version': resolved.version};
  }
}

extension _SlashExecutionOperations on _ScriptCoordinator {
  TavernSlashExecution _startSlash(
    String contextId,
    String sourceText, {
    String? executionId,
    String pipe = '',
    Map<String, String> arguments = const {},
  }) {
    final context = _context(contextId);
    if (executionId != null && executionId.isEmpty) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'triggerSlash',
        'Execution id must be nonempty.',
        contextId: contextId,
      );
    }
    final capturedArguments = Map<String, String>.of(arguments);
    final id = executionId ?? 'slash-${_newStateId()}';
    if (_slashExecutions.containsKey(id)) {
      throw _scriptError(
        TavernScriptErrorCode.duplicateId,
        'triggerSlash',
        'Execution id is active.',
        contextId: contextId,
      );
    }
    final owner = _SlashExecutionOwner(this, context, id);
    final record = _SlashExecutionRecord(owner, sourceText, pipe, capturedArguments);
    _slashExecutions[id] = record;
    record.started();
    unawaited(_runSlash(record));
    return record;
  }

  Future<void> _runSlash(_SlashExecutionRecord record) async {
    try {
      // Publish the real handle before parsing starts; parse failures still
      // belong to this registered record and its already observed result Future.
      await Future<void>.delayed(Duration.zero);
      record.owner.checkAlive();
      final source = SlashSource(record.sourceText, id: 'slash:${record.id}');
      record.source = source;
      final program = await SlashParser(source, checkCancelled: record.owner.checkAlive).parse();
      record.owner.checkAlive();
      record.runtime = _EngineSlashRuntime(record.owner);
      record.executor = SlashExecutor(record.runtime);
      record.runtimeReady = true;
      record.status = TavernSlashStatus.running;
      final outcome = await record.executor.execute(program, pipe: record.initialPipe, arguments: record.arguments);
      record.owner.checkAlive();
      record.complete(outcome);
    } catch (error, stack) {
      if (record.terminal == null) record.fail(_slashFailure(record, error), stack);
    }
  }

  Future<Object?> _invokeSlashClosure(
    _SlashInvocation invocation,
    SlashClosure closure, {
    Map<String, Object?> provided = const {},
    String? pipe,
  }) async {
    final owner = invocation.owner;
    owner.checkAlive();
    try {
      // The pure helper must preserve the caller's break owner. The run
      // command establishes its separate owner on its own language path.
      final result = await owner.record.executor.invokeClosure(
        invocation.language,
        closure,
        provided: provided,
        pipe: pipe,
      );
      owner.checkAlive();
      return result;
    } catch (error) {
      if (error is TavernScriptException) owner.observeIssues(error.issues, committed: error.committed);
      rethrow;
    }
  }

  TavernScriptException _slashFailure(_SlashExecutionRecord record, Object error) {
    final owner = record.owner;
    final original = error is TavernScriptException ? error : _scriptFailure(error);
    final cancellation = owner.cancellationFailure;
    owner.observeIssues(original.issues, committed: original.committed);
    if (cancellation != null) owner.observeIssues(cancellation.issues, committed: cancellation.committed);
    final known = <TavernScriptIssue>[...original.issues];
    if (cancellation != null) {
      _appendScriptIssuePropagation(known, cancellation.issues);
    }
    _appendScriptIssuePropagation(known, owner.issues);
    final code = cancellation?.code ?? (owner.token.isCancelled ? TavernScriptErrorCode.cancelled : original.code);
    final cancelled = code == TavernScriptErrorCode.cancelled;
    final span = original.sourceSpan ?? owner.currentSpan ?? owner.current?.sourceSpan;
    final current = owner.current;
    final callSites = record.runtimeReady ? record.runtime.callSites(span) : const <TavernScriptSourceSpan>[];
    final sourceDetails = record.runtimeReady ? record.runtime.sourceDetails(span) : null;
    final summary = owner.summary;
    final partial = record.partialGeneration;
    final message = cancellation?.message ?? (cancelled ? 'Script execution cancelled.' : original.message);
    final issue = TavernScriptIssue(
      code: 'slashExecution',
      message: message,
      committed: summary.committed,
      contextId: owner.context.value.id,
      sourceSpan: span,
      stage: owner.stage.name,
      cancelled: cancelled,
      details: {
        'executionId': record.id,
        'effects': summary.toJson(),
        if (current != null) 'commandIndex': current.commandIndex,
        if (current != null) 'command': current.spelling,
        if (callSites.isNotEmpty) 'callSites': [for (final site in callSites) _slashSpanJson(site)],
        'source': ?sourceDetails,
        if (partial != null) 'partialGeneration': _slashGenerationResultJson(partial),
      },
    );
    return TavernScriptException(
      code: code,
      operation: original.operation,
      message: message,
      contextId: owner.context.value.id,
      nodeId: original.nodeId,
      generationId: original.generationId,
      executionId: record.id,
      fieldPath: original.fieldPath,
      sourceSpan: span,
      committed: summary.committed,
      modelFailure: original.modelFailure,
      issues: [...known, issue],
      stateEdit: original.stateEdit,
    );
  }
}

bool _slashSameSpan(TavernScriptSourceSpan a, TavernScriptSourceSpan b) =>
    a.sourceId == b.sourceId && a.start == b.start && a.end == b.end && a.line == b.line && a.column == b.column;

TavernJsonObject _slashSpanJson(TavernScriptSourceSpan span) => {
  'sourceId': span.sourceId,
  'start': span.start,
  'end': span.end,
  'line': span.line,
  'column': span.column,
};

TavernJsonObject _slashGenerationResultJson(TavernScriptGenerationResult result) {
  final origin = result.origin;
  final anchor = origin.nodeAnchor;
  final usage = result.usage;
  return {
    'id': result.id,
    'text': result.text,
    'reasoning': result.reasoning,
    'finishReason': result.finishReason,
    'origin': {
      'contextId': origin.contextId,
      'instanceId': origin.instanceId,
      'provider': origin.provider,
      'model': origin.model,
      'chatId': origin.chatId,
      'nodeAnchor': anchor == null ? null : {'chatId': anchor.chatId, 'nodeId': anchor.nodeId},
      'emptyChatAnchor': origin.emptyChatAnchor,
    },
    'usage': usage == null
        ? null
        : {
            'promptTokens': usage.promptTokens,
            'cacheHitTokens': usage.cacheHitTokens,
            'completionTokens': usage.completionTokens,
            'model': usage.model,
          },
    'hookIssues': [for (final issue in result.hookIssues) _scriptIssueJson(issue)],
  };
}
