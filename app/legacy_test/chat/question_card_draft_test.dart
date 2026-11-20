import 'dart:ui' show CheckedState, Tristate;

import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const request = UserQuestionRequest(
  eventId: 'q1',
  sessionId: 's1',
  questions: [
    UserQuestion(
      id: 'db',
      question: '数据库',
      options: [QuestionOption('PostgreSQL', null), QuestionOption('SQLite', null)],
    ),
  ],
);

void main() {
  setUpAll(loadTestFonts);
  testWidgets('selection and custom text survive scrolling and route remount', (tester) async {
    usePhoneView(tester);
    final bucket = PageStorageBucket();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    List<QuestionAnswer>? answers;
    Widget page({bool show = true}) => testApp(
      Scaffold(
        body: PageStorage(
          bucket: bucket,
          child: show
              ? ListView.builder(
                  controller: scroll,
                  reverse: true,
                  itemCount: 31,
                  itemBuilder: (_, i) => i == 0
                      ? QuestionCard(
                          request: request,
                          onAnswer: (_, value) async {
                            answers = value;
                          },
                        )
                      : SizedBox(height: 90, child: Text('消息 $i')),
                )
              : const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(page());
    await tester.tap(find.text('PostgreSQL'));
    await tester.tap(find.text('其他回答'));
    await pumpFrames(tester, 4);
    await tester.enterText(find.byType(TextField), '补充说明');
    FocusManager.instance.primaryFocus?.unfocus();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '补充说明');
    await tester.pumpWidget(page(show: false));
    await tester.pumpWidget(page());
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '补充说明');
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(answers!.single.selected, ['PostgreSQL']);
    expect(answers!.single.custom, '补充说明');
  });
  testWidgets('single choice exposes checked, exclusive, enabled and tap semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: QuestionCard(request: request, onAnswer: (_, _) async {}),
        ),
      ),
    );
    await tester.tap(find.text('PostgreSQL'));
    await tester.pump();
    final node = tester.getSemantics(find.text('PostgreSQL'));
    final flags = node.flagsCollection;
    expect(flags.isChecked, CheckedState.isTrue);
    expect(flags.isInMutuallyExclusiveGroup, isTrue);
    expect(flags.isEnabled, Tristate.isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });
}
