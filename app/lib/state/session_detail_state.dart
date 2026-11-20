import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// The session's goal (`goal` projection of dsh-goal), when one is set.
class SessionGoal {
  const SessionGoal({
    required this.objective,
    required this.phase,
    this.blockedReason,
    this.roundsStarted = 0,
    this.maxRounds,
  });

  /// Reads the projection value; null for `null` or an unknown shape.
  static SessionGoal? fromJson(Object? json) {
    if (json is! Map) return null;
    final goal = json['goal'];
    if (goal is! Map) return null;
    final objective = goal['objective'];
    if (objective is! String) return null;
    final blocked = goal['blockedReason'];
    final rounds = json['roundsStarted'];
    final max = goal['maxGoalRounds'];
    return SessionGoal(
      objective: objective,
      phase: goal['phase'] is String ? goal['phase'] as String : 'active',
      blockedReason: blocked is Map && blocked['message'] is String ? blocked['message'] as String : null,
      roundsStarted: rounds is num ? rounds.toInt() : 0,
      maxRounds: max is num ? max.toInt() : null,
    );
  }

  final String objective;

  /// `active`, `paused`, `blocked`, `complete`.
  final String phase;
  final String? blockedReason;
  final int roundsStarted;
  final int? maxRounds;
}

/// Session-level state for the 对话详情 page, from DSH projections:
/// `goal`, `plan` (plan mode) and `todos`.
class SessionPanels {
  const SessionPanels({this.goal, this.planActive = false, this.planPending = false, this.todos});

  static const empty = SessionPanels();

  factory SessionPanels.fromProjections(Map<String, Object?> values) {
    final plan = values['plan'];
    final todos = values['todos'];
    return SessionPanels(
      goal: SessionGoal.fromJson(values['goal']),
      planActive: plan is Map && plan['active'] == true,
      planPending: plan is Map && plan['pending'] == true,
      todos: todos is List ? todos.map(TodoItem.fromJson).toList(growable: false) : null,
    );
  }

  final SessionGoal? goal;
  final bool planActive;
  final bool planPending;

  /// Null when the projection has no todo list (the chat log may still).
  final List<TodoItem>? todos;
}

/// Live [SessionPanels]: seeded from `session/projections`, then kept current
/// by `session/control` frames for its keys.
class SessionPanelsController extends Notifier<SessionPanels> {
  SessionPanelsController(this.sessionId);

  final String sessionId;
  Map<String, Object?> _values = const {};

  /// Seq each key was last set at: an older seed or frame never overwrites it.
  final Map<String, int> _keySeq = {};

  int _seedTicket = 0;
  bool _hasControlCut = false;

  static const _keys = {'goal', 'plan', 'todos'};

  @override
  SessionPanels build() {
    final conn = ref.watch(activeConnectionProvider).value;
    _values = const {};
    _keySeq.clear();
    _hasControlCut = false;
    if (conn == null) return SessionPanels.empty;
    final sub = conn.client.watchSessionControl().listen(
      (update) => _onControl(update, conn.client),
      onError: (Object _) {},
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    unawaited(_seed(conn.client));
    return SessionPanels.empty;
  }

  Future<void> _seed(DshClient client) async {
    // Notifier.ref changes when dependencies rebuild; this read belongs to this build.
    final r = ref;
    final ticket = ++_seedTicket;
    final readyGeneration = client.mux.lastReadyGenerationNumber;
    try {
      final projections = await client.projections(sessionId);
      if (!r.mounted ||
          ticket != _seedTicket ||
          client.mux.lastReadyGenerationNumber != readyGeneration ||
          projections == null) {
        return;
      }
      _merge(projections);
    } catch (_) {
      // Quiet: the control stream fills it in.
    }
  }

  void _onControl(SessionControlUpdate update, DshClient client) {
    if (!ref.mounted) return;
    switch (update) {
      case SessionControlBaseline(:final projections):
        if (_hasControlCut) ++_seedTicket;
        _hasControlCut = true;
        final mine = projections[sessionId];
        if (mine != null) {
          _replace(mine);
        } else {
          // A baseline lists resident sessions. Keep a cold session's cache
          // while querying its current projections under the new cut.
          _keySeq.clear();
          unawaited(_seed(client));
        }
      case SessionControlProjection(:final sessionId, :final key, :final value, :final seq)
          when sessionId == this.sessionId && _keys.contains(key):
        if (seq <= (_keySeq[key] ?? -1)) return;
        _keySeq[key] = seq;
        _values = {..._values, key: value};
        state = SessionPanels.fromProjections(_values);
      default:
        break;
    }
  }

  void _replace(SessionProjections projections) {
    for (final key in _keys) {
      _keySeq[key] = projections.asOfSeq;
    }
    _values = {
      for (final key in _keys)
        if (projections.values.containsKey(key)) key: projections.values[key],
    };
    state = SessionPanels.fromProjections(_values);
  }

  /// A seed: only keys no newer frame has set yet.
  void _merge(SessionProjections projections) {
    final values = {..._values};
    for (final key in _keys) {
      final seen = _keySeq[key];
      if (seen != null && projections.asOfSeq <= seen) continue;
      _keySeq[key] = projections.asOfSeq;
      if (projections.values.containsKey(key)) {
        values[key] = projections.values[key];
      } else {
        values.remove(key);
      }
    }
    _values = values;
    state = SessionPanels.fromProjections(_values);
  }
}

final sessionPanelsProvider = NotifierProvider.autoDispose.family<SessionPanelsController, SessionPanels, String>(
  SessionPanelsController.new,
);
