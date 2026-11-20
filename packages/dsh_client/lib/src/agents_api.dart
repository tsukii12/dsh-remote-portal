/// Multi-agent surfaces of the official web client, natively:
///
/// * **Subagents** (`@deepseek-ai/dsh-client-ui-subagent`): the parent-owned
///   `subagentCatalog` projection, the child's `subagentTiming` and `subagent`
///   identity projections, and continuing a continuable child through its
///   exact parent (`subagents/prompt`, `subagents/interruptByParent`).
/// * **Agent teams** (`@deepseek-ai/dsh-experimental-client-ui-agent-team`):
///   the Lead Session's `agentTeam` projection (roster and shared task board)
///   and the team messages members receive in their inboxes.
///
/// A subagent Session is owned by subagent routing: `session/follow`,
/// `session/page`, `session/prompt` and `session/cancel` reject it under a
/// plain `{kind: session}` address (`session/agent-busy`). [SubagentsApi]
/// keeps a per-client route table so [DshClient.watch], [DshClient.history],
/// [DshClient.prompt] and [DshClient.cancel] address a routed child through
/// its parent transparently.
///
/// Verified against DSH 0.2.1-rc.2 (`dsh-subagent` client types and typert
/// remote client, `dsh-api-session-controller` address validation,
/// `dsh-experimental-agent-team` client types).
library;

import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Subagent catalog and identity
// -----------------------------------------------------------------------------

/// Lifecycle of one catalog child.
enum SubagentMode {
  /// A terminal one-shot child: read-only history.
  oneShot('one-shot'),

  /// A resumable conversation: takes follow-up messages through its parent.
  continuable('continuable'),

  /// An external execution without a local Session (never openable).
  external('external'),

  /// Recorded without a known mode; resolved when the child history is read.
  unknown('unknown');

  const SubagentMode(this.wire);
  final String wire;

  static SubagentMode parse(Object? value) =>
      values.firstWhere((m) => m.wire == value, orElse: () => SubagentMode.unknown);
}

/// One direct child in a parent's `subagentCatalog` projection.
class SubagentCatalogEntry {
  const SubagentCatalogEntry({required this.id, required this.mode, this.label, this.createdAt});

  static SubagentCatalogEntry? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final label = asString(map['label'])?.trim();
    return SubagentCatalogEntry(
      id: id,
      mode: SubagentMode.parse(map['mode']),
      label: label == null || label.isEmpty ? null : label,
      createdAt: asEpochMs(map['createdAt']),
    );
  }

  /// The catalog rows of a projection value; unusable rows are dropped.
  static List<SubagentCatalogEntry> listFrom(Object? json) => [
    for (final row in asListOrEmpty(json)) ?SubagentCatalogEntry.fromJson(row),
  ];

  /// Child session id (or the external task id).
  final String id;
  final SubagentMode mode;

  /// Durable creation label (the `description` the parent gave the task).
  final String? label;
  final DateTime? createdAt;
}

/// The child's `subagentTiming` projection: active-turn time and whether the
/// latest closed turn completed normally.
class SubagentTiming {
  const SubagentTiming({this.settled = Duration.zero, this.activeSince, this.activeThrough, this.lastTurnCompleted});

  static SubagentTiming? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final active = asMap(map['active']);
    return SubagentTiming(
      settled: Duration(milliseconds: asInt(map['settledMs']) ?? 0),
      activeSince: asEpochMs(active?['since']),
      activeThrough: asEpochMs(active?['through']),
      lastTurnCompleted: asBool(map['lastTurnCompleted']),
    );
  }

  /// Time accumulated across closed turns.
  final Duration settled;

  /// Start of the turn still open at this projection cut (Host clock).
  final DateTime? activeSince;

  /// Latest event folded into the open turn (Host clock).
  final DateTime? activeThrough;

  /// True: the latest closed turn completed; false: it ended otherwise
  /// (failed, cancelled, refused, out of tokens); null: none closed yet or a
  /// turn is open.
  final bool? lastTurnCompleted;

  /// Active time at the projection cut (the open turn up to its last event).
  Duration get total {
    final since = activeSince;
    final through = activeThrough;
    if (since == null || through == null || through.isBefore(since)) return settled;
    return settled + through.difference(since);
  }
}

/// The child's own `subagent` identity projection (folded from its
/// `subagent/descriptor`); null when the descriptor is missing or invalid.
class SubagentIdentity {
  const SubagentIdentity(this.mode, this.label);

  static SubagentIdentity? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final label = asString(map['label'])?.trim();
    return SubagentIdentity(SubagentMode.parse(map['mode']), label == null || label.isEmpty ? null : label);
  }

  final SubagentMode mode;
  final String? label;
}

/// Durable parent/child browsing address (`SessionAddress` of kind
/// `subagent`). Only `one-shot`, `continuable` and `unknown` are valid modes
/// on the wire; anything else travels as `unknown`.
class SubagentAddress {
  const SubagentAddress({
    required this.parentSessionId,
    required this.childSessionId,
    this.mode = SubagentMode.unknown,
  });

  final String parentSessionId;
  final String childSessionId;
  final SubagentMode mode;

  SubagentAddress withMode(SubagentMode mode) =>
      SubagentAddress(parentSessionId: parentSessionId, childSessionId: childSessionId, mode: mode);

  Map<String, Object?> toJson() => {
    'kind': 'subagent',
    'parentSessionId': parentSessionId,
    'childSessionId': childSessionId,
    'mode': switch (mode) {
      SubagentMode.oneShot || SubagentMode.continuable => mode.wire,
      _ => SubagentMode.unknown.wire,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is SubagentAddress &&
      other.parentSessionId == parentSessionId &&
      other.childSessionId == childSessionId &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(parentSessionId, childSessionId, mode);
}

/// A one-shot child (or one whose parent cannot take it back) refused a
/// follow-up message. [toString] is the user-facing reason.
final class SubagentReadOnlyException implements Exception {
  const SubagentReadOnlyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Typed readers for the multi-agent projections.
extension AgentProjections on SessionProjections {
  /// Direct children (`subagentCatalog`); null when the projection is absent.
  List<SubagentCatalogEntry>? get subagentCatalog =>
      has('subagentCatalog') ? SubagentCatalogEntry.listFrom(values['subagentCatalog']) : null;

  SubagentTiming? get subagentTiming => SubagentTiming.fromJson(values['subagentTiming']);

  SubagentIdentity? get subagentIdentity => SubagentIdentity.fromJson(values['subagent']);

  /// The Team rooted at this Session; null when the Agent Teams bundle is off
  /// (no such projection) or the value is unreadable.
  TeamSnapshot? get agentTeam => TeamSnapshot.fromJson(values['agentTeam']);
}

// -----------------------------------------------------------------------------
// Routing and continuation
// -----------------------------------------------------------------------------

final Expando<Map<String, SubagentAddress>> _routes = Expando('subagentRoutes');

extension SubagentsApi on DshClient {
  Map<String, SubagentAddress> get _table => _routes[this] ??= <String, SubagentAddress>{};

  /// Addresses [address]'s child through its parent from now on (follow,
  /// history, prompt, cancel). A known mode is never downgraded to unknown.
  void routeSubagent(SubagentAddress address) {
    final known = _table[address.childSessionId];
    if (known != null &&
        known.parentSessionId == address.parentSessionId &&
        address.mode == SubagentMode.unknown &&
        known.mode != SubagentMode.unknown) {
      return;
    }
    _table[address.childSessionId] = address;
  }

  /// The parent route of [sessionId], when it is a routed subagent child.
  SubagentAddress? subagentRoute(String sessionId) => _table[sessionId];

  /// The durable `address` for `session/follow` and `session/page`.
  Map<String, Object?> sessionAddressOf(String sessionId) =>
      _table[sessionId]?.toJson() ?? {'kind': 'session', 'sessionId': sessionId};

  /// After [error] from a plain-addressed read of [sessionId]: when the Host
  /// says the Session belongs to subagent routing, finds its parent in
  /// `session/list` and routes it. True when a new route was added (retry).
  Future<bool> adoptSubagentRoute(String sessionId, Object error) async {
    if (error is! DshRemoteException || error.code != 'session/agent-busy') return false;
    if (_table.containsKey(sessionId)) return false;
    try {
      final sessions = await listSessions();
      for (final s in sessions) {
        if (s.sessionId != sessionId) continue;
        final parent = s.parentSessionId;
        if (!s.isSubagent || parent == null || parent.isEmpty) return false;
        routeSubagent(
          SubagentAddress(
            parentSessionId: parent,
            childSessionId: sessionId,
            mode: s.projections.subagentIdentity?.mode ?? SubagentMode.unknown,
          ),
        );
        return true;
      }
    } on Object {
      return false;
    }
    return false;
  }

  /// Resolves an unknown route mode from the child's `subagent` identity.
  Future<SubagentAddress> resolveSubagentMode(SubagentAddress route) async {
    if (route.mode != SubagentMode.unknown) return route;
    final identity = (await projections(route.childSessionId))?.subagentIdentity;
    if (identity == null || identity.mode == SubagentMode.unknown) return route;
    final resolved = route.withMode(identity.mode);
    routeSubagent(resolved);
    return resolved;
  }

  /// `subagents/prompt`: one human message for a continuable child, delivered
  /// through its exact live parent. Returns the request id (echoed like a
  /// `session/prompt` one). One-shot children throw
  /// [SubagentReadOnlyException]; Host refusals keep their codes
  /// (`subagent/parent-unavailable`, `subagent/not-resumable`, …).
  Future<String> promptSubagent(
    SubagentAddress route,
    String text, {
    List<PromptImage> images = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    final resolved = await resolveSubagentMode(route);
    if (resolved.mode == SubagentMode.oneShot) {
      throw const SubagentReadOnlyException('一次性子代理只能查看记录');
    }
    final id = requestId ?? uuidV4();
    try {
      await rpc.call('subagents/prompt', {
        'request': {
          'requestId': id,
          'parentSessionId': resolved.parentSessionId,
          'childSessionId': resolved.childSessionId,
          'mode': SubagentMode.continuable.wire,
          'delivery': mode.wire,
          'content': [
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            for (final image in images) image.toJson(),
          ],
          'clientTimeZone': ?timeZone,
        },
      });
    } on DshRemoteException catch (e) {
      throw switch (e.code) {
        'subagent/parent-unavailable' => const SubagentReadOnlyException('上级对话不在运行，回到上级对话后再继续'),
        'subagent/not-resumable' => const SubagentReadOnlyException('这个子代理不能继续对话'),
        _ => e,
      };
    }
    return id;
  }

  /// `subagents/interruptByParent`: stops a continuable child's current turn
  /// (an idle or finished child is an accepted no-op).
  Future<void> interruptSubagent(SubagentAddress route) async {
    final resolved = await resolveSubagentMode(route);
    if (resolved.mode == SubagentMode.oneShot) return;
    await rpc.call('subagents/interruptByParent', {
      'childSessionId': resolved.childSessionId,
      'parentSessionId': resolved.parentSessionId,
      'mode': SubagentMode.continuable.wire,
    });
  }
}

// -----------------------------------------------------------------------------
// Agent teams
// -----------------------------------------------------------------------------

/// One roster row of the `agentTeam` projection.
class TeamMember {
  const TeamMember({required this.id, required this.name, required this.lead, required this.phase, this.error});

  static TeamMember? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    return TeamMember(
      id: id,
      name: asString(map['name']) ?? id,
      lead: map['role'] == 'lead',
      phase: asString(map['phase']) ?? 'active',
      error: asString(map['error']),
    );
  }

  /// The member's Session id (the Lead's is the Team id).
  final String id;

  /// Permanent lower-case name (`reviewer`); the Lead's is `lead`.
  final String name;
  final bool lead;

  /// Durable lifecycle: `provisioning`, `active` or `failed`. Turn activity
  /// comes from the member Session's status.
  final String phase;
  final String? error;
}

/// One shared task (`TeamTaskView`).
class TeamTask {
  const TeamTask({
    required this.id,
    required this.subject,
    required this.status,
    this.revision = 0,
    this.description = '',
    this.ownerName,
    this.ready = false,
    this.blockedBy = const [],
    this.writeScopes = const [],
    this.warnings = const [],
  });

  static TeamTask? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    final status = asString(map['status']) ?? 'pending';
    if (status == 'deleted') return null;
    return TeamTask(
      id: id,
      revision: asInt(map['revision']) ?? 0,
      subject: asString(map['subject']) ?? id,
      description: asString(map['description']) ?? '',
      status: status,
      ownerName: asString(map['ownerName']),
      ready: map['ready'] == true,
      blockedBy: asStringList(map['blockedBy']),
      writeScopes: asStringList(map['writeScopes']),
      warnings: asStringList(map['writeScopeWarnings']),
    );
  }

  /// `task-<n>`.
  final String id;
  final int revision;
  final String subject;
  final String description;

  /// `pending`, `in_progress` or `completed`.
  final String status;
  final String? ownerName;

  /// Pending and every dependency completed.
  final bool ready;
  final List<String> blockedBy;
  final List<String> writeScopes;

  /// Overlaps with other in-progress tasks' write scopes (advisory).
  final List<String> warnings;
}

/// The `agentTeam` projection of a Lead Session.
class TeamSnapshot {
  const TeamSnapshot({this.members = const [], this.tasks = const [], this.failure});

  static TeamSnapshot? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return TeamSnapshot(
      members: [for (final m in asListOrEmpty(map['members'])) ?TeamMember.fromJson(m)],
      tasks: [for (final t in asListOrEmpty(map['tasks'])) ?TeamTask.fromJson(t)],
      failure: asString(map['failure']),
    );
  }

  static const empty = TeamSnapshot();

  final List<TeamMember> members;
  final List<TeamTask> tasks;

  /// The first rejected persisted Team record; members and tasks then stay at
  /// the last valid state.
  final String? failure;

  List<TeamMember> get teammates => [
    for (final m in members)
      if (!m.lead) m,
  ];

  /// Nothing to show beyond the Lead itself.
  bool get isEmpty => teammates.isEmpty && tasks.isEmpty;
}

/// One message a team member received in its inbox (`agent-message` source
/// whose first block is `Team message from <name>:`, or the historical
/// `team-message` source).
class TeamMessage {
  const TeamMessage({
    required this.recipientId,
    required this.text,
    required this.time,
    required this.seq,
    this.senderId,
    this.senderName,
  });

  final String recipientId;
  final String? senderId;
  final String? senderName;
  final String text;
  final DateTime time;

  /// Seq in the recipient's log.
  final int seq;

  static final _prefix = RegExp(r'^Team message from (.+?):\s*$');

  /// Reads a team message out of a recipient's `user/message`; null for
  /// anything else.
  static TeamMessage? fromEvent(String recipientId, SessionLogEvent event) {
    if (event is! UserMessageEvent) return null;
    final message = event.message;
    final source = message.source;
    if (source.kind != 'agent-message' && source.kind != 'team-message') return null;
    final texts = message.parts.whereType<TextPart>().map((p) => p.text).toList();
    String? name = asString(source.raw['senderName']);
    if (texts.isNotEmpty) {
      final match = _prefix.firstMatch(texts.first.trim());
      if (match != null) {
        name ??= match.group(1);
        texts.removeAt(0);
      } else if (source.kind == 'agent-message' && name == null) {
        // A plain adjacent-agent message (subagent control), not a team one.
        return null;
      }
    }
    final body = texts.join('\n').trim();
    if (body.isEmpty) return null;
    return TeamMessage(
      recipientId: recipientId,
      senderId: asString(source.raw['senderSessionId']) ?? asString(source.raw['senderId']),
      senderName: name,
      text: body,
      time: event.time,
      seq: event.seq,
    );
  }
}
