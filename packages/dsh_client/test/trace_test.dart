import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

List<DshEvent> follow(String fixture) => loadJsonl(fixture).map((v) => parseFollowFrame('s', v)).toList();

/// Durable events of a fixture in seq order (snapshots included, resyncs merged).
List<SessionLogEvent> durable(String fixture) {
  final bySeq = <int, SessionLogEvent>{};
  for (final event in follow(fixture)) {
    switch (event) {
      case SessionSnapshotEvent(:final events):
        for (final e in events) {
          bySeq[e.seq] = e;
        }
      case SessionLogEvent():
        bySeq[event.seq] = event;
      default:
        break;
    }
  }
  return (bySeq.keys.toList()..sort()).map((seq) => bySeq[seq]!).toList();
}

int ms(Duration? d) => d!.inMilliseconds;

void main() {
  group('approval turn (captured)', () {
    late List<SessionLogEvent> events;
    late DateTime t0;
    setUp(() {
      events = durable('follow_approval_with_resync.jsonl');
      t0 = events.firstWhere((e) => e is TurnStartedEvent).time;
    });

    int at(DateTime t) => t.difference(t0).inMilliseconds;

    test('model → approval → tool → model, timed from durable events', () {
      final traces = traceTurns(events);
      expect(traces, hasLength(1));
      final trace = traces.single;
      expect(trace.turn, 1);
      expect(trace.running, isFalse);
      expect(trace.endReason!.isCompleted, isTrue);
      expect(ms(trace.duration), 2081);
      expect(trace.steps, 2);

      expect(trace.spans.map((s) => s.kind), [TraceKind.model, TraceKind.approval, TraceKind.tool, TraceKind.model]);
      final [first, approval, tool, reply] = trace.spans;

      // Step 1 starts at step/start (61 ms after turn/start), ends at its message.
      expect(at(first.start), 61);
      expect(ms(first.duration), 1538);
      expect(first.toolCalls, 1);
      expect(first.hasText, isFalse);
      expect(first.hasReasoning, isTrue);
      expect(first.model, 'deepseek-flash');
      expect(first.ttft, isNotNull);
      expect(first.ttft! < first.duration!, isTrue);
      expect(first.decoding, isNotNull);

      // The wait for the answer is its own span; the command runs after it.
      expect(approval.waiting, isTrue);
      expect(approval.toolName, 'bash');
      expect(approval.outcome, ApprovalOutcome.allowedOnce);
      expect(ms(approval.duration), 4);
      expect(tool.toolName, 'bash');
      expect(tool.start, approval.end);
      expect(tool.dispatched!.isBefore(tool.start), isTrue);
      expect(ms(tool.duration), 86);
      expect(tool.failed, isFalse);
      expect(tool.outcome, ApprovalOutcome.allowedOnce);
      expect(tool.arguments, contains('echo hi'));

      expect(reply.hasText, isTrue);
      expect(reply.toolCalls, 0);
      expect(ms(reply.duration), 374);

      expect(trace.usage.uncachedInput, 3775 + 158);
      expect(trace.usage.cacheRead, 6400 + 10240);
      expect(trace.usage.output, 211);
      expect(trace.usage.requests, 2);
      expect(trace.usage.cacheHitRate, closeTo(16640 / (3933 + 16640), 1e-9));
      expect(trace.ttft, first.ttft);
      expect(ms(trace.waitTime), 4);
      expect(ms(trace.toolTime), 86);
      expect(ms(trace.modelTime), 1538 + 374);
    });

    test('while it runs, the open span is what the turn waits on', () {
      List<TurnTrace> upTo(int seq) => traceTurns(events.where((e) => e.seq <= seq));

      // step/start of step 1, no message yet: the model is being asked.
      var trace = upTo(12).single;
      expect(trace.running, isTrue);
      expect(trace.current!.kind, TraceKind.model);
      expect(trace.current!.open, isTrue);
      expect(at(trace.current!.start), 61);

      // Approval asked, not answered.
      trace = upTo(20).single;
      expect(trace.current!.kind, TraceKind.approval);
      expect(trace.current!.toolName, 'bash');
      expect(trace.spans.where((s) => s.kind == TraceKind.tool), isEmpty, reason: 'the command has not started');

      // Answered: the command runs from the answer on.
      trace = upTo(21).single;
      expect(trace.current!.kind, TraceKind.tool);
      expect(trace.current!.start, trace.spans.firstWhere((s) => s.kind == TraceKind.approval).end);

      // Between the result and the next step/start: still asking the model.
      trace = upTo(23).single;
      expect(trace.current!.kind, TraceKind.model);
    });

    test('a finished turn is reused as the same instance', () {
      final first = traceTurns(events);
      final again = traceTurns(events, reuse: first);
      expect(identical(first.single, again.single), isTrue);
      final running = traceTurns(events.where((e) => e.seq <= 21));
      expect(identical(traceTurns(events, reuse: running).single, running.single), isFalse);
    });
  });

  test('cancelled turn: aborted reason, interrupted reply, no usage', () {
    final trace = traceTurns(durable('follow_cancel.jsonl')).single;
    expect(trace.endReason!.isAborted, isTrue);
    expect(trace.spans, hasLength(1));
    final reply = trace.spans.single;
    expect(reply.kind, TraceKind.model);
    expect(reply.hasText, isTrue);
    expect(trace.usage.isEmpty, isTrue);
    expect(trace.usage.cacheHitRate, isNull);
  });

  test('reply OK: one request with a recorded time to first token', () {
    final trace = traceTurns(durable('follow_reply_ok.jsonl')).single;
    expect(trace.steps, 1);
    final reply = trace.spans.single;
    expect(ms(reply.duration), 39326 - 38012);
    expect(reply.ttft, isNotNull);
    expect(reply.ttft!.inMilliseconds, greaterThan(0));
    expect(trace.usage.total, 10129 + 2);
  });

  test('a turn whose start is not loaded is skipped', () {
    final events = durable('follow_approval_with_resync.jsonl');
    final partial = events.where((e) => e.seq > 4);
    expect(traceTurns(partial), isEmpty);
  });

  test('a turn left open by a new turn ends at its last event', () {
    final t = DateTime.fromMillisecondsSinceEpoch(1000);
    final events = <SessionLogEvent>[
      TurnStartedEvent(1, t, const {}, turn: 1),
      ToolCallEvent(
        2,
        t.add(const Duration(seconds: 1)),
        const {},
        turn: 1,
        step: 1,
        callId: 'c1',
        name: 'bash',
        arguments: '{}',
      ),
      TurnStartedEvent(3, t.add(const Duration(seconds: 9)), const {}, turn: 2),
    ];
    final traces = traceTurns(events);
    expect(traces, hasLength(2));
    expect(traces.first.running, isFalse);
    expect(traces.first.end, t.add(const Duration(seconds: 1)));
    expect(traces.first.endReason!.kind, 'interrupted');
    expect(traces.first.spans.single.cutShort, isTrue);
    expect(traces.last.running, isTrue);
  });

  test('transcript exposes traces and the latest todo list', () {
    final transcript = ChatTranscript();
    follow('follow_approval_with_resync.jsonl').forEach(transcript.apply);
    final turns = transcript.turns;
    expect(turns.single.steps, 2);
    expect(identical(transcript.turns, turns), isTrue, reason: 'cached until the log changes');
    expect(transcript.todos, isNull);

    transcript.apply(
      TodoWriteEvent(
        transcript.cursor + 1,
        DateTime.now(),
        const {},
        todos: const [TodoItem('读代码', 'completed'), TodoItem('改代码', 'in_progress')],
      ),
    );
    expect(transcript.todos!.map((t) => t.status), ['completed', 'in_progress']);
    expect(identical(transcript.turns.single, turns.single), isTrue, reason: 'finished turns are reused');
  });
}
