// Subagents and agent teams of the active host, the native implementation of
// the subagent and Agent Teams panels.
// See packages/dsh_client/lib/src/agents_api.dart for the wire side.
//
// The lineage is built from the session list the app already keeps
// (`session/list` lists subagent children with their parent and carries the
// `subagentCatalog`, `subagentTiming` and `subagent` projection hints), so the
// chat header can show it without extra requests. The team panel reads the
// Lead's `agentTeam` projection live (`session/projections` +
// `session/control`) and the messages members received.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';
import 'plugins_state.dart';
import 'sessions_state.dart';

/// Every session of the active host by id, subagent children included.
final hostSessionsProvider = Provider<Map<String, SessionSummary>>((ref) {
  if (ref.watch(activeConnectionProvider).value == null) return const {};
  ref.watch(sessionsProvider);
  final all = ref.read(sessionsProvider.notifier).allSessions;
  return {for (final s in all) s.sessionId: s};
});

/// What a subagent is doing, as the chip says it.
enum AgentRunState {
  running,
  completed,
  failed,
  idle;

  String get label => switch (this) {
    running => appL10n.commonRunning,
    completed => appL10n.commonCompleted,
    failed => appL10n.stateAgentError,
    idle => appL10n.stateNotRunning,
  };
}

String subagentModeLabel(SubagentMode mode) => switch (mode) {
  SubagentMode.oneShot => appL10n.stateAgentOneShot,
  SubagentMode.continuable => appL10n.stateAgentContinuable,
  SubagentMode.external => appL10n.stateAgentExternal,
  SubagentMode.unknown => appL10n.stateSubagent,
};

/// One child in a lineage tree.
class SubagentNode {
  const SubagentNode({
    required this.id,
    required this.parentId,
    required this.label,
    required this.mode,
    required this.state,
    this.title,
    this.timing,
    this.createdAt,
    this.children = const [],
  });

  final String id;
  final String parentId;

  /// The creation label (the task the parent gave it), else its title.
  final String label;
  final SubagentMode mode;
  final AgentRunState state;

  /// The child's own session title, when it differs from [label].
  final String? title;
  final SubagentTiming? timing;
  final DateTime? createdAt;
  final List<SubagentNode> children;

  /// External tasks have no local conversation.
  bool get openable => mode != SubagentMode.external;
  bool get running => state == AgentRunState.running;

  SubagentAddress get address => SubagentAddress(parentSessionId: parentId, childSessionId: id, mode: mode);

  /// This node and every descendant, depth first.
  Iterable<SubagentNode> get flattened sync* {
    yield this;
    for (final child in children) {
      yield* child.flattened;
    }
  }
}

AgentRunState _stateOf(SessionSummary? summary) {
  if (summary == null) return AgentRunState.idle;
  if (summary.running) return AgentRunState.running;
  return switch (summary.projections.subagentTiming?.lastTurnCompleted) {
    true => AgentRunState.completed,
    false => AgentRunState.failed,
    null => AgentRunState.idle,
  };
}

/// The direct children of [parentId] (and theirs, recursively): the parent's
/// catalog first, in creation order, then listed children the catalog does
/// not name yet.
List<SubagentNode> buildLineage(
  String parentId,
  Map<String, SessionSummary> sessions, {
  int depth = 0,
  Set<String>? seen,
}) {
  if (depth > 8) return const [];
  // Build once per snapshot traversal; even a leaf used to scan every host
  // session again. Keep this local so deletion/reparenting needs no cache invalidation.
  final childrenByParent = <String, List<SessionSummary>>{};
  for (final session in sessions.values) {
    final parent = session.parentSessionId;
    if (session.isSubagent && parent != null) {
      (childrenByParent[parent] ??= []).add(session);
    }
  }
  return _buildLineage(parentId, sessions, childrenByParent, depth, seen ?? <String>{parentId});
}

List<SubagentNode> _buildLineage(
  String parentId,
  Map<String, SessionSummary> sessions,
  Map<String, List<SessionSummary>> childrenByParent,
  int depth,
  Set<String> visited,
) {
  if (depth > 8) return const [];
  final parent = sessions[parentId];
  final entries = <SubagentCatalogEntry>[...?parent?.projections.subagentCatalog];
  final named = {for (final e in entries) e.id};
  final extra = [
    for (final s in childrenByParent[parentId] ?? const <SessionSummary>[])
      if (!named.contains(s.sessionId)) s,
  ]..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
  for (final s in extra) {
    final identity = s.projections.subagentIdentity;
    entries.add(
      SubagentCatalogEntry(id: s.sessionId, mode: identity?.mode ?? SubagentMode.unknown, label: identity?.label),
    );
  }
  final nodes = <SubagentNode>[];
  for (final entry in entries) {
    if (!visited.add(entry.id)) continue;
    final summary = sessions[entry.id];
    final identity = summary?.projections.subagentIdentity;
    final title = summary?.title?.trim();
    final label = entry.label ?? identity?.label ?? title;
    final mode = entry.mode == SubagentMode.unknown && identity != null ? identity.mode : entry.mode;
    nodes.add(
      SubagentNode(
        id: entry.id,
        parentId: parentId,
        label: label == null || label.isEmpty ? appL10n.stateSubagent : label,
        mode: mode,
        state: mode == SubagentMode.external ? AgentRunState.idle : _stateOf(summary),
        title: title == null || title.isEmpty || title == label ? null : title,
        timing: summary?.projections.subagentTiming,
        createdAt: entry.createdAt,
        children: _buildLineage(entry.id, sessions, childrenByParent, depth + 1, visited),
      ),
    );
  }
  return nodes;
}

/// The lineage under one conversation.
final subagentLineageProvider = Provider.autoDispose.family<List<SubagentNode>, String>((ref, parentId) {
  final sessions = ref.watch(hostSessionsProvider);
  return buildLineage(parentId, sessions);
});

/// A child conversation's place under its parent.
class SubagentParent {
  const SubagentParent({required this.address, required this.label, required this.parentTitle});

  final SubagentAddress address;

  /// The child's creation label (header title).
  final String label;
  final String parentTitle;
}

/// Where [sessionId] sits when it is a subagent child; null for a root
/// conversation (or one the session list doesn't know yet).
final subagentParentProvider = Provider.autoDispose.family<SubagentParent?, String>((ref, sessionId) {
  final sessions = ref.watch(hostSessionsProvider);
  final self = sessions[sessionId];
  final parentId = self?.parentSessionId;
  if (self == null || !self.isSubagent || parentId == null) return null;
  final parent = sessions[parentId];
  SubagentCatalogEntry? entry;
  for (final e in parent?.projections.subagentCatalog ?? const []) {
    if (e.id == sessionId) entry = e;
  }
  final identity = self.projections.subagentIdentity;
  final label = entry?.label ?? identity?.label ?? self.title?.trim();
  final parentTitle = parent?.title?.trim();
  return SubagentParent(
    address: SubagentAddress(
      parentSessionId: parentId,
      childSessionId: sessionId,
      mode: entry?.mode ?? identity?.mode ?? SubagentMode.unknown,
    ),
    label: label == null || label.isEmpty ? appL10n.stateSubagent : label,
    parentTitle: parentTitle == null || parentTitle.isEmpty ? appL10n.stateParentChat : parentTitle,
  );
});

/// What the chat header shows for the current conversation.
class HeaderAgents {
  const HeaderAgents({this.parent, this.children = 0, this.running = 0, this.team, this.leadId});

  /// Set in a subagent conversation: the breadcrumb back.
  final SubagentParent? parent;

  /// Direct children and how many of them run.
  final int children;
  final int running;

  /// The Lead's team when the Agent Teams bundle is on.
  final TeamSnapshot? team;
  final String? leadId;

  bool get isChild => parent != null;
  bool get hasTeam => team != null && leadId != null;
  bool get isEmpty => !isChild && children == 0 && !hasTeam;

  @override
  bool operator ==(Object other) =>
      other is HeaderAgents &&
      other.parent?.address == parent?.address &&
      other.parent?.label == parent?.label &&
      other.parent?.parentTitle == parent?.parentTitle &&
      other.children == children &&
      other.running == running &&
      other.leadId == leadId &&
      other.team?.teammates.length == team?.teammates.length &&
      (other.team == null) == (team == null);

  @override
  int get hashCode => Object.hash(
    parent?.address,
    parent?.label,
    parent?.parentTitle,
    children,
    running,
    leadId,
    team?.teammates.length,
    team == null,
  );
}

final headerAgentsProvider = Provider.autoDispose.family<HeaderAgents, String>((ref, sessionId) {
  final sessions = ref.watch(hostSessionsProvider);
  if (sessions.isEmpty) return const HeaderAgents();
  final parent = ref.watch(subagentParentProvider(sessionId));
  final children = ref.watch(subagentLineageProvider(sessionId));
  // Teammates are the Lead's direct children: a teammate's panel is the
  // Lead's.
  final leadId = parent?.address.parentSessionId ?? sessionId;
  final team = sessions[leadId]?.projections.agentTeam;
  return HeaderAgents(
    parent: parent,
    children: children.length,
    running: children.where((c) => c.running).length,
    team: team,
    leadId: team == null ? null : leadId,
  );
});

// -----------------------------------------------------------------------------
// Agent team

/// The Agent Teams bundle (Team service, tools and the official panel).
const agentTeamBundle = '@deepseek-ai/dsh-experimental-agent-team-profile';

/// The bundle row on the active host; null while unknown or not offered.
final agentTeamBundleProvider = Provider<AsyncValue<PluginBundle?>>((ref) {
  return ref
      .watch(installedPluginsProvider)
      .whenData((bundles) => bundles?.where((b) => b.name == agentTeamBundle).firstOrNull);
});

/// Live `agentTeam` of one Lead: the list hint at once, then
/// `session/projections`, then `session/control` frames. Null data means the
/// Team projection is absent (bundle off).
class TeamController extends Notifier<AsyncValue<TeamSnapshot?>> {
  TeamController(this.leadId);

  final String leadId;

  /// Seq of the team shown (-1: none yet): an older seed or frame never
  /// replaces a newer one.
  int _seq = -1;

  int _seedTicket = 0;
  bool _hasControlCut = false;

  @override
  AsyncValue<TeamSnapshot?> build() {
    _seq = -1;
    _hasControlCut = false;
    final conn = ref.watch(activeConnectionProvider).value;
    // Re-read after the bundle switches (late enabling registers the
    // projection on the open Lead).
    ref.watch(agentTeamBundleProvider.select((b) => b.value?.enabled ?? false));
    if (conn == null) return const AsyncData(null);
    final hint = ref.read(hostSessionsProvider)[leadId]?.projections.agentTeam;
    final sub = conn.client.watchSessionControl().listen(
      (update) => _onControl(update, conn.client),
      onError: (Object _) {},
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    unawaited(_seed(conn.client, retainOnError: hint != null));
    return hint == null ? const AsyncLoading() : AsyncData(hint);
  }

  Future<void> _seed(DshClient client, {required bool retainOnError}) async {
    // Notifier.ref changes when dependencies rebuild; this read belongs to this build.
    final r = ref;
    final ticket = ++_seedTicket;
    final readyGeneration = client.mux.lastReadyGenerationNumber;
    try {
      final projections = await client.projections(leadId);
      if (!r.mounted || ticket != _seedTicket || client.mux.lastReadyGenerationNumber != readyGeneration) {
        return;
      }
      if (_seq >= 0 && (projections == null || projections.asOfSeq <= _seq)) return;
      if (projections != null) _seq = projections.asOfSeq;
      state = AsyncData(projections?.agentTeam);
    } catch (error, stack) {
      if (!r.mounted || ticket != _seedTicket || client.mux.lastReadyGenerationNumber != readyGeneration) {
        return;
      }
      if (!retainOnError && _seq < 0) state = AsyncError(error, stack);
    }
  }

  void _onControl(SessionControlUpdate update, DshClient client) {
    if (!ref.mounted) return;
    switch (update) {
      case SessionControlBaseline(:final projections):
        if (_hasControlCut) ++_seedTicket;
        _hasControlCut = true;
        final mine = projections[leadId];
        if (mine != null && mine.has('agentTeam')) {
          _seq = mine.asOfSeq;
          state = AsyncData(mine.agentTeam);
        } else if (mine == null) {
          // Cold sessions are absent from the resident baseline. Their
          // current query can replace the cache, but a failed query cannot.
          _seq = -1;
          unawaited(_seed(client, retainOnError: state.hasValue));
        }
      case SessionControlProjection(:final sessionId, :final key, :final value, :final seq)
          when sessionId == leadId && key == 'agentTeam':
        if (seq <= _seq) return;
        _seq = seq;
        state = AsyncData(TeamSnapshot.fromJson(value));
      default:
        break;
    }
  }

  /// Re-reads the projection (pull to refresh, after enabling the bundle).
  Future<void> refresh() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client != null) await _seed(client, retainOnError: state.hasValue);
  }
}

final teamProvider = NotifierProvider.autoDispose.family<TeamController, AsyncValue<TeamSnapshot?>, String>(
  TeamController.new,
);

/// A roster row with its live activity.
class TeamMemberView {
  const TeamMemberView({required this.member, required this.running, this.model, this.mode = SubagentMode.continuable});

  final TeamMember member;
  final bool running;

  /// Model the member's next request uses (from its session hints).
  final ModelSelection? model;
  final SubagentMode mode;

  /// `provisioning`/`failed` win over activity.
  AgentRunState get state => switch (member.phase) {
    'failed' => AgentRunState.failed,
    _ when running || member.phase == 'provisioning' => AgentRunState.running,
    _ => AgentRunState.idle,
  };

  String get stateLabel => switch (member.phase) {
    'provisioning' => appL10n.statePreparing,
    'failed' => appL10n.commonFailed,
    _ => running ? appL10n.commonRunning : appL10n.stateNotRunning,
  };
}

/// [team]'s roster with each member's activity from the session list.
List<TeamMemberView> teamMembers(TeamSnapshot team, Map<String, SessionSummary> sessions) => [
  for (final m in team.members)
    TeamMemberView(
      member: m,
      running: sessions[m.id]?.running ?? false,
      model: sessions[m.id]?.projections.nextModel,
      mode: sessions[m.id]?.projections.subagentIdentity?.mode ?? SubagentMode.continuable,
    ),
];

/// One-shot read of a member's recent log (a follow snapshot, then closed).
Future<List<SessionLogEvent>> _recentEvents(DshClient client, String sessionId) async {
  final done = Completer<List<SessionLogEvent>>();
  final sub = client
      .watch(
        sessionId,
        options: const WatchOptions(
          assistantStream: false,
          turnWindow: null,
          maxMessages: 200,
          includeHostEvents: false,
          includeConnectionEvents: false,
        ),
      )
      .listen(
        (event) {
          if (event is SessionSnapshotEvent && !done.isCompleted) {
            done.complete(event.events);
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) done.completeError(error);
        },
        onDone: () {
          if (!done.isCompleted) done.completeError(StateError('Team log closed before its snapshot'));
        },
      );
  try {
    return await done.future.timeout(const Duration(seconds: 20));
  } finally {
    unawaited(sub.cancel());
  }
}

/// Recent messages plus the members whose logs could not be read. A successful
/// empty snapshot is different from a failed or prematurely closed follow.
class TeamMessagesSnapshot {
  const TeamMessagesSnapshot({this.messages = const [], this.unreadableMembers = const <String>{}});

  final List<TeamMessage> messages;
  final Set<String> unreadableMembers;
}

/// The team's messages, newest first: what every member received in its
/// inbox (every message has exactly one recipient, so the union is the whole
/// conversation between members). Re-read when activity changes.
final teamMessagesProvider = FutureProvider.autoDispose.family<TeamMessagesSnapshot, String>((ref, leadId) async {
  final conn = ref.watch(activeConnectionProvider).value;
  final team = ref.watch(teamProvider(leadId)).value;
  // A new turn anywhere in the team may have carried a message.
  ref.watch(
    hostSessionsProvider.select(
      (s) =>
          [for (final m in team?.members ?? const <TeamMember>[]) '${m.id}:${s[m.id]?.running}:${s[m.id]?.updatedAt}']
              .join('|'),
    ),
  );
  if (conn == null || team == null) return const TeamMessagesSnapshot();
  final client = conn.client;
  final out = <TeamMessage>[];
  final unreadable = <String>{};
  await Future.wait([
    for (final m in team.members)
      () async {
        if (!m.lead) {
          client.routeSubagent(SubagentAddress(parentSessionId: leadId, childSessionId: m.id));
        }
        try {
          for (final e in await _recentEvents(client, m.id)) {
            final message = TeamMessage.fromEvent(m.id, e);
            if (message != null) out.add(message);
          }
        } catch (_) {
          // Preserve the readable members, without presenting a partial result
          // (or all failed reads) as a complete, successfully empty inbox.
          unreadable.add(m.id);
        }
      }(),
  ]);
  out.sort((a, b) => b.time.compareTo(a.time));
  return TeamMessagesSnapshot(
    messages: List.unmodifiable(out),
    unreadableMembers: Set.unmodifiable(unreadable),
  );
});

// -----------------------------------------------------------------------------
// Navigation

/// Opens [address]'s child conversation in the chat: routes it through its
/// parent, then makes it current.
void selectSubagent(WidgetRef ref, SubagentAddress address) {
  ref.read(activeConnectionProvider).value?.client.routeSubagent(address);
  ref.read(currentSessionProvider.notifier).select(address.childSessionId);
}

/// Opens [sessionId] (a root conversation, or a child the session list
/// knows) in the chat.
void selectConversation(WidgetRef ref, String sessionId) {
  final parent = ref.read(subagentParentProvider(sessionId));
  if (parent != null) {
    selectSubagent(ref, parent.address);
  } else {
    ref.read(currentSessionProvider.notifier).select(sessionId);
  }
}
