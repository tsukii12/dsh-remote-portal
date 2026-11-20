import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

void main() {
  test('only the trailing tool group is live, including before queued prompts', () {
    final tools = [
      for (var i = 0; i < 3; i++) tool('live$i', 'bash', {'command': '$i'}),
    ];
    expect(deriveRows(items: tools, running: true).whereType<ToolGroupRow>().single.live, isTrue);
    expect(
      deriveRows(
        items: [
          ...tools,
          assistant(5, '', reasoning: 'thinking'),
        ],
        running: true,
      ).whereType<ToolGroupRow>().single.live,
      isFalse,
    );
    expect(
      deriveRows(
        items: tools,
        running: true,
        pending: [PendingPrompt(requestId: 'q', text: 'next', time: DateTime(2026), mode: SendMode.queue)],
      ).whereType<ToolGroupRow>().single.live,
      isTrue,
    );
  });
  test('orphan approval and question precede the queued prompt', () {
    final rows = deriveRows(
      items: [user(1, 'q'), assistant(2, 'answer', streaming: true)],
      running: true,
      approvals: [approval],
      questions: const [UserQuestionRequest(eventId: 'q', sessionId: 's1', questions: [])],
      pending: [PendingPrompt(requestId: 'p', text: 'next', time: DateTime(2026), mode: SendMode.queue)],
    );
    expect(rows.skip(rows.length - 3).map((row) => row.runtimeType), [ApprovalRow, QuestionRow, PendingRow]);
  });

  test('three or more consecutive tool calls collapse into a group', () {
    final rows = deriveRows(
      items: [
        user(1, 'hi'),
        tool('a', 'read', {'file_path': 'a'}),
        tool('b', 'read', {'file_path': 'b'}),
        assistant(2, 'text'),
        tool('c', 'grep', {'pattern': 'x'}),
        tool('d', 'glob', {'pattern': '*'}),
        tool('e', 'bash', {'command': 'ls'}),
      ],
    );
    expect(rows.map((r) => r.runtimeType).toList(), [UserRow, ToolCallRow, ToolCallRow, AssistantRow, ToolGroupRow]);
    expect((rows.last as ToolGroupRow).tools.map((t) => t.callId), ['c', 'd', 'e']);
  });

  test('copy action goes on the last text of each finished turn', () {
    final rows = deriveRows(
      items: [
        user(1, 'q1'),
        assistant(2, 'step one'),
        tool('a', 'bash', {'command': 'ls'}),
        assistant(3, 'answer one'),
        user(4, 'q2'),
        assistant(5, 'answer two'),
      ],
      running: true,
    );
    final assistants = rows.whereType<AssistantRow>().toList();
    expect(assistants.map((r) => r.showActions), [false, true, false]);
  });

  test('aborted notice after an interrupted reply is folded away', () {
    final rows = deriveRows(
      items: [
        user(1, 'q'),
        assistant(2, 'partial', interrupted: true),
        const NoticeChatItem(seq: 3, kind: 'aborted', text: 'Stopped'),
      ],
    );
    expect(rows.whereType<NoticeRowData>(), isEmpty);
  });

  test('approvals attached to a tool row are not repeated at the end', () {
    final orphan = ApprovalRequest(eventId: 'orphan', sessionId: 's', toolName: 'web_fetch');
    final rows = deriveRows(
      items: [
        user(1, 'q'),
        tool('call-test', 'bash', {'command': 'ls'}, status: ToolStatus.awaitingApproval, pending: approval),
      ],
      approvals: [approval, orphan],
      running: true,
    );
    final approvals = rows.whereType<ApprovalRow>().toList();
    expect(approvals.single.request.eventId, 'orphan');
  });

  test('no typing row: the strip above the composer shows the wait', () {
    // Waiting for the first token, or between steps: the list stays as it
    // is (a row coming and going there made the whole list jump).
    final waiting = deriveRows(items: [user(1, 'q')], running: true);
    expect(waiting.map((r) => r.runtimeType), [UserRow]);

    final betweenSteps = deriveRows(
      items: [
        user(1, 'q'),
        tool('a', 'bash', {'command': 'ls'}),
      ],
      running: true,
    );
    expect(betweenSteps.map((r) => r.runtimeType), [UserRow, ToolCallRow]);
  });

  test('an echoed prompt keeps its optimistic row key', () {
    final echoed = UserChatItem(
      seq: 3,
      time: DateTime(2026),
      text: 'next',
      images: const [],
      files: const [],
      requestId: 'r1',
    );
    final prompt = PendingPrompt(requestId: 'r1', text: 'next', time: DateTime(2026));
    final before = deriveRows(items: const [], pending: [prompt]);
    final after = deriveRows(items: [echoed]);
    expect(after.single.key, before.single.key);
    // Without a request id (another client), the seq key.
    expect(deriveRows(items: [user(4, 'x')]).single.key, 'u4');
  });

  test('optimistic prompts follow the transcript', () {
    final prompt = PendingPrompt(requestId: 'r1', text: 'next', time: DateTime(2026), mode: SendMode.queue);
    final queued = deriveRows(
      items: [user(1, 'q'), assistant(2, 'An', streaming: true)],
      pending: [prompt],
      running: true,
    );
    expect(queued.last, isA<PendingRow>());

    final sending = deriveRows(items: const [], pending: [prompt]);
    expect(sending.map((r) => r.runtimeType), [PendingRow]);
  });
}
