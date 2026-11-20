// What the transcript hands out stays the same object while nothing about it
// changed: the chat list keeps those rows (values are covered by the
// full-build oracle in transcript_incremental_test.dart).

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  var seq = 0;
  late ChatTranscript t;

  void log(String type, Map<String, Object?> data) => t.apply(
    parseFollowFrame('s', {
      'type': 'event',
      'event': {'seq': ++seq, 'time': 1000 + seq, 'type': type, 'data': data},
    }),
  );
  void call(String id) => log('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': id,
    'name': 'bash',
    'arguments': jsonEncode({'command': id}),
  });
  void result(String id) => log('tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'role': 'tool',
      'toolCallId': id,
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    },
  });
  ToolChatItem tool(String id) => t.items.whereType<ToolChatItem>().firstWhere((item) => item.callId == id);
  void start(String id, {int step = 1, int after = 0}) =>
      t.apply(AssistantStreamStarted(id, 1, turn: 1, step: step, startedAfterSeq: after));
  void chunk(String id, int index, StreamChunk chunk) =>
      t.apply(AssistantChunkEvent(id, 1, index: index, time: DateTime(2026), chunk: chunk));

  setUp(() {
    seq = 0;
    t = ChatTranscript();
    t.apply(SessionSnapshotEvent.fromJson('s', {'cursor': 0, 'records': const <Object?>[]}));
    log('turn/start', {'turn': 1});
    log('user/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'go'},
      ],
      'source': {'kind': 'user'},
    });
  });

  test('calls nothing happened to keep their item; the one that changed gets a new one', () {
    call('a');
    call('b');
    final a = tool('a');
    final b = tool('b');
    call('c');
    expect(tool('a'), same(a));
    expect(tool('b'), same(b));
    result('b');
    expect(tool('a'), same(a));
    expect(tool('b'), isNot(same(b)));
    expect(tool('b').status, ToolStatus.succeeded);
    final done = tool('b');
    log('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
    // The turn ended before a and c had a result: they change, b does not.
    expect(tool('a').status, ToolStatus.cancelled);
    expect(tool('b'), same(done));
  });

  test('an approval waiting on a call changes that call only', () {
    call('a');
    call('b');
    final a = tool('a');
    t.apply(ApprovalRequestedEvent(const ApprovalRequest(eventId: 'e', sessionId: 's', toolName: 'bash', callId: 'b')));
    expect(tool('a'), same(a));
    expect(tool('b').status, ToolStatus.awaitingApproval);
    final waiting = tool('b');
    t.apply(const HostRequestCancelledEvent('e'));
    expect(tool('a'), same(a));
    expect(tool('b'), isNot(same(waiting)));
  });

  test('events that show nothing keep the items list itself', () {
    call('a');
    final items = t.items;
    log('permission/preset', {'preset': 'auto'});
    log('session/title', {'title': 'A title'});
    log('turn/start', {'turn': 2});
    log('some/unknown', {'x': 1});
    expect(t.items, same(items));
    expect(t.title, 'A title');
    call('b');
    expect(t.items, isNot(same(items)));
    expect(t.items.whereType<ToolChatItem>().first, same(items.whereType<ToolChatItem>().first));
  });

  test('unchanged live text and tools keep their list across reads and metadata', () {
    start('live');
    chunk('live', 0, const TextDeltaChunk(0, 'Answer'));
    chunk('live', 1, const ReasoningDeltaChunk(1, 'Thinking'));
    chunk('live', 2, const ToolCallDeltaChunk(2, id: 'live-call', name: 'bash', argumentsDelta: '{'));
    final items = t.items;
    expect(t.items, same(items));
    t.apply(const SessionStatusEvent('s', true));
    t.apply(const ConnectionStateEvent(DshConnectionState.connected));
    log('session/title', {'title': 'New title'});
    log('permission/preset', {'preset': 'auto'});
    log('agent/inbox/spliced', {
      'target': 'next-turn',
      'start': 0,
      'removedCount': 0,
      'inserted': [
        {
          'id': 'queued',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Next'},
          ],
        },
      ],
    });
    t.apply(const UserQuestionRequestedEvent(UserQuestionRequest(eventId: 'q', sessionId: 's', questions: [])));
    expect(t.items, same(items));
    expect(t.title, 'New title');
    expect(t.running, isTrue);
    expect(t.connectionState, DshConnectionState.connected);
    expect(t.inbox.single.text, 'Next');
    expect(t.pendingQuestions.keys, ['q']);
    expect((items[1] as AssistantChatItem).text, 'Answer');
    expect((items[1] as AssistantChatItem).reasoning, 'Thinking');
    expect((items.last as ToolChatItem).arguments, '{');
  });

  test('draft changes replace the list without changing already published values', () {
    start('live');
    chunk('live', 0, const TextDeltaChunk(0, 'First'));
    final first = t.items;
    chunk('live', 1, const TextDeltaChunk(0, ' second'));
    final second = t.items;
    expect(second, isNot(same(first)));
    expect((first.last as AssistantChatItem).text, 'First');
    expect((second.last as AssistantChatItem).text, 'First second');
    // A replayed chunk is ignored and cannot disturb the current projection.
    chunk('live', 0, const TextDeltaChunk(0, 'duplicate'));
    expect(t.items, same(second));
    t.apply(const AssistantStreamEnded('live', 2, index: 2, committed: true, committedSeq: 99));
    final ended = t.items;
    expect((ended.last as AssistantChatItem).streaming, isFalse);
    expect((second.last as AssistantChatItem).streaming, isTrue);
    t.apply(const AssistantStreamEnded('live', 3, index: 2, committed: false));
    expect(t.items.whereType<AssistantChatItem>(), isEmpty);
  });

  test('an attempt-only commit retires one draft while another still streams', () {
    start('old');
    chunk('old', 0, const TextDeltaChunk(0, 'Old'));
    final old = t.items;
    start('other', step: 2);
    chunk('other', 0, const TextDeltaChunk(0, 'Other'));
    expect(t.items.whereType<AssistantChatItem>().map((item) => item.text), ['Old', 'Other']);
    expect(old.whereType<AssistantChatItem>().map((item) => item.text), ['Old']);
    log('assistant/attempt', {'turn': 1, 'step': 1});
    expect(t.items.whereType<AssistantChatItem>().map((item) => item.text), ['Other']);
    // A fresh attempt for the same step after that commit is not retired by it.
    start('later', after: seq);
    chunk('later', 0, const TextDeltaChunk(0, 'Later'));
    expect(t.items.whereType<AssistantChatItem>().map((item) => item.text), ['Other', 'Later']);
  });

  test('durable calls and approval changes still reach a cached live projection', () {
    call('a');
    start('live');
    chunk('live', 0, const TextDeltaChunk(0, 'Answer'));
    final first = t.items;
    call('b');
    expect(t.items, isNot(same(first)));
    expect(t.items.whereType<ToolChatItem>().map((item) => item.callId), ['a', 'b']);
    final beforeApproval = t.items;
    t.apply(ApprovalRequestedEvent(const ApprovalRequest(eventId: 'e', sessionId: 's', toolName: 'bash', callId: 'b')));
    expect(tool('b').status, ToolStatus.awaitingApproval);
    expect((beforeApproval[2] as ToolChatItem).status, ToolStatus.running);
    t.apply(const HostRequestCancelledEvent('e'));
    expect(tool('b').status, ToolStatus.running);
    result('b');
    expect(tool('b').resultText, 'ok');
    expect(t.items.whereType<AssistantChatItem>().single.text, 'Answer');
  });
}
