/// Wire models for DSH 0.2.0-rc.2 / 0.2.1-rc.2 and the sealed [DshEvent] hierarchy.
///
/// Every parser is tolerant: unknown fields are ignored, unknown event types
/// become [UnknownEvent] / [UnknownHostEvent] / [UnknownFrameEvent], and a
/// malformed member degrades to a default instead of throwing. Each parsed
/// object keeps its `raw` JSON so a UI can still render something new.
library;

import 'dart:convert';

import 'json.dart';

// =============================================================================
// Content parts and messages
// =============================================================================

/// One content block of a message (`ContentBlock` on the wire).
sealed class Part {
  const Part();

  /// Parses one block; unknown `type`s become [UnknownPart].
  static Part fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final type = asString(map['type']) ?? '';
    switch (type) {
      case 'text':
        return TextPart(asString(map['text']) ?? '');
      case 'reasoning':
        return ReasoningPart(asString(map['text']) ?? '');
      case 'image':
        return ImagePart(ImageAttachment.fromJson(map['attachment']), offloaded: map['offloaded'] == true);
      case 'file':
        return FilePart(FileAttachment.fromJson(map['attachment']));
      case 'tool-call':
        return ToolCallPart(
          id: asString(map['id']) ?? '',
          name: asString(map['name']) ?? '',
          arguments: asString(map['arguments']) ?? '',
        );
      default:
        return UnknownPart(type, map);
    }
  }

  static List<Part> listFromJson(Object? json) => asListOrEmpty(json).map(Part.fromJson).toList(growable: false);
}

final class TextPart extends Part {
  const TextPart(this.text);
  final String text;
}

/// Model reasoning ("thinking"); render collapsed, never as the answer.
final class ReasoningPart extends Part {
  const ReasoningPart(this.text);
  final String text;
}

/// Durable image reference; fetch bytes with `session/attachment`.
final class ImagePart extends Part {
  const ImagePart(this.attachment, {this.offloaded = false});
  final ImageAttachment attachment;

  /// The model saw a text placeholder instead of the pixels.
  final bool offloaded;
}

final class FilePart extends Part {
  const FilePart(this.attachment);
  final FileAttachment attachment;
}

/// A tool invocation inside an assistant message. [arguments] is the raw JSON
/// string exactly as the model produced it.
final class ToolCallPart extends Part {
  const ToolCallPart({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final String arguments;

  /// [arguments] decoded, or `null` when it is not a JSON object.
  Map<String, Object?>? get decodedArguments => asMap(tryDecodeJson(arguments));
}

/// `tool-addition` / `tool-removal` (developer messages) and future blocks.
final class UnknownPart extends Part {
  const UnknownPart(this.type, this.raw);
  final String type;
  final Map<String, Object?> raw;
}

class ImageAttachment {
  const ImageAttachment({
    required this.attachmentId,
    required this.mediaType,
    this.bytes,
    this.width,
    this.height,
    this.name,
    this.raw = const {},
  });

  factory ImageAttachment.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return ImageAttachment(
      attachmentId: asString(map['attachmentId']) ?? '',
      mediaType: asString(map['mediaType']) ?? 'application/octet-stream',
      bytes: asInt(map['bytes']),
      width: asInt(map['width']),
      height: asInt(map['height']),
      name: asString(map['name']),
      raw: map,
    );
  }

  final String attachmentId;
  final String mediaType;
  final int? bytes;
  final int? width;
  final int? height;
  final String? name;
  final Map<String, Object?> raw;

  Map<String, Object?> toJson() => {
    'attachmentId': attachmentId,
    'mediaType': mediaType,
    'bytes': ?bytes,
    'width': ?width,
    'height': ?height,
    'name': ?name,
  };

  @override
  bool operator ==(Object other) =>
      other is ImageAttachment &&
      attachmentId == other.attachmentId &&
      mediaType == other.mediaType &&
      bytes == other.bytes &&
      width == other.width &&
      height == other.height &&
      name == other.name;

  @override
  int get hashCode => Object.hash(attachmentId, mediaType, bytes, width, height, name);
}

class FileAttachment {
  const FileAttachment({this.attachmentId, this.name, this.bytes, this.raw = const {}});

  factory FileAttachment.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return FileAttachment(
      attachmentId: asString(map['attachmentId']),
      name: asString(map['name']),
      bytes: asInt(map['bytes']),
      raw: map,
    );
  }

  final String? attachmentId;
  final String? name;
  final int? bytes;
  final Map<String, Object?> raw;
}

enum MessageRole {
  system,
  developer,
  user,
  assistant,
  tool,
  unknown;

  static MessageRole parse(Object? value) => switch (value) {
    'system' => system,
    'developer' => developer,
    'user' => user,
    'assistant' => assistant,
    'tool' => tool,
    _ => unknown,
  };
}

/// Who produced a message. For `user/message` events only
/// `kind == 'user'` is a human prompt; `runtime-context`, `skill-catalog`,
/// reminders, goal rounds etc. are synthetic context the model sees and a chat
/// UI normally hides. `user-question-reply` is a late answer to a question.
class MessageSource {
  const MessageSource(this.kind, this.raw);

  factory MessageSource.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return MessageSource(asString(map['kind']) ?? 'unknown', map);
  }

  final String kind;
  final Map<String, Object?> raw;

  bool get isHuman => kind == 'user';

  /// Client `requestId` of the prompt (`session/prompt`), echoed as `rpcId`.
  String? get requestId => asString(raw['rpcId']);
  String? get provider => asString(raw['provider']);
  String? get model => asString(raw['model']);
}

class Message {
  const Message({
    required this.id,
    required this.role,
    required this.parts,
    required this.source,
    this.toolCallId,
    this.isError = false,
    this.raw = const {},
  });

  factory Message.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return Message(
      id: asString(map['id']) ?? '',
      role: MessageRole.parse(map['role']),
      parts: Part.listFromJson(map['content']),
      source: MessageSource.fromJson(map['source']),
      toolCallId: asString(map['toolCallId']),
      isError: map['isError'] == true,
      raw: map,
    );
  }

  final String id;
  final MessageRole role;
  final List<Part> parts;
  final MessageSource source;

  /// Tool-role messages: the call this result answers.
  final String? toolCallId;
  final bool isError;
  final Map<String, Object?> raw;

  /// Concatenated visible text (text parts only).
  String get text => parts.whereType<TextPart>().map((p) => p.text).join();

  /// Explicit final-answer text in the known pi-ai v2 replay format.
  /// Text blocks are joined for display, so any final block keeps the message.
  bool get isFinalAnswer {
    if (role != MessageRole.assistant || source.kind != 'model') return false;
    final replay = asMap(source.raw['replayState']);
    final response = asMap(replay?['response']);
    final blocks = asList(replay?['blocks']);
    if (response?['kind'] != 'pi-ai' || response?['version'] != 2 || blocks == null || blocks.length != parts.length) {
      return false;
    }
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is! TextPart || part.text.trim().isEmpty) continue;
      final block = asMap(blocks[i]);
      if (block?['type'] != 'text') continue;
      final signature = asString(block?['textSignature']);
      final metadata = signature == null ? null : asMap(tryDecodeJson(signature));
      if (metadata?['v'] == 1 &&
          metadata?['phase'] == 'final_answer' &&
          (asString(metadata?['id'])?.isNotEmpty ?? false)) {
        return true;
      }
    }
    return false;
  }

  String get reasoning => parts.whereType<ReasoningPart>().map((p) => p.text).join();

  List<ToolCallPart> get toolCalls => parts.whereType<ToolCallPart>().toList(growable: false);
}

class TokenUsage {
  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.totalTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.reasoningTokens,
  });

  static TokenUsage? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return TokenUsage(
      inputTokens: asInt(map['inputTokens']) ?? 0,
      outputTokens: asInt(map['outputTokens']) ?? 0,
      totalTokens: asInt(map['totalTokens']),
      cacheReadTokens: asInt(map['cacheReadTokens']),
      cacheWriteTokens: asInt(map['cacheWriteTokens']),
      reasoningTokens: asInt(map['reasoningTokens']),
    );
  }

  /// Uncached input only; billed input = input + cacheRead + cacheWrite.
  final int inputTokens;
  final int outputTokens;
  final int? totalTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? reasoningTokens;
}

/// Provider or transport failure facts (`LlmFailure`), e.g. code
/// `MISSING_CREDENTIAL`, `INVALID_CREDENTIAL`, rate limits.
class LlmFailure {
  const LlmFailure({required this.message, required this.code, this.status, this.raw = const {}});

  static LlmFailure? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return LlmFailure(
      message: asString(map['message']) ?? '',
      code: asString(map['code']) ?? 'UNKNOWN',
      status: asInt(map['status']),
      raw: map,
    );
  }

  final String message;
  final String code;
  final int? status;
  final Map<String, Object?> raw;

  @override
  String toString() => '$code: $message';
}

// =============================================================================
// Model streaming chunks
// =============================================================================

/// One raw model-stream chunk (`StreamChunk`). Block indexes correlate
/// deltas of the same block; `block-end` carries the assembled block.
sealed class StreamChunk {
  const StreamChunk();

  static StreamChunk fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final index = asInt(map['index']) ?? 0;
    switch (asString(map['type'])) {
      case 'block-start':
        return BlockStartChunk(index, asString(map['blockType']) ?? '');
      case 'text-delta':
        return TextDeltaChunk(index, asString(map['text']) ?? '');
      case 'reasoning-delta':
        return ReasoningDeltaChunk(index, asString(map['text']) ?? '');
      case 'tool-call-delta':
        return ToolCallDeltaChunk(
          index,
          id: asString(map['id']) ?? '',
          name: asString(map['name']),
          argumentsDelta: asString(map['argumentsDelta']) ?? '',
        );
      case 'block-end':
        return BlockEndChunk(index, Part.fromJson(map['block']));
      case 'usage':
        return UsageChunk(TokenUsage.fromJson(map['usage']) ?? const TokenUsage(inputTokens: 0, outputTokens: 0));
      case 'finish':
        final reason = asMapOrEmpty(map['reason']);
        return FinishChunk(asString(reason['kind']) ?? 'unknown', LlmFailure.fromJson(reason['failure']));
      default:
        return UnknownChunk(map);
    }
  }
}

final class BlockStartChunk extends StreamChunk {
  const BlockStartChunk(this.blockIndex, this.blockType);
  final int blockIndex;

  /// `text`, `reasoning`, `tool-call`, ...
  final String blockType;
}

final class TextDeltaChunk extends StreamChunk {
  const TextDeltaChunk(this.blockIndex, this.text);
  final int blockIndex;
  final String text;
}

final class ReasoningDeltaChunk extends StreamChunk {
  const ReasoningDeltaChunk(this.blockIndex, this.text);
  final int blockIndex;
  final String text;
}

final class ToolCallDeltaChunk extends StreamChunk {
  const ToolCallDeltaChunk(this.blockIndex, {required this.id, this.name, required this.argumentsDelta});
  final int blockIndex;
  final String id;
  final String? name;
  final String argumentsDelta;
}

final class BlockEndChunk extends StreamChunk {
  const BlockEndChunk(this.blockIndex, this.block);
  final int blockIndex;
  final Part block;
}

final class UsageChunk extends StreamChunk {
  const UsageChunk(this.usage);
  final TokenUsage usage;
}

/// `stop`, `tool-calls`, `max-tokens`, `aborted`, `error`.
final class FinishChunk extends StreamChunk {
  const FinishChunk(this.reason, this.failure);
  final String reason;
  final LlmFailure? failure;
}

final class UnknownChunk extends StreamChunk {
  const UnknownChunk(this.raw);
  final Map<String, Object?> raw;
}

class TimedChunk {
  const TimedChunk(this.time, this.chunk);
  final DateTime time;
  final StreamChunk chunk;
}

/// Expands the compact `AssistantStreamRecord[]` stored in
/// `assistant/message.stream`, `assistant/attempt.stream` and the follow
/// snapshot's active attempt into the exact chunk sequence.
List<TimedChunk> expandCompactStream(Object? records) {
  final out = <TimedChunk>[];
  for (final record in asListOrEmpty(records)) {
    final map = asMapOrEmpty(record);
    final type = asString(map['type']);
    if (type == 'chunk') {
      out.add(
        TimedChunk(
          asEpochMs(map['time']) ?? DateTime.fromMillisecondsSinceEpoch(0),
          StreamChunk.fromJson(map['chunk']),
        ),
      );
      continue;
    }
    if (type != 'text-chunks' && type != 'reasoning-chunks' && type != 'tool-call-chunks') {
      continue;
    }
    final members = asStringList(type == 'tool-call-chunks' ? map['args'] : map['texts']);
    final dt = asListOrEmpty(map['dt']).map((v) => asInt(v) ?? 0).toList();
    final index = asInt(map['index']) ?? 0;
    var time = asInt(map['time0']) ?? 0;
    for (var i = 0; i < members.length; i++) {
      if (i > 0 && i - 1 < dt.length) time += dt[i - 1];
      final StreamChunk chunk = switch (type) {
        'text-chunks' => TextDeltaChunk(index, members[i]),
        'reasoning-chunks' => ReasoningDeltaChunk(index, members[i]),
        _ => ToolCallDeltaChunk(
          index,
          id: asString(map['id']) ?? '',
          name: asString(map['name']),
          argumentsDelta: members[i],
        ),
      };
      out.add(TimedChunk(DateTime.fromMillisecondsSinceEpoch(time), chunk));
    }
  }
  return out;
}

// =============================================================================
// Sessions, workspaces, models, credentials
// =============================================================================

class ModelSelection {
  const ModelSelection({required this.provider, required this.model, this.reasoningEffort});

  static ModelSelection? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final provider = asString(map['provider']);
    final model = asString(map['model']);
    if (provider == null || model == null) return null;
    return ModelSelection(provider: provider, model: model, reasoningEffort: asString(map['reasoningEffort']));
  }

  final String provider;
  final String model;
  final String? reasoningEffort;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  };

  @override
  String toString() => '$provider/$model${reasoningEffort == null ? '' : ' ($reasoningEffort)'}';
}

/// Saving the next-session default is separate from switching this session.
enum ModelDefaultSaveStatus { saved, skipped, failed, unknown }

class ModelDefaultSave {
  const ModelDefaultSave({required this.status, this.code});

  static ModelDefaultSave? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final status = switch (asString(map['status'])) {
      'saved' => ModelDefaultSaveStatus.saved,
      'skipped' => ModelDefaultSaveStatus.skipped,
      'failed' => ModelDefaultSaveStatus.failed,
      _ => ModelDefaultSaveStatus.unknown,
    };
    return ModelDefaultSave(status: status, code: asString(map['code']));
  }

  final ModelDefaultSaveStatus status;
  final String? code;
}

class ModelSelectionResult {
  const ModelSelectionResult({required this.selected, this.defaultSave});

  final ModelSelection selected;

  /// Null for older hosts that do not acknowledge default persistence.
  final ModelDefaultSave? defaultSave;
}

class TodoItem {
  const TodoItem(this.content, this.status);

  factory TodoItem.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return TodoItem(asString(map['content']) ?? '', asString(map['status']) ?? 'pending');
  }

  final String content;

  /// `pending`, `in_progress`, `completed`.
  final String status;
}

/// Projection values (`SessionProjectionValues`): Host-folded state keyed by
/// projection name. Typed getters cover the keys a chat UI needs; [values]
/// keeps everything else (`contextPressure`, `turnOutline`, `goal`, ...).
class SessionProjections {
  const SessionProjections(this.asOfSeq, this.values);

  factory SessionProjections.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return SessionProjections(asInt(map['asOfSeq']) ?? -1, asMapOrEmpty(map['values']));
  }

  static const empty = SessionProjections(-1, {});

  final int asOfSeq;
  final Map<String, Object?> values;

  bool has(String key) => values.containsKey(key);
  String? get title => asString(values['title']);
  String? get agentPreset => asString(values['agentPreset']);

  /// Current permission preset (`read-only`, `workspace-write`,
  /// `danger-full-access`, `auto`, or `custom`).
  String? get permissionPreset => asString(asMap(values['permissions'])?['currentValue']);
  ModelSelection? get lastUsedModel => ModelSelection.fromJson(asMap(values['modelSelection'])?['lastUsed']);

  /// Selection the next request will use (falls back to [lastUsedModel]).
  ModelSelection? get nextModel => ModelSelection.fromJson(asMap(values['modelSelection'])?['next']) ?? lastUsedModel;
  List<TodoItem>? get todos {
    final list = asList(values['todos']);
    return list?.map(TodoItem.fromJson).toList(growable: false);
  }

  bool? get blank => asBool(asMap(values['sessionListMetadata'])?['blank']);

  /// Messages waiting in the agent inbox (queued prompts), as raw messages.
  List<Message> get queuedMessages => [
    ...asListOrEmpty(asMap(values['inbox'])?['next-turn']).map(Message.fromJson),
    ...asListOrEmpty(asMap(values['inbox'])?['next-step']).map(Message.fromJson),
  ];

  /// The agent inbox by target: `next-turn` (queued for after the running
  /// turn) and `next-step` (steering into it).
  Map<String, List<Message>> get inbox => {
    for (final target in const ['next-turn', 'next-step'])
      target: asListOrEmpty(asMap(values['inbox'])?[target]).map(Message.fromJson).toList(),
  };

  Map<String, Object?>? get tokenUsage => asMap(values['tokenUsage']);
  Map<String, Object?>? get imageLimits => asMap(values['imageLimits']);

  /// Merge one `session/control` projection frame (later seq wins).
  SessionProjections withValue(String key, Object? value, int seq) {
    if (seq < asOfSeq) return this;
    return SessionProjections(seq, {...values, key: value});
  }
}

/// One `session/list` row (also the payload of `api-session/added`).
///
/// `session/list` returns archived sessions too: filter them with the
/// `archivedSessionIds` from [WorkspaceBaseline]/[WorkspaceArchivedUpdate].
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    required this.agentAvailable,
    this.cwd,
    this.parentSessionId,
    this.origin,
    this.projections = SessionProjections.empty,
    this.projectionsKind,
    this.raw = const {},
  });

  factory SessionSummary.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final hints = asMap(map['projections']);
    return SessionSummary(
      sessionId: asString(map['sessionId']) ?? '',
      updatedAt: asEpochMs(map['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      running: map['running'] == true,
      blank: map['blank'] == true,
      agentAvailable: map['agentAvailable'] == true,
      cwd: asString(map['cwd']),
      parentSessionId: asString(map['parentSessionId']),
      origin: asString(map['origin']),
      projections: hints == null ? SessionProjections.empty : SessionProjections.fromJson(hints),
      projectionsKind: asString(hints?['kind']),
      raw: map,
    );
  }

  final String sessionId;
  final DateTime updatedAt;
  final bool running;

  /// No turn yet ("New session").
  final bool blank;

  /// The Host currently holds a live Agent for it.
  final bool agentAvailable;
  final String? cwd;
  final String? parentSessionId;

  /// `subagent` for child sessions; hide those from a top-level list.
  final String? origin;

  /// Partial, possibly stale hints (`kind` cached|sequenced).
  final SessionProjections projections;
  final String? projectionsKind;
  final Map<String, Object?> raw;

  String? get title => projections.title;
  bool get isSubagent => origin == 'subagent';

  SessionSummary copyWith({
    bool? running,
    DateTime? updatedAt,
    bool? blank,
    SessionProjections? projections,
    String? projectionsKind,
  }) => SessionSummary(
    sessionId: sessionId,
    updatedAt: updatedAt ?? this.updatedAt,
    running: running ?? this.running,
    blank: blank ?? this.blank,
    agentAvailable: agentAvailable,
    cwd: cwd,
    parentSessionId: parentSessionId,
    origin: origin,
    projections: projections ?? this.projections,
    projectionsKind: projectionsKind ?? this.projectionsKind,
    raw: raw,
  );
}

class SessionCreated {
  const SessionCreated(this.sessionId, this.agentPreset);
  final String sessionId;
  final String? agentPreset;
}

/// Immutable storage header from the follow snapshot.
class SessionHeader {
  const SessionHeader({
    required this.id,
    required this.version,
    required this.createdAt,
    required this.isSeeded,
    this.cwd,
    this.parentSession,
    this.origin,
    this.agentPreset,
  });

  factory SessionHeader.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return SessionHeader(
      id: asString(map['id']) ?? '',
      version: asInt(map['version']) ?? 0,
      createdAt: asEpochMs(map['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      isSeeded: map['isSeeded'] == true,
      cwd: asString(map['cwd']),
      parentSession: asString(map['parentSession']),
      origin: asString(map['origin']),
      agentPreset: asString(map['agentPreset']),
    );
  }

  final String id;

  /// Session format version (4 on 0.2.0-rc.2 and 0.2.1-rc.2).
  final int version;
  final DateTime createdAt;
  final bool isSeeded;
  final String? cwd;
  final String? parentSession;
  final String? origin;
  final String? agentPreset;
}

class HistoryPage {
  const HistoryPage(this.events, this.hasMore);
  final List<SessionLogEvent> events;

  /// Older events exist before the first one in [events].
  final bool hasMore;
}

class ReasoningEffort {
  const ReasoningEffort(this.id, this.name, this.description);
  final String id;
  final String name;
  final String? description;
}

class ModelInfo {
  const ModelInfo({
    required this.provider,
    required this.id,
    required this.name,
    this.description,
    this.efforts = const [],
    this.defaultEffort,
  });

  final String provider;
  final String id;
  final String name;
  final String? description;

  /// Selectable reasoning efforts (`off`, `low`, `high`, `max` for DeepSeek).
  final List<ReasoningEffort> efforts;
  final String? defaultEffort;
}

class ProviderGroup {
  const ProviderGroup(this.id, this.name, this.models);
  final String id;
  final String name;
  final List<ModelInfo> models;
}

/// `session/modelCatalog`.
///
/// 0.2.1-rc.2 only lists providers that have a usable credential: with no
/// DeepSeek key both [ModelCatalog] lists are empty (0.2.0-rc.2 still listed
/// `deepseek-official`). Re-read it after `setProviderKey`.
class ModelCatalog {
  const ModelCatalog({
    required this.defaultSelection,
    required this.routableProviders,
    required this.groups,
    required this.failures,
  });

  factory ModelCatalog.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final groups = asListOrEmpty(map['groups'])
        .map((g) {
          final group = asMapOrEmpty(g);
          final providerId = asString(group['id']) ?? '';
          return ProviderGroup(
            providerId,
            asString(group['name']) ?? providerId,
            asListOrEmpty(group['models'])
                .map((m) {
                  final model = asMapOrEmpty(m);
                  final reasoning = asMap(model['reasoning']);
                  return ModelInfo(
                    provider: providerId,
                    id: asString(model['id']) ?? '',
                    name: asString(model['name']) ?? asString(model['id']) ?? '',
                    description: asString(model['description']),
                    efforts: asListOrEmpty(reasoning?['efforts'])
                        .map((e) {
                          final effort = asMapOrEmpty(e);
                          return ReasoningEffort(
                            asString(effort['id']) ?? '',
                            asString(effort['name']) ?? asString(effort['id']) ?? '',
                            asString(effort['description']),
                          );
                        })
                        .toList(growable: false),
                    defaultEffort: asString(reasoning?['defaultEffort']),
                  );
                })
                .toList(growable: false),
          );
        })
        .toList(growable: false);
    return ModelCatalog(
      defaultSelection: ModelSelection.fromJson(map['default']),
      routableProviders: asStringList(map['routableProviders']),
      groups: groups,
      failures: asListOrEmpty(map['failures'])
          .map((f) {
            final failure = asMapOrEmpty(f);
            return (
              provider: asString(failure['id']) ?? '',
              name: asString(failure['name']) ?? '',
              message: asString(failure['message']) ?? '',
            );
          })
          .toList(growable: false),
    );
  }

  /// Used by sessions that never selected a model.
  final ModelSelection? defaultSelection;

  /// Providers with at least one available model right now.
  final List<String> routableProviders;
  final List<ProviderGroup> groups;
  final List<({String provider, String name, String message})> failures;

  Iterable<ModelInfo> get models => groups.expand((g) => g.models);
}

/// `credentials/describe` row: never the value itself.
class CredentialStatus {
  const CredentialStatus({required this.configured, required this.writable, this.source});

  factory CredentialStatus.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return CredentialStatus(
      configured: map['configured'] == true,
      writable: map['writable'] == true,
      source: asString(map['source']),
    );
  }

  final bool configured;

  /// `false` when the launch environment supplies the value (e.g.
  /// `DEEPSEEK_API_KEY=... dsh web`): `credentials/set` is then rejected.
  final bool writable;

  /// `env` or `file` on 0.2.0-rc.2.
  final String? source;
}

class Workspace {
  const Workspace({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    this.createdAt,
    this.updatedAt,
  });

  factory Workspace.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return Workspace(
      workspaceId: asString(map['workspaceId']) ?? '',
      path: asString(map['path']) ?? '',
      title: asString(map['title']) ?? '',
      sessionIds: asStringList(map['sessionIds']),
      createdAt: DateTime.tryParse(asString(map['createdAt']) ?? ''),
      updatedAt: DateTime.tryParse(asString(map['updatedAt']) ?? ''),
    );
  }

  final String workspaceId;
  final String path;
  final String title;

  /// Sessions attached to this workspace (created with `workspaceId`).
  final List<String> sessionIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

/// Frames of the `workspace/follow` stream.
sealed class WorkspaceUpdate {
  const WorkspaceUpdate();

  static WorkspaceUpdate fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    switch (asString(map['type'])) {
      case 'baseline':
        final value = asMapOrEmpty(map['value']);
        return WorkspaceBaseline(
          asListOrEmpty(value['items']).map(Workspace.fromJson).toList(growable: false),
          asStringList(value['archivedSessionIds']),
          asStringList(value['pinnedSessionIds']),
        );
      case 'upsert':
        return WorkspaceUpsert(Workspace.fromJson(map['workspace']));
      case 'remove':
        return WorkspaceRemoved(asString(map['workspaceId']) ?? '');
      case 'order':
        return WorkspaceOrder(asStringList(map['workspaceIds']));
      case 'archived':
        return WorkspaceArchivedUpdate(asStringList(map['archivedSessionIds']));
      case 'pinned':
        return WorkspacePinnedUpdate(asStringList(map['pinnedSessionIds']));
      default:
        return UnknownWorkspaceUpdate(map);
    }
  }
}

final class WorkspaceBaseline extends WorkspaceUpdate {
  const WorkspaceBaseline(this.workspaces, this.archivedSessionIds, this.pinnedSessionIds);
  final List<Workspace> workspaces;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;
}

final class WorkspaceUpsert extends WorkspaceUpdate {
  const WorkspaceUpsert(this.workspace);
  final Workspace workspace;
}

final class WorkspaceRemoved extends WorkspaceUpdate {
  const WorkspaceRemoved(this.workspaceId);
  final String workspaceId;
}

final class WorkspaceOrder extends WorkspaceUpdate {
  const WorkspaceOrder(this.workspaceIds);
  final List<String> workspaceIds;
}

/// The complete archived set (replace, not delta).
final class WorkspaceArchivedUpdate extends WorkspaceUpdate {
  const WorkspaceArchivedUpdate(this.archivedSessionIds);
  final List<String> archivedSessionIds;
}

final class WorkspacePinnedUpdate extends WorkspaceUpdate {
  const WorkspacePinnedUpdate(this.pinnedSessionIds);
  final List<String> pinnedSessionIds;
}

final class UnknownWorkspaceUpdate extends WorkspaceUpdate {
  const UnknownWorkspaceUpdate(this.raw);
  final Map<String, Object?> raw;
}

// =============================================================================
// Approvals and user questions (Host -> client waterfalls on `$events`)
// =============================================================================

/// The decision a client returns for an [ApprovalRequest].
enum ApprovalDecision {
  /// One-shot grant (`allowed-once`); there is no "always allow" in rc.2.
  allowOnce('allowed-once'),

  /// Explicit rejection (`rejected`): the tool call fails for the model.
  reject('rejected'),

  /// Let other connected clients answer (`{kind: 'next'}`). When every
  /// client passes, the request falls through to the Host's next answerer.
  pass('next');

  const ApprovalDecision(this.wire);
  final String wire;
}

/// Closed approval outcome vocabulary recorded in `approval/decided`.
enum ApprovalOutcome {
  allowedOnce,
  rejected,
  cancelled,
  unavailable,
  unknown;

  static ApprovalOutcome parse(Object? value) => switch (value) {
    'allowed-once' => allowedOnce,
    'rejected' => rejected,
    'cancelled' => cancelled,
    'unavailable' => unavailable,
    _ => unknown,
  };
}

/// `approval/request` waterfall: a sensitive tool action waits for a human.
///
/// Answer with `DshClient.respondApproval`. The same [eventId] is redelivered
/// to every newly connected `$events` client while it is pending, and a
/// [HostRequestCancelledEvent] with this [eventId] arrives once any client
/// answered or the request was withdrawn (turn cancelled, Agent released).
class ApprovalRequest {
  const ApprovalRequest({
    required this.eventId,
    required this.sessionId,
    required this.toolName,
    this.callId,
    this.reason,
    this.displayReason = const {},
    this.raw = const {},
  });

  factory ApprovalRequest.fromWaterfall(String eventId, String agentId, Object? request) {
    final map = asMapOrEmpty(request);
    final display = asMapOrEmpty(map['displayReason']);
    return ApprovalRequest(
      eventId: eventId,
      sessionId: agentId,
      toolName: asString(map['toolName']) ?? 'tool',
      callId: asString(map['callId']),
      reason: asString(map['reason']),
      displayReason: {
        for (final entry in display.entries)
          if (entry.value is String) entry.key: entry.value! as String,
      },
      raw: map,
    );
  }

  final String eventId;

  /// The Agent id; equal to the session id for ordinary sessions.
  final String sessionId;
  final String toolName;

  /// The exact `tool/call` being decided, when the asker had one.
  final String? callId;
  final String? reason;

  /// Localized presentation text keyed by locale (`en` always present).
  final Map<String, String> displayReason;
  final Map<String, Object?> raw;

  /// Best text to show: localized display reason, else [reason].
  String describe([String locale = 'en']) =>
      displayReason[locale] ?? displayReason['en'] ?? reason ?? 'Allow $toolName?';
}

class QuestionOption {
  const QuestionOption(this.label, this.description);
  final String label;
  final String? description;
}

class UserQuestion {
  const UserQuestion({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options = const [],
    this.multiSelect = false,
    this.intent,
  });

  factory UserQuestion.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return UserQuestion(
      id: asString(map['id']) ?? '',
      question: asString(map['question']) ?? '',
      detail: asString(map['detail']),
      header: asString(map['header']),
      options: asListOrEmpty(map['options'])
          .map((o) {
            final option = asMapOrEmpty(o);
            return QuestionOption(asString(option['label']) ?? '', asString(option['description']));
          })
          .toList(growable: false),
      multiSelect: map['multiSelect'] == true,
      intent: asMap(map['intent']),
    );
  }

  final String id;
  final String question;

  /// Markdown detail (the plan text for `intent.kind == 'plan-review'`).
  final String? detail;
  final String? header;
  final List<QuestionOption> options;
  final bool multiSelect;

  /// e.g. `{kind: 'plan-review', approve: '<option label>'}`.
  final Map<String, Object?>? intent;
}

class QuestionAnswer {
  const QuestionAnswer(this.id, {this.selected = const [], this.custom});
  final String id;

  /// Selected option labels (empty when [custom] replaces a single choice).
  final List<String> selected;
  final String? custom;

  Map<String, Object?> toJson() => {'id': id, 'selected': selected, if (custom != null) 'custom': custom};
}

/// `user-questions/request` waterfall (the `ask_user_question` tool).
class UserQuestionRequest {
  const UserQuestionRequest({
    required this.eventId,
    required this.sessionId,
    required this.questions,
    this.waitCallId,
    this.timed = false,
    this.raw = const {},
  });

  factory UserQuestionRequest.fromWaterfall(String eventId, String agentId, Object? request) {
    final map = asMapOrEmpty(request);
    final wait = asMap(map['wait']);
    return UserQuestionRequest(
      eventId: eventId,
      sessionId: agentId,
      questions: asListOrEmpty(map['questions']).map(UserQuestion.fromJson).toList(growable: false),
      waitCallId: asString(wait?['callId']),
      timed: wait?['timed'] == true,
      raw: map,
    );
  }

  final String eventId;
  final String sessionId;
  final List<UserQuestion> questions;

  /// Tool call the question card is keyed by.
  final String? waitCallId;

  /// Foreground timed wait: claim it with `userQuestions/attachWait` before
  /// counting down; unanswered it times out and becomes `continued`.
  final bool timed;
  final Map<String, Object?> raw;
}

// =============================================================================
// Events
// =============================================================================

/// Everything a session watcher or the host event stream can deliver.
sealed class DshEvent {
  const DshEvent();
}

/// Connection state of the mux, surfaced inside `watch()` streams.
enum DshConnectionState {
  idle,
  connecting,
  connected,

  /// The carrier dropped; automatic retry is scheduled.
  reconnecting,

  /// 401/403 on the WebSocket upgrade: log in again before retrying.
  unauthorized,
  closed,
}

final class ConnectionStateEvent extends DshEvent {
  const ConnectionStateEvent(this.state, {this.error});
  final DshConnectionState state;
  final Object? error;
}

/// Local ownership of one follow attempt, independent of the mux generation.
/// Retirement is immediate, even before queued stream events reach a consumer.
/// This is client bookkeeping; it is never sent to the Host.
class SessionFollowEpoch {
  SessionFollowEpoch({this.generation});

  /// The mux generation identity captured when the follow opens; null while
  /// waiting for a connection. Kept opaque to avoid a model/transport cycle.
  final Object? generation;
  bool _current = true;
  bool get isCurrent => _current;

  /// Revocation is permanent. A retry must allocate a new epoch.
  void retire() => _current = false;
}

/// The session is waiting for a complete snapshot in [epoch]. A connected mux
/// alone does not make the previous running state or inbox current.
final class SessionSyncEvent extends DshEvent {
  const SessionSyncEvent(this.epoch);
  final SessionFollowEpoch epoch;
}

/// Raw follow frame whose `type` this client does not know.
final class UnknownFrameEvent extends DshEvent {
  const UnknownFrameEvent(this.raw);
  final Object? raw;
}

/// First frame of every `session/follow` generation.
///
/// [events] is a window of the durable log ending at [cursor]; on a resync
/// ([isResync]) merge it by `seq` into what you already have (the watcher
/// has already filled any gap since the last event it delivered). Durable
/// events after the snapshot always continue at `cursor + 1`.
final class SessionSnapshotEvent extends DshEvent {
  const SessionSnapshotEvent({
    required this.sessionId,
    required this.header,
    required this.cursor,
    required this.events,
    required this.hasMore,
    required this.projections,
    required this.assistantRevision,
    this.activeAttempt,
    this.isResync = false,
    this.followEpoch,
  });

  factory SessionSnapshotEvent.fromJson(String sessionId, Object? json, {bool isResync = false}) {
    final map = asMapOrEmpty(json);
    final stream = asMap(map['assistantStream']);
    final attempt = asMap(stream?['activeAttempt']);
    return SessionSnapshotEvent(
      sessionId: sessionId,
      header: SessionHeader.fromJson(map['header']),
      cursor: asInt(map['cursor']) ?? -1,
      events: asListOrEmpty(
        map['records'],
      ).map((r) => SessionLogEvent.fromJson(asMapOrEmpty(r)['event'])).toList(growable: false),
      hasMore: map['hasMore'] == true,
      projections: SessionProjections.fromJson(map['projections']),
      assistantRevision: asInt(stream?['revision']),
      activeAttempt: attempt == null ? null : ActiveAttempt.fromJson(attempt),
      isResync: isResync,
    );
  }

  final String sessionId;
  final SessionHeader header;

  /// Seq of the last durable event at the cut (`-1` for an empty log).
  final int cursor;
  final List<SessionLogEvent> events;

  /// Older history exists before `events.first` (page with `history()`).
  final bool hasMore;
  final SessionProjections projections;

  /// Baseline for assistant-stream revisions (each frame is +1).
  final int? assistantRevision;

  /// Model attempt streaming right now, with everything streamed so far.
  final ActiveAttempt? activeAttempt;
  final bool isResync;

  /// Local follow ownership; absent for snapshots decoded outside a watch.
  final SessionFollowEpoch? followEpoch;

  SessionSnapshotEvent withEvents(List<SessionLogEvent> events, {SessionFollowEpoch? followEpoch}) =>
      SessionSnapshotEvent(
        sessionId: sessionId,
        header: header,
        cursor: cursor,
        events: events,
        hasMore: hasMore,
        projections: projections,
        assistantRevision: assistantRevision,
        activeAttempt: activeAttempt,
        isResync: isResync,
        followEpoch: followEpoch ?? this.followEpoch,
      );
}

/// In-flight model attempt carried by a follow snapshot.
class ActiveAttempt {
  const ActiveAttempt({
    required this.attemptId,
    required this.startedAfterSeq,
    required this.turn,
    required this.step,
    required this.nextIndex,
    required this.chunks,
  });

  factory ActiveAttempt.fromJson(Map<String, Object?> map) => ActiveAttempt(
    attemptId: asString(map['attemptId']) ?? '',
    startedAfterSeq: asInt(map['startedAfterSeq']) ?? -1,
    turn: asInt(map['turn']) ?? 0,
    step: asInt(map['step']) ?? 0,
    nextIndex: asInt(map['nextIndex']) ?? 0,
    chunks: expandCompactStream(map['stream']),
  );

  final String attemptId;
  final int startedAfterSeq;
  final int turn;
  final int step;

  /// Index the next `chunk` frame of this attempt will carry.
  final int nextIndex;
  final List<TimedChunk> chunks;
}

// -----------------------------------------------------------------------------
// Durable session log events (`session/follow` `event` frames, `session/page`)
// -----------------------------------------------------------------------------

/// One durable Session event: contiguous `seq`, epoch-ms `time`, typed `data`.
sealed class SessionLogEvent extends DshEvent {
  const SessionLogEvent(this.seq, this.time, this.type, this.data);

  final int seq;
  final DateTime time;
  final String type;

  /// The raw `data` object (kept for forward compatibility and debugging).
  final Map<String, Object?> data;

  /// Parses one `SessionWireEvent`; never throws.
  static SessionLogEvent fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final seq = asInt(map['seq']) ?? -1;
    final time = asEpochMs(map['time']) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final type = asString(map['type']) ?? '';
    final rawData = map['data'];
    final data = asMapOrEmpty(rawData);
    int turn() => asInt(data['turn']) ?? 0;
    int step() => asInt(data['step']) ?? 0;
    switch (type) {
      case 'turn/start':
        return TurnStartedEvent(seq, time, data, turn: turn());
      case 'turn/end':
        return TurnEndedEvent(seq, time, data, turn: turn(), reason: TurnEndReason.fromJson(data['reason']));
      case 'step/start':
        return StepStartedEvent(seq, time, data, turn: turn(), step: step());
      case 'step/end':
        return StepEndedEvent(seq, time, data, turn: turn(), step: step());
      case 'user/message':
        return UserMessageEvent(seq, time, data, message: Message.fromJson(data));
      case 'assistant/message':
        return AssistantMessageEvent(
          seq,
          time,
          data,
          turn: turn(),
          step: step(),
          message: Message.fromJson(data['message']),
          usage: TokenUsage.fromJson(data['usage']),
          interrupted: data['interrupted'] == true,
        );
      case 'assistant/attempt':
        return AssistantAttemptEvent(seq, time, data, turn: turn(), step: step());
      case 'tool/call':
        return ToolCallEvent(
          seq,
          time,
          data,
          turn: turn(),
          step: step(),
          callId: asString(data['callId']) ?? '',
          name: asString(data['name']) ?? '',
          arguments: asString(data['arguments']) ?? '',
        );
      case 'tool/result':
        final message = Message.fromJson(data['message']);
        final error = asMap(data['error']);
        return ToolResultEvent(
          seq,
          time,
          data,
          turn: turn(),
          step: step(),
          message: message,
          failure: error == null
              ? null
              : ToolFailure(
                  asString(error['name']) ?? 'Error',
                  asString(error['code']) ?? 'UNKNOWN',
                  asString(error['reason']),
                ),
        );
      case 'session/title':
        return TitleChangedEvent(
          seq,
          time,
          data,
          title: asString(data['title']) ?? '',
          sourceKind: asString(asMap(data['source'])?['kind']) ?? 'unknown',
        );
      case 'model/selection':
        return ModelSelectedEvent(seq, time, data, selection: ModelSelection.fromJson(data));
      case 'approval/asked':
        return ApprovalAskedEvent(
          seq,
          time,
          data,
          approvalId: asString(data['id']) ?? '',
          toolName: asString(data['toolName']) ?? '',
          callId: asString(data['callId']),
          reason: asString(data['reason']),
        );
      case 'approval/decided':
        return ApprovalDecidedEvent(
          seq,
          time,
          data,
          approvalId: asString(data['id']) ?? '',
          outcome: ApprovalOutcome.parse(data['outcome']),
        );
      case 'approval/policy':
        return ApprovalPolicyChangedEvent(seq, time, data, policy: asString(data['policy']) ?? '');
      case 'permission/preset':
        return PermissionPresetChangedEvent(seq, time, data, preset: asString(data['preset']) ?? '');
      case 'sandbox/mode':
        return SandboxModeChangedEvent(seq, time, data, mode: asString(data['mode']) ?? '');
      case 'agent/inbox/spliced':
        return InboxSplicedEvent(
          seq,
          time,
          data,
          target: asString(data['target']) ?? '',
          start: asInt(data['start']) ?? 0,
          removedCount: asInt(data['removedCount']) ?? 0,
          inserted: asListOrEmpty(data['inserted']).map(Message.fromJson).toList(growable: false),
          canceled: data['outcome'] == 'canceled',
        );
      case 'llm/retry':
        return LlmRetryEvent(
          seq,
          time,
          data,
          turn: turn(),
          step: step(),
          retry: asInt(data['retry']) ?? 0,
          maxRetries: asInt(data['maxRetries']),
          delayMs: asInt(data['delayMs']) ?? 0,
          failure: LlmFailure.fromJson(data['failure']),
        );
      case 'todo/write':
        return TodoWriteEvent(
          seq,
          time,
          data,
          todos: asListOrEmpty(data['todos']).map(TodoItem.fromJson).toList(growable: false),
        );
      default:
        return UnknownEvent(seq, time, type, data, rawData: rawData);
    }
  }
}

final class TurnStartedEvent extends SessionLogEvent {
  const TurnStartedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.turn})
    : super(seq, time, 'turn/start', data);
  final int turn;
}

/// Why a turn ended (`TurnEndReason`).
class TurnEndReason {
  const TurnEndReason(this.kind, {this.cancelCause, this.error, this.raw = const {}});

  factory TurnEndReason.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return TurnEndReason(
      asString(map['kind']) ?? 'unknown',
      cancelCause: asString(asMap(map['reason'])?['kind']),
      error: LlmFailure.fromJson(map['error']),
      raw: map,
    );
  }

  /// `completed`, `aborted`, `blocked`, `error`, `max-tokens`,
  /// `interrupted` (crash-closed), `forked`.
  final String kind;

  /// For `aborted`: `user`, `parent`, `hook`, `disposed`, `legacy`.
  final String? cancelCause;

  /// For `error`: the structured failure (e.g. `MISSING_CREDENTIAL`).
  final LlmFailure? error;
  final Map<String, Object?> raw;

  bool get isCompleted => kind == 'completed';
  bool get isAborted => kind == 'aborted';
  bool get isError => kind == 'error';
}

final class TurnEndedEvent extends SessionLogEvent {
  const TurnEndedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.turn, required this.reason})
    : super(seq, time, 'turn/end', data);
  final int turn;
  final TurnEndReason reason;
}

final class StepStartedEvent extends SessionLogEvent {
  const StepStartedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.turn, required this.step})
    : super(seq, time, 'step/start', data);
  final int turn;
  final int step;
}

final class StepEndedEvent extends SessionLogEvent {
  const StepEndedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.turn, required this.step})
    : super(seq, time, 'step/end', data);
  final int turn;
  final int step;
}

/// A user-role message on the model surface. Only [isHumanPrompt] ones are
/// what the person typed; others are injected context.
final class UserMessageEvent extends SessionLogEvent {
  const UserMessageEvent(int seq, DateTime time, Map<String, Object?> data, {required this.message})
    : super(seq, time, 'user/message', data);
  final Message message;

  bool get isHumanPrompt => message.source.isHuman;

  /// The `requestId` passed to `session/prompt`, for optimistic-echo matching.
  String? get requestId => message.source.requestId;
}

/// The committed assistant message of one step (text, reasoning, tool calls).
final class AssistantMessageEvent extends SessionLogEvent {
  const AssistantMessageEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.turn,
    required this.step,
    required this.message,
    this.usage,
    this.interrupted = false,
  }) : super(seq, time, 'assistant/message', data);
  final int turn;
  final int step;
  final Message message;
  final TokenUsage? usage;

  /// Cancelled mid-stream: [message] holds the delivered prefix.
  final bool interrupted;

  /// The exact timed stream (`data.stream`), expanded on demand.
  List<TimedChunk> get chunks => expandCompactStream(data['stream']);
}

/// A model attempt that committed no message (failed, retried, cancelled).
final class AssistantAttemptEvent extends SessionLogEvent {
  const AssistantAttemptEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.turn,
    required this.step,
  }) : super(seq, time, 'assistant/attempt', data);
  final int turn;
  final int step;

  List<TimedChunk> get chunks => expandCompactStream(data['stream']);

  /// The terminal failure, when the attempt's finish chunk carried one.
  LlmFailure? get failure {
    for (final timed in chunks.reversed) {
      final chunk = timed.chunk;
      if (chunk is FinishChunk) return chunk.failure;
    }
    return null;
  }
}

/// The model requested a tool invocation (logged when it is dispatched).
final class ToolCallEvent extends SessionLogEvent {
  const ToolCallEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.turn,
    required this.step,
    required this.callId,
    required this.name,
    required this.arguments,
  }) : super(seq, time, 'tool/call', data);
  final int turn;
  final int step;
  final String callId;
  final String name;

  /// Raw JSON argument string as the model produced it.
  final String arguments;

  Map<String, Object?>? get decodedArguments => asMap(tryDecodeJson(arguments));
}

class ToolFailure {
  const ToolFailure(this.name, this.code, this.reason);
  final String name;
  final String code;

  /// User-facing reason (outside model content).
  final String? reason;
}

final class ToolResultEvent extends SessionLogEvent {
  const ToolResultEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.turn,
    required this.step,
    required this.message,
    this.failure,
  }) : super(seq, time, 'tool/result', data);
  final int turn;
  final int step;

  /// Tool-role message: [Message.toolCallId], [Message.isError], content parts.
  final Message message;
  final ToolFailure? failure;

  String get callId => message.toolCallId ?? '';
  bool get isError => message.isError;

  /// Tool-private presentation payload (`data.meta`), e.g. diffs.
  Object? get meta => data['meta'];
}

final class TitleChangedEvent extends SessionLogEvent {
  const TitleChangedEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.title,
    required this.sourceKind,
  }) : super(seq, time, 'session/title', data);
  final String title;

  /// `user` (rename), `provider` (LLM-generated), `fallback`.
  final String sourceKind;
}

final class ModelSelectedEvent extends SessionLogEvent {
  const ModelSelectedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.selection})
    : super(seq, time, 'model/selection', data);
  final ModelSelection? selection;
}

/// Audit record: a question went to the approval answerers.
final class ApprovalAskedEvent extends SessionLogEvent {
  const ApprovalAskedEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.approvalId,
    required this.toolName,
    this.callId,
    this.reason,
  }) : super(seq, time, 'approval/asked', data);
  final String approvalId;
  final String toolName;
  final String? callId;
  final String? reason;
}

final class ApprovalDecidedEvent extends SessionLogEvent {
  const ApprovalDecidedEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.approvalId,
    required this.outcome,
  }) : super(seq, time, 'approval/decided', data);
  final String approvalId;
  final ApprovalOutcome outcome;
}

final class ApprovalPolicyChangedEvent extends SessionLogEvent {
  const ApprovalPolicyChangedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.policy})
    : super(seq, time, 'approval/policy', data);

  /// `ask` or `never`.
  final String policy;
}

final class PermissionPresetChangedEvent extends SessionLogEvent {
  const PermissionPresetChangedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.preset})
    : super(seq, time, 'permission/preset', data);
  final String preset;
}

final class SandboxModeChangedEvent extends SessionLogEvent {
  const SandboxModeChangedEvent(int seq, DateTime time, Map<String, Object?> data, {required this.mode})
    : super(seq, time, 'sandbox/mode', data);

  /// `read-only`, `workspace-write`, `danger-full-access`.
  final String mode;
}

/// Queue (agent inbox) mutation: prompts waiting for the next turn/step.
final class InboxSplicedEvent extends SessionLogEvent {
  const InboxSplicedEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.target,
    required this.start,
    required this.removedCount,
    required this.inserted,
    this.canceled = false,
  }) : super(seq, time, 'agent/inbox/spliced', data);

  /// `next-turn` (queued) or `next-step` (steering).
  final String target;
  final int start;
  final int removedCount;
  final List<Message> inserted;
  final bool canceled;
}

/// The Host is retrying a failed model request.
final class LlmRetryEvent extends SessionLogEvent {
  const LlmRetryEvent(
    int seq,
    DateTime time,
    Map<String, Object?> data, {
    required this.turn,
    required this.step,
    required this.retry,
    required this.delayMs,
    this.maxRetries,
    this.failure,
  }) : super(seq, time, 'llm/retry', data);
  final int turn;
  final int step;
  final int retry;
  final int? maxRetries;
  final int delayMs;
  final LlmFailure? failure;
}

final class TodoWriteEvent extends SessionLogEvent {
  const TodoWriteEvent(int seq, DateTime time, Map<String, Object?> data, {required this.todos})
    : super(seq, time, 'todo/write', data);
  final List<TodoItem> todos;
}

/// Any durable event this client does not model (`system/message`,
/// `request/header`, `compaction/*`, plugin events, future types). Kept, never
/// thrown, so `seq` continuity is preserved.
final class UnknownEvent extends SessionLogEvent {
  const UnknownEvent(super.seq, super.time, super.type, super.data, {this.rawData});

  /// Original `data` value (may be a non-object JSON value).
  final Object? rawData;

  /// Whether a supported DSH release declares this type (as opposed to a
  /// newer/plugin type).
  bool get isKnownType => knownSessionEventTypes.contains(type);
}

/// Union of `KNOWN_SESSION_EVENT_TYPES` in dsh-session 0.2.0-rc.2 and
/// 0.2.1-rc.2 (0.2.1 adds `job/registered`, `job/settled` and drops
/// `workspace/changes`; the session format version is 4 in both).
const Set<String> knownSessionEventTypes = {
  'agent-preset/selected',
  'agent/inbox/spliced',
  'approval/asked',
  'approval/decided',
  'approval/policy',
  'assistant/attempt',
  'assistant/message',
  'command/done',
  'command/run',
  'compaction/end',
  'compaction/prune',
  'compaction/start',
  'compaction/summary',
  'deliverables/presented',
  'developer/message',
  'feedback/message-delete',
  'feedback/message-put',
  'feedback/record',
  'goal/change',
  'hook/invoked',
  'hook/result',
  'image/offload',
  'job/registered',
  'job/settled',
  'llm/retry',
  'llm/retry-started',
  'model/selection',
  'permission/preset',
  'plan/mode',
  'request/context',
  'request/header',
  'sandbox/mode',
  'schedule/change',
  'session-log-deepseek/delivery-accepted',
  'session/end-seed',
  'session/title',
  'session/title-llm-request',
  'step/end',
  'step/start',
  'subagent/catalog',
  'subagent/descriptor',
  'subagent/model-selection-policy',
  'system/message',
  'team/member',
  'team/message/delivered',
  'team/message/queued',
  'team/task',
  'todo/write',
  'tool-workflow/agent-end',
  'tool-workflow/agent-start',
  'tool-workflow/run-end',
  'tool-workflow/run-start',
  'tool/call',
  'tool/ptc-dispatch',
  'tool/ptc-dispatch-start',
  'tool/result',
  'turn/end',
  'turn/start',
  'user/message',
  'web/deepseek-search-llm-request',
  'workspace/changes',
};

// -----------------------------------------------------------------------------
// Live assistant stream (cursorless, `assistantStream: true` follow frames)
// -----------------------------------------------------------------------------

sealed class AssistantStreamEvent extends DshEvent {
  const AssistantStreamEvent(this.attemptId, this.revision);
  final String attemptId;

  /// Per-follow counter; each frame is exactly previous + 1.
  final int revision;

  static DshEvent fromFrame(Object? json) {
    final frame = asMapOrEmpty(json);
    final attemptId = asString(frame['attemptId']) ?? '';
    final revision = asInt(frame['revision']) ?? -1;
    switch (asString(frame['type'])) {
      case 'start':
        return AssistantStreamStarted(
          attemptId,
          revision,
          turn: asInt(frame['turn']) ?? 0,
          step: asInt(frame['step']) ?? 0,
          startedAfterSeq: asInt(frame['startedAfterSeq']) ?? -1,
        );
      case 'chunk':
        return AssistantChunkEvent(
          attemptId,
          revision,
          index: asInt(frame['index']) ?? 0,
          time: asEpochMs(frame['time']) ?? DateTime.now(),
          chunk: StreamChunk.fromJson(frame['chunk']),
        );
      case 'end':
        final outcome = asMapOrEmpty(frame['outcome']);
        return AssistantStreamEnded(
          attemptId,
          revision,
          index: asInt(frame['index']) ?? 0,
          committed: outcome['kind'] == 'committed',
          committedEventType: asString(outcome['eventType']),
          committedSeq: asInt(outcome['seq']),
        );
      default:
        return UnknownFrameEvent(frame);
    }
  }
}

/// A model attempt began streaming after durable event [startedAfterSeq].
final class AssistantStreamStarted extends AssistantStreamEvent {
  const AssistantStreamStarted(
    super.attemptId,
    super.revision, {
    required this.turn,
    required this.step,
    required this.startedAfterSeq,
  });
  final int turn;
  final int step;
  final int startedAfterSeq;
}

/// One streamed chunk: text/reasoning/tool-call deltas, block boundaries,
/// usage and finish. [index] is dense per attempt (0, 1, 2, ...).
final class AssistantChunkEvent extends AssistantStreamEvent {
  const AssistantChunkEvent(
    super.attemptId,
    super.revision, {
    required this.index,
    required this.time,
    required this.chunk,
  });
  final int index;
  final DateTime time;
  final StreamChunk chunk;
}

/// The attempt settled: [committed] with the durable `assistant/message` or
/// `assistant/attempt` at [committedSeq], or abandoned (drop the draft).
final class AssistantStreamEnded extends AssistantStreamEvent {
  const AssistantStreamEnded(
    super.attemptId,
    super.revision, {
    required this.index,
    required this.committed,
    this.committedEventType,
    this.committedSeq,
  });
  final int index;
  final bool committed;
  final String? committedEventType;
  final int? committedSeq;
}

// -----------------------------------------------------------------------------
// Host events (`$events` stream)
// -----------------------------------------------------------------------------

sealed class HostEvent extends DshEvent {
  const HostEvent();

  /// Parses one `$events` item: `ready`, `emit`, `waterfall` or `cancel`.
  static HostEvent fromFrame(Object? json) {
    final frame = asMapOrEmpty(json);
    switch (asString(frame['type'])) {
      case 'ready':
        return HostReadyEvent(asString(frame['clientId']) ?? '', asString(asMap(frame['host'])?['home']) ?? '');
      case 'emit':
        return _emit(asString(frame['event']) ?? '', asListOrEmpty(frame['args']));
      case 'waterfall':
        final event = asString(frame['event']) ?? '';
        final eventId = asString(frame['eventId']) ?? '';
        final agentId = asString(frame['agentId']) ?? '';
        if (event == 'approval/request') {
          return ApprovalRequestedEvent(ApprovalRequest.fromWaterfall(eventId, agentId, frame['request']));
        }
        if (event == 'user-questions/request') {
          return UserQuestionRequestedEvent(UserQuestionRequest.fromWaterfall(eventId, agentId, frame['request']));
        }
        return UnknownHostEvent(event, frame, eventId: eventId, agentId: agentId);
      case 'cancel':
        return HostRequestCancelledEvent(asString(frame['eventId']) ?? '');
      default:
        return UnknownHostEvent(asString(frame['type']) ?? '', frame);
    }
  }

  static HostEvent _emit(String event, List<Object?> args) {
    Object? arg(int i) => i < args.length ? args[i] : null;
    switch (event) {
      case 'api-session/added':
        return SessionAddedEvent(SessionSummary.fromJson(arg(0)));
      case 'api-session/removed':
        return SessionRemovedEvent(asString(arg(0)) ?? '');
      case 'api-session/status':
        return SessionStatusEvent(asString(arg(0)) ?? '', arg(1) == true);
      case 'api-session/activity':
        return SessionActivityEvent(asString(arg(0)) ?? '', asEpochMs(arg(1)) ?? DateTime.now());
      case 'api-session/error':
        return SessionErrorEvent(asString(arg(0)) ?? '', asString(arg(1)) ?? '');
      case 'credentials/reference-updated':
        return CredentialUpdatedEvent(asString(arg(0)) ?? '');
      case 'settings/document-updated':
        return SettingsUpdatedEvent(asString(arg(0)) ?? '', asInt(arg(1)));
      default:
        return UnknownHostEvent(event, {'type': 'emit', 'event': event, 'args': args});
    }
  }
}

/// Opening item of each `$events` generation.
final class HostReadyEvent extends HostEvent {
  const HostReadyEvent(this.clientId, this.home);

  /// Binds `$events/result` replies to this generation.
  final String clientId;

  /// Host account home, only for abbreviating displayed paths.
  final String home;
}

/// Emitted (possibly twice) when a session is created or adopted.
final class SessionAddedEvent extends HostEvent {
  const SessionAddedEvent(this.summary);
  final SessionSummary summary;
}

final class SessionRemovedEvent extends HostEvent {
  const SessionRemovedEvent(this.sessionId);
  final String sessionId;
}

/// A turn started (`running: true`) or the session went idle.
final class SessionStatusEvent extends HostEvent {
  const SessionStatusEvent(this.sessionId, this.running);
  final String sessionId;
  final bool running;
}

final class SessionActivityEvent extends HostEvent {
  const SessionActivityEvent(this.sessionId, this.updatedAt);
  final String sessionId;
  final DateTime updatedAt;
}

/// A live failure with no turn position (show as a toast/banner).
final class SessionErrorEvent extends HostEvent {
  const SessionErrorEvent(this.sessionId, this.message);
  final String sessionId;
  final String message;
}

final class CredentialUpdatedEvent extends HostEvent {
  const CredentialUpdatedEvent(this.ref);
  final String ref;
}

final class SettingsUpdatedEvent extends HostEvent {
  const SettingsUpdatedEvent(this.namespace, this.revision);
  final String namespace;
  final int? revision;
}

final class ApprovalRequestedEvent extends HostEvent {
  const ApprovalRequestedEvent(this.request);
  final ApprovalRequest request;
}

final class UserQuestionRequestedEvent extends HostEvent {
  const UserQuestionRequestedEvent(this.request);
  final UserQuestionRequest request;
}

/// A pending approval/question was answered (by any client) or withdrawn:
/// dismiss its UI.
final class HostRequestCancelledEvent extends HostEvent {
  const HostRequestCancelledEvent(this.eventId);
  final String eventId;
}

/// Any other forwarded Host event (`llm/adapters-updated`, `commands/change`,
/// `plugin-manager/*`, `schedule/changed`, ...), kept verbatim.
final class UnknownHostEvent extends HostEvent {
  const UnknownHostEvent(this.event, this.raw, {this.eventId, this.agentId});
  final String event;
  final Map<String, Object?> raw;

  /// Set for unknown waterfalls: answer with `respondHostEvent(..., pass)`.
  final String? eventId;
  final String? agentId;
}

/// Parses one `session/follow` item into a [DshEvent].
DshEvent parseFollowFrame(String sessionId, Object? value, {bool isResync = false}) {
  final map = asMap(value);
  switch (asString(map?['type'])) {
    case 'snapshot':
      return SessionSnapshotEvent.fromJson(sessionId, map, isResync: isResync);
    case 'event':
      return SessionLogEvent.fromJson(map!['event']);
    case 'assistant-stream':
      return AssistantStreamEvent.fromFrame(map!['frame']);
    default:
      return UnknownFrameEvent(value);
  }
}

/// Pretty JSON for debugging output.
String prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);
