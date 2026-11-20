import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/todos_fold.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> failure(String code, String message) => {
  'ok': false,
  'error': {'code': code, 'message': message, 'details': <String, Object?>{}},
};

/// A `GoalView` as `goals/get` and the mutations return it (dsh-goal 0.2.1).
Map<String, Object?> view({
  String id = 'goal-1',
  int revision = 3,
  String objective = '把登录迁到新接口\n并补齐测试',
  String phase = 'active',
  String activation = 'armed',
  int rounds = 2,
  Map<String, Object?>? blockedReason,
}) => {
  'id': id,
  'revision': revision,
  'objective': objective,
  'phase': phase,
  'blockedReason': ?blockedReason,
  'maxGoalRounds': 256,
  'roundsStarted': rounds,
  'createdAt': 1792720800000,
  'updatedAt': 1792720900000,
  'activation': activation,
};

SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1792720800000 + seq, 'type': type, 'data': data});

Map<String, Object?> snapshotChange(String operation, Map<String, Object?> goal, {int rounds = 0}) => {
  'kind': 'goal/change',
  'version': 1,
  'operation': operation,
  'goal': goal,
  'roundsStarted': rounds,
  'createdAt': 1792720800000,
  'updatedAt': 1792720900000,
};

Map<String, Object?> snapshot(String id, int revision, String phase, {String objective = '迁移登录'}) => {
  'id': id,
  'revision': revision,
  'objective': objective,
  'phase': phase,
  'maxGoalRounds': 8,
};

void main() {
  group('Remote', () {
    late FakeDsh host;

    setUp(() async => host = await FakeDsh.start());
    tearDown(() async => host.close());

    Future<DshClient> connect() async {
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
      addTearDown(client.close);
      return client;
    }

    Map<String, Object?> argsOf(String endpoint) {
      final call = host.rpcCalls.lastWhere((c) => c['method'] == endpoint);
      return ((call['payload']! as Map)['args']! as Map).cast<String, Object?>();
    }

    test('goals/get reads the view with its activation', () async {
      host.handlers['goals/get'] = (_) => ok(view());
      final client = await connect();
      final goal = (await client.goal('s1'))!;
      expect(argsOf('goals/get'), {'agentId': 's1'});
      expect(goal.ref, const GoalRef('goal-1', 3));
      expect(goal.goal.objective, '把登录迁到新接口\n并补齐测试');
      expect(goal.goal.phase, GoalPhase.active);
      expect(goal.goal.maxGoalRounds, 256);
      expect(goal.projection.roundsStarted, 2);
      expect(goal.projection.updatedAt, DateTime.fromMillisecondsSinceEpoch(1792720900000));
      expect(goal.activation, GoalActivation.armed);
    });

    test('goals/get without a goal is null', () async {
      host.handlers['goals/get'] = (_) => {'ok': true};
      expect(await (await connect()).goal('s1'), isNull);
    });

    test('a blocked goal keeps its reason; other phases drop a stray one', () async {
      host.handlers['goals/get'] = (_) => ok(
        view(
          phase: 'blocked',
          activation: 'disarmed',
          blockedReason: {'code': 'round-budget-exhausted', 'message': '轮次用完了'},
        ),
      );
      final client = await connect();
      final blocked = (await client.goal('s1'))!;
      expect(blocked.goal.phase, GoalPhase.blocked);
      expect(blocked.goal.blockedReason!.message, '轮次用完了');
      expect(blocked.activation, GoalActivation.disarmed);

      host.handlers['goals/get'] = (_) => ok(view(phase: 'paused', blockedReason: {'code': 'x', 'message': 'stale'}));
      expect((await client.goal('s1'))!.goal.blockedReason, isNull);
    });

    test('edit sends the exact ref and a trimmed objective', () async {
      host.handlers['goals/edit'] = (args) => ok(view(revision: 4, objective: '只迁移登录'));
      final client = await connect();
      final edited = await client.editGoal('s1', const GoalRef('goal-1', 3), objective: '  只迁移登录 \n');
      expect(argsOf('goals/edit'), {
        'agentId': 's1',
        'ref': {'id': 'goal-1', 'revision': 3},
        'request': {'objective': '只迁移登录'},
      });
      expect(edited.ref, const GoalRef('goal-1', 4));
      expect(edited.goal.objective, '只迁移登录');
    });

    test('edit can change only the round cap; it needs one of the two', () async {
      host.handlers['goals/edit'] = (args) => ok(view(revision: 4));
      final client = await connect();
      await client.editGoal('s1', const GoalRef('goal-1', 3), maxGoalRounds: 32);
      expect(argsOf('goals/edit')['request'], {'maxGoalRounds': 32});
      expect(() => client.editGoal('s1', const GoalRef('goal-1', 3)), throwsArgumentError);
    });

    test('pause, resume and complete address the ref and return the new view', () async {
      host.handlers['goals/pause'] = (_) => ok(view(revision: 4, phase: 'paused', activation: 'disarmed'));
      host.handlers['goals/resume'] = (_) => ok(view(revision: 5));
      host.handlers['goals/complete'] = (_) => ok(view(revision: 6, phase: 'complete', activation: 'disarmed'));
      final client = await connect();

      final paused = await client.pauseGoal('s1', const GoalRef('goal-1', 3));
      expect(argsOf('goals/pause'), {
        'agentId': 's1',
        'ref': {'id': 'goal-1', 'revision': 3},
      });
      expect(paused.goal.phase, GoalPhase.paused);
      expect(paused.activation, GoalActivation.disarmed);

      final resumed = await client.resumeGoal('s1', paused.ref);
      expect(argsOf('goals/resume')['ref'], {'id': 'goal-1', 'revision': 4});
      expect(resumed.goal.phase, GoalPhase.active);
      expect(resumed.activation, GoalActivation.armed);

      final done = await client.completeGoal('s1', resumed.ref);
      expect(argsOf('goals/complete')['ref'], {'id': 'goal-1', 'revision': 5});
      expect(done.goal.phase, GoalPhase.complete);
    });

    test('clear returns the tombstone ref', () async {
      host.handlers['goals/clear'] = (_) => ok({'id': 'goal-1', 'revision': 4});
      final client = await connect();
      final tombstone = await client.clearGoal('s1', const GoalRef('goal-1', 3));
      expect(argsOf('goals/clear'), {
        'agentId': 's1',
        'ref': {'id': 'goal-1', 'revision': 3},
      });
      expect(tombstone, const GoalRef('goal-1', 4));
    });

    test('create omits an unset round cap', () async {
      host.handlers['goals/create'] = (_) => ok({
        'ref': {'id': 'goal-2', 'revision': 1},
      });
      final client = await connect();
      final ref = await client.createGoal('s1', ' 修好构建 ');
      expect(argsOf('goals/create'), {
        'agentId': 's1',
        'request': {'objective': '修好构建'},
      });
      expect(ref, const GoalRef('goal-2', 1));
      await client.createGoal('s1', '修好构建', maxGoalRounds: 12);
      expect(argsOf('goals/create')['request'], {'objective': '修好构建', 'maxGoalRounds': 12});
    });

    test('a stale ref surfaces the Host code', () async {
      host.handlers['goals/pause'] = (_) =>
          failure('GOAL_STALE_REVISION', 'stale goal ref "goal-1" revision 2; current is "goal-1" revision 3');
      final client = await connect();
      await expectLater(
        client.pauseGoal('s1', const GoalRef('goal-1', 2)),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'GOAL_STALE_REVISION')),
      );
    });

    test('a mutation without a goal in the answer is a protocol error', () async {
      host.handlers['goals/resume'] = (_) => {'ok': true};
      final client = await connect();
      await expectLater(client.resumeGoal('s1', const GoalRef('goal-1', 3)), throwsA(isA<DshProtocolException>()));
    });

    test('activation edges arrive per session; a cleared goal has none', () async {
      final client = await connect();
      await client.mux.ready();
      final seen = <GoalActivationChange>[];
      final sub = client.goalActivationChanges.listen(seen.add);
      addTearDown(sub.cancel);
      final socket = host.sockets.single;
      socket.event({
        'type': 'emit',
        'event': 'api-session/status',
        'args': ['s1', true],
      });
      socket.event({
        'type': 'emit',
        'event': 'goal/activation-changed',
        'args': [
          {
            'sessionId': 's1',
            'goal': {'id': 'goal-1', 'revision': 3, 'activation': 'disarmed'},
          },
        ],
      });
      socket.event({
        'type': 'emit',
        'event': 'goal/activation-changed',
        'args': [
          {'sessionId': 's2'},
        ],
      });
      await _until(() => seen.length == 2);
      expect(seen.first.sessionId, 's1');
      expect(seen.first.ref, const GoalRef('goal-1', 3));
      expect(seen.first.activation, GoalActivation.disarmed);
      expect(seen.last.sessionId, 's2');
      expect(seen.last.ref, isNull);
      expect(seen.last.activation, isNull);
    });

    test('an HTTP Host reaches every goal endpoint', () async {
      final client = await connect();
      expect(client.canReadGoal, isTrue);
      expect(client.canChangeGoal, isTrue);
    });
  });

  group('foldGoalProjection', () {
    test('starts from the snapshot value and skips what it already counts', () {
      final projections = SessionProjections(10, {
        'goal': {
          'goal': snapshot('goal-1', 2, 'active'),
          'roundsStarted': 1,
          'createdAt': 1792720800000,
          'updatedAt': 1792720800000,
        },
      });
      final goal = foldGoalProjection(projections, [
        // Already in the snapshot: must not move the goal back.
        event(4, 'goal/change', snapshotChange('create', snapshot('goal-1', 1, 'active'))),
      ])!;
      expect(goal.goal.ref, const GoalRef('goal-1', 2));
      expect(goal.roundsStarted, 1);
    });

    test('later changes and goal rounds apply on top', () {
      final projections = SessionProjections(10, {
        'goal': {'goal': snapshot('goal-1', 2, 'active'), 'roundsStarted': 1},
      });
      final events = [
        event(11, 'user/message', {
          'role': 'user',
          'content': const <Object?>[],
          'source': {'kind': 'goal', 'goalId': 'goal-1', 'revision': 2, 'round': 2},
        }),
        // A round of another goal does not count.
        event(12, 'user/message', {
          'source': {'kind': 'goal', 'goalId': 'goal-9', 'revision': 1, 'round': 7},
        }),
      ];
      expect(foldGoalProjection(projections, events)!.roundsStarted, 2);

      final paused = foldGoalProjection(projections, [
        ...events,
        event(13, 'goal/change', snapshotChange('pause', snapshot('goal-1', 3, 'paused'), rounds: 2)),
      ])!;
      expect(paused.goal.phase, GoalPhase.paused);
      expect(paused.goal.revision, 3);
      expect(paused.roundsStarted, 2);
    });

    test('clear leaves no goal; a new create replaces it', () {
      const projections = SessionProjections(3, {'goal': null});
      final events = [
        event(4, 'goal/change', snapshotChange('create', snapshot('goal-1', 1, 'active'))),
        event(5, 'goal/change', {
          'kind': 'goal/change',
          'version': 1,
          'operation': 'clear',
          'cleared': {'id': 'goal-1', 'revision': 2},
          'clearedAt': 1792720900000,
        }),
      ];
      expect(foldGoalProjection(projections, events.take(1))!.goal.id, 'goal-1');
      expect(foldGoalProjection(projections, events), isNull);
      expect(
        foldGoalProjection(projections, [
          ...events,
          event(6, 'goal/change', snapshotChange('create', snapshot('goal-2', 1, 'active', objective: '新目标'))),
        ])!.goal.objective,
        '新目标',
      );
    });

    test('a snapshot without the goal key folds the whole log', () {
      const projections = SessionProjections(20, {'title': 'x'});
      final goal = foldGoalProjection(projections, [
        event(4, 'goal/change', snapshotChange('create', snapshot('goal-1', 1, 'active'))),
        event(9, 'goal/change', {
          ...snapshotChange('block', {
            ...snapshot('goal-1', 2, 'blocked'),
            'blockedReason': {'code': 'needs-input', 'message': '需要你确认数据库'},
          }),
        }),
      ])!;
      expect(goal.goal.phase, GoalPhase.blocked);
      expect(goal.goal.blockedReason!.message, '需要你确认数据库');
    });

    test('unknown shapes are ignored', () {
      const projections = SessionProjections(0, {
        'goal': {'goal': 'nope'},
      });
      expect(
        foldGoalProjection(projections, [
          event(1, 'goal/change', {'operation': 'edit'}),
        ]),
        isNull,
      );
    });
  });

  group('ChatTranscript', () {
    test('folds the goal and the todo list the way the projections do', () {
      final transcript = ChatTranscript()
        ..apply(
          SessionSnapshotEvent.fromJson('s1', {
            'type': 'snapshot',
            'cursor': 3,
            'records': const <Object?>[],
            'hasMore': false,
            'projections': {
              'asOfSeq': 3,
              'values': {'goal': null, 'todos': null},
            },
          }),
        );
      expect(transcript.goal, isNull);
      transcript
        ..apply(event(4, 'turn/start', {'turn': 1}))
        ..apply(event(5, 'goal/change', snapshotChange('create', snapshot('goal-1', 1, 'active'))))
        ..apply(
          event(6, 'todo/write', {
            'todos': [
              {'content': '读代码', 'status': 'completed'},
            ],
          }),
        )
        ..apply(
          event(7, 'turn/end', {
            'turn': 1,
            'reason': {'kind': 'completed'},
          }),
        );
      expect(transcript.goal!.goal.ref, const GoalRef('goal-1', 1));
      expect(transcript.todos!.single.content, '读代码', reason: 'kept after the turn ends');

      transcript.apply(event(8, 'turn/start', {'turn': 2}));
      expect(transcript.todos, isNull, reason: 'the next turn clears it');
      expect(transcript.goal, isNotNull, reason: 'a goal outlives turns');

      transcript.apply(
        event(9, 'goal/change', {
          'kind': 'goal/change',
          'version': 1,
          'operation': 'clear',
          'cleared': {'id': 'goal-1', 'revision': 2},
          'clearedAt': 1792720900000,
        }),
      );
      expect(transcript.goal, isNull);
    });
  });

  group('foldTodos', () {
    final first = [
      {'content': '读代码', 'status': 'completed'},
      {'content': '改代码', 'status': 'in_progress'},
    ];

    test('the latest write wins; a new turn clears; a turn end keeps it', () {
      final events = [
        event(4, 'turn/start', {'turn': 1}),
        event(5, 'todo/write', {'todos': first}),
        event(9, 'turn/end', {
          'turn': 1,
          'reason': {'kind': 'completed'},
        }),
      ];
      expect(foldTodos(SessionProjections.empty, events)!.map((t) => t.content), ['读代码', '改代码']);
      expect(
        foldTodos(SessionProjections.empty, [
          ...events,
          event(10, 'turn/start', {'turn': 2}),
        ]),
        isNull,
      );
    });

    test('starts from the snapshot value; earlier writes are already in it', () {
      const projections = SessionProjections(8, {'todos': null});
      // The turn that cleared the list is before the cut: the write before it
      // must not come back.
      expect(
        foldTodos(projections, [
          event(5, 'todo/write', {'todos': first}),
        ]),
        isNull,
      );
      final seeded = SessionProjections(8, {'todos': first});
      expect(foldTodos(seeded, const [])!.length, 2);
      expect(
        foldTodos(seeded, [
          event(9, 'todo/write', {
            'todos': [
              {'content': '读代码', 'status': 'completed'},
              {'content': '改代码', 'status': 'completed'},
            ],
          }),
        ])!.every((t) => t.status == 'completed'),
        isTrue,
      );
    });
  });
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
