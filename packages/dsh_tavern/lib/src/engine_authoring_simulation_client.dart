part of 'engine.dart';

final class _AuthoringSimulationRequestRecord {
  _AuthoringSimulationRequestRecord(this.index, this.turnIndex, this.model, this.body) {
    unawaited(drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  final int index, turnIndex;
  final Map<String, Object?> model, body;
  final attempts = <int>[];
  final text = StringBuffer(), reasoning = StringBuffer();
  final streamingUsage = StreamingToolUsage();
  final issues = <TavernAuthoringIssue>[];
  final ready = Completer<void>(), drained = Completer<void>();
  StreamSubscription<ModelDelta>? subscription;
  ModelRequestContext? context;
  Future<void>? cancellationFuture;
  var sourceDone = false, outwardStopped = false;
  var status = TavernAuthoringSimulationRequestStatus.running;
  var usage = emptyToolUsageLedger();
  var legacyUsage = 0;
  ModelFinished? finished;
  (Object, StackTrace)? cleanupFailure;

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

  void observeDelta(ModelDelta delta) {
    switch (delta) {
      case ModelText(:final text):
        this.text.write(text);
      case ModelReasoning(:final text):
        reasoning.write(text);
      case ModelToolFragment():
        break;
      case ModelUsage(:final usage, :final report):
        observeUsage(report ?? ModelUsageReport.legacyNormalized(observationIndex: legacyUsage++), normalized: usage);
      case ModelFinished():
        finished = delta;
        if (delta.finalUsageReport case final report?) {
          observeUsage(report);
        }
    }
  }

  void failed(Object error) {
    status = error is TavernModelException && error.kind == TavernFailure.cancelled
        ? TavernAuthoringSimulationRequestStatus.cancelled
        : TavernAuthoringSimulationRequestStatus.failed;
    issues.add(
      TavernAuthoringIssue(
        type: 'request_failed',
        message: error is TavernModelException ? '${error.kind.name}:${error.detail}' : '${error.runtimeType}',
      ),
    );
  }

  void ended() {
    sourceDone = true;
    if (status == TavernAuthoringSimulationRequestStatus.running) {
      status = finished == null
          ? TavernAuthoringSimulationRequestStatus.failed
          : TavernAuthoringSimulationRequestStatus.completed;
      if (finished == null) {
        issues.add(
          const TavernAuthoringIssue(
            type: 'response_incomplete',
            message: 'The actual model stream ended without a finished response.',
          ),
        );
      }
    }
    if (cancellationFuture == null) {
      _drained();
    }
  }

  void _drained() {
    context?.closeObservations();
    if (!drained.isCompleted) {
      drained.complete();
    }
  }

  Future<void> cancelSource() {
    outwardStopped = true;
    if (sourceDone && cancellationFuture == null) {
      return Future.value();
    }
    final existing = cancellationFuture;
    if (existing != null) {
      return existing;
    }
    final result = _cancelSource();
    cancellationFuture = result;
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return result;
  }

  Future<void> _cancelSource() async {
    try {
      await ready.future;
      // Retain and await the delegate's real cancellation Future. Native
      // helper code may ignore ours, but the simulation owner does not.
      if (!sourceDone) {
        try {
          await subscription?.cancel();
        } on TavernModelException catch (error) {
          // An async* generator can report its cancelled exit through this
          // original Future after its finally blocks have completed.
          if (error.kind != TavernFailure.cancelled || context?.isCancelled != true) {
            rethrow;
          }
        }
      }
      if (status == TavernAuthoringSimulationRequestStatus.running) {
        status = finished == null
            ? TavernAuthoringSimulationRequestStatus.cancelled
            : TavernAuthoringSimulationRequestStatus.completed;
      }
      _drained();
    } catch (error, stack) {
      cleanupFailure = (error, stack);
      context?.closeObservations();
      if (!drained.isCompleted) {
        drained.completeError(error, stack);
      }
      rethrow;
    }
  }

  Map<String, Object?> get usageView => streamingUsage.record(usage).ledger;
  TavernAuthoringSimulationRequestSnapshot get view => TavernAuthoringSimulationRequestSnapshot(
    index: index,
    turnIndex: turnIndex,
    status: status,
    model: _copy(model),
    body: _copy(body),
    attempts: List.of(attempts),
    text: text.toString(),
    reasoning: reasoning.toString(),
    responseComplete: finished != null,
    finishReason: finished?.reason,
    assistant: finished?.assistantSnapshot?.toJson(),
    usage: _copy(usageView),
    issues: List.of(issues),
  );
}

final class _AuthoringSimulationClient extends TavernModelClient {
  _AuthoringSimulationClient(this.owner, this.delegate);
  final _AuthoringSimulationTask owner;
  final TavernModelClient delegate;
  var turnIndex = 0;

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    late StreamController<ModelDelta> outward;
    _AuthoringSimulationRequestRecord? record;
    outward = StreamController<ModelDelta>(
      sync: true,
      onListen: () {
        final current = _AuthoringSimulationRequestRecord(
          owner.requests.length + 1,
          turnIndex,
          _authoringSimulationModel(
            config,
            identical(config, owner.config)
                ? 'main'
                : identical(config, owner.helperConfig)
                ? 'helper'
                : 'unclassified',
          ),
          _copy(body),
        );
        record = current;
        owner.requests.add(current);
        final context = ModelRequestContext(
          cancellation: cancellation,
          onUsageReport: (report) {
            if (cancellation is ModelRequestContext) {
              cancellation.reportUsage(report);
            }
            current.observeUsage(report);
          },
        );
        current.context = context;
        try {
          current.subscription = delegate
              .generate(
                config: config,
                body: body,
                cancellation: context,
                onRequestStarted: (attempt) {
                  try {
                    onRequestStarted?.call(attempt);
                  } finally {
                    current.attempts.add(attempt);
                  }
                },
              )
              .listen(
                (delta) {
                  current.observeDelta(delta);
                  if (!current.outwardStopped) {
                    outward.add(delta);
                  }
                },
                onError: (Object error, StackTrace stack) {
                  current.failed(error);
                  if (!current.outwardStopped) {
                    outward.addError(error, stack);
                  }
                },
                onDone: () {
                  current.ended();
                  unawaited(outward.close());
                },
              );
          if (outward.isPaused) {
            current.subscription!.pause();
          }
        } catch (error, stack) {
          current.failed(error);
          current.ended();
          outward.addError(error, stack);
          unawaited(outward.close());
        } finally {
          current.ready.complete();
        }
      },
      onPause: () {
        record?.subscription?.pause();
      },
      onResume: () {
        record?.subscription?.resume();
      },
      onCancel: () => record?.cancelSource() ?? Future.value(),
    );
    return outward.stream;
  }

  Future<void> drain() async {
    // A helper queue can start another actual subscription while an earlier
    // one is finishing. Always wait the originals, then check the set again.
    var count = -1;
    (Object, StackTrace)? failure;
    while (count != owner.requests.length) {
      count = owner.requests.length;
      try {
        await Future.wait([for (final request in owner.requests) request.drained.future]);
      } catch (error, stack) {
        failure ??= (error, stack);
      }
    }
    var keys = -1;
    while (keys != owner.keys.length) {
      keys = owner.keys.length;
      await Future.wait(owner.keys.toList());
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }
}

Map<String, Object?> _authoringSimulationModel(TavernModelConfig config, String role) => {
  'model': config.model,
  'deepseek': config.deepseek,
  'thinking': config.thinking,
  'role': role,
};
