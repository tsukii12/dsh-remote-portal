import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

const _request = UserQuestionRequest(
  eventId: 'question-event',
  sessionId: 's1',
  waitCallId: 'question-call',
  questions: [UserQuestion(id: 'submit', question: '现在提交吗？', header: '提交确认')],
);

const _arguments = {
  'questions': [
    {'id': 'submit', 'question': '现在提交吗？', 'header': '提交确认'},
  ],
};

Map<String, Object?> _answer(String text) => {
  'answers': [
    {'id': 'submit', 'selected': <String>[], 'custom': text},
  ],
};

ToolChatItem _tool({Object? result, ToolStatus status = ToolStatus.succeeded, String name = 'ask_user_question'}) =>
    tool('question-call', name, _arguments, status: status, result: jsonEncode(result ?? _answer('先运行测试')));

ChatTranscript _history() {
  final transcript = ChatTranscript();
  var seq = 0;
  void event(String type, Map<String, Object?> data) =>
      transcript.apply(SessionLogEvent.fromJson({'seq': seq++, 'time': 1730000000000, 'type': type, 'data': data}));
  event('turn/start', {'turn': 1});
  event('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'question-call',
    'name': 'ask_user_question',
    'arguments': jsonEncode(_arguments),
  });
  event('tool/result', {
    'turn': 1,
    'step': 1,
    'message': {
      'role': 'tool',
      'toolCallId': 'question-call',
      'content': [
        {'type': 'text', 'text': jsonEncode(_answer('先运行测试'))},
      ],
    },
  });
  event('turn/end', {
    'turn': 1,
    'reason': {'kind': 'completed'},
  });
  return transcript;
}

ChatState _restored() {
  final transcript = _history();
  return ChatState(loading: false, items: transcript.items, turns: transcript.turns);
}

void main() {
  setUpAll(loadTestFonts);

  test('a saved question answer stays outside the completed turn fold', () {
    final transcript = _history();
    expect(transcript.items.whereType<UserChatItem>(), isEmpty, reason: 'the foreground answer is only a tool result');
    final rows = deriveRows(items: transcript.items, turns: transcript.turns, foldTurns: true);
    final visible = rows.whereType<ToolCallRow>().toList();
    expect(visible, hasLength(1));
    expect(visible.single.card, ToolCardPlacement.cardOnly);
    expect(visible.single.key, 'tquestion-call');
    expect(
      rows.whereType<TurnProcessRow>().single.rows.whereType<ToolCallRow>().single.card,
      ToolCardPlacement.rowOnly,
    );
  });

  test('an answered question stays visible between ordinary tool groups', () {
    final rows = deriveRows(
      items: [
        for (var i = 0; i < 3; i++) tool('before$i', 'read', {'path': '$i'}),
        _tool(),
        for (var i = 0; i < 3; i++) tool('after$i', 'read', {'path': '$i'}),
      ],
      running: true,
    );
    expect(rows.map((row) => row.runtimeType), [ToolGroupRow, ToolCallRow, ToolGroupRow]);
    expect(rows.whereType<ToolCallRow>().single.key, 'tquestion-call');
  });

  for (final status in [ToolStatus.running, ToolStatus.failed, ToolStatus.cancelled]) {
    test('a $status question does not claim an answer was saved', () {
      expect(hasToolCard(_tool(status: status)), isFalse);
    });
  }

  for (final (name, result) in <(String, Object)>[
    ('empty', {'answers': []}),
    ('continued', {'status': 'continued'}),
    (
      'unknown question',
      {
        'answers': [
          {'id': 'another-question', 'selected': [], 'custom': 'wrong target'},
        ],
      },
    ),
    (
      'duplicate answer',
      {
        'answers': [
          {'id': 'submit', 'selected': [], 'custom': 'one'},
          {'id': 'submit', 'selected': [], 'custom': 'two'},
        ],
      },
    ),
    (
      'non-text choice',
      {
        'answers': [
          {
            'id': 'submit',
            'selected': [42],
          },
        ],
      },
    ),
    (
      'non-text custom',
      {
        'answers': [
          {
            'id': 'submit',
            'selected': [],
            'custom': {'text': 'nested'},
          },
        ],
      },
    ),
    (
      'blank answer',
      {
        'answers': [
          {'id': 'submit', 'selected': [], 'custom': '  '},
        ],
      },
    ),
    ('non-object result', ['not an answer']),
  ]) {
    test('$name results keep the existing raw tool presentation', () {
      expect(hasToolCard(_tool(result: result)), isFalse);
    });
  }

  test('a different tool with answer-shaped output has no question receipt', () {
    expect(hasToolCard(_tool(name: 'read')), isFalse);
  });

  testWidgets('selected options and custom text are readable without opening raw detail', (tester) async {
    final item = tool(
      'multiple',
      'ask_user_question',
      {
        'questions': [
          {'id': 'db', 'question': '数据库'},
          {'id': 'delivery', 'question': '交付要求'},
        ],
      },
      result: jsonEncode({
        'answers': [
          {
            'id': 'db',
            'selected': ['SQLite', 'PostgreSQL'],
            'custom': '保留旧数据',
          },
          {'id': 'delivery', 'selected': [], 'custom': '先运行测试'},
        ],
      }),
    );
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ToolRow(item: item, onRespond: (_, _) async {}),
        ),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('已回答'), findsOneWidget);
    expect(find.text('SQLite\nPostgreSQL\n保留旧数据'), findsOneWidget);
    expect(find.text('交付要求'), findsOneWidget);
    expect(find.text('先运行测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a typed answer is receipted only after the saved result and survives remount', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': const ChatState(loading: false, running: true, questions: [_request]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    await tester.enterText(field, '先运行测试');
    await pumpFrames(tester, 2);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    final controller = harness.controllers['s1']!;
    expect(controller.answers.single.$1.eventId, _request.eventId);
    expect(controller.answers.single.$2.single.custom, '先运行测试');
    expect(controller.sent, isEmpty);
    expect(find.text('已回答'), findsNothing, reason: 'an RPC acknowledgement alone is not a saved answer');
    controller.emit(_restored());
    await pumpFrames(tester);
    expect(find.text('已回答'), findsOneWidget);
    expect(find.text('先运行测试'), findsOneWidget);
    expect(find.text('发送文字将回答待答问题'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester);
    final replay = ChatHarness(session: 's1', states: {'s1': _restored()});
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: replay.overrides));
    await pumpFrames(tester);
    expect(find.text('已回答'), findsOneWidget);
    expect(find.text('提交确认'), findsOneWidget);
    expect(find.text('先运行测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('answer receipts keep the existing credential masking', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      // Synthetic fixture, not a credential.
      final value = 'sk-${'a1' * 16}';
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ToolRow(
              item: _tool(result: _answer(value)),
              onRespond: (_, _) async {},
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('已回答'), findsOneWidget);
      expect(find.text(value), findsNothing);
      expect(find.bySemanticsLabel(value.substring(0, 8) + '*' * (value.length - 8)), findsOneWidget);
      expect(find.bySemanticsLabel(value), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
