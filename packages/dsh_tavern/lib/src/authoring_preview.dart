import 'api.dart' show TavernRole;
import 'authoring.dart';
import 'prompt/prompt_types.dart' show PromptAssembly;

/// Cancellation completes after the admitted task's actual work has drained.
abstract interface class TavernAuthoringTask<T> {
  String get requestId;
  Future<T> get result;
  Future<void> cancel();
}

sealed class TavernAuthoringPromptContext {
  const TavernAuthoringPromptContext();
  Map<String, Object?> toJson();

  factory TavernAuthoringPromptContext.fromJson(Map<String, Object?> value) => switch (value['kind']) {
    'chat' => TavernAuthoringChatContext(
      chatId: value['chatId']! as String,
      nodeId: value['nodeId'] as String?,
      generationType: value['generationType']! as String,
      actorId: value['actorId'] as String?,
    ),
    'sample' => TavernAuthoringSampleContext(
      characterResourceId: value['characterResourceId']! as String,
      history: [
        for (final item in (value['history']! as List<Object?>).cast<Map<String, Object?>>())
          TavernAuthoringSampleMessage.fromJson(item),
      ],
      presetId: value['presetId'] as String?,
      personaId: value['personaId'] as String?,
      settings: value['settings']! as Map<String, Object?>,
      state: value['state']! as Map<String, Object?>,
      variables: value['variables']! as Map<String, Object?>,
    ),
    _ => throw const FormatException('Unknown authoring prompt context.'),
  };
}

/// Uses the selected real branch as captured input, without sending a turn.
final class TavernAuthoringChatContext extends TavernAuthoringPromptContext {
  const TavernAuthoringChatContext({required this.chatId, this.nodeId, this.generationType = 'normal', this.actorId});
  final String chatId;
  final String? nodeId, actorId;

  /// normal, regenerate, continue, or impersonate. Groups require an actor.
  /// Regenerate/continue require their character-message target in [nodeId].
  /// Normal/impersonate use the captured current leaf and reject a nodeId.
  final String generationType;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'chat',
    'chatId': chatId,
    'nodeId': nodeId,
    'generationType': generationType,
    'actorId': actorId,
  };
}

/// A normal send over local sample messages; it creates no real chat or audit.
final class TavernAuthoringSampleContext extends TavernAuthoringPromptContext {
  const TavernAuthoringSampleContext({
    required this.characterResourceId,
    this.history = const [],
    this.presetId,
    this.personaId,
    this.settings = const {},
    this.state = const {},
    this.variables = const {},
  });
  final String characterResourceId;
  final List<TavernAuthoringSampleMessage> history;
  final String? presetId, personaId;
  final Map<String, Object?> settings, state, variables;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'sample',
    'characterResourceId': characterResourceId,
    'history': [for (final item in history) item.toJson()],
    'presetId': presetId,
    'personaId': personaId,
    'settings': settings,
    'state': state,
    'variables': variables,
  };
}

final class TavernAuthoringSampleMessage {
  const TavernAuthoringSampleMessage({
    required this.role,
    required this.text,
    this.speaker,
    this.reasoning,
    this.hidden = false,
    this.at,
  });
  final TavernRole role;
  final String text;
  final String? speaker, reasoning;
  final bool hidden;

  /// An omitted timestamp uses the preview request's fixed time.
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'role': role.name,
    'text': text,
    'speaker': speaker,
    'reasoning': reasoning,
    'hidden': hidden,
    'at': at?.microsecondsSinceEpoch,
    'atIsUtc': at?.isUtc,
  };
  factory TavernAuthoringSampleMessage.fromJson(Map<String, Object?> value) => TavernAuthoringSampleMessage(
    role: TavernRole.values.byName(value['role']! as String),
    text: value['text']! as String,
    speaker: value['speaker'] as String?,
    reasoning: value['reasoning'] as String?,
    hidden: value['hidden']! as bool,
    at: value['at'] == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(value['at']! as int, isUtc: value['atIsUtc']! as bool),
  );
}

final class TavernAuthoringPromptRequest {
  const TavernAuthoringPromptRequest({
    required this.requestId,
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.context,
    required this.at,
    required this.seed,
    this.text = '',
  });
  final String requestId, draftId, text;
  final int draftRevision, seed;
  final List<String> changeIds;
  final TavernAuthoringPromptContext context;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'changeIds': changeIds,
    'context': context.toJson(),
    'at': at.microsecondsSinceEpoch,
    'atIsUtc': at.isUtc,
    'seed': seed,
    'text': text,
  };
  factory TavernAuthoringPromptRequest.fromJson(Map<String, Object?> value) => TavernAuthoringPromptRequest(
    requestId: value['requestId']! as String,
    draftId: value['draftId']! as String,
    draftRevision: value['draftRevision']! as int,
    changeIds: (value['changeIds']! as List<Object?>).cast<String>(),
    context: TavernAuthoringPromptContext.fromJson(value['context']! as Map<String, Object?>),
    at: DateTime.fromMicrosecondsSinceEpoch(value['at']! as int, isUtc: value['atIsUtc']! as bool),
    seed: value['seed']! as int,
    text: value['text']! as String,
  );
}

enum TavernAuthoringPreviewStatus { complete, unsupported, cancelled, conflict, failed }

/// A captured preparation result. Unsupported/failed results have no assembly.
final class TavernAuthoringPromptPreview {
  const TavernAuthoringPromptPreview({
    required this.requestId,
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.captureId,
    required this.origin,
    required this.status,
    this.assembly,
    this.worldInfo = const {},
    this.regexTrace = const [],
    this.secretTrace = const {},
    this.issues = const [],
  });
  final String requestId, draftId, captureId;
  final int draftRevision;
  final List<String> changeIds;
  final Map<String, Object?> origin, worldInfo;
  final TavernAuthoringPreviewStatus status;
  final PromptAssembly? assembly;

  /// Actual transform observations from this preparation; no regex is rerun.
  final List<Map<String, Object?>> regexTrace;

  /// Preview-scoped adoption and release observations, including after a
  /// later budget failure or cancellation. This contains no reusable proof
  /// or committed audit; attempted is always false because no HTTP is sent.
  final Map<String, Object?> secretTrace;
  final List<TavernAuthoringIssue> issues;

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'draftId': draftId,
    'draftRevision': draftRevision,
    'changeIds': changeIds,
    'captureId': captureId,
    'origin': origin,
    'status': status.name,
    'assembly': assembly?.toJson(),
    'worldInfo': worldInfo,
    'regexTrace': regexTrace,
    'secretTrace': secretTrace,
    'issues': [
      for (final issue in issues) {'type': issue.type, 'message': issue.message},
    ],
  };
}
