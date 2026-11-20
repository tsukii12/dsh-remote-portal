import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A client whose session stream and approval answers are scripted.
class ScriptedClient extends DshClient {
  ScriptedClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final answered = <(String, ApprovalDecision)>[];
  final failing = <String>{};
  final questionAnswers = <String>[];

  @override
  Future<void> answerQuestion(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    questionAnswers.add(request.eventId);
  }

  @override
  Future<void> rejectQuestion(
    UserQuestionRequest request, {
    String name = 'UserQuestionError',
    String message = 'declined',
    String? code,
  }) async {
    questionAnswers.add(request.eventId);
  }

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<void> respondApproval(ApprovalRequest request, ApprovalDecision decision) async {
    if (failing.contains(request.eventId)) throw StateError('offline');
    answered.add((request.eventId, decision));
  }
}

ApprovalRequest request(String id) =>
    ApprovalRequest(eventId: id, sessionId: 's', toolName: 'bash', callId: 'call-$id');

/// Lets the stream deliver and the 32 ms publish timer fire.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  late ScriptedClient client;
  late ProviderContainer container;
  late ChatController chat;

  setUp(() {
    client = ScriptedClient();
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(hostId: '', client: client, label: '本机', isLocal: true)),
        ),
      ],
    );
    container.listen(chatProvider('s'), (_, _) {});
    chat = container.read(chatProvider('s').notifier);
  });

  tearDown(() async {
    container.dispose();
    await client.events.close();
  });

  ChatState state() => container.read(chatProvider('s'));

  test('off by default: approvals wait for a person', () async {
    client.events.add(ApprovalRequestedEvent(request('a')));
    await settle();
    expect(state().approvals.single.eventId, 'a');
    expect(client.answered, isEmpty);
    expect(state().autoApprove, isFalse);
  });

  test('allowAll answers the request and every later one, once each', () async {
    client.events.add(ApprovalRequestedEvent(request('a')));
    await settle();

    await chat.allowAll(request('a'));
    expect(state().autoApprove, isTrue);
    expect(client.answered, [('a', ApprovalDecision.allowOnce)]);
    expect(state().autoAnswered, contains('a'));

    client.events.add(ApprovalRequestedEvent(request('b')));
    await settle();
    // Redelivered after a reconnect: not answered twice.
    client.events.add(ApprovalRequestedEvent(request('b')));
    await settle();
    expect(client.answered, [('a', ApprovalDecision.allowOnce), ('b', ApprovalDecision.allowOnce)]);
    expect(state().autoAnswered, {'a', 'b'});

    // The Host withdraws answered requests: they are forgotten.
    client.events.add(const HostRequestCancelledEvent('a'));
    client.events.add(const HostRequestCancelledEvent('b'));
    await settle();
    expect(state().autoAnswered, isEmpty);
    expect(state().approvals, isEmpty);
  });

  test('turning it off stops auto answers', () async {
    chat.setAutoApprove(true);
    chat.setAutoApprove(false);
    client.events.add(ApprovalRequestedEvent(request('c')));
    await settle();
    expect(client.answered, isEmpty);
    expect(state().approvals.single.eventId, 'c');
  });

  test('turning it on answers what is already pending', () async {
    client.events.add(ApprovalRequestedEvent(request('d')));
    await settle();
    chat.setAutoApprove(true);
    await settle();
    expect(client.answered, [('d', ApprovalDecision.allowOnce)]);
  });

  test('auto approval never answers or suppresses schedule authorization questions', () async {
    final question = UserQuestionRequest.fromWaterfall('schedule-consent', 's', {
      'purpose': 'schedule-authorization',
      'questions': [
        {
          'id': 'dsh-go-schedule-authorization-one',
          'question': 'Session: s\nCreate\nAutonomous execution risk\n{"prompt":"full prompt","at":"tomorrow"}',
          'options': [
            {'label': '授权 / Authorize'},
            {'label': '拒绝 / Reject'},
          ],
        },
      ],
    });
    client.events.add(UserQuestionRequestedEvent(question));
    await settle();
    chat.setAutoApprove(true);
    await settle();
    expect(state().questions.single.eventId, 'schedule-consent');
    expect(client.questionAnswers, isEmpty);
    expect(state().autoAnswered, isEmpty);
    client.events.add(UserQuestionRequestedEvent(question));
    client.events.add(ApprovalRequestedEvent(request('ordinary-command')));
    await settle();
    expect(state().questions.single.eventId, 'schedule-consent', reason: 'redelivery keeps one manual card');
    expect(client.questionAnswers, isEmpty);
    expect(client.answered, [('ordinary-command', ApprovalDecision.allowOnce)]);
    expect(state().autoAnswered, {'ordinary-command'});
    client.events.add(const HostRequestCancelledEvent('schedule-consent'));
    await settle();
    expect(state().questions, isEmpty);
    expect(client.questionAnswers, isEmpty);
  });

  test('a failed auto answer puts the card back with an error', () async {
    client.failing.add('e');
    chat.setAutoApprove(true);
    client.events.add(ApprovalRequestedEvent(request('e')));
    await settle();
    expect(client.answered, isEmpty);
    expect(state().autoAnswered, isEmpty);
    expect(state().approvals.single.eventId, 'e');
    expect(state().error, '自动允许失败');
  });
}
