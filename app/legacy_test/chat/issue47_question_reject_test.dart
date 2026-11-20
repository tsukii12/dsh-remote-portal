import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const request = UserQuestionRequest(
  eventId: 'q1',
  sessionId: 's',
  questions: [UserQuestion(id: 'q', question: 'Proceed?')],
);

class QuestionClient extends DshClient {
  QuestionClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final events = StreamController<DshEvent>.broadcast();
  String? rejectedCode;
  bool fail = false;
  @override
  Stream<DshEvent> watch(String id, {WatchOptions options = const WatchOptions()}) => events.stream;
  @override
  Future<void> rejectQuestion(
    UserQuestionRequest question, {
    String name = 'UserQuestionError',
    String message = 'declined',
    String? code,
  }) async {
    if (fail) throw StateError('offline');
    rejectedCode = code;
    events.add(HostRequestCancelledEvent(question.eventId));
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('decline is explicit, works without selecting, and never hides locally', (tester) async {
    final done = Completer<void>();
    var declined = 0;
    var answered = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: QuestionCard(
            request: request,
            onAnswer: (_, _) async {
              answered++;
            },
            onReject: (_) async {
              declined++;
              await done.future;
            },
          ),
        ),
      ),
    );
    expect(declined, 0);
    // Decline and submit mirror each other like the approval card's pair.
    final card = tester.getRect(find.byType(QuestionCard));
    final decline = tester.getRect(find.widgetWithText(OutlinedButton, '不回答'));
    final submit = tester.getRect(find.widgetWithText(FilledButton, '提交'));
    expect(decline.size, submit.size);
    expect(decline.top, submit.top);
    expect(submit.left - decline.right, 12);
    expect(decline.left - card.left, card.right - submit.right);
    await tester.tap(find.text('不回答'));
    await tester.pump();
    expect(declined, 1);
    expect(answered, 0);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '不回答')).onPressed, isNull);
    expect(find.byType(QuestionCard), findsOneWidget);
    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsOneWidget, reason: 'only Host cancellation may remove the pending request');
  });

  for (final fails in [false, true]) {
    test('Host rejection ${fails ? 'failure keeps pending card' : 'ack removes pending via event'}', () async {
      final client = QuestionClient()..fail = fails;
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData<HostConnection?>(HostConnection(hostId: '', client: client, label: 'local', isLocal: true)),
          ),
        ],
      );
      container.listen(chatProvider('s'), (_, _) {});
      addTearDown(() async {
        container.dispose();
        await client.events.close();
        await client.close();
      });
      client.events.add(const UserQuestionRequestedEvent(request));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(container.read(chatProvider('s')).questions, hasLength(1));
      final ok = await container.read(chatProvider('s').notifier).rejectQuestion(request);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(ok, !fails);
      final state = container.read(chatProvider('s'));
      if (fails) {
        expect(state.questions, hasLength(1));
        expect(state.error, isNotNull);
      } else {
        expect(client.rejectedCode, 'ASK_CANCELLED');
        expect(state.questions, isEmpty);
      }
    });
  }
}
