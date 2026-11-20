import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/chat/widgets/schedule_question_body.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

// Captured by calling the patched ScheduleService.dshGoAuthorize with synthetic
// data, rejecting its question. No task or user data was saved. Only the random
// question id was replaced with a stable test id.
Map<String, dynamic> _payload() =>
    jsonDecode(File('test/chat/fixtures/schedule_authorization_request.json').readAsStringSync())
        as Map<String, dynamic>;

UserQuestionRequest _request() => UserQuestionRequest.fromWaterfall('schedule-question', 's1', _payload());

Future<ChatHarness> _chat(
  WidgetTester tester,
  UserQuestionRequest request, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  usePhoneView(tester);
  tester.view.physicalSize = size * 2;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(loading: false, running: true, questions: [request]),
    },
  );
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 12);
  return harness;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('schedule task renders complete instructions and every metadata field as readable text', (tester) async {
    final request = _request();
    await _chat(tester, request);
    final prompt = [for (var i = 1; i <= 45; i++) '$i. 检查合成项目，保留完整结果与换行。', '最后一行：只报告测试结果。'].join('\n');
    expect(find.text(prompt), findsOneWidget, reason: 'real line feeds, not JSON escape text');
    expect(tester.widget<Text>(find.text(prompt)).maxLines, isNull);
    for (final text in [
      'update',
      '合成每日检查',
      'synthetic-task',
      'daily',
      '23:00:00.000',
      'Asia/Shanghai',
      '2099-12-30T15:00:00.000Z',
      'active',
      'deliveryHistory',
      'earlierRecordsUnavailable',
      'earlierRecordsPruned',
      'extraContext',
      '2',
      '{}',
      'null',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('s1'), findsNWidgets(3), reason: 'actor, target and involved session remain visible');
    expect(find.text('false'), findsNWidgets(2));
    expect(find.text('[]'), findsOneWidget);
    expect(find.text(r'visible\u202ekey'), findsOneWidget);
    expect(find.text(r'visible\u2066value'), findsOneWidget);
    final displayed = tester
        .widgetList<Text>(find.descendant(of: find.byType(QuestionCard), matching: find.byType(Text)))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(displayed, isNot(contains('\u202e')));
    expect(displayed, isNot(contains('\u2066')));
    expect(request.questions.single.question, contains(r'\u202e'));
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale) in [(const Size(390, 844), 1.0), (const Size(320, 640), 1.3)]) {
    testWidgets('scrolling the full schedule body keeps choices stationary at $size/$scale', (tester) async {
      final request = _request();
      final harness = await _chat(tester, request, size: size, scale: scale);
      final submit = find.widgetWithText(FilledButton, '提交');
      // ChatList follows pending questions to their actions. Check that real
      // position; ensureVisible assumes a viewport without ChatList's anchor.
      expect(submit.hitTestable(), findsOneWidget);
      expect(find.text('授权 / Authorize').hitTestable(), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      final choiceRect = tester.getRect(find.text('授权 / Authorize'));
      final submitRect = tester.getRect(submit);
      final scroll = find.descendant(of: find.byType(ScheduleQuestionBody), matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scroll).position;
      expect(position.maxScrollExtent, greaterThan(500));
      final before = position.pixels;
      await tester.drag(find.byType(ScheduleQuestionBody), const Offset(0, -180));
      await pumpFrames(tester);
      expect(position.pixels, greaterThan(before + 100));
      expect(tester.getRect(find.text('授权 / Authorize')), choiceRect);
      expect(tester.getRect(submit), submitRect);
      // Use actual inner drags: Flutter's scrollUntilVisible ends by revealing
      // every ancestor, which would also move the anchored outer ChatList.
      for (var i = 0; i < 40 && find.text('null').hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ScheduleQuestionBody), const Offset(0, -220));
        await pumpFrames(tester, 2);
      }
      expect(find.text('null').hitTestable(), findsOneWidget, reason: 'the last optional field is reachable');
      expect(tester.getRect(find.text('授权 / Authorize')), choiceRect);
      expect(tester.getRect(submit), submitRect);
      expect(harness.controllers['s1']!.answers, isEmpty);
      await tester.tap(find.text('授权 / Authorize'));
      await tester.pump();
      expect(harness.controllers['s1']!.answers, isEmpty, reason: 'selecting is not submitting');
      await tester.tap(submit);
      await pumpFrames(tester);
      final answer = harness.controllers['s1']!.answers.single;
      expect(identical(answer.$1, request), isTrue);
      expect(answer.$2.single.id, request.questions.single.id);
      expect(answer.$2.single.selected, ['授权 / Authorize']);
      expect(answer.$2.single.custom, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a short schedule keeps real newlines distinct from literal backslashes', (tester) async {
    const prompt = '第一行\n第二行中的字面量 \\n 保持原样。';
    final payload = _payload();
    final question = (payload['questions'] as List).single as Map<String, dynamic>;
    final original = question['question'] as String;
    final split = original.indexOf('\n\n');
    final details = jsonDecode(original.substring(split + 2));
    details['task']['record']['prompt'] = prompt;
    question['question'] = '${original.substring(0, split)}\n\n${jsonEncode(details)}';
    final request = UserQuestionRequest.fromWaterfall('short-task', 's1', payload);
    await _chat(tester, request);
    expect(find.text(prompt), findsOneWidget);
    expect(find.text('合成每日检查'), findsOneWidget);
    expect(find.text(r'visible\u202ekey'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交')).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final purpose in ['ordinary', 'schedule-authorization']) {
    testWidgets('unrecognized $purpose content keeps the entire original question', (tester) async {
      usePhoneView(tester);
      const text = 'Complete future question\n\n{"unclosed":';
      final request = UserQuestionRequest(
        eventId: 'unknown',
        sessionId: 's1',
        raw: {'purpose': purpose},
        questions: const [UserQuestion(id: 'dsh-go-schedule-authorization-future', question: text)],
      );
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: QuestionCard(request: request, onAnswer: (_, _) async {}),
            ),
          ),
        ),
      );
      expect(find.text(text), findsOneWidget);
      expect(find.byType(ScheduleQuestionBody), purpose == 'ordinary' ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a matching purpose alone does not reinterpret an unrelated question id', (tester) async {
    final payload = _payload();
    (payload['questions'] as List).single['id'] = 'ordinary-question';
    final request = UserQuestionRequest.fromWaterfall('ordinary', 's1', payload);
    await _chat(tester, request);
    expect(find.byType(ScheduleQuestionBody), findsNothing);
    expect(find.text(request.questions.single.question), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
