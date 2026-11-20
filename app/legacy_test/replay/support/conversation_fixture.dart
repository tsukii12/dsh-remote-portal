// A two-turn conversation as the chat holds it (items, traces, log), for the
// export, the replay and the share sheet tests.

import 'dart:convert';

import 'package:dsh_app/share_code/conversation_export.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';

final t0 = DateTime.utc(2026, 10, 24, 14, 0, 0);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

SessionLogEvent event(int seq, int ms, String type, Map<String, Object?> data) =>
    SessionLogEvent.fromJson({'seq': seq, 'time': at(ms).millisecondsSinceEpoch, 'type': type, 'data': data});

const secret = 'sk-abcdefghij0123456789klmnopqrstuv';

/// Long tool output: 6000 characters, a recognisable start and end.
final longOutput = 'FAIL test/login.test.ts\n${'x' * 6000}\nTests: 1 failed, 41 passed';

final fixtureItems = <ChatItem>[
  // Turn 1 (seq 1 … 9).
  UserChatItem(
    seq: 2,
    time: at(200),
    text: '帮我看看 /home/user/code/app 里的测试为什么挂了，密钥是 $secret',
    images: const [ImageAttachment(attachmentId: 'img-1', mediaType: 'image/png', width: 4, height: 4, name: '截图.png')],
    files: const [FileAttachment(name: 'log.txt', bytes: 2048)],
  ),
  AssistantChatItem(
    id: 'a3',
    seq: 3,
    time: at(5200),
    text: '我先跑一下测试。',
    reasoning: '用户说测试挂了，先跑 npm test 看看。',
    model: 'deepseek-v4-pro',
  ),
  ToolChatItem(
    callId: 'call-1',
    name: 'bash',
    arguments: jsonEncode({'command': 'cd /home/user/code/app && npm test', 'env': 'API_KEY=hunter2hunter2'}),
    status: ToolStatus.failed,
    seq: 4,
    resultParts: [TextPart(longOutput)],
  ),
  AssistantChatItem(
    id: 'a6',
    seq: 6,
    time: at(30000),
    text: '登录测试挂在重复提交上。看图：![截图](/root/workspace/shot.png)\n\n```dsh-ui\n{"view":"x"}\n```',
    reasoning: '',
    model: 'deepseek-v4-pro',
  ),
  // Turn 2 (seq 10 …).
  UserChatItem(seq: 11, time: at(90000), text: '好的，修一下', images: const [], files: const []),
  ToolChatItem(
    callId: 'call-2',
    name: 'edit',
    arguments: jsonEncode({'file_path': '/root/workspace/src/login.ts', 'old_string': 'a', 'new_string': 'b'}),
    status: ToolStatus.succeeded,
    seq: 12,
    resultParts: const [TextPart('ok')],
  ),
  ToolChatItem(
    callId: 'call-3',
    name: 'read',
    arguments: jsonEncode({'file_path': '/root/workspace/src/form.ts'}),
    status: ToolStatus.succeeded,
    seq: 13,
    resultParts: const [TextPart('export const form = 1;')],
  ),
  AssistantChatItem(
    id: 'a15',
    seq: 15,
    time: at(140000),
    text: '修好了，重复提交现在会被拦下。',
    reasoning: '改完了。',
    model: 'deepseek-v4-pro',
  ),
  const NoticeChatItem(seq: 16, kind: 'retry', text: '网络波动，已重试'),
];

TraceSpan model(int seq, int start, int first, int last) => TraceSpan(
  kind: TraceKind.model,
  step: 1,
  seq: seq,
  start: at(start),
  end: at(last),
  firstToken: at(first),
  lastToken: at(last),
  usage: const TokenUsage(inputTokens: 1000, outputTokens: 200),
);

TraceSpan tool(String callId, int seq, int start, int end) =>
    TraceSpan(kind: TraceKind.tool, step: 1, seq: seq, start: at(start), end: at(end), callId: callId);

final fixtureTurns = [
  TurnTrace(
    turn: 1,
    startSeq: 1,
    start: at(100),
    endSeq: 9,
    end: at(31000),
    endReason: const TurnEndReason('completed'),
    spans: [model(3, 300, 2200, 5200), tool('call-1', 4, 5300, 25300), model(6, 25400, 27000, 30000)],
  ),
  TurnTrace(
    turn: 2,
    startSeq: 10,
    start: at(89900),
    endSeq: 17,
    end: at(141000),
    endReason: const TurnEndReason('completed'),
    spans: [tool('call-2', 12, 95000, 95400), tool('call-3', 13, 95010, 95300), model(15, 96000, 99000, 140000)],
  ),
];

final fixtureEvents = [
  event(1, 100, 'turn/start', {'turn': 1}),
  event(5, 5250, 'todo/write', {
    'todos': [
      {'content': '跑测试', 'status': 'completed'},
      {'content': '修复 /home/user/code/app 的登录', 'status': 'in_progress'},
    ],
  }),
  event(9, 31000, 'turn/end', {'turn': 1}),
  event(10, 89900, 'turn/start', {'turn': 2}),
  event(14, 95500, 'goal/change', {
    'operation': 'set',
    'goal': {'id': 'g1', 'revision': 1, 'objective': '登录不再重复提交', 'phase': 'active', 'maxGoalRounds': 3},
  }),
  event(16, 140500, 'llm/retry', {}),
  event(17, 141000, 'turn/end', {'turn': 2}),
];

final fixtureCommands = [const CommandNotice(id: 'x1', name: 'compact', seq: 8, done: true, text: 'Compacted.')];

ConversationSource fixtureSource() => ConversationSource(
  title: '修复登录重复提交',
  items: fixtureItems,
  turns: fixtureTurns,
  commands: fixtureCommands,
  events: [...fixtureEvents, event(8, 30500, 'command/run', {})],
  model: 'deepseek-v4-pro',
);
