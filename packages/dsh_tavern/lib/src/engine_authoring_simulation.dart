part of 'engine.dart';

final class _AuthoringSimulationTurnRecord {
  _AuthoringSimulationTurnRecord(this.index, this.input);
  final int index;
  final String input;
  var status = TavernAuthoringSimulationStatus.running;
  _Turn? nativeTurn;
  TavernMessage? message;
  String? finishReason, logicalTurnId;
  Map<String, Object?>? failure, toolTurn;
  final helpers = <Map<String, Object?>>[];
  var hookIssues = <Map<String, Object?>>[];
  var evidenceRead = false;

  void observe(TavernEvent event) {
    switch (event) {
      case TavernTurnStarted():
        message = event.message;
        logicalTurnId = event.logicalTurnId;
      case TavernTurnDone():
        message = event.message;
        logicalTurnId = event.logicalTurnId;
        finishReason = event.finishReason;
        status = TavernAuthoringSimulationStatus.completed;
        hookIssues = [for (final issue in event.hookIssues) _scriptIssueJson(issue)];
      case TavernTurnFailed():
        message = event.partial;
        logicalTurnId = event.logicalTurnId;
        status = event.kind == TavernFailure.cancelled
            ? TavernAuthoringSimulationStatus.cancelled
            : TavernAuthoringSimulationStatus.failed;
        failure = {'kind': event.kind.name, 'detail': event.detail, 'toolFailureCode': event.toolFailureCode};
        hookIssues = [for (final issue in event.hookIssues) _scriptIssueJson(issue)];
      default:
        break;
    }
  }

  TavernAuthoringSimulationTurn get view => TavernAuthoringSimulationTurn(
    index: index,
    input: input,
    status: status,
    message: message,
    finishReason: finishReason,
    logicalTurnId: logicalTurnId,
    failure: failure == null ? null : _copy(failure!),
    toolTurn: toolTurn == null ? null : _copy(toolTurn!),
    helpers: [for (final item in helpers) _copy(item)],
    hookIssues: [for (final item in hookIssues) _copy(item)],
  );
}

final class _AuthoringSimulationTask implements TavernAuthoringSimulationTask {
  _AuthoringSimulationTask(
    this.request,
    this.captureId,
    TavernModelConfig main,
    TavernModelConfig helper,
    TavernModelClient delegate,
  ) {
    helperConfig = _ownConfig(helper, 'helper');
    config = _ownConfig(main, 'main', auxiliary: helperConfig);
    client = _AuthoringSimulationClient(this, delegate);
    unawaited(drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(_result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(
      cancellation.whenCancelled.then<void>((_) {
        startClose();
      }),
    );
  }
  final TavernAuthoringSimulationRequest request;
  final String captureId;
  late final TavernModelConfig config, helperConfig;
  late final _AuthoringSimulationClient client;
  final cancellation = ModelCancellation();
  final drained = Completer<void>();
  final _result = Completer<TavernAuthoringSimulationResult>();
  final requests = <_AuthoringSimulationRequestRecord>[];
  final turns = <_AuthoringSimulationTurnRecord>[];
  final keys = <Future<void>>[];
  final issues = <TavernAuthoringIssue>[];
  final helperIds = <String>{}, transientFacts = <String>{};
  var status = TavernAuthoringSimulationStatus.running;
  var origin = <String, Object?>{};
  final cleanup = <String, Object?>{'rootCreated': false, 'closeConfirmed': false, 'removed': false};
  Directory? directory;
  String? identity, chatId;
  var reserved = false, conflictingRoot = false, openStarted = false, openDrained = false;
  TavernEngine? temporary;
  Completer<void>? evidenceOwner;
  Future<void>? closing;

  TavernModelConfig _ownConfig(TavernModelConfig source, String role, {TavernModelConfig? auxiliary}) =>
      TavernModelConfig(
        apiKey: () {
          final Future<String?> original;
          try {
            original = source.apiKey();
          } catch (error) {
            issues.add(TavernAuthoringIssue(type: 'key_supplier_failed', message: '$role:${error.runtimeType}'));
            rethrow;
          }
          // Keep the original supplier Future and error in the transport. This
          // observer also owns a cancelled wait's eventual supplier completion.
          keys.add(
            original.then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                issues.add(TavernAuthoringIssue(type: 'key_supplier_failed', message: '$role:${error.runtimeType}'));
              },
            ),
          );
          return original;
        },
        baseUrl: source.baseUrl,
        model: source.model,
        deepseek: source.deepseek,
        thinking: source.thinking,
        headers: Map.unmodifiable(source.headers),
        auxiliary: auxiliary,
      );

  @override
  String get requestId => request.requestId;
  @override
  Future<TavernAuthoringSimulationResult> get result => _result.future;
  @override
  Future<void> cancel() {
    cancellation.cancel();
    startClose();
    return drained.future;
  }

  void adoptTemporary(TavernEngine value) {
    final evidence = Completer<void>();
    value._operations.add(evidence.future);
    evidenceOwner = evidence;
    temporary = value;
    if (cancellation.isCancelled) {
      startClose();
    }
  }

  void startClose() {
    final engine = temporary;
    if (engine == null || closing != null) {
      return;
    }
    final original = engine.close();
    closing = original;
    unawaited(original.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  void releaseEvidence() {
    final evidence = evidenceOwner;
    if (evidence == null || evidence.isCompleted) {
      return;
    }
    temporary!._operations.remove(evidence.future);
    evidence.complete();
  }

  @override
  TavernAuthoringSimulationResult get view => TavernAuthoringSimulationResult(
    requestId: requestId,
    captureId: captureId,
    draftId: request.draftId,
    draftRevision: request.draftRevision,
    changeIds: List.of(request.changeIds),
    status: status,
    origin: _copy({
      'scope': 'simulation',
      'context': request.context.toJson(),
      'at': request.at.toIso8601String(),
      'atIsUtc': request.at.isUtc,
      'seed': request.seed,
      'sealed': false,
      ...origin,
    }),
    turns: [for (final turn in turns) turn.view],
    requests: [for (final request in requests) request.view],
    usage: summarizeToolUsage([
      for (final request in requests) (requestIndex: request.index, usage: request.usageView),
    ]),
    cleanup: _copy(cleanup),
    issues: List.of(issues),
  );
}

extension _AuthoringSimulation on TavernEngine {
  TavernAuthoringSimulationTask _simulateAuthoringDraft(TavernAuthoringSimulationRequest supplied) {
    _ensureAdmission();
    final Map<String, Object?> input;
    try {
      input = _captureScriptObject(supplied.toJson());
    } on TavernScriptException {
      _authoringInvalid('Simulation materials must be finite JSON.');
    }
    final request = TavernAuthoringSimulationRequest.fromJson(input);
    if (request.requestId.isEmpty ||
        request.draftId.isEmpty ||
        request.draftRevision < 1 ||
        request.changeIds.toSet().length != request.changeIds.length ||
        request.userInputs.isEmpty ||
        request.userInputs.length > 4) {
      _authoringInvalid('A simulation requires valid draft identities and one to four user inputs.');
    }
    final helper = _auxiliaryModelConfig(_config);
    final selected = request.modelRole == TavernAuthoringModelRole.main ? _config : helper;
    final task = _AuthoringSimulationTask(
      request,
      'simulation:${_store.newAuthoringOperationId()}',
      selected,
      helper,
      _modelClient,
    );
    _operations.add(task.drained.future);
    _authoringPreviewCancellations.add(task.cancellation);
    unawaited(_driveAuthoringSimulation(task));
    return task;
  }

  Future<void> _driveAuthoringSimulation(_AuthoringSimulationTask task) async {
    (Object, StackTrace)? failure;
    var retainedOwner = false;
    try {
      if (_counter is! EstimatedTokenCounter) {
        throw const TavernAuthoringException(
          'unsupported_counter',
          'This simulation requires the built-in token counter.',
        );
      }
      if (task.request.context.history.isEmpty && task.request.context.state.isNotEmpty) {
        throw const TavernAuthoringException(
          'unsupported_simulation_state',
          'An empty sample history has no real leaf on which to install nonempty state.',
        );
      }
      task.cancellation.check();
      final request = task.request;
      final captured = await _captureAuthoringPromptContext(
        TavernAuthoringPromptRequest(
          requestId: request.requestId,
          draftId: request.draftId,
          draftRevision: request.draftRevision,
          changeIds: request.changeIds,
          context: request.context,
          at: request.at,
          seed: request.seed,
          text: request.userInputs.first,
        ),
        task.captureId,
        task.cancellation,
        simulationBootstrap: true,
      );
      task.origin = {
        ...captured.origin,
        'sealed': true,
        'model': task.config.model,
        'deepseek': task.config.deepseek,
        'thinking': task.config.thinking,
        'modelRole': request.modelRole.name,
        'mainModel': _authoringSimulationModel(task.config, 'main'),
        'helperModel': _authoringSimulationModel(task.helperConfig, 'helper'),
      };
      task.cancellation.check();
      final base = Directory.systemTemp;
      final baseIdentity = await _directoryIdentity(base);
      task.cancellation.check();
      if (_ownedTavernRoots.any(baseIdentity.startsWith)) {
        throw StateError('The system temporary directory is inside an owned tavern root.');
      }
      final root = await base.createTemp('dshgo-authoring-');
      task.directory = root;
      task.cleanup['rootCreated'] = true;
      task.cancellation.check();
      final identity = await _directoryIdentity(root);
      task.identity = identity;
      if (!_reserveTavernRoot(identity)) {
        task.conflictingRoot = true;
        throw StateError('The simulation directory overlaps an owned tavern root.');
      }
      task.reserved = true;
      task.cancellation.check();
      final seed = captured.simulationSeed!;
      await _writeAuthoringSimulationSeed(root, seed, request.at, task.cancellation);
      task.cancellation.check();
      final random = Random(request.seed), roll = Random(request.seed ^ 0x6a09e667);
      task.openStarted = true;
      final temporary = await TavernEngine._openReservedDirectory(
        root,
        identity,
        config: task.config,
        modelClient: task.client,
        counter: _counter,
        clock: () => request.at,
        random: random.nextDouble,
        rollRandom: roll.nextInt,
        releaseRootOnClose: false,
        onFailedOpenDrained: () {
          task.openDrained = true;
        },
      );
      task.adoptTemporary(temporary);
      task.cancellation.check();
      task.chatId = _bootstrapAuthoringSimulationStore(temporary, seed);
      task.origin = {
        ...task.origin,
        'temporaryGameplay': {
          'domainId': temporary._authoringAuthority.domainId,
          'chatId': task.chatId,
          'originDomainId': seed.gameplay.domainId,
        },
      };
      for (var index = 0; index < request.userInputs.length; index++) {
        task.cancellation.check();
        final turn = _AuthoringSimulationTurnRecord(index + 1, request.userInputs[index]);
        task.turns.add(turn);
        task.client.turnIndex = turn.index;
        await for (final event in temporary._streamTurn(
          task.chatId!,
          _TurnKind.send,
          input: turn.input,
          onAdmitted: (value) {
            turn.nativeTurn = value;
          },
        )) {
          turn.observe(event);
        }
        await turn.nativeTurn?.done.future;
        await temporary._directors.drainNaturally(task.chatId!);
        await task.client.drain();
        _readAuthoringSimulationEvidence(task, turn);
        if (turn.status != TavernAuthoringSimulationStatus.completed) {
          task.status = turn.status == TavernAuthoringSimulationStatus.running
              ? TavernAuthoringSimulationStatus.failed
              : turn.status;
          break;
        }
      }
      if (task.status == TavernAuthoringSimulationStatus.running) {
        task.status = task.cancellation.isCancelled
            ? TavernAuthoringSimulationStatus.cancelled
            : TavernAuthoringSimulationStatus.completed;
      }
    } on TavernAuthoringException catch (error) {
      task.status = switch (error.code) {
        'unsupported_counter' ||
        'unsupported_simulation_state' ||
        'unsupported_preview' => TavernAuthoringSimulationStatus.unsupported,
        'capture_conflict' || 'revision_conflict' => TavernAuthoringSimulationStatus.conflict,
        'cancelled' => TavernAuthoringSimulationStatus.cancelled,
        _ => TavernAuthoringSimulationStatus.failed,
      };
      task.issues.add(TavernAuthoringIssue(type: error.code, message: error.message));
    } on TavernModelException catch (error, stack) {
      if (error.kind == TavernFailure.cancelled) {
        task.status = TavernAuthoringSimulationStatus.cancelled;
      } else {
        failure = (error, stack);
        task.status = TavernAuthoringSimulationStatus.failed;
      }
    } catch (error, stack) {
      failure = (error, stack);
      task.status = TavernAuthoringSimulationStatus.failed;
    } finally {
      final engine = task.temporary;
      if (task.status != TavernAuthoringSimulationStatus.completed) {
        task.startClose();
      }
      try {
        final turn = task.turns.lastOrNull;
        if (turn != null) {
          await turn.nativeTurn?.done.future;
        }
        if (engine != null && task.chatId != null) {
          await engine._directors.drainNaturally(task.chatId!);
        }
        await task.client.drain();
      } catch (error, stack) {
        failure ??= (error, stack);
        task.issues.add(TavernAuthoringIssue(type: 'request_drain_failed', message: '${error.runtimeType}'));
      }
      try {
        final turn = task.turns.lastOrNull;
        if (turn != null && !turn.evidenceRead) {
          _readAuthoringSimulationEvidence(task, turn);
        }
      } catch (error, stack) {
        failure ??= (error, stack);
        task.issues.add(TavernAuthoringIssue(type: 'final_evidence_failed', message: '${error.runtimeType}'));
      } finally {
        task.releaseEvidence();
      }
      task.startClose();
      if (task.closing case final closing?) {
        try {
          await closing;
          task.cleanup['closeConfirmed'] = true;
        } catch (error, stack) {
          failure ??= (error, stack);
          retainedOwner = true;
        }
      } else if (task.openStarted && !task.openDrained) {
        retainedOwner = true;
      } else {
        task.cleanup['closeConfirmed'] = true;
      }
      if (task.requests.any((request) => request.cleanupFailure != null)) {
        retainedOwner = true;
      }
      final root = task.directory;
      if (retainedOwner) {
        task.status = TavernAuthoringSimulationStatus.failed;
        task.cleanup['retainedDirectory'] = root?.path;
        task.cleanup['reason'] = 'cleanup_unconfirmed';
        task.issues.add(
          const TavernAuthoringIssue(
            type: 'cleanup_failed',
            message: 'Actual temporary-root work or close could not be confirmed; the owner remains reserved.',
          ),
        );
      } else {
        if (root != null && !task.conflictingRoot) {
          try {
            await root.delete(recursive: true);
            task.cleanup['removed'] = true;
          } catch (error, stack) {
            failure ??= (error, stack);
            task.cleanup['retainedDirectory'] = root.path;
            task.cleanup['reason'] = 'delete_failed';
            task.issues.add(TavernAuthoringIssue(type: 'cleanup_delete_failed', message: '${error.runtimeType}'));
          }
        } else if (root != null) {
          task.cleanup['retainedDirectory'] = root.path;
          task.cleanup['reason'] = 'root_conflict';
        }
        if (task.reserved) {
          _ownedTavernRoots.remove(task.identity);
        }
        _authoringPreviewCancellations.remove(task.cancellation);
        _operations.remove(task.drained.future);
      }
    }
    if (failure != null) {
      if (task.status == TavernAuthoringSimulationStatus.running ||
          task.status == TavernAuthoringSimulationStatus.completed) {
        task.status = TavernAuthoringSimulationStatus.failed;
      }
      final turn = task.turns.lastOrNull;
      if (turn?.status == TavernAuthoringSimulationStatus.running) {
        turn!.status = TavernAuthoringSimulationStatus.failed;
      }
      task.issues.add(TavernAuthoringIssue(type: 'simulation_failed', message: '${failure.$1.runtimeType}'));
    }
    if (retainedOwner) {
      final error = failure ?? (StateError('Simulation cleanup remains unconfirmed.'), StackTrace.current);
      task.drained.completeError(error.$1, error.$2);
      task._result.completeError(error.$1, error.$2);
    } else {
      task.drained.complete();
      if (failure != null) {
        task._result.completeError(failure.$1, failure.$2);
      } else {
        task._result.complete(task.view);
      }
    }
  }
}

void _readAuthoringSimulationEvidence(_AuthoringSimulationTask task, _AuthoringSimulationTurnRecord turn) {
  turn.evidenceRead = true;
  final engine = task.temporary!;
  final chatId = task.chatId!;
  final native = turn.nativeTurn;
  final logicalTurnId = turn.logicalTurnId ?? (native?.toolAdmitted == true ? native!.toolLogicalId : null);
  turn.logicalTurnId = logicalTurnId;
  if (logicalTurnId != null) {
    turn.toolTurn = engine._store.readToolTurn(logicalTurnId)?.toJson();
  }
  const kinds = {
    'director.success',
    'director.failure',
    'director.secret_proposal',
    'director.secret_failure',
    'director.tick',
    'director.event',
  };
  final persisted = <String>{};
  String? before;
  while (true) {
    final page = engine._store.agentRunsByKind(chatId, kinds, limit: 64, beforeId: before);
    for (final row in page) {
      persisted.add(row.id);
      if (task.helperIds.add(row.id)) {
        turn.helpers.add({
          'scope': 'simulation',
          'tempChatId': chatId,
          'id': row.id,
          'kind': row.kind,
          'nodeId': row.nodeId,
          'at': row.at.toIso8601String(),
          'usage': row.usage,
          'result': row.result,
          'persisted': true,
        });
      }
    }
    if (page.length < 64) {
      break;
    }
    before = page.last.id;
  }
  final transient = engine._directors._transient[chatId];
  if (transient != null) {
    final value = <String, Object?>{
      'scope': 'simulation',
      'tempChatId': chatId,
      'id': transient.id,
      'kind': 'director.transient',
      'sourceKind': transient.sourceKind,
      'sourceNodeId': transient.sourceNodeId,
      'sourceFingerprint': transient.sourceFingerprint,
      'success': transient.success,
      'automatic': transient.automatic,
      'failure': transient.failure,
      'output': transient.output,
      'usage': _directorUsageJson(transient.reportedUsage),
      'startedAt': transient.startedAt.toIso8601String(),
      'finishedAt': transient.finishedAt.toIso8601String(),
      'issues': transient.issues,
      'durableRecordPresent': persisted.contains(transient.id),
      'notPersisted': !persisted.contains(transient.id),
    };
    if (task.transientFacts.add(_directorHash(value))) {
      turn.helpers.add(value);
    }
  }
  for (final issue in engine._directors._transientIssues[chatId] ?? const <Map<String, Object?>>[]) {
    final value = <String, Object?>{
      'scope': 'simulation',
      'tempChatId': chatId,
      'kind': 'director.transient_issue',
      'issue': _copy(issue),
      'durableRecordPresent': persisted.contains(issue['id']),
      'notPersisted': !persisted.contains(issue['id']),
    };
    if (task.transientFacts.add(_directorHash(value))) {
      turn.helpers.add(value);
    }
  }
}
