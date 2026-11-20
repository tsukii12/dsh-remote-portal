// The state behind the goal bar above the composer. Behaviour follows the
// official `dsh-client-ui-goal` GoalDock: the durable goal comes from the
// session's `goal` projection (here: folded by the transcript into
// ChatState.goal), the process-local activation from
// `goals/get` plus `goal/activation-changed`, mutations are compare-and-set on
// the goal's current ref and single-flight, and a cleared goal stays hidden
// until the log catches up.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'chat_error_text.dart';
import 'chat_state.dart';
import 'connection_state.dart';

/// The `goals/*` calls the goal bar makes; a seam for tests.
abstract interface class GoalBackend {
  /// `goals/get` reaches the Host (the DSH Remote relay refuses it).
  bool get canRead;

  /// Edit, pause, resume and clear all reach the Host.
  bool get canChange;

  Future<GoalView?> read(String sessionId);
  Future<GoalView> edit(String sessionId, GoalRef ref, String objective);
  Future<GoalView> pause(String sessionId, GoalRef ref);
  Future<GoalView> resume(String sessionId, GoalRef ref);
  Future<GoalRef> clear(String sessionId, GoalRef ref);

  /// `goal/activation-changed` edges of every session.
  Stream<GoalActivationChange> get activationChanges;

  /// A new Host generation is ready (activation must be read again).
  Stream<void> get hostReady;
}

class DshGoalBackend implements GoalBackend {
  DshGoalBackend(this.client);

  final DshClient client;

  @override
  bool get canRead => client.canReadGoal;

  @override
  bool get canChange => client.canChangeGoal;

  @override
  Future<GoalView?> read(String sessionId) => client.goal(sessionId);

  @override
  Future<GoalView> edit(String sessionId, GoalRef ref, String objective) =>
      client.editGoal(sessionId, ref, objective: objective);

  @override
  Future<GoalView> pause(String sessionId, GoalRef ref) => client.pauseGoal(sessionId, ref);

  @override
  Future<GoalView> resume(String sessionId, GoalRef ref) => client.resumeGoal(sessionId, ref);

  @override
  Future<GoalRef> clear(String sessionId, GoalRef ref) => client.clearGoal(sessionId, ref);

  @override
  Stream<GoalActivationChange> get activationChanges => client.goalActivationChanges;

  @override
  Stream<void> get hostReady => client.hostEvents.where((e) => e is HostReadyEvent);
}

final goalBackendProvider = Provider<GoalBackend?>((ref) {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  return client == null ? null : DshGoalBackend(client);
});

/// What the goal bar shows.
@immutable
class DockGoal {
  const DockGoal({required this.projection, this.activation, this.busy = false, this.canChange = true});

  final GoalProjection projection;

  /// Whether the Host may continue the goal by itself; null while unknown
  /// (not read yet, or `goals/get` is not reachable).
  final GoalActivation? activation;

  /// A change is on its way: actions wait.
  final bool busy;

  /// Edit, pause, resume and clear reach the Host.
  final bool canChange;

  GoalSnapshot get goal => projection.goal;
  GoalRef get ref => goal.ref;
  GoalPhase get phase => goal.phase;

  /// Active, but every session start disarms it until resumed.
  bool get disarmed => phase == GoalPhase.active && activation == GoalActivation.disarmed;

  /// Not moving on by itself: paused, or active but disarmed.
  bool get stopped => phase == GoalPhase.paused || disarmed;

  /// Official rule: pause an active goal that is armed. An unknown
  /// activation still offers pause (it is valid on any active goal).
  bool get canPause => phase == GoalPhase.active && !disarmed;

  /// Official rule: resume a paused goal or a disarmed active one.
  bool get canResume => phase == GoalPhase.paused || disarmed;

  @override
  bool operator ==(Object other) =>
      other is DockGoal &&
      other.projection == projection &&
      other.activation == activation &&
      other.busy == busy &&
      other.canChange == canChange;

  @override
  int get hashCode => Object.hash(projection, activation, busy, canChange);
}

/// The goal bar of one conversation; null when there is nothing to show
/// (no goal, a finished one, or one just cleared).
class GoalDockController extends Notifier<DockGoal?> {
  GoalDockController(this.sessionId);

  final String sessionId;

  /// The transcript's goal (the `goal` projection).
  GoalProjection? _logged;

  /// A mutation's answer the log has not caught up with yet.
  GoalView? _ahead;

  /// Tombstone of a clear the log has not caught up with yet.
  GoalRef? _cleared;

  /// Activation known for one exact goal revision.
  ({GoalRef ref, GoalActivation? activation})? _activation;

  bool _busy = false;
  bool _running = false;

  /// Bumped by live edges and new reads: an older read never overwrites a
  /// newer answer.
  int _readEpoch = 0;
  int _eventEpoch = 0;

  GoalBackend? get _backend => ref.read(goalBackendProvider);

  @override
  DockGoal? build() {
    final backend = ref.watch(goalBackendProvider);
    _ahead = null;
    _cleared = null;
    _activation = null;
    _busy = false;
    _readEpoch++;
    if (backend != null) {
      final changes = backend.activationChanges
          .where((c) => c.sessionId == sessionId)
          .listen(_onActivation, onError: (Object _) {});
      final ready = backend.hostReady.listen((_) => _onHostReady(), onError: (Object _) {});
      ref.onDispose(() {
        unawaited(changes.cancel());
        unawaited(ready.cancel());
      });
    }
    final chat = ref.read(chatProvider(sessionId));
    _logged = chat.goal;
    _running = chat.running;
    ref.listen(
      chatProvider(sessionId).select((s) => (goal: s.goal, running: s.running)),
      (_, next) => _onChat(next.goal, next.running),
    );
    // A read kicked off here answers after build returns.
    _ensureActivation();
    return _compose();
  }

  void _publish() {
    if (ref.mounted) state = _compose();
  }

  /// The goal as the bar shows it: the log, with our own newer answer laid
  /// over it.
  GoalProjection? get _current {
    final logged = _logged;
    final ahead = _ahead;
    if (ahead != null &&
        logged != null &&
        logged.goal.id == ahead.goal.id &&
        logged.goal.revision < ahead.goal.revision) {
      return ahead.projection;
    }
    return logged;
  }

  DockGoal? _compose() {
    final current = _current;
    if (current == null || current.goal.phase == GoalPhase.complete) {
      return null;
    }
    final cleared = _cleared;
    if (cleared != null && cleared.id == current.goal.id && current.goal.revision < cleared.revision) {
      return null;
    }
    final known = _activation;
    return DockGoal(
      projection: current,
      activation: known != null && known.ref == current.goal.ref ? known.activation : null,
      busy: _busy,
      canChange: _backend?.canChange ?? false,
    );
  }

  void _onChat(GoalProjection? logged, bool running) {
    final runningChanged = running != _running;
    _running = running;
    if (logged != _logged) {
      _logged = logged;
      // The log caught up with (or moved past) what we did.
      final ahead = _ahead;
      if (ahead != null &&
          (logged == null || logged.goal.id != ahead.goal.id || logged.goal.revision >= ahead.goal.revision)) {
        _ahead = null;
      }
      final cleared = _cleared;
      if (cleared != null &&
          (logged == null || logged.goal.id != cleared.id || logged.goal.revision >= cleared.revision)) {
        _cleared = null;
      }
    }
    // A turn starting or ending may arm or disarm the goal: read again.
    _ensureActivation(force: runningChanged);
    _publish();
  }

  void _onActivation(GoalActivationChange change) {
    _eventEpoch++;
    _readEpoch++;
    final changed = change.ref;
    _activation = changed == null ? null : (ref: changed, activation: change.activation);
    _publish();
  }

  void _onHostReady() {
    _eventEpoch++;
    _ensureActivation(force: true);
  }

  /// Reads the activation of the shown goal when it is active and its
  /// activation for this exact revision is unknown (or [force]).
  void _ensureActivation({bool force = false}) {
    final current = _current;
    if (current == null || current.goal.phase != GoalPhase.active) return;
    final goalRef = current.goal.ref;
    final known = _activation;
    if (known != null && known.ref == goalRef && !force) return;
    if (known == null || known.ref != goalRef) {
      // Unknown for this revision until a read or an edge says.
      _activation = (ref: goalRef, activation: null);
    }
    unawaited(_read(goalRef));
  }

  Future<void> _read(GoalRef goalRef) async {
    final backend = _backend;
    if (backend == null || !backend.canRead) return;
    final read = ++_readEpoch;
    final events = _eventEpoch;
    try {
      final view = await backend.read(sessionId);
      if (!ref.mounted || read != _readEpoch || events != _eventEpoch) return;
      if (view == null || view.ref != goalRef) return;
      _activation = (ref: view.ref, activation: view.activation);
      _publish();
    } catch (e) {
      debugPrint('goals/get: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Actions: each resolves to null when done, or a short sentence saying why
  // not.

  Future<String?> edit(String objective) {
    final text = objective.trim();
    if (text.isEmpty) return Future.value(appL10n.stateGoalEmpty);
    return _mutate(appL10n.commonSaveFailed, (b, r) => b.edit(sessionId, r, text));
  }

  Future<String?> pause() => _mutate(appL10n.stateGoalPauseFailed, (b, r) => b.pause(sessionId, r));

  Future<String?> resume() => _mutate(appL10n.stateGoalResumeFailed, (b, r) => b.resume(sessionId, r));

  Future<String?> clear() async {
    final shown = state;
    final backend = _backend;
    if (shown == null) return null;
    if (backend == null) return appL10n.stateGoalClearOffline;
    if (_busy) return null;
    _setBusy(true);
    try {
      final tombstone = await backend.clear(sessionId, shown.ref);
      if (ref.mounted) _cleared = tombstone;
      return null;
    } catch (e) {
      return goalErrorText(e, action: appL10n.stateGoalClearFailed);
    } finally {
      _setBusy(false);
    }
  }

  Future<String?> _mutate(String action, Future<GoalView> Function(GoalBackend backend, GoalRef ref) call) async {
    final shown = state;
    final backend = _backend;
    if (shown == null) return null;
    if (backend == null) return appL10n.stateGoalActionOffline(action);
    // Single flight: a second tap while one is on its way does nothing.
    if (_busy) return null;
    _setBusy(true);
    try {
      final view = await call(backend, shown.ref);
      if (ref.mounted) {
        _eventEpoch++;
        _ahead = view;
        _activation = (ref: view.ref, activation: view.activation);
      }
      return null;
    } catch (e) {
      return goalErrorText(e, action: action);
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool busy) {
    if (!ref.mounted) return;
    _busy = busy;
    _publish();
  }
}

final goalDockProvider = NotifierProvider.autoDispose.family<GoalDockController, DockGoal?, String>(
  GoalDockController.new,
);

/// 「[action]：原因」 for a refused goal change; transport and other failures
/// read like the rest of the chat ([chatErrorText]).
String goalErrorText(Object error, {required String action}) {
  if (error is DshRemoteException) {
    final reason = switch (error.code) {
      'GOAL_STALE_REVISION' => appL10n.stateGoalStale,
      'GOAL_NOT_FOUND' => appL10n.stateGoalMissing,
      'GOAL_AGENT_NOT_LIVE' => appL10n.stateGoalChatNotReady,
      'GOAL_INVALID_OBJECTIVE' || 'GOAL_INVALID_EDIT' => appL10n.stateGoalEmpty,
      'GOAL_INVALID_TRANSITION' when error.message.contains('exhausted') => appL10n.stateGoalTurnsExhausted,
      'GOAL_INVALID_TRANSITION' => appL10n.stateGoalStateChanged,
      _ => null,
    };
    if (reason != null) {
      debugPrint('$action: $error');
      return appL10n.stateActionReason(action, reason);
    }
  }
  return chatErrorText(error, action: action);
}
