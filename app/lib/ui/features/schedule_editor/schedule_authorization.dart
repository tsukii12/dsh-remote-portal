import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

/// One editor save owns only schedule questions from its destination session.
/// Closing this scope rejects pending requests; it can never authorize them.
class ScheduleAuthorization {
  ScheduleAuthorization(this.client, {this._sessionId, this.onChanged});

  final DshClient client;
  void Function()? onChanged;
  String? _sessionId;
  final Map<String, UserQuestionRequest> _requests = {};
  StreamSubscription<HostEvent>? _events;
  StreamSubscription<DshConnectionState>? _states;
  Object? _generation;
  bool _active = true;

  bool get active => _active;
  List<UserQuestionRequest> get requests => List.unmodifiable(_requests.values);

  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    // Subscribe before ready/replay and before issuing any saving RPC. The
    // broadcast stream does not replay, but the mux records pending requests.
    _events = client.hostEvents.listen(_event);
    _states = client.mux.states.listen((state) {
      if (state != DshConnectionState.connected && _requests.isNotEmpty) {
        _requests.clear();
        onChanged?.call();
      }
    });
    _replay();
    await client.mux.ready(timeout: timeout);
    if (_active) _replay();
  }

  void setSession(String sessionId) {
    if (!_active) return;
    if (_sessionId != sessionId) {
      final previous = _ownedPending();
      _requests.clear();
      _sessionId = sessionId;
      onChanged?.call();
      for (final request in previous) {
        unawaited(client.rejectQuestion(request).catchError((Object _) {}));
      }
    }
    _replay();
  }

  bool _matches(UserQuestionRequest request) =>
      request.sessionId == _sessionId &&
      request.raw['purpose'] == 'schedule-authorization' &&
      request.questions.isNotEmpty &&
      request.questions.first.id.startsWith('dsh-go-schedule-authorization-');

  void _replay() {
    for (final event in client.mux.pendingRequests) {
      _event(event);
    }
  }

  void _event(HostEvent event) {
    if (!_active) return;
    switch (event) {
      case UserQuestionRequestedEvent(:final request) when _matches(request) && _pending(request):
        _generation = client.mux.generation;
        _requests[request.eventId] = request;
        onChanged?.call();
      case HostRequestCancelledEvent(:final eventId):
        if (_requests.remove(eventId) != null) onChanged?.call();
      default:
        break;
    }
  }

  bool _pending(UserQuestionRequest request) => client.mux.pendingRequests.any(
    (event) => event is UserQuestionRequestedEvent && identical(event.request, request),
  );

  bool _owns(UserQuestionRequest request) =>
      _active &&
      _matches(request) &&
      identical(_requests[request.eventId], request) &&
      _pending(request) &&
      _generation != null &&
      identical(_generation, client.mux.generation);

  Future<void> answer(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    if (!_owns(request)) return;
    final authorized =
        request.questions.length == 1 &&
        answers.length == 1 &&
        answers.single.id == request.questions.single.id &&
        answers.single.selected.length == 1 &&
        answers.single.selected.single == '授权 / Authorize' &&
        answers.single.custom == null;
    if (!authorized) return reject(request);
    await client.answerQuestion(request, answers);
    if (_active && _requests.remove(request.eventId) != null) onChanged?.call();
  }

  Future<void> reject(UserQuestionRequest request) async {
    if (!_owns(request)) return;
    await client.rejectQuestion(request);
    if (_active && _requests.remove(request.eventId) != null) onChanged?.call();
  }

  List<UserQuestionRequest> _ownedPending() => [
    if (client.mux.generation != null)
      for (final event in client.mux.pendingRequests)
        if (event is UserQuestionRequestedEvent && _matches(event.request)) event.request,
  ];

  void dispose() {
    if (!_active) return;
    final pending = _ownedPending();
    _active = false;
    _requests.clear();
    unawaited(_events?.cancel());
    unawaited(_states?.cancel());
    onChanged = null;
    // Revoke local authority first; cancel only on the original client. A
    // failed/disconnected cancellation is still bounded by the Host timeout.
    for (final request in pending) {
      unawaited(client.rejectQuestion(request).catchError((Object _) {}));
    }
  }
}
