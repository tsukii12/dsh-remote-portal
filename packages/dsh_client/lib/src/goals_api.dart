/// The session's long-term goal (`@deepseek-ai/dsh-goal`): the `goals/*`
/// Remote, the `goal` projection and the `goal/activation-changed` event.
///
/// Verified against DSH 0.2.1-rc.2 (`dsh-goal` typings and
/// `typert.remote-client.js`, `dsh-client-ui-goal` client):
///
/// * every verb is addressed by the owning session (`agentId`); mutations
///   carry the exact current [GoalRef] (compare-and-set, a stale one fails
///   with `GOAL_STALE_REVISION`);
/// * the durable state is the session's `goal` projection
///   (`{goal, roundsStarted, createdAt, updatedAt}` or `null`), folded from
///   `goal/change` session events; [foldGoalProjection] does the same over a
///   follow window;
/// * whether an active goal continues by itself ([GoalActivation]) is
///   process-local: `goals/get` reads it and `goal/activation-changed`
///   announces each edge. Every session start disarms an active goal.
///
/// The ds-harness-remote relay allows the mutations but not `goals/get`;
/// check [GoalsApi.canReadGoal] / [GoalsApi.canChangeGoal].
library;

import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

/// Durable lifecycle phase of a goal.
enum GoalPhase {
  active,
  paused,
  blocked,
  complete;

  static GoalPhase? fromWire(Object? wire) {
    for (final p in values) {
      if (p.name == wire) return p;
    }
    return null;
  }
}

/// Whether this Host process may continue an active goal automatically.
/// Never persisted: a reopened session's active goal starts [disarmed].
enum GoalActivation {
  armed,
  disarmed;

  static GoalActivation? fromWire(Object? wire) {
    for (final a in values) {
      if (a.name == wire) return a;
    }
    return null;
  }
}

/// Compare-and-set identity of one exact goal revision.
class GoalRef {
  const GoalRef(this.id, this.revision);

  static GoalRef? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    final revision = asInt(map?['revision']);
    if (id == null || id.isEmpty || revision == null) return null;
    return GoalRef(id, revision);
  }

  final String id;

  /// Positive; every durable mutation increments it.
  final int revision;

  /// Exactly `{id, revision}` (the strict codec rejects extra keys).
  Map<String, Object?> toJson() => {'id': id, 'revision': revision};

  @override
  bool operator ==(Object other) => other is GoalRef && other.id == id && other.revision == revision;

  @override
  int get hashCode => Object.hash(id, revision);

  @override
  String toString() => 'GoalRef($id@$revision)';
}

/// Why a goal is blocked (`phase: blocked` only).
class GoalBlockReason {
  const GoalBlockReason(this.code, this.message);

  static GoalBlockReason? fromJson(Object? json) {
    final map = asMap(json);
    final message = asString(map?['message']);
    if (map == null || message == null || message.trim().isEmpty) return null;
    return GoalBlockReason(asString(map['code']) ?? '', message);
  }

  /// Lower-kebab-case classification chosen by the blocking policy.
  final String code;

  /// Explanation shown to people.
  final String message;

  @override
  bool operator ==(Object other) => other is GoalBlockReason && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}

/// One durable goal revision.
class GoalSnapshot {
  const GoalSnapshot({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    required this.maxGoalRounds,
    this.blockedReason,
  });

  /// Null for anything without an id, a revision, an objective or a known
  /// phase.
  static GoalSnapshot? fromJson(Object? json) {
    final map = asMap(json);
    final ref = GoalRef.fromJson(map);
    final objective = asString(map?['objective']);
    final phase = GoalPhase.fromWire(map?['phase']);
    if (map == null || ref == null || objective == null || phase == null) return null;
    return GoalSnapshot(
      id: ref.id,
      revision: ref.revision,
      objective: objective,
      phase: phase,
      maxGoalRounds: asInt(map['maxGoalRounds']) ?? 0,
      blockedReason: phase == GoalPhase.blocked ? GoalBlockReason.fromJson(map['blockedReason']) : null,
    );
  }

  final String id;
  final int revision;

  /// What the person asked to get done (may span lines).
  final String objective;
  final GoalPhase phase;
  final GoalBlockReason? blockedReason;

  /// Cap on automatic continuation rounds.
  final int maxGoalRounds;

  GoalRef get ref => GoalRef(id, revision);

  @override
  bool operator ==(Object other) =>
      other is GoalSnapshot &&
      other.id == id &&
      other.revision == revision &&
      other.objective == objective &&
      other.phase == phase &&
      other.blockedReason == blockedReason &&
      other.maxGoalRounds == maxGoalRounds;

  @override
  int get hashCode => Object.hash(id, revision, objective, phase, blockedReason, maxGoalRounds);
}

/// The `goal` projection value: the current goal with its counters.
class GoalProjection {
  const GoalProjection({required this.goal, this.roundsStarted = 0, this.createdAt, this.updatedAt});

  /// Null for `null` (no goal yet, or cleared) and unknown shapes.
  static GoalProjection? fromJson(Object? json) {
    final map = asMap(json);
    final goal = GoalSnapshot.fromJson(map?['goal']);
    if (map == null || goal == null) return null;
    return GoalProjection(
      goal: goal,
      roundsStarted: asInt(map['roundsStarted']) ?? 0,
      createdAt: asEpochMs(map['createdAt']),
      updatedAt: asEpochMs(map['updatedAt']),
    );
  }

  final GoalSnapshot goal;

  /// Highest admitted continuation round of this goal.
  final int roundsStarted;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  GoalProjection copyWith({int? roundsStarted}) => GoalProjection(
    goal: goal,
    roundsStarted: roundsStarted ?? this.roundsStarted,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is GoalProjection &&
      other.goal == goal &&
      other.roundsStarted == roundsStarted &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(goal, roundsStarted, createdAt, updatedAt);
}

/// `goals/get` and mutation results: the projection plus the live
/// [activation].
class GoalView {
  const GoalView({required this.projection, required this.activation});

  static GoalView? fromJson(Object? json) {
    final map = asMap(json);
    final goal = GoalSnapshot.fromJson(map);
    if (map == null || goal == null) return null;
    return GoalView(
      projection: GoalProjection(
        goal: goal,
        roundsStarted: asInt(map['roundsStarted']) ?? 0,
        createdAt: asEpochMs(map['createdAt']),
        updatedAt: asEpochMs(map['updatedAt']),
      ),
      activation: GoalActivation.fromWire(map['activation']),
    );
  }

  final GoalProjection projection;

  /// Null when a newer Host sends a value this client does not know.
  final GoalActivation? activation;

  GoalSnapshot get goal => projection.goal;
  GoalRef get ref => goal.ref;
}

/// One `goal/activation-changed` edge for [sessionId]; [ref] and
/// [activation] are null when no goal is current any more.
class GoalActivationChange {
  const GoalActivationChange(this.sessionId, {this.ref, this.activation});

  /// Null for any other Host event.
  static GoalActivationChange? fromHostEvent(HostEvent event) {
    if (event is! UnknownHostEvent || event.event != 'goal/activation-changed') return null;
    final args = asListOrEmpty(event.raw['args']);
    final payload = asMap(args.isEmpty ? null : args.first);
    final sessionId = asString(payload?['sessionId']);
    if (sessionId == null) return null;
    final goal = asMap(payload?['goal']);
    return GoalActivationChange(
      sessionId,
      ref: GoalRef.fromJson(goal),
      activation: GoalActivation.fromWire(goal?['activation']),
    );
  }

  final String sessionId;
  final GoalRef? ref;
  final GoalActivation? activation;
}

/// The session's current goal over a follow window, the way the Host folds
/// its `goal` projection: start from the snapshot's `goal` value (as of
/// [SessionProjections.asOfSeq]), then apply the `goal/change` events and
/// goal rounds committed after it. When the snapshot carries no `goal` key
/// (an older Host) the whole loaded log is folded instead.
GoalProjection? foldGoalProjection(SessionProjections projections, Iterable<SessionLogEvent> events) {
  final seeded = projections.has('goal');
  var current = seeded ? GoalProjection.fromJson(projections.values['goal']) : null;
  final after = seeded ? projections.asOfSeq : -1;
  for (final event in events) {
    if (event.seq <= after) continue;
    switch (event.type) {
      case 'goal/change':
        final data = event.data;
        if (data['operation'] == 'clear') {
          current = null;
        } else if (GoalSnapshot.fromJson(data['goal']) case final goal?) {
          current = GoalProjection(
            goal: goal,
            roundsStarted: asInt(data['roundsStarted']) ?? 0,
            createdAt: asEpochMs(data['createdAt']),
            updatedAt: asEpochMs(data['updatedAt']),
          );
        }
      case 'user/message':
        // An admitted continuation round of the current goal.
        final source = asMap(event.data['source']);
        final round = asInt(source?['round']);
        if (current != null &&
            source?['kind'] == 'goal' &&
            source?['goalId'] == current.goal.id &&
            round != null &&
            round > current.roundsStarted) {
          current = current.copyWith(roundsStarted: round);
        }
    }
  }
  return current;
}

extension GoalsApi on DshClient {
  /// `goals/get` reaches this Host (the DSH Remote relay refuses it).
  bool get canReadGoal => supportsEndpoint('goals/get');

  /// Edit, pause, resume and clear all reach this Host.
  bool get canChangeGoal => const ['goals/edit', 'goals/pause', 'goals/resume', 'goals/clear'].every(supportsEndpoint);

  /// `goal/activation-changed` edges, every session's.
  Stream<GoalActivationChange> get goalActivationChanges =>
      hostEvents.map(GoalActivationChange.fromHostEvent).where((e) => e != null).cast<GoalActivationChange>();

  /// `goals/get`: the current goal with its live activation; null when the
  /// session has none.
  Future<GoalView?> goal(String sessionId) async =>
      GoalView.fromJson(await rpc.call('goals/get', {'agentId': sessionId}));

  /// `goals/create`: a new active goal. Fails with `GOAL_ALREADY_EXISTS`
  /// while an unfinished one is current.
  Future<GoalRef> createGoal(String sessionId, String objective, {int? maxGoalRounds}) async {
    final value = asMap(
      await rpc.call('goals/create', {
        'agentId': sessionId,
        'request': {'objective': objective.trim(), 'maxGoalRounds': ?maxGoalRounds},
      }),
    );
    return _ref(GoalRef.fromJson(value?['ref']), 'goals/create');
  }

  /// `goals/edit`: replaces the objective and/or the round cap; the phase
  /// stays.
  Future<GoalView> editGoal(String sessionId, GoalRef ref, {String? objective, int? maxGoalRounds}) async {
    if (objective == null && maxGoalRounds == null) {
      throw ArgumentError('editGoal needs an objective or a round cap');
    }
    return _view(
      await rpc.call('goals/edit', {
        'agentId': sessionId,
        'ref': ref.toJson(),
        'request': {'objective': ?objective?.trim(), 'maxGoalRounds': ?maxGoalRounds},
      }),
      'goals/edit',
    );
  }

  /// `goals/pause`: an active goal stops continuing (phase `paused`).
  Future<GoalView> pauseGoal(String sessionId, GoalRef ref) async =>
      _view(await rpc.call('goals/pause', {'agentId': sessionId, 'ref': ref.toJson()}), 'goals/pause');

  /// `goals/resume`: a paused or blocked goal, or an active one disarmed by a
  /// session start, continues again (while its round cap allows).
  Future<GoalView> resumeGoal(String sessionId, GoalRef ref) async =>
      _view(await rpc.call('goals/resume', {'agentId': sessionId, 'ref': ref.toJson()}), 'goals/resume');

  /// `goals/complete`: marks the goal done.
  Future<GoalView> completeGoal(String sessionId, GoalRef ref) async =>
      _view(await rpc.call('goals/complete', {'agentId': sessionId, 'ref': ref.toJson()}), 'goals/complete');

  /// `goals/clear`: removes the current goal (its history stays in the log);
  /// returns the tombstone ref, one revision past [ref].
  Future<GoalRef> clearGoal(String sessionId, GoalRef ref) async =>
      _ref(GoalRef.fromJson(await rpc.call('goals/clear', {'agentId': sessionId, 'ref': ref.toJson()})), 'goals/clear');
}

GoalView _view(Object? value, String endpoint) =>
    GoalView.fromJson(value) ?? (throw DshProtocolException('$endpoint returned no goal'));

GoalRef _ref(GoalRef? ref, String endpoint) => ref ?? (throw DshProtocolException('$endpoint returned no goal ref'));
