// The goal bar's state (official dsh-client-ui-goal GoalDock behaviour): the
// goal comes from the log, the activation from `goals/get` and live edges,
// mutations are compare-and-set and single-flight, a cleared goal stays
// hidden until the log catches up, refusals read as short sentences.

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/goal_dock_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/goal_fakes.dart';

class _Setup {
  _Setup({GoalProjection? goal, bool running = false, FakeGoalBackend? backend})
    : backend = backend ?? FakeGoalBackend() {
    container = ProviderContainer(
      overrides: [
        goalBackendProvider.overrideWithValue(this.backend),
        chatProvider.overrideWith2(
          (id) => chats[id] = FakeChatController(id, ChatState(loading: false, goal: goal, running: running)),
        ),
      ],
    );
    sub = container.listen(goalDockProvider('s1'), (_, _) {});
  }

  final FakeGoalBackend backend;
  late final ProviderContainer container;
  late final ProviderSubscription<DockGoal?> sub;
  final chats = <String, FakeChatController>{};

  DockGoal? get shown => container.read(goalDockProvider('s1'));
  GoalDockController get controller => container.read(goalDockProvider('s1').notifier);

  /// The log moves on (a `goal/change` folded into ChatState).
  void log(GoalProjection? goal, {bool running = false}) =>
      chats['s1']!.emit(ChatState(loading: false, goal: goal, running: running));

  Future<void> dispose() async {
    sub.close();
    container.dispose();
    await backend.close();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('what shows', () {
    test('no goal, or a finished one: nothing', () async {
      final s = _Setup();
      addTearDown(s.dispose);
      expect(s.shown, isNull);
      s.log(goalOf(phase: GoalPhase.complete));
      await _settle();
      expect(s.shown, isNull);
    });

    test('an active goal reads its activation once per revision', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend()..onRead = () => GoalView(projection: goal, activation: GoalActivation.armed);
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      expect(s.shown!.goal.objective, goal.goal.objective);
      expect(s.shown!.activation, isNull, reason: 'unknown until read');
      await _settle();
      expect(s.shown!.activation, GoalActivation.armed);
      expect(s.shown!.canPause, isTrue);
      expect(s.shown!.canResume, isFalse);
      expect(s.shown!.stopped, isFalse);
      expect(backend.calls, ['read s1']);

      // The same revision again: no new read.
      s.log(goal);
      await _settle();
      expect(backend.calls, ['read s1']);
    });

    test('a disarmed active goal reads as paused and offers resume', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend()..onRead = () => GoalView(projection: goal, activation: GoalActivation.disarmed);
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      await _settle();
      expect(s.shown!.disarmed, isTrue);
      expect(s.shown!.stopped, isTrue);
      expect(s.shown!.canPause, isFalse);
      expect(s.shown!.canResume, isTrue);
    });

    test('paused and blocked goals are not read; blocked offers neither', () async {
      final backend = FakeGoalBackend();
      final s = _Setup(
        goal: goalOf(phase: GoalPhase.paused),
        backend: backend,
      );
      addTearDown(s.dispose);
      await _settle();
      expect(s.shown!.canResume, isTrue);
      expect(s.shown!.canPause, isFalse);
      s.log(goalOf(revision: 2, phase: GoalPhase.blocked, blocked: '需要确认'));
      await _settle();
      expect(s.shown!.phase, GoalPhase.blocked);
      expect(s.shown!.canPause, isFalse);
      expect(s.shown!.canResume, isFalse);
      expect(backend.calls, isEmpty);
    });

    test('without goals/get (relay) pause is still offered', () async {
      final backend = FakeGoalBackend(canRead: false);
      final s = _Setup(goal: goalOf(), backend: backend);
      addTearDown(s.dispose);
      await _settle();
      expect(backend.calls, isEmpty);
      expect(s.shown!.activation, isNull);
      expect(s.shown!.canPause, isTrue);
      expect(s.shown!.canResume, isFalse);

      // A live edge still tells.
      backend.emitActivation('s1', const GoalRef('goal-1', 1), GoalActivation.disarmed);
      await _settle();
      expect(s.shown!.canResume, isTrue);
    });
  });

  group('live activation', () {
    test('edges for this session and this revision apply', () async {
      final backend = FakeGoalBackend(canRead: false);
      final s = _Setup(goal: goalOf(), backend: backend);
      addTearDown(s.dispose);
      backend
        ..emitActivation('s2', const GoalRef('goal-1', 1), GoalActivation.armed)
        ..emitActivation('s1', const GoalRef('goal-1', 9), GoalActivation.disarmed);
      await _settle();
      expect(s.shown!.activation, isNull, reason: 'other session / revision');
      backend.emitActivation('s1', const GoalRef('goal-1', 1), GoalActivation.armed);
      await _settle();
      expect(s.shown!.activation, GoalActivation.armed);
    });

    test('an edge that lands during a read wins over the read', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend()
        ..holdReads = Completer<void>()
        ..onRead = () => GoalView(projection: goal, activation: GoalActivation.armed);
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      await _settle();
      backend.emitActivation('s1', const GoalRef('goal-1', 1), GoalActivation.disarmed);
      await _settle();
      backend.holdReads!.complete();
      await _settle();
      expect(s.shown!.activation, GoalActivation.disarmed);
    });

    test('a turn starting or ending reads again; so does a new Host', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend()..onRead = () => GoalView(projection: goal, activation: GoalActivation.armed);
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      await _settle();
      s.log(goal, running: true);
      await _settle();
      s.log(goal);
      await _settle();
      backend.emitReady();
      await _settle();
      expect(backend.calls, List.filled(4, 'read s1'));
    });
  });

  group('actions', () {
    test('pause addresses the current ref; its answer shows at once', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      expect(await s.controller.pause(), isNull);
      expect(backend.calls, ['pause s1 goal-1@1']);
      expect(s.shown!.phase, GoalPhase.paused);
      expect(s.shown!.goal.revision, 2);
      expect(s.shown!.canResume, isTrue);

      // The log catches up, then moves past it: the log wins again.
      s.log(nextOf(goal, phase: GoalPhase.paused));
      await _settle();
      expect(s.shown!.goal.revision, 2);
      s.log(goalOf(revision: 3, objective: '改过的目标', phase: GoalPhase.paused));
      await _settle();
      expect(s.shown!.goal.objective, '改过的目标');
    });

    test('resume answers armed', () async {
      final goal = goalOf(phase: GoalPhase.paused);
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      expect(await s.controller.resume(), isNull);
      expect(s.shown!.phase, GoalPhase.active);
      expect(s.shown!.activation, GoalActivation.armed);
      expect(s.shown!.canPause, isTrue);
    });

    test('edit trims; an empty one never leaves the app', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      expect(await s.controller.edit('  \n '), '目标不能为空');
      expect(backend.calls, isEmpty);
      expect(await s.controller.edit(' 只迁移登录\n再补测试 '), isNull);
      expect(backend.calls, ['edit s1 goal-1@1 只迁移登录\n再补测试']);
      expect(s.shown!.goal.objective, '只迁移登录\n再补测试');
    });

    test('busy while on its way; a second tap does nothing', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)
        ..current = goal
        ..holdMutations = Completer<void>();
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      final first = s.controller.pause();
      await _settle();
      expect(s.shown!.busy, isTrue);
      expect(await s.controller.pause(), isNull);
      expect(await s.controller.clear(), isNull);
      backend.holdMutations!.complete();
      expect(await first, isNull);
      expect(s.shown!.busy, isFalse);
      expect(backend.calls, ['pause s1 goal-1@1']);
    });

    test('clear hides the goal until the log says so, then a new one shows', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);
      expect(await s.controller.clear(), isNull);
      expect(backend.calls, ['clear s1 goal-1@1']);
      expect(s.shown, isNull, reason: 'the log still has revision 1');
      s.log(goal);
      await _settle();
      expect(s.shown, isNull);
      s.log(null);
      await _settle();
      expect(s.shown, isNull);
      s.log(goalOf(id: 'goal-2', objective: '新目标'));
      await _settle();
      expect(s.shown!.goal.objective, '新目标');
    });

    test('refusals read as short sentences', () async {
      final goal = goalOf();
      final backend = FakeGoalBackend(canRead: false)..current = goal;
      final s = _Setup(goal: goal, backend: backend);
      addTearDown(s.dispose);

      backend.fail = const DshRemoteException(
        'GOAL_STALE_REVISION',
        'stale goal ref "goal-1" revision 1; current is "goal-1" revision 2',
      );
      expect(await s.controller.pause(), '没能暂停：目标刚有变化，再试一次');

      backend.fail = const DshRemoteException(
        'GOAL_INVALID_TRANSITION',
        'goal "goal-1" exhausted 256 goal rounds; increase maxGoalRounds before resuming',
      );
      expect(await s.controller.resume(), '没能恢复：轮次已用完');

      backend.fail = const DshTransportException('connection refused');
      expect(await s.controller.clear(), '没能清除：没能连上引擎');
      expect(s.shown, isNotNull, reason: 'a failed clear keeps the goal');
      expect(s.shown!.busy, isFalse);
    });

    test('no connection: the goal still shows, changes say why not', () async {
      final container = ProviderContainer(
        overrides: [
          goalBackendProvider.overrideWithValue(null),
          chatProvider.overrideWith2((id) => FakeChatController(id, ChatState(loading: false, goal: goalOf()))),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(goalDockProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      final shown = container.read(goalDockProvider('s1'))!;
      expect(shown.canChange, isFalse);
      expect(await container.read(goalDockProvider('s1').notifier).pause(), '没能暂停：没能连上引擎');
    });
  });
}
