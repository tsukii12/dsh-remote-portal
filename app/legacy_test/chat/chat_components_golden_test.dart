// Component sheet: every chat row type, with tool details expanded, so the
// renderers (ANSI output, diff, read window, question card, notices) can be
// reviewed without driving the whole screen.

import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<void> _noRespond(ApprovalRequest r, ApprovalDecision d) async {}
Future<void> _noAnswer(UserQuestionRequest r, List<QuestionAnswer> a) async {}

final _bash = tool(
  'b1',
  'bash',
  {'command': 'flutter test test/auth --reporter expanded'},
  result:
      '00:01 \x1B[32m+3\x1B[0m: login submits once\n'
      '00:01 \x1B[32m+4\x1B[0m: login shows error on 401\n'
      '00:02 \x1B[31m-1\x1B[0m: \x1B[1mlogin retries after timeout\x1B[0m\n'
      '  Expected: <1>\n    Actual: <2>\n'
      '00:02 \x1B[32m+4\x1B[0m \x1B[31m-1\x1B[0m: Some tests failed.',
);

final _edit = conversationState().items.whereType<ToolChatItem>().firstWhere((t) => t.name == 'edit');

final _read = conversationState().items.whereType<ToolChatItem>().firstWhere((t) => t.name == 'read');

final _running = tool('r1', 'bash', {'command': 'npm install'}, status: ToolStatus.running);

final _failed = tool(
  'f1',
  'web_fetch',
  {'url': 'https://pub.dev/packages/gpt_markdown'},
  status: ToolStatus.failed,
  result: 'Request failed: 503 Service Unavailable',
);

final _denied = tool('d1', 'write', {
  'file_path': '/root/workspace/.env',
  'content': 'TOKEN=…',
}, status: ToolStatus.denied);

const _question = UserQuestionRequest(
  eventId: 'q1',
  sessionId: 's',
  questions: [
    UserQuestion(
      id: 'q-db',
      question: '数据库用哪一个?',
      header: '存储',
      options: [QuestionOption('SQLite', '单文件,零配置'), QuestionOption('PostgreSQL', '需要单独的服务')],
    ),
  ],
);

Widget _sheet() {
  return Builder(
    builder: (context) => AppBackdrop(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UserBubble(
              text: '帮我跑一下测试',
              attachments: SentAttachments.pending([DraftAttachment(name: 'crash.log', bytes: Uint8List(2048))]),
            ),
            const SizedBox(height: 8),
            const UserBubble(text: '再看看依赖有没有过期', pendingLabel: '排队中 · 本轮结束后发送'),
            const SizedBox(height: 16),
            const ThinkingPill(reasoning: '先跑一遍测试,看看失败的是哪一个用例。\n然后对照最近的改动定位原因', active: true),
            const SizedBox(height: 8),
            const ThinkingPill(reasoning: '**定位失败用例**\n超时重试会多发一次请求,看 retry 的计数'),
            const SizedBox(height: 8),
            ToolRow(key: const ValueKey('bash'), item: _bash, onRespond: _noRespond),
            ToolRow(key: const ValueKey('edit'), item: _edit, onRespond: _noRespond),
            ToolRow(key: const ValueKey('read'), item: _read, onRespond: _noRespond),
            ToolRow(item: _running, onRespond: _noRespond),
            ToolRow(item: _failed, onRespond: _noRespond),
            ToolRow(item: _denied, onRespond: _noRespond),
            const SizedBox(height: 8),
            AssistantMessage(item: assistant(9, '有一个用例失败:**超时重试**会多发一次请求。', interrupted: true)),
            const SizedBox(height: 12),
            const NoticeRow(
              item: NoticeChatItem(
                seq: 10,
                kind: 'error',
                text: 'The turn failed',
                failure: LlmFailure(message: '429 rate limited', code: 'RATE_LIMIT'),
              ),
            ),
            const SizedBox(height: 8),
            const NoticeRow(
              item: NoticeChatItem(seq: 11, kind: 'retry', text: 'Retrying model request (2/5)'),
            ),
            const SizedBox(height: 12),
            const QuestionCard(request: _question, onAnswer: _noAnswer),
            const SizedBox(height: 12),
            ErrorBanner(message: '发送失败：连接已断开', onDismiss: () {}),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('chat components ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 4200);
      mockClipboard(tester);
      await tester.pumpWidget(testApp(Scaffold(body: _sheet()), brightness: brightness));
      for (final key in ['bash', 'edit', 'read']) {
        await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(InkWell)).first);
        await pumpFrames(tester, 2);
      }
      await pumpFrames(tester, 4);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/components_$suffix.png'));
    });
  }
}
