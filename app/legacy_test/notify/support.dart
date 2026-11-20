// Fakes shared by the notification tests.

import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';

/// Lets queued microtasks and zero-length timers run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SessionSummary session(String id, {String? title, bool running = false, String? parent}) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: running,
  blank: false,
  agentAvailable: true,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(1, {'title': title}),
);

ApprovalRequestedEvent approval(String eventId, String sessionId, {String tool = 'bash', String? reason}) =>
    ApprovalRequestedEvent(ApprovalRequest(eventId: eventId, sessionId: sessionId, toolName: tool, reason: reason));

UserQuestionRequestedEvent question(String eventId, String sessionId, List<String> questions) =>
    UserQuestionRequestedEvent(
      UserQuestionRequest(
        eventId: eventId,
        sessionId: sessionId,
        questions: [for (final (i, q) in questions.indexed) UserQuestion(id: 'q$i', question: q)],
      ),
    );

TurnOutcome outcome(int seq, String kind, {String? reply, String? title, LlmFailure? error, String? cause}) =>
    TurnOutcome(
      seq: seq,
      reason: TurnEndReason(kind, error: error, cancelCause: cause),
      reply: reply,
      title: title,
    );

/// A connected host whose `$events` the test drives by hand.
class FakeAlertSource implements AlertSource {
  final _events = StreamController<HostEvent>.broadcast(sync: true);
  List<HostEvent> pending = [];
  bool isConnected = true;
  List<SessionSummary> sessions = [];

  /// Next answer of [lastTurn] per session (null: unreadable).
  final Map<String, TurnOutcome?> outcomes = {};
  final Map<String, ToolCallPart> approvalCalls = {};
  int listCalls = 0;
  final List<String> lastTurnCalls = [];

  void emit(HostEvent event) => _events.add(event);

  @override
  Stream<HostEvent> get events => _events.stream;

  @override
  List<HostEvent> get pendingRequests => pending;

  @override
  bool get connected => isConnected;

  @override
  Future<List<SessionSummary>> listSessions() async {
    listCalls++;
    return sessions;
  }

  @override
  Future<ToolCallPart?> approvalCall(ApprovalRequest request) async => approvalCalls[request.callId];

  @override
  Future<TurnOutcome?> lastTurn(String sessionId) async {
    lastTurnCalls.add(sessionId);
    return outcomes[sessionId];
  }
}

/// Records what would reach the native side.
class FakeNotifyChannel extends NotifyChannel {
  FakeNotifyChannel({this.system = const NotifySystemStatus()});

  NotifySystemStatus system;
  final List<NotifyPost> shown = [];
  final List<(String, String)> cancelled = [];
  final List<String> cancelledGroups = [];
  int cancelledAll = 0;
  final List<String?> openedSettings = [];
  final actionController = StreamController<NotifyAction>.broadcast(sync: true);
  final actionResults = <(NotifyAction, NotifyActionResult)>[];
  final tapController = StreamController<NotifyTap>.broadcast(sync: true);

  @override
  Future<NotifySystemStatus> status() async => system;

  @override
  Future<void> show(NotifyPost post) async => shown.add(post);

  @override
  Future<bool> tryShow(NotifyPost post, {bool Function()? stillCurrent}) async {
    if (stillCurrent?.call() == false) return false;
    if (!system.native || !system.enabled || !(post.attention ? system.attention : system.done)) return false;
    await show(post);
    return true;
  }

  @override
  Future<void> cancel(String group, String key) async => cancelled.add((group, key));

  @override
  Future<void> cancelGroup(String group) async => cancelledGroups.add(group);

  @override
  Future<void> cancelAll() async => cancelledAll++;

  @override
  Future<bool> openSettings({String? channel}) async {
    openedSettings.add(channel);
    return true;
  }

  @override
  Stream<NotifyTap> get taps => tapController.stream;

  @override
  Stream<NotifyAction> get actions => actionController.stream;

  @override
  Future<void> completeAction(NotifyAction action, NotifyActionResult result) async =>
      actionResults.add((action, result));
}

/// A connection object that is never used: [FakeAlertSource] stands in.
HostConnection fakeHostConnection({bool local = true, HostKind kind = HostKind.portal, String? hostId}) =>
    HostConnection(
      client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))),
      label: local ? '本机' : '电脑 · SSH',
      isLocal: local,
      kind: kind,
      hostId: hostId,
    );
