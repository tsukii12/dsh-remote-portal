/// Message-level actions: branching a conversation at a message
/// (`session/fork`) and per-reply feedback (`messageFeedback/*`).
///
/// DSH 0.2.1 has no in-place edit, regenerate or rewind — a session log is
/// append-only. What it does have is `session/fork` at an exact event prefix,
/// which covers both "branch from this reply" ([forkPointAfterReply], the
/// official web client's branch button) and "edit this prompt and resend"
/// ([forkPointBeforePrompt]: a fork that stops just before the prompt).
library;

import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

/// Overall judgment of one reply.
enum FeedbackRating {
  positive,
  negative;

  static FeedbackRating? parse(Object? wire) => switch (wire) {
    'positive' => positive,
    'negative' => negative,
    _ => null,
  };
}

/// The fixed DSH feedback taxonomy (`dsh-command-feedback`), in the order the
/// official dialog lists it.
enum FeedbackCategory {
  taskResult('task-result'),
  instructionFollowing('instruction-following'),
  productInteraction('product-interaction'),
  serviceStability('service-stability'),
  resourceCost('resource-cost'),
  securityPrivacyPermission('security-privacy-permission'),
  other('other');

  const FeedbackCategory(this.wire);
  final String wire;

  static FeedbackCategory? parse(Object? wire) {
    for (final category in values) {
      if (category.wire == wire) return category;
    }
    return null;
  }
}

/// One stored rating (`messageFeedback` item). Log-only: the model never sees it.
class MessageFeedback {
  const MessageFeedback({
    required this.messageId,
    required this.rating,
    required this.version,
    this.note,
    this.category,
    this.createdAt,
    this.updatedAt,
  });

  /// `null` when [json] is not an item (unknown rating, no id or version).
  static MessageFeedback? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final messageId = asString(map['messageId']);
    final rating = FeedbackRating.parse(map['rating']);
    final version = asString(map['version']);
    if (messageId == null || rating == null || version == null) return null;
    return MessageFeedback(
      messageId: messageId,
      rating: rating,
      version: version,
      note: asString(map['note']),
      category: FeedbackCategory.parse(map['category']),
      createdAt: asEpochMs(map['createdAt']),
      updatedAt: asEpochMs(map['updatedAt']),
    );
  }

  /// `assistant/message` `message.id` of the rated reply.
  final String messageId;
  final FeedbackRating rating;

  /// Equality-only token; pass it back as `ifVersion` to change or delete.
  final String version;
  final String? note;
  final FeedbackCategory? category;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

/// A business refusal from `messageFeedback/*`: `session-not-found`,
/// `target-not-found` (not a finalized reply), `version-conflict` (with the
/// authoritative [current] item), `note-blank`, `note-too-large`.
class MessageFeedbackException implements Exception {
  const MessageFeedbackException(this.code, {this.current, this.details = const {}});

  final String code;

  /// For `version-conflict`: what is stored now (`null` = nothing).
  final MessageFeedback? current;
  final JsonMap details;

  bool get isConflict => code == 'version-conflict';

  @override
  String toString() => 'MessageFeedbackException($code)';
}

/// What [MessageActions.forkAt] produced.
class ForkOutcome {
  const ForkOutcome(this.sessionId, {this.title, this.leftQueued = 0});

  /// The new session.
  final String sessionId;

  /// The title it got (`T (1)` for an inherited `T`), when renamed.
  final String? title;

  /// Inherited queued prompts that could not be dropped; the fork's next turn
  /// would pick them up together with the next message.
  final int leftQueued;
}

extension MessageActions on DshClient {
  /// `session/fork` through event [atSeq] (inclusive), tidied up like a branch
  /// the person made by hand:
  /// * prompts the fork inherited from the source inbox (sent while the cut
  ///   was still open, so they belong *after* it) are dropped with
  ///   `session/updateQueue`; otherwise the fork's next turn would pick them up
  ///   together with the next message;
  /// * an inherited title `T` becomes `T (1)` (`T (2)` from `T (1)`), named
  ///   from [sourceTitle] when given — what the official web client does. A
  ///   fork without a title keeps automatic titling.
  ///
  /// Throws [DshRemoteException] when the fork itself fails
  /// (`session/fork-unavailable` for a seq the source does not have). The
  /// clean-up steps never throw: the fork exists by then.
  Future<ForkOutcome> forkAt(String sessionId, int atSeq, {String? sourceTitle}) async {
    final child = await forkSession(sessionId, atSeq: atSeq);
    SessionProjections? projections;
    try {
      projections = await this.projections(child);
    } catch (_) {
      projections = null;
    }
    var left = 0;
    for (final queued in [...?projections?.inbox['next-step'], ...?projections?.inbox['next-turn']]) {
      try {
        await updateQueue(child, queued.id, remove: true);
      } on DshRemoteException catch (e) {
        if (e.code != 'session/queue-item-not-found') left++;
      } catch (_) {
        left++;
      }
    }
    String? title;
    final inherited = projections?.title;
    if (inherited != null && inherited.trim().isNotEmpty) {
      final base = sourceTitle != null && sourceTitle.trim().isNotEmpty ? sourceTitle : inherited;
      try {
        title = await renameSession(child, bumpedForkTitle(base));
      } catch (_) {
        title = null;
      }
    }
    return ForkOutcome(child, title: title, leftQueued: left);
  }

  /// `messageFeedback/list`: current ratings of [sessionId], oldest first.
  Future<List<MessageFeedback>> listMessageFeedback(String sessionId) async {
    final value = _unwrapFeedback(
      await rpc.call('messageFeedback/list', {
        'request': {'sessionId': sessionId},
      }),
    );
    return [for (final item in asListOrEmpty(asMap(value)?['items'])) ?MessageFeedback.fromJson(item)];
  }

  /// `messageFeedback/put`: rates reply [messageId]. Pass the stored
  /// [ifVersion], or `null` to create (fails with `version-conflict` when an
  /// item exists). Omitting [note] or [category] clears it.
  Future<MessageFeedback> putMessageFeedback(
    String sessionId,
    String messageId,
    FeedbackRating rating, {
    required String? ifVersion,
    String? note,
    FeedbackCategory? category,
  }) async {
    final value = _unwrapFeedback(
      await rpc.call('messageFeedback/put', {
        'request': {
          'sessionId': sessionId,
          'messageId': messageId,
          'rating': rating.name,
          'note': ?note,
          'category': ?category?.wire,
          'ifVersion': ifVersion,
        },
      }),
    );
    final item = MessageFeedback.fromJson(value);
    if (item == null) throw const DshProtocolException('messageFeedback/put returned no item');
    return item;
  }

  /// `messageFeedback/delete`: retracts the rating of [messageId]. Succeeds
  /// when nothing is stored.
  Future<void> deleteMessageFeedback(String sessionId, String messageId, {required String ifVersion}) async {
    _unwrapFeedback(
      await rpc.call('messageFeedback/delete', {
        'request': {'sessionId': sessionId, 'messageId': messageId, 'ifVersion': ifVersion},
      }),
    );
  }
}

/// `messageFeedback/*` answer with a business union (`{ok, value}` /
/// `{ok: false, error}`) inside the transport result.
Object? _unwrapFeedback(Object? result) {
  final map = asMapOrEmpty(result);
  if (map['ok'] == true) return map['value'];
  final error = asMapOrEmpty(map['error']);
  throw MessageFeedbackException(
    asString(error['code']) ?? 'unknown',
    current: MessageFeedback.fromJson(error['current']),
    details: error,
  );
}

/// `T` → `T (1)`, `T (1)` → `T (2)`, `T（1）` → `T（2）` (the web client's
/// `increasedForkTitle`).
String bumpedForkTitle(String title) {
  final ascii = RegExp(r'^(.*?)\((\d+)\)$').firstMatch(title);
  if (ascii != null) return '${ascii[1]}(${BigInt.parse(ascii[2]!) + BigInt.one})';
  final fullWidth = RegExp(r'^(.*?)（(\d+)）$').firstMatch(title);
  if (fullWidth != null) return '${fullWidth[1]}（${BigInt.parse(fullWidth[2]!) + BigInt.one}）';
  return '$title (1)';
}

/// Where "branch from this reply" cuts: the `turn/end` seq of the turn that
/// the `assistant/message` at [replySeq] closes, or `null` when it does not
/// close a finished turn — the official web client's rule: the reply has
/// text, the turn has ended, nothing transcript-visible (another step, a tool
/// call or result, a retry, an error ending) comes after it.
///
/// [events] must be in seq order (`ChatTranscript.events`).
int? forkPointAfterReply(Iterable<SessionLogEvent> events, int replySeq) {
  var found = false;
  for (final event in events) {
    if (!found) {
      if (event.seq < replySeq) continue;
      if (event.seq > replySeq || event is! AssistantMessageEvent || event.message.text.trim().isEmpty) return null;
      found = true;
      continue;
    }
    switch (event) {
      case TurnEndedEvent(:final reason):
        return reason.isError ? null : event.seq;
      case AssistantMessageEvent() || ToolCallEvent() || ToolResultEvent() || LlmRetryEvent():
        return null;
      default:
        break;
    }
  }
  return null;
}

/// Where "edit this prompt and resend" cuts: the last event before the
/// `user/message` at [promptSeq] that is not part of how that prompt got
/// delivered (the inbox splices, `turn/start`, `step/start`, the step's
/// system prompt). Usually the previous `turn/end`; for the first prompt, the
/// session's opening settings; for a message that joined a running turn, the
/// end of the step before it (the fork closes that turn as `forked`).
///
/// `null` when the events right before [promptSeq] are not in [events] (load
/// older history and ask again) or there is nothing before the prompt.
/// [events] must be in seq order.
int? forkPointBeforePrompt(Iterable<SessionLogEvent> events, int promptSeq) {
  final before = [
    for (final event in events)
      if (event.seq < promptSeq) event,
  ];
  var expected = promptSeq - 1;
  for (var i = before.length - 1; i >= 0; i--) {
    final event = before[i];
    // A gap means the walk would skip events it has not seen.
    if (event.seq != expected) return null;
    expected--;
    if (!_deliversPrompt(event)) return event.seq;
  }
  return null;
}

bool _deliversPrompt(SessionLogEvent event) =>
    event is InboxSplicedEvent ||
    event is TurnStartedEvent ||
    event is StepStartedEvent ||
    event.type == 'system/message';
