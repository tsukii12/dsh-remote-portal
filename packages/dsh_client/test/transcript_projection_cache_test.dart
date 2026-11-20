import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/todos_fold.dart';
import 'package:test/test.dart';

SessionLogEvent event(int seq, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': 1000 + seq, 'type': type, 'data': data});

Map<String, Object?> goalData({int revision = 1, String objective = 'own objective', int rounds = 1}) => {
  'goal': {'id': 'own-goal', 'revision': revision, 'objective': objective, 'phase': 'active', 'maxGoalRounds': 10},
  'roundsStarted': rounds,
  'createdAt': 1000,
  'updatedAt': 1000 + revision,
};

SessionLogEvent todo(int seq, String text) => event(seq, 'todo/write', {
  'todos': [
    {'content': text, 'status': 'pending'},
  ],
});

SessionLogEvent round(int seq, int round, {String kind = 'goal'}) => event(seq, 'user/message', {
  'id': 'u$seq',
  'role': 'user',
  'source': {'kind': kind, 'goalId': 'own-goal', 'round': round},
  'content': [
    {'type': 'text', 'text': 'continue'},
  ],
});

SessionSnapshotEvent snapshot(
  List<SessionLogEvent> events, {
  Map<String, Object?> values = const {},
  int asOfSeq = -1,
  int? cursor,
  bool resync = false,
}) => SessionSnapshotEvent(
  sessionId: 'own',
  header: SessionHeader.fromJson({'id': 'own', 'version': 4, 'createdAt': 1000}),
  cursor: cursor ?? (events.isEmpty ? -1 : events.last.seq),
  events: events,
  hasMore: false,
  projections: SessionProjections(asOfSeq, values),
  assistantRevision: 0,
  isResync: resync,
);

// The uncached public folds are the semantic reference. Assertions observe
// values, not private cache state or allocation/identity promises.
void check(ChatTranscript transcript) {
  final expectedTodos = foldTodos(transcript.projections, transcript.events);
  final expectedGoal = foldGoalProjection(transcript.projections, transcript.events);
  for (var read = 0; read < 2; read++) {
    expect(
      transcript.todos?.map((t) => (t.content, t.status)).toList(),
      expectedTodos?.map((t) => (t.content, t.status)).toList(),
    );
    expect(transcript.goal, expectedGoal);
  }
}

void main() {
  test('unrelated append after warmed seeded values retains the same values', () {
    final transcript = ChatTranscript()
      ..apply(
        snapshot(
          [],
          asOfSeq: 0,
          values: {
            'todos': [
              {'content': 'keep', 'status': 'pending'},
            ],
            'goal': goalData(),
          },
        ),
      );
    check(transcript);
    final events = [
      event(1, 'step/start', {'turn': 1, 'step': 1}),
      event(2, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'own', 'name': 'read_file', 'arguments': '{}'}),
      event(3, 'tool/result', {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'r',
          'role': 'tool',
          'toolCallId': 'own',
          'content': [
            {'type': 'text', 'text': 'done'},
          ],
        },
      }),
      event(4, 'assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'a',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'done'},
          ],
        },
      }),
      event(5, 'step/end', {'turn': 1, 'step': 1}),
      event(6, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
    ];
    for (final value in events) {
      transcript.apply(value);
      check(transcript);
    }
    expect(transcript.todos!.single.content, 'keep');
    expect(transcript.goal!.goal.objective, 'own objective');
  });

  test('warmed absence is replaced by a todo write and cleared by next turn', () {
    final transcript = ChatTranscript()..apply(snapshot([]));
    check(transcript);
    transcript.apply(event(0, 'step/start', {'turn': 1, 'step': 1}));
    check(transcript);
    transcript.apply(todo(1, 'new'));
    check(transcript);
    expect(transcript.todos!.single.content, 'new');
    transcript.apply(
      event(2, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      }),
    );
    check(transcript);
    expect(transcript.todos!.single.content, 'new');
    transcript.apply(event(3, 'turn/start', {'turn': 2}));
    check(transcript);
    expect(transcript.todos, isNull);
  });

  test('goal changes, ordinary user input, admitted rounds and clear stay current', () {
    final transcript = ChatTranscript()..apply(snapshot([]));
    check(transcript);
    transcript.apply(event(0, 'goal/change', goalData()));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 1);
    transcript.apply(round(1, 9, kind: 'user'));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 1);
    transcript.apply(round(2, 4));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 4);
    transcript.apply(round(3, 2));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 4);
    transcript.apply(event(4, 'goal/change', goalData(revision: 2, objective: 'edited', rounds: 4)));
    check(transcript);
    expect(transcript.goal!.goal.objective, 'edited');
    transcript.apply(event(5, 'goal/change', {'operation': 'clear'}));
    check(transcript);
    expect(transcript.goal, isNull);
  });

  test('projection boundary and follow cursor do not replace actual append boundary', () {
    final transcript = ChatTranscript()
      ..apply(
        snapshot(
          [
            event(10, 'step/start', {'turn': 1, 'step': 1}),
          ],
          cursor: 100,
          asOfSeq: 50,
          values: {'todos': null, 'goal': goalData(rounds: 5)},
        ),
      );
    check(transcript);
    transcript.apply(todo(11, 'before baseline'));
    check(transcript);
    expect(transcript.todos, isNull);
    transcript.apply(round(12, 9));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 5);
    transcript.apply(todo(51, 'after baseline'));
    check(transcript);
    expect(transcript.todos!.single.content, 'after baseline');
    transcript.apply(round(52, 8));
    check(transcript);
    expect(transcript.goal!.roundsStarted, 8);
  });

  test('history completion after warmed absence refolds both projections', () {
    final transcript = ChatTranscript()
      ..apply(
        snapshot([
          event(10, 'step/start', {'turn': 1, 'step': 1}),
        ]),
      );
    check(transcript);
    transcript.prependHistory(HistoryPage([todo(2, 'older'), event(3, 'goal/change', goalData())], false));
    check(transcript);
    expect(transcript.todos!.single.content, 'older');
    expect(transcript.goal!.goal.id, 'own-goal');
  });

  test('replacing relevant records by unrelated records invalidates warmed values', () {
    final transcript = ChatTranscript()
      ..apply(
        snapshot([
          todo(1, 'old'),
          event(2, 'goal/change', goalData()),
          event(3, 'step/start', {'turn': 1, 'step': 1}),
        ]),
      );
    check(transcript);
    transcript.apply(event(1, 'step/start', {'turn': 1, 'step': 1}));
    check(transcript);
    expect(transcript.todos, isNull);
    transcript.apply(event(2, 'step/end', {'turn': 1, 'step': 1}));
    check(transcript);
    expect(transcript.goal, isNull);
  });

  test('resync replaces projection seeds and a new snapshot clears history', () {
    final transcript = ChatTranscript()..apply(snapshot([todo(1, 'old'), event(2, 'goal/change', goalData())]));
    check(transcript);
    transcript.apply(
      snapshot([], cursor: 2, asOfSeq: 2, resync: true, values: {'todos': null, 'goal': goalData(revision: 2)}),
    );
    check(transcript);
    expect(transcript.todos, isNull);
    expect(transcript.goal!.goal.revision, 2);
    transcript.apply(snapshot([]));
    check(transcript);
    expect(transcript.todos, isNull);
    expect(transcript.goal, isNull);
  });
}
