part of 'engine.dart';

final class _AuthoringRunRecord implements TavernAuthoringRun {
  _AuthoringRunRecord(this.engine, this.input, this.config, {this.snapshot, this.promptHost, this.renderHost}) {
    currentRevision = snapshot?.currentRevision ?? input['draftRevision']! as int;
    if (snapshot != null) {
      answer.write(snapshot!.answer);
    }
    unawaited(_result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final TavernEngine engine;
  final Map<String, Object?> input;
  final TavernModelConfig? config;
  final TavernAuthoringPromptHost? promptHost;
  final TavernAuthoringPreviewHost? renderHost;
  _AuthoringImageBinding? imageBinding;
  Object? cleanupFailure;
  StackTrace? cleanupStack;
  final cancellation = ModelCancellation();
  final drained = Completer<void>();
  final _result = Completer<TavernAuthoringRunSnapshot>();
  final _events = StreamController<TavernAuthoringRunEvent>.broadcast();
  final answer = StringBuffer();
  final issues = <TavernAuthoringIssue>[];
  TavernAuthoringRunSnapshot? snapshot;
  TavernAuthoringToolReceipt? adoptedReceipt;
  TavernAuthoringRunStatus? terminalStatus;
  late int currentRevision;
  _AuthoringRequestRecord? activeRequest;
  var seq = 0;
  var admitted = false;
  var created = false;
  @override
  String get runId => input['runId']! as String;
  String get draftId => input['draftId']! as String;
  int get revision => currentRevision;
  bool get canPreview => input['previewContext'] != null && engine._counter is EstimatedTokenCounter;
  bool get canRender => imageBinding != null;
  TavernAuthoringRunSnapshot get publicView => _detachAuthoringRun(view);
  @override
  Future<TavernAuthoringRunSnapshot> get result => _result.future;
  @override
  Future<void> cancel() {
    cancellation.cancel();
    return drained.future;
  }

  Future<T> waitForChild<T>(Future<T> result, Future<void> childDrained) async {
    try {
      return await result;
    } finally {
      try {
        await childDrained;
      } catch (error, stack) {
        cleanupFailure = error;
        cleanupStack = stack;
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  TavernAuthoringRunSnapshot get view {
    final value = snapshot!;
    final active = activeRequest;
    final requests = [
      for (final request in value.requests)
        if (active == null || request.requestIndex != active.initial.requestIndex) request,
      if (active != null) active.view,
    ];
    return TavernAuthoringRunSnapshot(
      runId: value.runId,
      draftId: value.draftId,
      startRevision: value.startRevision,
      currentRevision: revision,
      status: terminalStatus ?? value.status,
      answer: answer.toString(),
      request: input,
      model: value.model,
      requests: requests,
      receipts: [
        ...value.receipts,
        if (adoptedReceipt != null && !value.receipts.any((receipt) => receipt.receiptId == adoptedReceipt!.receiptId))
          adoptedReceipt!,
      ],
      usage: summarizeToolUsage([
        for (final request in requests) (requestIndex: request.requestIndex, usage: request.usage),
      ]),
      issues: [
        ...value.issues,
        for (final issue in issues)
          if (!value.issues.any((saved) => saved.type == issue.type && saved.message == issue.message)) issue,
      ],
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
    );
  }

  @override
  Stream<TavernAuthoringRunEvent> get events => Stream.multi((sink) {
    if (snapshot != null) {
      sink.add(
        TavernAuthoringRunEvent(
          runId: runId,
          seq: seq,
          kind: TavernAuthoringRunEventKind.snapshot,
          status: terminalStatus ?? snapshot!.status,
          draftRevision: revision,
          snapshot: publicView,
        ),
      );
    }
    if (drained.isCompleted) {
      sink.close();
      return;
    }
    final subscription = _events.stream.listen(sink.add, onDone: sink.close);
    sink.onCancel = subscription.cancel;
  });

  void emit(TavernAuthoringRunEventKind kind, {String? delta, String? receiptId}) {
    final value = snapshot;
    if (value == null || _events.isClosed) {
      return;
    }
    _events.add(
      TavernAuthoringRunEvent(
        runId: runId,
        seq: ++seq,
        kind: kind,
        status: terminalStatus ?? value.status,
        draftRevision: revision,
        delta: delta,
        receiptId: receiptId,
        snapshot: kind == TavernAuthoringRunEventKind.snapshot || kind == TavernAuthoringRunEventKind.terminal
            ? publicView
            : null,
      ),
    );
  }

  void publicationIssue(Object error) => issues.add(
    TavernAuthoringIssue(
      type: 'publication_failed',
      message: 'A committed authoring record could not finish publication (${error.runtimeType}).',
    ),
  );
}

final class _AuthoringRequestRecord {
  _AuthoringRequestRecord(this.initial) : status = initial.status;
  final TavernAuthoringRequestSnapshot initial;
  final text = StringBuffer(), reasoning = StringBuffer();
  final tools = ModelToolAccumulator();
  final streamingUsage = StreamingToolUsage();
  final attempts = <int>[];
  TavernAuthoringRequestStatus status;
  var usage = emptyToolUsageLedger();
  var legacyUsage = 0;
  var sawTools = false;
  var complete = false;
  var sealed = false;
  ModelFinished? finished;
  ModelToolBatch? batch;

  void observeUsage(ModelUsageReport report, {TavernUsage? normalized}) {
    if (report.transport == 'streaming' && report.origin != 'legacy_normalized') {
      streamingUsage.observe(report, normalizedUsage: normalized);
    } else {
      usage = recordToolUsageObservation(
        streamingUsage.record(usage).ledger,
        report: report,
        normalizedUsage: normalized,
      ).ledger;
      streamingUsage.clear();
    }
  }

  Map<String, Object?> get response => {
    'text': text.toString(),
    'reasoning': reasoning.toString(),
    'attempts': attempts,
    'responseComplete': complete,
    'finishReason': finished?.reason,
    'assistant': finished?.assistantSnapshot?.toJson(),
    'toolBatch': batch?.toJson(),
    'usage': streamingUsage.record(usage).ledger,
  };

  TavernAuthoringRequestSnapshot get view => TavernAuthoringRequestSnapshot(
    runId: initial.runId,
    requestIndex: initial.requestIndex,
    status: status,
    body: initial.body,
    attempts: attempts,
    text: text.toString(),
    reasoning: reasoning.toString(),
    responseComplete: complete,
    finishReason: finished?.reason,
    assistant: finished?.assistantSnapshot?.toJson(),
    toolBatch: batch?.toJson(),
    usage: streamingUsage.record(usage).ledger,
    createdAt: initial.createdAt,
    updatedAt: initial.updatedAt,
  );
}

extension _AuthoringRuns on TavernEngine {
  TavernAuthoringRun _startAuthoringRun(
    TavernAuthoringRunRequest request, {
    TavernAuthoringPromptHost? promptHost,
    TavernAuthoringPreviewHost? renderHost,
  }) {
    _ensureAdmission();
    final Map<String, Object?> input;
    try {
      input = _captureScriptObject(request.toJson());
    } on TavernScriptException {
      _authoringInvalid('Authoring materials must be finite JSON.');
    }
    if (request.runId.isEmpty || request.draftId.isEmpty || request.draftRevision < 1 || request.instruction.isEmpty) {
      _authoringInvalid('Use nonempty run, draft and instruction values and a valid draft revision.');
    }
    final live = _authoringRuns[request.runId];
    if (live != null) {
      _checkAuthoringRunInput(live.input, input);
      return live;
    }
    final saved = _store.readAuthoringRunData(request.runId);
    if (saved != null) {
      _checkAuthoringRunInput(saved.request.toJson(), input);
      final replay = _AuthoringRunRecord(this, input, null, snapshot: saved);
      replay.drained.complete();
      replay._result.complete(_detachAuthoringRun(saved));
      unawaited(replay._events.close());
      return replay;
    }
    final selected = request.modelRole == TavernAuthoringModelRole.main ? _config : _auxiliaryModelConfig(_config);
    final config = TavernModelConfig(
      apiKey: selected.apiKey,
      baseUrl: selected.baseUrl,
      model: selected.model,
      deepseek: selected.deepseek,
      thinking: selected.thinking,
      headers: Map.unmodifiable(selected.headers),
    );
    if (!config.deepseek || config.thinking) {
      throw const TavernAuthoringException(
        'unsupported_model',
        'Author tools require the DeepSeek non-thinking Chat Completions profile.',
      );
    }
    _authoringView(_requireAuthoringDraft(request.draftId, request.draftRevision));
    final record = _AuthoringRunRecord(this, input, config, promptHost: promptHost, renderHost: renderHost);
    _authoringRuns[record.runId] = record;
    _operations.add(record.drained.future);
    try {
      _store.admitAuthoringRunData(
        input,
        {'provider': 'deepseek', 'model': config.model, 'modelRole': request.modelRole.name},
        onCommitted: (snapshot, created) {
          record.snapshot = snapshot;
          record.currentRevision = snapshot.currentRevision;
          record.admitted = true;
          record.created = created;
        },
      );
    } catch (error, stack) {
      if (!record.admitted) {
        _authoringRuns.remove(record.runId);
        _operations.remove(record.drained.future);
        record.drained.complete();
        record._result.completeError(error, stack);
        unawaited(record._events.close());
        rethrow;
      }
      record.publicationIssue(error);
    }
    record.emit(TavernAuthoringRunEventKind.snapshot);
    if (record.created) {
      unawaited(_driveAuthoringRun(record));
    } else {
      _finishAuthoringOwner(record);
    }
    return record;
  }

  Future<TavernAuthoringRunSnapshot?> _readAuthoringRun(String runId) => _authoringOperation(() {
    if (runId.isEmpty) {
      _authoringInvalid('The run id must be nonempty.');
    }
    return _authoringRuns[runId]?.publicView ?? _store.readAuthoringRunData(runId);
  });

  Future<List<TavernAuthoringRunSummary>> _listAuthoringRuns({String? draftId, int limit = 30, String? beforeRunId}) =>
      _authoringOperation(() {
        if (limit < 1 || limit > 100 || draftId == '' || beforeRunId == '') {
          _authoringInvalid('Use a limit from 1 to 100 and valid identifiers.');
        }
        return _store.listAuthoringRunData(draftId: draftId, limit: limit, beforeRunId: beforeRunId);
      });

  Future<TavernAuthoringToolReceipt?> _readAuthoringToolReceipt(String runId, String receiptId) =>
      _authoringOperation(() {
        if (runId.isEmpty || receiptId.isEmpty) {
          _authoringInvalid('Run and receipt ids must be nonempty.');
        }
        return _store.readAuthoringToolReceiptData(runId, receiptId);
      });

  Future<void> _cancelAuthoringRun(String runId) {
    final active = _authoringRuns[runId];
    if (active != null) {
      return active.cancel();
    }
    _ensureOpen();
    if (runId.isEmpty) {
      _authoringInvalid('The run id must be nonempty.');
    }
    if (_store.readAuthoringRunData(runId) == null) {
      throw const TavernAuthoringException('not_found', 'The authoring run does not exist.');
    }
    return Future.value();
  }

  void _cancelAuthoringRuns() {
    for (final record in _authoringRuns.values) {
      record.cancellation.cancel();
    }
  }

  Future<void> _driveAuthoringRun(_AuthoringRunRecord record) async {
    Object? failure;
    StackTrace? failureStack;
    var status = TavernAuthoringRunStatus.completed;
    try {
      // The returned handle can be stopped before any model request is registered.
      await Future<void>.delayed(Duration.zero);
      record.cancellation.check();
      if (record.input['renderContext'] != null && record.renderHost != null) {
        record.imageBinding = _captureAuthoringImageBinding(_modelClient, record.config!, record.cancellation);
      }
      final draft = _authoringRunDraft(record);
      var messages = <Map<String, Object?>>[
        {'role': 'system', 'content': _authoringRunPrompt(record.canPreview, record.canRender)},
        {
          'role': 'user',
          'content': jsonEncode({
            'instruction': record.input['instruction'],
            'materials': record.input['materials'],
            'draftId': record.draftId,
            'draftRevision': record.revision,
            'sources': [
              for (final source in draft.sources)
                {
                  'physicalResourceId': source.physicalResourceId,
                  'kind': source.target.kind.name,
                  'origin': source.origin.name,
                  'sourceFormat': source.sourceFormat,
                },
            ],
            'changeIds': [for (final change in draft.changes) change.id],
            if (record.canPreview) 'previewContext': record.input['previewContext'],
            if (record.canRender) 'renderContext': record.input['renderContext'],
          }),
        },
      ];
      for (var index = 1; index <= 4; index++) {
        record.cancellation.check();
        _store.checkAuthoringRunDraft(record.runId, record.revision);
        final body = <String, Object?>{
          'model': record.config!.model,
          'stream': true,
          'thinking': {'type': 'disabled'},
          'messages': messages,
          'tools': _authoringRunTools(promptPreview: record.canPreview, renderPreview: record.canRender),
          'tool_choice': 'auto',
        };
        final response = await _consumeAuthoringRequest(record, index, body);
        record.cancellation.check();
        final batch = response.batch!;
        final needsTools = response.sawTools || response.finished?.reason == 'tool_calls';
        if (!needsTools) {
          _store.checkAuthoringRunDraft(record.runId, record.revision);
          break;
        }
        if (index == 4) {
          status = TavernAuthoringRunStatus.budget;
          record.issues.add(
            const TavernAuthoringIssue(
              type: 'budget_exhausted',
              message: 'The fourth response requires another tool request; this batch was not executed.',
            ),
          );
          break;
        }
        final assistant = response.finished?.assistantSnapshot;
        if (response.finished?.reason != 'stop' && response.finished?.reason != 'tool_calls' ||
            batch.calls.isEmpty ||
            batch.resourceOverflow ||
            batch.hasUnassignedFragment ||
            batch.metadataConflict ||
            batch.unsupportedEnvelope ||
            !batch.finalIdentityComplete ||
            !batch.originalArgumentsStringComplete ||
            assistant == null ||
            !_sameAssistantCalls(assistant, batch)) {
          throw const TavernAuthoringException(
            'protocol_invalid',
            'The complete tool batch cannot be returned with its actual assistant identities.',
          );
        }
        final outputs = <Map<String, Object?>>[];
        final images = <Map<String, Object?>>[];
        for (final call in batch.calls) {
          record.cancellation.check();
          final executed = await _executeAuthoringTool(record, index, call);
          final receipt = executed.receipt;
          outputs.add({'role': 'tool', 'tool_call_id': call.id, 'content': jsonEncode(receipt.toJson())});
          if (executed.image case final image?) {
            images.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text':
                      'Rendered preview for tool receipt ${receipt.receiptId}, draft revision ${receipt.beforeRevision}.',
                },
                image,
              ],
            });
          }
        }
        messages = [...messages, assistant.wireMessage, ...outputs, ...images];
      }
    } catch (error, stack) {
      if (record.cleanupFailure == null && error is TavernModelException && error.kind == TavernFailure.cancelled) {
        status = TavernAuthoringRunStatus.cancelled;
      } else if (record.cleanupFailure == null &&
          error is TavernAuthoringException &&
          (error.code == 'revision_conflict' || error.code == 'not_found')) {
        status = TavernAuthoringRunStatus.conflict;
        record.issues.add(TavernAuthoringIssue(type: error.code, message: error.message));
      } else {
        status = TavernAuthoringRunStatus.failed;
        failure = error;
        failureStack = stack;
        record.issues.add(
          TavernAuthoringIssue(
            type: error is TavernAuthoringException ? error.code : error.runtimeType.toString(),
            message: error is TavernModelException
                ? error.detail
                : error is TavernAuthoringException
                ? error.message
                : 'Authoring failed (${error.runtimeType}).',
          ),
        );
      }
    }
    try {
      var adopted = false;
      try {
        _store.finishAuthoringRunData(
          record.runId,
          status,
          answer: record.answer.toString(),
          issues: record.issues,
          onCommitted: (value) {
            record.snapshot = value;
            if (record.activeRequest?.sealed == true) {
              record.activeRequest = null;
            }
            adopted = true;
          },
        );
      } catch (error) {
        if (!adopted) {
          rethrow;
        }
        record.publicationIssue(error);
        try {
          _store.noteAuthoringRunIssueData(record.runId, record.issues.last);
        } catch (_) {
          /* The original terminal fact and publication issue remain available in the live handle. */
        }
      }
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
      record.issues.add(
        const TavernAuthoringIssue(
          type: 'terminal_record_failed',
          message:
              'The live run ended, but its terminal record could not be saved. Reopening will interrupt the saved unfinished run.',
        ),
      );
    } finally {
      record.terminalStatus = status;
      _finishAuthoringOwner(record, error: failure, stack: failureStack);
    }
  }

  void _finishAuthoringOwner(_AuthoringRunRecord record, {Object? error, StackTrace? stack}) {
    // A failed child close stays in its own operation gate. Retain this handle
    // too so a repeated cancellation cannot claim that cleanup succeeded.
    if (record.cleanupFailure == null &&
        record.snapshot?.status != TavernAuthoringRunStatus.running &&
        record.activeRequest == null) {
      _authoringRuns.remove(record.runId);
    }
    _operations.remove(record.drained.future);
    if (record.cleanupFailure == null) {
      record.drained.complete();
    } else {
      record.drained.completeError(record.cleanupFailure!, record.cleanupStack!);
    }
    record.emit(TavernAuthoringRunEventKind.terminal);
    if (error == null) {
      record._result.complete(record.publicView);
    } else {
      record._result.completeError(error, stack);
    }
    unawaited(record._events.close());
  }

  TavernAuthoringDraft _authoringRunDraft(_AuthoringRunRecord record) =>
      _authoringView(_requireAuthoringDraft(record.draftId, record.revision));

  Future<_AuthoringRequestRecord> _consumeAuthoringRequest(
    _AuthoringRunRecord record,
    int index,
    Map<String, Object?> body,
  ) async {
    TavernAuthoringRequestSnapshot? admitted;
    try {
      _store.registerAuthoringRequestData(
        record.runId,
        index,
        body,
        onCommitted: (value) {
          admitted = value;
        },
      );
    } catch (error) {
      if (admitted == null) {
        rethrow;
      }
      record.publicationIssue(error);
    }
    final request = _AuthoringRequestRecord(admitted!);
    record.activeRequest = request;
    record.snapshot = _store.readAuthoringRunData(record.runId)!;
    record.emit(TavernAuthoringRunEventKind.request);
    Object? failure;
    StackTrace? failureStack;
    final context = ModelRequestContext(cancellation: record.cancellation, onUsageReport: request.observeUsage);
    StreamSubscription<ModelDelta>? subscription;
    Future<void>? sourceDrain;
    final done = Completer<void>();
    unawaited(done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    Future<void> cancelSource() => sourceDrain ??= subscription?.cancel() ?? Future.value();
    void fail(Object error, StackTrace stack) {
      if (!done.isCompleted) {
        done.completeError(error, stack);
        // Stop the actual transport wait too; cancelling only the stream
        // subscription cannot interrupt an accepted body or pending key.
        record.cancellation.cancel();
      }
    }

    try {
      record.cancellation.check();
      final stream = _modelClient.generate(
        config: record.config!,
        body: body,
        cancellation: context,
        onRequestStarted: (attempt) {
          if (!request.attempts.contains(attempt)) {
            request.attempts.add(attempt);
          }
          request.status = TavernAuthoringRequestStatus.running;
          var adopted = false;
          try {
            _store.recordAuthoringAttemptData(
              record.runId,
              index,
              attempt,
              onCommitted: () {
                adopted = true;
              },
            );
          } catch (error, stack) {
            if (adopted) {
              record.publicationIssue(error);
            } else {
              fail(error, stack);
            }
          }
        },
      );
      subscription = stream.listen(
        (delta) {
          if (done.isCompleted) {
            return;
          }
          try {
            record.cancellation.check();
            switch (delta) {
              case ModelText(:final text):
                request.text.write(text);
                record.answer.write(text);
                if (text.isNotEmpty) {
                  record.emit(TavernAuthoringRunEventKind.text, delta: text);
                }
              case ModelReasoning(:final text):
                request.reasoning.write(text);
              case ModelToolFragment():
                request.sawTools = true;
                request.tools.add(delta);
              case ModelUsage(:final usage, :final report):
                request.observeUsage(
                  report ?? ModelUsageReport.legacyNormalized(observationIndex: request.legacyUsage++),
                  normalized: usage,
                );
              case ModelFinished():
                if (request.finished != null) {
                  throw const TavernModelException(TavernFailure.server, 'duplicate_authoring_finish');
                }
                request.finished = delta;
                if (delta.finalUsageReport != null) {
                  request.observeUsage(delta.finalUsageReport!);
                }
            }
          } catch (error, stack) {
            fail(error, stack);
          }
        },
        onError: fail,
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );
      unawaited(
        record.cancellation.whenCancelled.then<void>((_) async {
          if (done.isCompleted) {
            return;
          }
          try {
            await cancelSource();
            fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'), StackTrace.current);
          } catch (error, stack) {
            fail(error, stack);
          }
        }),
      );
      await done.future;
      record.cancellation.check();
      if (request.finished == null) {
        throw const TavernModelException(TavernFailure.server, 'authoring_response_incomplete');
      }
      request.complete = true;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      context.closeObservations();
      try {
        await cancelSource();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      request.batch = request.tools.finish();
      var adopted = false;
      final status = failure == null
          ? TavernAuthoringRequestStatus.completed
          : failure is TavernModelException && failure.kind == TavernFailure.cancelled
          ? TavernAuthoringRequestStatus.cancelled
          : TavernAuthoringRequestStatus.failed;
      try {
        _store.finishAuthoringRequestData(
          record.runId,
          index,
          status: status,
          response: request.response,
          answer: record.answer.toString(),
          onCommitted: () {
            request.status = status;
            request.sealed = true;
            adopted = true;
          },
        );
      } catch (error, stack) {
        if (adopted) {
          record.publicationIssue(error);
        } else {
          request.status = TavernAuthoringRequestStatus.failed;
          failure ??= error;
          failureStack ??= stack;
          record.issues.add(
            TavernAuthoringIssue(
              type: 'request_record_failed',
              message:
                  'Request $index response evidence could not be saved. Its durable row is incomplete; absent attempt markers do not prove that it was not sent.',
            ),
          );
        }
      }
      try {
        record.snapshot = _store.readAuthoringRunData(record.runId)!;
        if (request.sealed) {
          record.activeRequest = null;
        }
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    return request;
  }

  Future<({TavernAuthoringToolReceipt receipt, Map<String, Object?>? image})> _executeAuthoringTool(
    _AuthoringRunRecord record,
    int index,
    ModelToolCall call,
  ) async {
    final receiptId = '$index:${call.index}';
    final prior = _store.readAuthoringToolReceiptData(record.runId, receiptId);
    if (prior != null) {
      if (prior.callId != call.id || prior.toolName != call.name || prior.arguments != call.arguments) {
        throw const TavernAuthoringException(
          'operation_conflict',
          'The authoring call already has different parameters.',
        );
      }
      return (receipt: prior, image: null);
    }
    final stored = _requireAuthoringDraft(record.draftId, record.revision);
    final draft = _authoringView(stored);
    var status = TavernAuthoringToolStatus.succeeded;
    Map<String, Object?>? next;
    var changes = <String>[];
    late Map<String, Object?> result;
    TavernAuthoringPromptRequest? promptRequest;
    TavernAuthoringRenderRequest? renderRequest;
    Map<String, Object?>? imagePart;
    try {
      final parameters = call.parameters;
      if (!call.valid || call.unsupportedEnvelope || call.type != 'function' || parameters == null) {
        _authoringInvalid('The call does not contain valid JSON parameters for a supported function.');
      }
      if (call.name == 'prompt_preview') {
        promptRequest = _authoringPromptToolRequest(record, receiptId, parameters);
      } else if (call.name == 'render_preview') {
        renderRequest = _authoringRenderToolRequest(record, receiptId, parameters);
      } else {
        final prepared = await _prepareAuthoringTool(record, stored, draft, call.name!, parameters);
        result = prepared.result;
        next = prepared.draftData;
        changes = prepared.changeIds;
      }
      record.cancellation.check();
    } on TavernAuthoringException catch (error) {
      if (error.code == 'revision_conflict' || error.code == 'not_found') {
        rethrow;
      }
      status = TavernAuthoringToolStatus.rejected;
      result = {
        'code': error.code,
        'message': error.message,
        'physicalResourceId': ?error.physicalResourceId,
        'changeId': ?error.changeId,
      };
    } on FormatException catch (error) {
      status = TavernAuthoringToolStatus.rejected;
      result = {'code': 'invalid_change', 'message': error.message};
    } on ArgumentError {
      status = TavernAuthoringToolStatus.rejected;
      result = {'code': 'invalid_change', 'message': 'A tool parameter has an invalid value.'};
    } on TypeError {
      status = TavernAuthoringToolStatus.rejected;
      result = {'code': 'invalid_change', 'message': 'A tool parameter has an invalid type.'};
    }
    if (promptRequest != null) {
      // Only argument construction belongs to the rejection catches above.
      // A real capture/assembler error keeps its original exception and stack.
      final task = _startAuthoringPrompt(promptRequest, cancellation: record.cancellation, host: record.promptHost);
      final preview = await record.waitForChild(task.result, task.drained.future);
      record.cancellation.check();
      result = preview.toJson();
      status = preview.status == TavernAuthoringPreviewStatus.complete
          ? TavernAuthoringToolStatus.succeeded
          : TavernAuthoringToolStatus.rejected;
    }
    if (renderRequest != null) {
      final task = _startAuthoringRender(renderRequest, record.renderHost!, cancellation: record.cancellation);
      final rendered = await record.waitForChild(task.result, task.drained.future);
      record.cancellation.check();
      result = _authoringRenderReceipt(rendered);
      status = TavernAuthoringToolStatus.rejected;
      if (rendered.status == TavernAuthoringRenderStatus.complete) {
        final image = _AcceptedAuthoringImage(rendered);
        final binding = record.imageBinding!;
        result['imageInput'] = binding.descriptor;
        if (binding.accepts(image)) {
          imagePart = binding.encode(image, record.cancellation);
          status = TavernAuthoringToolStatus.succeeded;
        } else {
          result['code'] = 'unsupported_image_input';
          result['message'] = 'The actual rendered image exceeds this adapter\'s formats or dimensions/byte limits.';
        }
      }
    }
    record.cancellation.check();
    TavernAuthoringToolReceipt? adopted;
    try {
      _store.commitAuthoringToolData(
        record.runId,
        requestIndex: index,
        callIndex: call.index,
        callId: call.id!,
        toolName: call.name!,
        arguments: call.arguments,
        revision: record.revision,
        status: status,
        result: result,
        changeIds: changes,
        draftData: next,
        onCommitted: (value) {
          adopted = value;
          record.currentRevision = value.afterRevision;
          record.adoptedReceipt = value;
        },
      );
    } catch (error) {
      if (adopted == null) {
        rethrow;
      }
      record.publicationIssue(error);
    }
    record.snapshot = _store.readAuthoringRunData(record.runId)!;
    record.adoptedReceipt = null;
    record.emit(TavernAuthoringRunEventKind.receipt, receiptId: receiptId);
    return (receipt: adopted!, image: imagePart);
  }

  Future<({Map<String, Object?> result, Map<String, Object?>? draftData, List<String> changeIds})>
  _prepareAuthoringTool(
    _AuthoringRunRecord record,
    StoredAuthoringDraft stored,
    TavernAuthoringDraft draft,
    String name,
    Map<String, Object?> parameters,
  ) async {
    Map<String, Object?> result;
    if (const ['card_write', 'lore_write', 'regex_write', 'preset_write'].contains(name)) {
      _authoringToolKeys(parameters, const {'physicalResourceId', 'changes'});
      final id = parameters['physicalResourceId'];
      final source = draft.sources.where((source) => source.physicalResourceId == id).firstOrNull;
      if (source == null) {
        _authoringInvalid('Select a source already present in this draft.');
      }
      final raw = parameters['changes'];
      if (raw is! List<Object?> || raw.isEmpty) {
        _authoringInvalid('Supply at least one draft change.');
      }
      final added = <TavernAuthoringChange>[];
      for (final item in raw) {
        if (item is! Map<String, Object?>) {
          _authoringInvalid('Each change must be an object.');
        }
        _authoringToolKeys(item, const {'id', 'path', 'operation', 'value', 'dependsOn'});
        final path = item['path'];
        if (item['id'] is! String ||
            path is! String ||
            item['operation'] != 'set' && item['operation'] != 'remove' ||
            item['operation'] == 'set' && !item.containsKey('value') ||
            item['dependsOn'] != null &&
                (item['dependsOn'] is! List<Object?> ||
                    (item['dependsOn']! as List<Object?>).any((value) => value is! String))) {
          _authoringInvalid('A change requires id, JSON Pointer path, operation and string dependencies.');
        }
        _authoringToolSource(name, source, path);
        added.add(
          _authoringChange({
            ...item,
            'physicalResourceId': source.physicalResourceId,
            'dependsOn': item['dependsOn'] ?? <String>[],
          }),
        );
      }
      final all = [...draft.changes, ...added];
      final data = <String, Object?>{
        ...stored.data,
        'changes': [for (final change in all) _authoringChangeJson(change)],
      };
      final candidate = _authoringView(
        StoredAuthoringDraft(
          id: stored.id,
          revision: stored.revision,
          data: data,
          createdAt: stored.createdAt,
          updatedAt: stored.updatedAt,
        ),
      );
      final materialized = _materializeAuthoring(candidate, all.map((change) => change.id).toSet());
      final ids = added.map((change) => change.id).toList();
      return (
        result: {
          'draftRevision': draft.draftRevision + 1,
          'changeIds': ids,
          'diffs': [
            for (final diff in materialized.diffs)
              if (ids.contains(diff.changeId)) _authoringRunDiff(diff),
          ],
        },
        draftData: data,
        changeIds: ids,
      );
    }
    if (name == 'draft_read') {
      _authoringToolKeys(parameters, const {});
      final materialized = _materializeAuthoring(draft, draft.changes.map((change) => change.id).toSet());
      result = {
        'draftId': draft.id,
        'draftRevision': draft.draftRevision,
        'sources': [
          for (final source in draft.sources)
            {
              'physicalResourceId': source.physicalResourceId,
              'kind': source.target.kind.name,
              'origin': source.origin.name,
              'base': source.base,
              'candidate': materialized.candidates[source.physicalResourceId],
            },
        ],
        'changes': [for (final change in draft.changes) _authoringChangeJson(change)],
      };
    } else if (name == 'lint' || name == 'regex_test') {
      _authoringToolKeys(
        parameters,
        name == 'lint' ? const {'changeIds'} : const {'changeIds', 'physicalResourceId', 'scriptPath', 'text'},
      );
      final selection = parameters['changeIds'];
      if (selection != null && (selection is! List<Object?> || selection.any((id) => id is! String))) {
        _authoringInvalid('changeIds must be an array of strings.');
      }
      final selected = selection == null
          ? draft.changes.map((change) => change.id).toSet()
          : (selection as List<Object?>).cast<String>().toSet();
      final materialized = _materializeAuthoring(draft, selected, includeDiffs: false);
      if (name == 'lint') {
        final reports = <String, Object?>{}, findings = <String, Object?>{};
        for (final source in draft.sources) {
          record.cancellation.check();
          final inspected = await _inspectAuthoringSource(source, materialized.candidates[source.physicalResourceId]!);
          reports[source.physicalResourceId] = [for (final report in inspected.reports) report.toJson()];
          findings[source.physicalResourceId] = [for (final issue in inspected.issues) issue.toJson()];
        }
        result = {'reports': reports, 'issues': findings};
      } else {
        final id = parameters['physicalResourceId'], path = parameters['scriptPath'], text = parameters['text'];
        if (id is! String || path is! String || text is! String || !materialized.candidates.containsKey(id)) {
          _authoringInvalid('Select a source, regex script pointer and sample text.');
        }
        final value = _authoringLookup(materialized.candidates[id], _authoringPointer(path));
        if (!value.exists || value.value is! Map<String, Object?>) {
          _authoringInvalid('The script pointer must identify a regex object.');
        }
        final script = RegexScript.fromJson(value.value! as Map<String, Object?>);
        final compilation = await RegexEngine.checkScript(script, _regexWorker);
        record.cancellation.check();
        final match = compilation.status == RegexCompileStatus.compatible
            ? await _regexWorker.hasMatch(script.findRegex, text)
            : null;
        result = {
          'compilation': {'status': compilation.status.name, 'code': compilation.code, 'message': compilation.message},
          'match': match == null ? null : {'status': match.status.name, 'code': match.code, 'message': match.message},
        };
      }
    } else {
      throw const TavernAuthoringException('unsupported_tool', 'This tool is not available to the author run.');
    }
    return (result: result, draftData: null, changeIds: <String>[]);
  }
}

void _checkAuthoringRunInput(Object? a, Object? b) {
  bool same(Object? left, Object? right) {
    if (left is Map<String, Object?> && right is Map<String, Object?>) {
      return left.length == right.length &&
          left.keys.every((key) => right.containsKey(key) && same(left[key], right[key]));
    }
    if (left is List<Object?> && right is List<Object?>) {
      return left.length == right.length &&
          Iterable<int>.generate(left.length).every((index) => same(left[index], right[index]));
    }
    if (left is num && right is num && left.runtimeType != right.runtimeType) {
      return false;
    }
    return left == right;
  }

  if (!same(a, b)) {
    throw const TavernAuthoringException('run_id_conflict', 'This run id already has different input.');
  }
}

TavernAuthoringRunSnapshot _detachAuthoringRun(TavernAuthoringRunSnapshot value) =>
    TavernAuthoringRunSnapshot.fromJson(_authoringCopy(value.toJson())! as Map<String, Object?>);

void _authoringToolKeys(Map<String, Object?> parameters, Set<String> allowed) {
  if (parameters.keys.any((key) => !allowed.contains(key))) {
    _authoringInvalid('The tool contains an unknown parameter.');
  }
}

void _authoringToolSource(String name, TavernAuthoringSource source, String path) {
  final kind = source.target.kind;
  bool below(String root) => path == root || path.startsWith('$root/');
  final allowed = switch (name) {
    'card_write' => kind == TavernAuthoringTargetKind.character,
    'lore_write' =>
      kind == TavernAuthoringTargetKind.lorebook ||
          kind == TavernAuthoringTargetKind.character && below('/data/character_book'),
    'regex_write' =>
      kind == TavernAuthoringTargetKind.regexLibrary ||
          kind == TavernAuthoringTargetKind.character && below('/data/extensions/regex_scripts'),
    'preset_write' => kind == TavernAuthoringTargetKind.preset,
    _ => false,
  };
  if (!allowed) {
    _authoringInvalid('This tool cannot edit the selected resource field.', resourceId: source.physicalResourceId);
  }
}

Map<String, Object?> _authoringRunDiff(TavernAuthoringDiff diff) => {
  'changeId': diff.changeId,
  'physicalResourceId': diff.physicalResourceId,
  'path': diff.path,
  'beforeExists': diff.beforeExists,
  'before': diff.before,
  'afterExists': diff.afterExists,
  'after': diff.after,
};

TavernAuthoringPromptRequest _authoringPromptToolRequest(
  _AuthoringRunRecord record,
  String receiptId,
  Map<String, Object?> parameters,
) {
  if (!record.canPreview) {
    throw const TavernAuthoringException('unsupported_tool', 'This run has no supported prompt preview context.');
  }
  _authoringToolKeys(parameters, const {'changeIds', 'text', 'at', 'seed'});
  final selection = parameters['changeIds'];
  if (selection is! List<Object?> ||
      selection.any((id) => id is! String || id.isEmpty) ||
      selection.toSet().length != selection.length ||
      parameters['text'] is! String ||
      parameters['at'] is! String ||
      parameters['seed'] is! int) {
    _authoringInvalid('Supply distinct changeIds, text, a fixed ISO-8601 at value and an integer seed.');
  }
  return TavernAuthoringPromptRequest(
    requestId: '${record.runId}:preview:$receiptId',
    draftId: record.draftId,
    draftRevision: record.revision,
    changeIds: selection.cast<String>().toList(),
    context: TavernAuthoringPromptContext.fromJson(record.input['previewContext']! as Map<String, Object?>),
    text: parameters['text']! as String,
    at: DateTime.parse(parameters['at']! as String),
    seed: parameters['seed']! as int,
  );
}

List<Map<String, Object?>> _authoringRunTools({bool promptPreview = false, bool renderPreview = false}) {
  Map<String, Object?> definition(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'strict': false,
      'parameters': {'type': 'object', 'properties': properties, 'required': required, 'additionalProperties': false},
    },
  };
  const selection = {
    'type': 'array',
    'items': {'type': 'string'},
  };
  final writes = {
    'physicalResourceId': {'type': 'string'},
    'changes': {
      'type': 'array',
      'minItems': 1,
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['id', 'path', 'operation'],
        'properties': {
          'id': {'type': 'string'},
          'path': {'type': 'string'},
          'operation': {
            'type': 'string',
            'enum': ['set', 'remove'],
          },
          'value': <String, Object?>{},
          'dependsOn': selection,
        },
      },
    },
  };
  return [
    definition('draft_read', 'Read the saved bases, current candidates and draft changes.', {}, []),
    for (final name in const ['card_write', 'lore_write', 'regex_write', 'preset_write'])
      definition(
        name,
        'Append draft changes only. Use distinct ids and explicit dependencies for overlapping paths; replace an entire array to change its size.',
        writes,
        ['physicalResourceId', 'changes'],
      ),
    definition('lint', 'Inspect selected draft candidates with the real static import checks.', {
      'changeIds': selection,
    }, []),
    definition(
      'regex_test',
      'Compile and test one draft regex using the protected worker; skipped is not a negative match.',
      {
        'changeIds': selection,
        'physicalResourceId': {'type': 'string'},
        'scriptPath': {'type': 'string'},
        'text': {'type': 'string'},
      },
      ['physicalResourceId', 'scriptPath', 'text'],
    ),
    if (promptPreview)
      definition(
        'prompt_preview',
        'Prepare the actual prompt locally for the user-selected previewContext. Select changes explicitly; supply fixed time and seed. No roleplay HTTP or live write is performed.',
        {
          'changeIds': selection,
          'text': {'type': 'string'},
          'at': {'type': 'string', 'description': 'Fixed ISO-8601 timestamp, including Z for UTC.'},
          'seed': {'type': 'integer'},
        },
        ['changeIds', 'text', 'at', 'seed'],
      ),
    if (renderPreview)
      definition(
        'render_preview',
        'Render the user-selected renderContext with explicit selected changes. An accepted image can be included in the next author request; no live resource is adopted.',
        {'changeIds': selection},
        ['changeIds'],
      ),
  ];
}

String _authoringRunPrompt(bool promptPreview, bool renderPreview) {
  const preview =
      'prompt_preview uses only the user-selected previewContext. Supply explicit changeIds, text, fixed ISO-8601 at and integer seed. '
      'Only a complete result contains a prepared prompt; unsupported, conflict, failed or rejected results do not prove success. ';
  if (!renderPreview) {
    final ending = promptPreview
        ? '${preview}No render, network lookup, or simulation is available in this run.'
        : 'No prompt preview, render, network lookup, or simulation is available in this run.';
    return '$_authoringRunPromptBase$ending';
  }
  final preparation = promptPreview ? preview : 'No prompt preview is available in this run. ';
  return '$_authoringRunPromptBase$preparation'
      'render_preview uses only the user-selected renderContext. Supply explicit changeIds. '
      'Only an accepted complete render can provide an image; its receipt alone does not mean an image was sent. '
      'No network lookup or simulation is available in this run.';
}

const _authoringRunPromptBase =
    'You are an authoring assistant working on an independent persistent draft. '
    'Use draft_read to inspect complete sources. Only append edits to resources already in the draft. '
    'card_write edits character JSON; lore_write edits a standalone book or /data/character_book; '
    'regex_write edits the managed regex library or /data/extensions/regex_scripts; preset_write edits preset JSON. '
    'Changes use JSON Pointer set/remove and explicit dependencies on earlier overlapping changes. '
    'Preserve unknown fields and raw source meaning. Tools do not adopt, restore, save as, send a roleplay turn, or write live resources. '
    'There are at most four model requests including the first; any tool batch on the fourth response is not executed. '
    'Use the returned persisted receipts; never claim an edit or test that was rejected or skipped. ';
