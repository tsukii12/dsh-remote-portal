import 'api.dart' show TavernMessage;
import 'authoring.dart';
import 'authoring_preview.dart';
import 'authoring_run.dart' show TavernAuthoringModelRole;

enum TavernAuthoringSimulationStatus { running, completed, cancelled, conflict, unsupported, failed }

enum TavernAuthoringSimulationRequestStatus { running, completed, cancelled, failed }

/// One to four real normal sends in an exclusive temporary tavern. The sample
/// character must be a character source in this draft. Empty history cannot
/// carry a nonempty state. No live chat, script host or network discovery is
/// inherited. Repeating requestId is a new invocation and can spend again.
final class TavernAuthoringSimulationRequest {
  const TavernAuthoringSimulationRequest({
    required this.requestId,
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.context,
    required this.userInputs,
    required this.at,
    required this.seed,
    this.modelRole = TavernAuthoringModelRole.main,
  });
  final String requestId, draftId;
  final int draftRevision, seed;
  final List<String> changeIds, userInputs;
  final TavernAuthoringSampleContext context;
  final DateTime at;
  final TavernAuthoringModelRole modelRole;

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'changeIds': changeIds,
    'context': context.toJson(),
    'userInputs': userInputs,
    'at': at.microsecondsSinceEpoch,
    'atIsUtc': at.isUtc,
    'seed': seed,
    'modelRole': modelRole.name,
  };

  factory TavernAuthoringSimulationRequest.fromJson(Map<String, Object?> value) => TavernAuthoringSimulationRequest(
    requestId: value['requestId']! as String,
    draftId: value['draftId']! as String,
    draftRevision: value['draftRevision']! as int,
    changeIds: (value['changeIds']! as List<Object?>).cast<String>(),
    context:
        TavernAuthoringPromptContext.fromJson(value['context']! as Map<String, Object?>)
            as TavernAuthoringSampleContext,
    userInputs: (value['userInputs']! as List<Object?>).cast<String>(),
    at: DateTime.fromMicrosecondsSinceEpoch(value['at']! as int, isUtc: value['atIsUtc']! as bool),
    seed: value['seed']! as int,
    modelRole: TavernAuthoringModelRole.values.byName(value['modelRole']! as String),
  );
}

/// Actual subscription evidence. Index and turnIndex start at one. Body is
/// the assembler input to generate, not encoded HTTP bytes. Attempts record
/// client.send invocations, not server acceptance. An empty attempt list
/// cannot establish that a custom transport sent nothing.
final class TavernAuthoringSimulationRequestSnapshot {
  const TavernAuthoringSimulationRequestSnapshot({
    required this.index,
    required this.turnIndex,
    required this.status,
    required this.model,
    required this.body,
    required this.attempts,
    required this.text,
    required this.reasoning,
    required this.responseComplete,
    required this.usage,
    required this.issues,
    this.finishReason,
    this.assistant,
  });
  final int index, turnIndex;
  final TavernAuthoringSimulationRequestStatus status;
  final Map<String, Object?> model, body, usage;
  final Map<String, Object?>? assistant;
  final List<int> attempts;
  final String text, reasoning;
  final bool responseComplete;
  final String? finishReason;
  final List<TavernAuthoringIssue> issues;
  String get attemptEvidence => attempts.isEmpty ? 'unavailable' : 'observed';
}

/// Main-turn and helper facts remain separate. A completed main turn stays
/// completed if its later helper fails or the simulation is then cancelled.
final class TavernAuthoringSimulationTurn {
  const TavernAuthoringSimulationTurn({
    required this.index,
    required this.input,
    required this.status,
    required this.helpers,
    required this.hookIssues,
    this.message,
    this.finishReason,
    this.failure,
    this.logicalTurnId,
    this.toolTurn,
  });
  final int index;
  final String input;
  final TavernAuthoringSimulationStatus status;
  final TavernMessage? message;
  final String? finishReason, logicalTurnId;
  final Map<String, Object?>? failure, toolTurn;
  final List<Map<String, Object?>> helpers, hookIssues;
}

/// Captured-file fresh-open semantics preserve saved regex diagnostics; they
/// do not reproduce a different live loaded-regex cache or recheck imports.
/// Every model request, including helpers and retries, is accounted for;
/// four main turns do not mean four HTTP attempts. Cleanup describes actual
/// close/removal. A retained directory records incomplete cleanup, including
/// an unconfirmed close for which removal was never attempted.
final class TavernAuthoringSimulationResult {
  const TavernAuthoringSimulationResult({
    required this.requestId,
    required this.captureId,
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.status,
    required this.origin,
    required this.turns,
    required this.requests,
    required this.usage,
    required this.cleanup,
    required this.issues,
  });
  final String requestId, captureId, draftId;
  final int draftRevision;
  final List<String> changeIds;
  final TavernAuthoringSimulationStatus status;
  final Map<String, Object?> origin, usage, cleanup;
  final List<TavernAuthoringSimulationTurn> turns;
  final List<TavernAuthoringSimulationRequestSnapshot> requests;
  final List<TavernAuthoringIssue> issues;
}

abstract interface class TavernAuthoringSimulationTask implements TavernAuthoringTask<TavernAuthoringSimulationResult> {
  /// Detached observations, also available if result throws an unexpected
  /// storage error. No read of this view executes or repeats model work.
  TavernAuthoringSimulationResult get view;
}
