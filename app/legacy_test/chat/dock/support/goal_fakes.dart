import 'dart:async';

import 'package:dsh_app/state/goal_dock_state.dart';
import 'package:dsh_client/dsh_client.dart';

/// A goal as the `goal` projection carries it.
GoalProjection goalOf({
  String id = 'goal-1',
  int revision = 1,
  String objective = '把登录迁到新接口，并补齐连点测试',
  GoalPhase phase = GoalPhase.active,
  int rounds = 0,
  int max = 256,
  String? blocked,
}) => GoalProjection(
  goal: GoalSnapshot(
    id: id,
    revision: revision,
    objective: objective,
    phase: phase,
    maxGoalRounds: max,
    blockedReason: blocked == null ? null : GoalBlockReason('needs-input', blocked),
  ),
  roundsStarted: rounds,
);

/// The same goal one revision on, in [phase].
GoalProjection nextOf(GoalProjection p, {GoalPhase? phase, String? objective}) => goalOf(
  id: p.goal.id,
  revision: p.goal.revision + 1,
  objective: objective ?? p.goal.objective,
  phase: phase ?? p.goal.phase,
  rounds: p.roundsStarted,
  max: p.goal.maxGoalRounds,
);

/// `goals/*` without a Host: answers what the test says, records calls.
class FakeGoalBackend implements GoalBackend {
  FakeGoalBackend({this.canRead = true, this.canChange = true});

  @override
  bool canRead;

  @override
  bool canChange;

  /// Every call: `read s1`, `pause s1 goal-1@1`, `edit s1 goal-1@1 text`.
  final calls = <String>[];

  /// What `goals/get` answers; null = no goal.
  GoalView? Function()? onRead;

  /// Holds every read until completed (for ordering tests).
  Completer<void>? holdReads;

  /// Holds every mutation until completed.
  Completer<void>? holdMutations;

  /// Thrown by the next mutation.
  Object? fail;

  /// Activation the mutations answer with.
  GoalActivation activationAfter = GoalActivation.armed;

  final _activation = StreamController<GoalActivationChange>.broadcast();
  final _ready = StreamController<void>.broadcast();

  void emitActivation(String sessionId, GoalRef? ref, GoalActivation? activation) =>
      _activation.add(GoalActivationChange(sessionId, ref: ref, activation: activation));

  void emitReady() => _ready.add(null);

  Future<void> close() async {
    await _activation.close();
    await _ready.close();
  }

  @override
  Stream<GoalActivationChange> get activationChanges => _activation.stream;

  @override
  Stream<void> get hostReady => _ready.stream;

  @override
  Future<GoalView?> read(String sessionId) async {
    calls.add('read $sessionId');
    await holdReads?.future;
    return onRead?.call();
  }

  /// The goal a mutation starts from: what the test last told reads.
  GoalProjection? current;

  Future<GoalView> _answer(
    String op,
    String sessionId,
    GoalRef ref,
    GoalProjection Function(GoalProjection p) next, {
    String? extra,
  }) async {
    calls.add([op, sessionId, '${ref.id}@${ref.revision}', ?extra].join(' '));
    await holdMutations?.future;
    final failure = fail;
    if (failure != null) {
      fail = null;
      throw failure;
    }
    final from = current ?? goalOf(id: ref.id, revision: ref.revision);
    final after = next(from);
    current = after;
    return GoalView(projection: after, activation: activationAfter);
  }

  @override
  Future<GoalView> edit(String sessionId, GoalRef ref, String objective) =>
      _answer('edit', sessionId, ref, (p) => nextOf(p, objective: objective), extra: objective);

  @override
  Future<GoalView> pause(String sessionId, GoalRef ref) {
    activationAfter = GoalActivation.disarmed;
    return _answer('pause', sessionId, ref, (p) => nextOf(p, phase: GoalPhase.paused));
  }

  @override
  Future<GoalView> resume(String sessionId, GoalRef ref) {
    activationAfter = GoalActivation.armed;
    return _answer('resume', sessionId, ref, (p) => nextOf(p, phase: GoalPhase.active));
  }

  @override
  Future<GoalRef> clear(String sessionId, GoalRef ref) async {
    calls.add('clear $sessionId ${ref.id}@${ref.revision}');
    await holdMutations?.future;
    final failure = fail;
    if (failure != null) {
      fail = null;
      throw failure;
    }
    current = null;
    return GoalRef(ref.id, ref.revision + 1);
  }
}
