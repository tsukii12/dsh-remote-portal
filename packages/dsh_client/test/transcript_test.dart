import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

List<DshEvent> follow(String fixture) => loadJsonl(fixture).map((v) => parseFollowFrame('s', v)).toList();

void main() {
  test('reply OK: user bubble then assistant answer, synthetic context hidden', () {
    final transcript = ChatTranscript();
    follow('follow_reply_ok.jsonl').forEach(transcript.apply);
    final items = transcript.items;
    expect(items, hasLength(2));
    final user = items[0] as UserChatItem;
    expect(user.text, 'Reply with exactly the word OK and nothing else.');
    expect(user.requestId, startsWith('req-'));
    final assistant = items[1] as AssistantChatItem;
    expect(assistant.text, 'OK');
    expect(assistant.streaming, isFalse);
    expect(assistant.usage!.outputTokens, 2);
    expect(transcript.running, isFalse);
    expect(transcript.title, 'Probe session');
    expect(transcript.cursor, 18);

    final verbose = ChatTranscript(showSyntheticUserMessages: true);
    follow('follow_reply_ok.jsonl').forEach(verbose.apply);
    expect(verbose.items.whereType<UserChatItem>(), hasLength(3));
  });

  test('live draft streams, then the durable message replaces it', () {
    final transcript = ChatTranscript();
    final events = follow('follow_reply_ok.jsonl');
    final durableIndex = events.indexWhere((e) => e is AssistantMessageEvent);
    events.take(durableIndex).forEach(transcript.apply);
    expect(transcript.running, isTrue);
    final draft = transcript.items.last as AssistantChatItem;
    expect(draft.id, startsWith('d'));
    expect(draft.text, 'OK');
    expect(draft.key, 'm1.1');
    events.skip(durableIndex).forEach(transcript.apply);
    expect(transcript.items.whereType<AssistantChatItem>().single.id, 'a16');
    expect(transcript.items.whereType<AssistantChatItem>().single.key, draft.key);
  });

  test('only the latest draft for a step owns its shared row key', () {
    final t = ChatTranscript();
    for (final id in ['first', 'second']) {
      t.apply(AssistantStreamStarted(id, 1, turn: 1, step: 1, startedAfterSeq: 0));
      t.apply(AssistantChunkEvent(id, 1, index: 0, time: DateTime(2026), chunk: TextDeltaChunk(0, id)));
    }
    expect(t.items.map((item) => item.key), ['dfirst', 'm1.1']);
    final durable = follow('follow_reply_ok.jsonl').whereType<AssistantMessageEvent>().single;
    t.apply(durable);
    // A later attempt for the same committed step must not collide with it.
    t.apply(const AssistantStreamStarted('later', 2, turn: 1, step: 1, startedAfterSeq: 16));
    t.apply(AssistantChunkEvent('later', 2, index: 0, time: DateTime(2026), chunk: const TextDeltaChunk(0, 'later')));
    expect(t.items.map((item) => item.key), ['m1.1', 'dlater']);
  });

  test('approval turn: resync keeps one transcript, tool card goes through approval', () {
    final transcript = ChatTranscript();
    final events = follow('follow_approval_with_resync.jsonl');
    final resyncIndex = events.lastIndexWhere((e) => e is SessionSnapshotEvent);
    events.take(resyncIndex).forEach(transcript.apply);
    expect(transcript.title, 'This is a test of');

    // The resync snapshot is a fresh generation: merge, rebuild the draft.
    final resync = events[resyncIndex] as SessionSnapshotEvent;
    transcript.apply(
      SessionSnapshotEvent(
        sessionId: resync.sessionId,
        header: resync.header,
        cursor: resync.cursor,
        events: resync.events,
        hasMore: resync.hasMore,
        projections: resync.projections,
        assistantRevision: resync.assistantRevision,
        activeAttempt: resync.activeAttempt,
        isResync: true,
      ),
    );
    expect(transcript.title, 'Testing approval UI with bash echo');
    final draft = transcript.items.last as AssistantChatItem;
    expect(draft.streaming, isTrue);
    expect(draft.reasoning, startsWith('The user'));

    // Apply up to the tool call, then the Host approval request.
    final callIndex = events.indexWhere((e) => e is ToolCallEvent);
    events.skip(resyncIndex + 1).take(callIndex - resyncIndex).forEach(transcript.apply);
    final call = events[callIndex] as ToolCallEvent;
    final request = ApprovalRequest(
      eventId: 'evt-1',
      sessionId: 's',
      toolName: 'bash',
      callId: call.callId,
      reason: 'escalate sandbox to danger-full-access: protocol capture test',
    );
    transcript.apply(ApprovalRequestedEvent(request));
    var tool = transcript.items.whereType<ToolChatItem>().single;
    expect(tool.status, ToolStatus.awaitingApproval);
    expect(tool.pendingApproval, same(request));
    expect(transcript.pendingApprovals.keys, ['evt-1']);

    transcript.apply(const HostRequestCancelledEvent('evt-1'));
    events.skip(callIndex + 1).forEach(transcript.apply);
    tool = transcript.items.whereType<ToolChatItem>().single;
    expect(tool.status, ToolStatus.succeeded);
    expect(tool.approvalOutcome, ApprovalOutcome.allowedOnce);
    expect(tool.resultText, 'hi\n');
    expect(tool.pendingApproval, isNull);
    final kinds = transcript.items.map((i) => i.runtimeType).toList();
    expect(kinds, [UserChatItem, AssistantChatItem, ToolChatItem, AssistantChatItem]);
    expect((transcript.items.last as AssistantChatItem).text, 'hi');
    expect(transcript.running, isFalse);
  });

  test('cancelled turn shows the interrupted prefix and a stop notice', () {
    final transcript = ChatTranscript();
    follow('follow_cancel.jsonl').forEach(transcript.apply);
    final assistant = transcript.items.whereType<AssistantChatItem>().single;
    expect(assistant.interrupted, isTrue);
    expect(assistant.text, startsWith('one two three'));
    final notice = transcript.items.last as NoticeChatItem;
    expect(notice.kind, 'aborted');
    expect(transcript.title, 'Count from 1 to 80 in words');
  });

  test('older history merges idempotently', () {
    final transcript = ChatTranscript();
    final events = follow('follow_reply_ok.jsonl');
    final snapshot = events.first as SessionSnapshotEvent;
    transcript.apply(snapshot.withEvents(snapshot.events.skip(3).toList()));
    expect(transcript.oldestSeq, 3);
    transcript.prependHistory(HistoryPage(snapshot.events.take(3).toList(), false));
    transcript.prependHistory(HistoryPage(snapshot.events.take(3).toList(), false));
    expect(transcript.oldestSeq, 0);
    expect(transcript.events.length, 5);
    expect(transcript.hasMoreHistory, isFalse);
  });

  group('inbox', () {
    Map<String, Object?> msg(String id, String text, String rpcId) => {
      'id': id,
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user', 'rpcId': rpcId},
    };

    SessionLogEvent splice(int seq, String target, int start, int removed, List<Map<String, Object?>> inserted) =>
        SessionLogEvent.fromJson({
          'seq': seq,
          'time': 1792700000000 + seq,
          'type': 'agent/inbox/spliced',
          'data': {'target': target, 'start': start, 'removedCount': removed, 'inserted': inserted},
        });

    ChatTranscript seeded(Map<String, Object?> inbox) {
      final base = follow('follow_reply_ok.jsonl').first as SessionSnapshotEvent;
      return ChatTranscript()..apply(
        SessionSnapshotEvent(
          sessionId: base.sessionId,
          header: base.header,
          cursor: 10,
          events: const [],
          hasMore: false,
          projections: SessionProjections(10, {'inbox': inbox}),
          assistantRevision: base.assistantRevision,
        ),
      );
    }

    test('seeded from the snapshot projection, steering first', () {
      final t = seeded({
        'next-turn': [msg('q1', '之后再做', 'r1')],
        'next-step': [msg('s1', '用 pnpm', 'r2')],
      });
      expect(
        [for (final q in t.inbox) (q.id, q.steering, q.requestId, q.text)],
        [('s1', true, 'r2', '用 pnpm'), ('q1', false, 'r1', '之后再做')],
      );
    });

    test('live splices queue, steer and claim; replayed ones are ignored', () {
      final t = seeded({'next-turn': <Object?>[], 'next-step': <Object?>[]});
      final queue = splice(11, 'next-turn', 0, 0, [msg('q1', 'a', 'r1')]);
      t.apply(queue);
      t.apply(splice(12, 'next-turn', 1, 0, [msg('q2', 'b', 'r2')]));
      expect(t.inbox.map((q) => q.id), ['q1', 'q2']);

      // updateQueue steer: removed from next-turn, appended to next-step.
      t.apply(splice(13, 'next-turn', 0, 1, []));
      t.apply(splice(14, 'next-step', 0, 0, [msg('q1', 'a', 'r1')]));
      expect([for (final q in t.inbox) (q.id, q.steering)], [('q1', true), ('q2', false)]);

      // A replay of an already-applied splice changes nothing.
      t.apply(queue);
      expect(t.inbox.map((q) => q.id), ['q1', 'q2']);

      // The turn claims the steering message.
      t.apply(splice(15, 'next-step', 0, 1, []));
      expect(t.inbox.map((q) => q.id), ['q2']);
    });
  });
}
