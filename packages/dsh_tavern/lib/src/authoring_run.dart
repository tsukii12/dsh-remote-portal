import 'dart:async';

import 'authoring.dart';
import 'authoring_preview.dart';
import 'authoring_render.dart' show TavernAuthoringRenderMode;

enum TavernAuthoringModelRole { main, auxiliary }

enum TavernAuthoringRunStatus { running, completed, cancelled, conflict, budget, failed, interrupted }

enum TavernAuthoringRequestStatus { registered, running, completed, cancelled, failed, interrupted }

enum TavernAuthoringToolStatus { succeeded, rejected, cancelled }

/// The user's fixed rendering choices for an author conversation. The model
/// selects changes only; it cannot replace the target, samples or viewport.
final class TavernAuthoringRenderContext {
  const TavernAuthoringRenderContext({
    required this.physicalResourceId,
    required this.viewportWidth,
    required this.viewportHeight,
    this.devicePixelRatio = 1,
    this.theme = 'light',
    this.mode = TavernAuthoringRenderMode.staticMarkup,
    this.samples = const [],
  });

  final String physicalResourceId, theme;
  final int viewportWidth, viewportHeight;
  final double devicePixelRatio;
  final TavernAuthoringRenderMode mode;
  final List<TavernAuthoringSampleMessage> samples;

  Map<String, Object?> toJson() => {
    'physicalResourceId': physicalResourceId,
    'viewportWidth': viewportWidth,
    'viewportHeight': viewportHeight,
    'devicePixelRatio': devicePixelRatio,
    'theme': theme,
    'mode': mode.name,
    'samples': [for (final sample in samples) sample.toJson()],
  };

  factory TavernAuthoringRenderContext.fromJson(Map<String, Object?> value) => TavernAuthoringRenderContext(
    physicalResourceId: value['physicalResourceId']! as String,
    viewportWidth: value['viewportWidth']! as int,
    viewportHeight: value['viewportHeight']! as int,
    devicePixelRatio: (value['devicePixelRatio']! as num).toDouble(),
    theme: value['theme']! as String,
    mode: TavernAuthoringRenderMode.values.byName(value['mode']! as String),
    samples: [
      for (final sample in (value['samples']! as List<Object?>).cast<Map<String, Object?>>())
        TavernAuthoringSampleMessage.fromJson(sample),
    ],
  );
}

/// A separate author conversation. Inputs are captured synchronously at start;
/// materials contain only user-supplied named text or finite JSON values.
final class TavernAuthoringRunRequest {
  const TavernAuthoringRunRequest({
    required this.runId,
    required this.draftId,
    required this.draftRevision,
    required this.instruction,
    this.materials = const {},
    this.modelRole = TavernAuthoringModelRole.main,
    this.previewContext,
    this.renderContext,
  });

  final String runId, draftId, instruction;
  final int draftRevision;
  final Map<String, Object?> materials;
  final TavernAuthoringModelRole modelRole;
  final TavernAuthoringPromptContext? previewContext;
  final TavernAuthoringRenderContext? renderContext;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'instruction': instruction,
    'materials': materials,
    'modelRole': modelRole.name,
    if (previewContext != null) 'previewContext': previewContext!.toJson(),
    if (renderContext != null) 'renderContext': renderContext!.toJson(),
  };

  factory TavernAuthoringRunRequest.fromJson(Map<String, Object?> value) => TavernAuthoringRunRequest(
    runId: value['runId']! as String,
    draftId: value['draftId']! as String,
    draftRevision: value['draftRevision']! as int,
    instruction: value['instruction']! as String,
    materials: value['materials']! as Map<String, Object?>,
    modelRole: TavernAuthoringModelRole.values.byName(value['modelRole']! as String),
    previewContext: value['previewContext'] == null
        ? null
        : TavernAuthoringPromptContext.fromJson(value['previewContext']! as Map<String, Object?>),
    renderContext: value['renderContext'] == null
        ? null
        : TavernAuthoringRenderContext.fromJson(value['renderContext']! as Map<String, Object?>),
  );
}

/// Registered application request and actual transport evidence. Attempt
/// numbers are supplied by the transport; a registration alone is not a send.
/// Missing markers do not prove that no send occurred. A request_record_failed
/// run issue identifies response evidence that could not be saved durably.
final class TavernAuthoringRequestSnapshot {
  const TavernAuthoringRequestSnapshot({
    required this.runId,
    required this.requestIndex,
    required this.status,
    required this.body,
    required this.attempts,
    required this.text,
    required this.reasoning,
    required this.responseComplete,
    required this.usage,
    required this.createdAt,
    required this.updatedAt,
    this.finishReason,
    this.assistant,
    this.toolBatch,
  });

  final String runId, text, reasoning;
  final int requestIndex;
  final TavernAuthoringRequestStatus status;
  final List<int> attempts;
  final bool responseComplete;
  final String? finishReason;
  final DateTime createdAt, updatedAt;
  final Map<String, Object?> body, usage;
  final Map<String, Object?>? assistant, toolBatch;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'requestIndex': requestIndex,
    'status': status.name,
    'body': body,
    'attempts': attempts,
    'text': text,
    'reasoning': reasoning,
    'responseComplete': responseComplete,
    'finishReason': finishReason,
    'assistant': assistant,
    'toolBatch': toolBatch,
    'usage': usage,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  factory TavernAuthoringRequestSnapshot.fromJson(Map<String, Object?> value) => TavernAuthoringRequestSnapshot(
    runId: value['runId']! as String,
    requestIndex: value['requestIndex']! as int,
    status: TavernAuthoringRequestStatus.values.byName(value['status']! as String),
    body: value['body']! as Map<String, Object?>,
    attempts: (value['attempts']! as List<Object?>).cast<int>(),
    text: value['text']! as String,
    reasoning: value['reasoning']! as String,
    responseComplete: value['responseComplete']! as bool,
    finishReason: value['finishReason'] as String?,
    assistant: value['assistant'] as Map<String, Object?>?,
    toolBatch: value['toolBatch'] as Map<String, Object?>?,
    usage: value['usage']! as Map<String, Object?>,
    createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt']! as int, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(value['updatedAt']! as int, isUtc: true),
  );
}

/// One actual model call, stored atomically with any draft edit. Reading this
/// receipt never executes the tool; provider argument text remains unchanged.
final class TavernAuthoringToolReceipt {
  const TavernAuthoringToolReceipt({
    required this.runId,
    required this.receiptId,
    required this.requestIndex,
    required this.callIndex,
    required this.callId,
    required this.toolName,
    required this.arguments,
    required this.status,
    required this.beforeRevision,
    required this.afterRevision,
    required this.changeIds,
    required this.result,
  });

  final String runId, receiptId, callId, toolName, arguments;
  final int requestIndex, callIndex, beforeRevision, afterRevision;
  final TavernAuthoringToolStatus status;
  final List<String> changeIds;
  final Map<String, Object?> result;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'receiptId': receiptId,
    'requestIndex': requestIndex,
    'callIndex': callIndex,
    'callId': callId,
    'toolName': toolName,
    'arguments': arguments,
    'status': status.name,
    'beforeRevision': beforeRevision,
    'afterRevision': afterRevision,
    'changeIds': changeIds,
    'result': result,
  };

  factory TavernAuthoringToolReceipt.fromJson(Map<String, Object?> value) => TavernAuthoringToolReceipt(
    runId: value['runId']! as String,
    receiptId: value['receiptId']! as String,
    requestIndex: value['requestIndex']! as int,
    callIndex: value['callIndex']! as int,
    callId: value['callId']! as String,
    toolName: value['toolName']! as String,
    arguments: value['arguments']! as String,
    status: TavernAuthoringToolStatus.values.byName(value['status']! as String),
    beforeRevision: value['beforeRevision']! as int,
    afterRevision: value['afterRevision']! as int,
    changeIds: (value['changeIds']! as List<Object?>).cast<String>(),
    result: value['result']! as Map<String, Object?>,
  );
}

final class TavernAuthoringRunSnapshot {
  TavernAuthoringRunSnapshot({
    required this.runId,
    required this.draftId,
    required this.startRevision,
    required this.currentRevision,
    required this.status,
    required this.answer,
    required Map<String, Object?> request,
    required this.model,
    required this.requests,
    required this.receipts,
    required this.usage,
    required this.issues,
    required this.createdAt,
    required this.updatedAt,
  }) : request = TavernAuthoringRunRequest.fromJson(request);

  final String runId, draftId, answer;
  final int startRevision, currentRevision;
  final TavernAuthoringRunStatus status;
  final List<TavernAuthoringRequestSnapshot> requests;
  final List<TavernAuthoringToolReceipt> receipts;
  final List<TavernAuthoringIssue> issues;
  final DateTime createdAt, updatedAt;
  final TavernAuthoringRunRequest request;
  final Map<String, Object?> model, usage;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'draftId': draftId,
    'startRevision': startRevision,
    'currentRevision': currentRevision,
    'status': status.name,
    'answer': answer,
    'request': request.toJson(),
    'model': model,
    'usage': usage,
    'requests': [for (final request in requests) request.toJson()],
    'receipts': [for (final receipt in receipts) receipt.toJson()],
    'issues': [
      for (final issue in issues) {'type': issue.type, 'message': issue.message},
    ],
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  factory TavernAuthoringRunSnapshot.fromJson(Map<String, Object?> value) => TavernAuthoringRunSnapshot(
    runId: value['runId']! as String,
    draftId: value['draftId']! as String,
    startRevision: value['startRevision']! as int,
    currentRevision: value['currentRevision']! as int,
    status: TavernAuthoringRunStatus.values.byName(value['status']! as String),
    answer: value['answer']! as String,
    request: value['request']! as Map<String, Object?>,
    model: value['model']! as Map<String, Object?>,
    requests: [
      for (final request in (value['requests']! as List<Object?>).cast<Map<String, Object?>>())
        TavernAuthoringRequestSnapshot.fromJson(request),
    ],
    receipts: [
      for (final receipt in (value['receipts']! as List<Object?>).cast<Map<String, Object?>>())
        TavernAuthoringToolReceipt.fromJson(receipt),
    ],
    usage: value['usage']! as Map<String, Object?>,
    issues: [
      for (final issue in (value['issues']! as List<Object?>).cast<Map<String, Object?>>())
        TavernAuthoringIssue(type: issue['type']! as String, message: issue['message']! as String),
    ],
    createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt']! as int, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(value['updatedAt']! as int, isUtc: true),
  );
}

final class TavernAuthoringRunSummary {
  const TavernAuthoringRunSummary({
    required this.runId,
    required this.draftId,
    required this.startRevision,
    required this.currentRevision,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
  final String runId, draftId;
  final int startRevision, currentRevision;
  final TavernAuthoringRunStatus status;
  final DateTime createdAt, updatedAt;
}

enum TavernAuthoringRunEventKind { snapshot, text, request, receipt, terminal }

final class TavernAuthoringRunEvent {
  const TavernAuthoringRunEvent({
    required this.runId,
    required this.seq,
    required this.kind,
    required this.status,
    required this.draftRevision,
    this.delta,
    this.receiptId,
    this.snapshot,
  });
  final String runId;
  final int seq, draftRevision;
  final TavernAuthoringRunEventKind kind;
  final TavernAuthoringRunStatus status;
  final String? delta, receiptId;
  final TavernAuthoringRunSnapshot? snapshot;
}

abstract interface class TavernAuthoringRun {
  String get runId;

  /// Each observer receives a current snapshot, then future events. Leaving an
  /// event subscription does not cancel the run or resume it after reopening.
  Stream<TavernAuthoringRunEvent> get events;

  /// Completion, budget, conflict and cancellation return their saved snapshot.
  /// Model/storage failures retain their original exception; read the saved run
  /// for its terminal status and evidence. This completes after actual drain.
  Future<TavernAuthoringRunSnapshot> get result;
  Future<void> cancel();
}
