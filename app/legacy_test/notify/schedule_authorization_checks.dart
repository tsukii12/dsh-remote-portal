// Also runnable without a Flutter engine:
// dart --packages=.dart_tool/package_config.json test/notify/schedule_authorization_checks.dart
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/ui/features/schedule_editor/schedule_authorization.dart';
import 'package:dsh_client/dsh_client.dart';

class _Carrier extends DshCarrier {
  final results = <Map<String, Object?>>[];
  late _Link link;
  void Function(_Link)? onReady;
  void Function()? onUpdate;
  bool ready = true;

  @override
  String get kind => 'schedule-authorization-test';
  @override
  DshTracer? get tracer => null;
  @override
  bool allowsEndpoint(String endpoint) => true;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == r'$events/result') results.add(args);
    if (endpoint == 'schedule/update') onUpdate?.call();
    return const RpcOk(null);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link = _Link(onReady, ready: ready);
  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  _Link(this.onReady, {this.ready = true});
  final void Function(_Link)? onReady;
  final bool ready;
  late DshMuxFrameHandler _frame;
  String? _id;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => _frame = onFrame;
  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint != r'$events') return;
    _id = streamId;
    if (!ready) return;
    scheduleMicrotask(() {
      push({
        'type': 'ready',
        'clientId': 'client',
        'host': {'home': '/test'},
      });
      onReady?.call(this);
    });
  }

  void push(Map<String, Object?> value) => _frame({'type': 'item', 'streamId': _id, 'value': value});
  @override
  void sendItem(String streamId, Object? value) {}
  @override
  void endUplink(String streamId) {}
  @override
  void cancel(String streamId) {}
  @override
  Future<void> close(int code, String reason) async {}
}

Map<String, Object?> scheduleQuestionFrame(
  String id, {
  String session = 's1',
  String purpose = 'schedule-authorization',
  String prefix = 'dsh-go-schedule-authorization-',
}) => {
  'type': 'waterfall',
  'event': 'user-questions/request',
  'eventId': id,
  'agentId': session,
  'request': {
    'purpose': purpose,
    'questions': [
      {
        'id': '$prefix$id',
        'question':
            'Session: $session\nModify\nAutonomous execution risk\n'
            '{"id":"task","prompt":"complete instruction","kind":"daily","timeZone":"Asia/Shanghai"}',
        'options': [
          {'label': '授权 / Authorize'},
          {'label': '拒绝 / Reject'},
        ],
      },
    ],
  },
};

var _checks = 0;

void _check(bool condition, String message) {
  _checks++;
  if (!condition) throw StateError(message);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> runScheduleAuthorizationChecks() async {
  _checks = 0;
  final silentCarrier = _Carrier()..ready = false;
  final silentClient = DshClient.withCarrier(silentCarrier);
  final silent = ScheduleAuthorization(silentClient, sessionId: 's1');
  try {
    var timedOut = false;
    try {
      await silent.start(timeout: const Duration(milliseconds: 5));
    } on DshTransportException {
      timedOut = true;
    }
    _check(timedOut, 'missing events ready left saving unbounded');
    _check(silentCarrier.results.isEmpty, 'events startup failure automatically answered authorization');
  } finally {
    silent.dispose();
    await silentClient.close();
  }
  final carrier = _Carrier();
  final client = DshClient.withCarrier(carrier);
  ScheduleAuthorization? scope;
  try {
    // The ready burst can precede the save's awaited connection startup.
    carrier.onReady = (link) => link.push(scheduleQuestionFrame('ready-burst'));
    scope = ScheduleAuthorization(client, sessionId: 's1');
    await scope.start();
    await _flush();
    _check(scope.requests.single.eventId == 'ready-burst', 'lost request from initial ready burst');
    _check(carrier.results.isEmpty, 'request was answered without a person');
    carrier.link.push({'type': 'cancel', 'eventId': 'ready-burst'});
    await _flush();
    _check(scope.requests.isEmpty, 'withdrawn card stayed visible');
    scope.dispose();

    // Subscribe then replay: a request already buffered by the mux is not lost.
    carrier.link.push(scheduleQuestionFrame('before-subscribe'));
    await _flush();
    scope = ScheduleAuthorization(client, sessionId: 's1');
    await scope.start();
    _check(scope.requests.single.eventId == 'before-subscribe', 'pending replay lost a fast request');
    final withdrawn = scope.requests.single;
    carrier.link.push({'type': 'cancel', 'eventId': withdrawn.eventId});
    // Cancellation is synchronous in the mux, even before the broadcast fires.
    await scope.answer(withdrawn, [
      QuestionAnswer(withdrawn.questions.single.id, selected: ['授权 / Authorize']),
    ]);
    _check(carrier.results.isEmpty, 'stale card authorized a synchronously withdrawn request');
    await _flush();

    carrier.onUpdate = () {
      carrier.link.push(scheduleQuestionFrame('other-session', session: 's2'));
      carrier.link.push(scheduleQuestionFrame('ordinary', purpose: 'ordinary'));
      carrier.link.push(scheduleQuestionFrame('wrong-prefix', prefix: 'ordinary-'));
      carrier.link.push(scheduleQuestionFrame('during-save'));
      carrier.link.push(scheduleQuestionFrame('during-save'));
    };
    await client.rpc.call('schedule/update');
    await _flush();
    _check(scope.requests.length == 1, 'did not filter session/purpose/prefix or deduplicate');
    _check(scope.requests.single.eventId == 'during-save', 'lost request emitted synchronously by saving RPC');
    _check(carrier.results.isEmpty, 'redelivery automatically answered the question');
    final request = scope.requests.single;
    await scope.answer(request, [
      QuestionAnswer(request.questions.single.id, selected: ['授权 / Authorize']),
    ]);
    _check(carrier.results.length == 1, 'explicit answer was not sent exactly once');
    final outcome = carrier.results.single['outcome']! as Map;
    _check(outcome['kind'] == 'result', 'manual authorization did not use question response protocol');
    final answers = (outcome['value']! as Map)['answers']! as List;
    final answer = answers.single as Map;
    _check((answer['selected']! as List).single == '授权 / Authorize', 'wrong authorization label');
    _check(!answer.containsKey('custom'), 'manual selection unexpectedly sent a custom answer');
    await scope.answer(request, []);
    _check(carrier.results.length == 1, 'settled request answered twice');
    await _flush();
    scope.dispose();

    // New-session destination becomes known only after creation; replay then.
    scope = ScheduleAuthorization(client);
    await scope.start();
    carrier.link.push(scheduleQuestionFrame('new-session', session: 'new-1'));
    await _flush();
    _check(scope.requests.isEmpty, 'unbound scope captured another session');
    scope.setSession('new-1');
    _check(scope.requests.single.eventId == 'new-session', 'new-session binding lost an early request');
    await scope.reject(scope.requests.single);
    _check((carrier.results.last['outcome']! as Map)['kind'] == 'rejected', 'manual decline was not a rejection');
    scope.dispose();

    for (final custom in ['', 'authorize']) {
      scope = ScheduleAuthorization(client, sessionId: 's1');
      await scope.start();
      carrier.link.push(scheduleQuestionFrame('custom-$custom'));
      await _flush();
      final customRequest = scope.requests.firstWhere((r) => r.eventId == 'custom-$custom');
      await scope.answer(customRequest, [
        QuestionAnswer(customRequest.questions.single.id, selected: ['授权 / Authorize'], custom: custom),
      ]);
      _check((carrier.results.last['outcome']! as Map)['kind'] == 'rejected', 'custom answer authorized execution');
      scope.dispose();
    }

    scope = ScheduleAuthorization(client, sessionId: 's1');
    await scope.start();
    carrier.link.push(scheduleQuestionFrame('rebinding'));
    await _flush();
    final beforeRebind = scope.requests.single;
    final responsesBeforeRebind = carrier.results.length;
    scope.setSession('s2');
    await scope.answer(beforeRebind, [
      QuestionAnswer(beforeRebind.questions.single.id, selected: ['授权 / Authorize']),
    ]);
    await _flush();
    _check(scope.requests.every((r) => r.sessionId == 's2'), 'rebind retained the old session card');
    final rebound = carrier.results.skip(responsesBeforeRebind).toList();
    _check(
      rebound.length == 1 &&
          rebound.single['eventId'] == 'rebinding' &&
          (rebound.single['outcome']! as Map)['kind'] == 'rejected',
      'old destination was not safely cancelled or its callback authorized after rebind',
    );
    scope.dispose();

    scope = ScheduleAuthorization(client, sessionId: 's1');
    await scope.start();
    carrier.link.push(scheduleQuestionFrame('before-reconnect'));
    await _flush();
    final disconnected = scope.requests.single;
    carrier.onReady = null;
    client.mux.reconnect();
    await client.mux.ready();
    await _flush();
    final responsesBeforeReconnect = carrier.results.length;
    await scope.answer(disconnected, [
      QuestionAnswer(disconnected.questions.single.id, selected: ['授权 / Authorize']),
    ]);
    _check(scope.requests.isEmpty, 'disconnected generation retained its card');
    _check(carrier.results.length == responsesBeforeReconnect, 'old generation callback authorized after reconnect');
    scope.dispose();

    scope = ScheduleAuthorization(client, sessionId: 's1');
    await scope.start();
    carrier.link.push(scheduleQuestionFrame('exit-before-delivery'));
    scope.dispose();
    await _flush();
    _check(carrier.results.last['eventId'] == 'exit-before-delivery', 'exit lost a request queued before broadcast');
    _check((carrier.results.last['outcome']! as Map)['kind'] == 'rejected', 'fast exit did not reject safely');

    // Retired page/Host scope cancels only its own pending authorization, on
    // the original client; stale callbacks cannot authorize it or the new Host.
    final nextCarrier = _Carrier();
    final nextClient = DshClient.withCarrier(nextCarrier);
    final next = ScheduleAuthorization(nextClient, sessionId: 's1');
    try {
      await next.start();
      scope = ScheduleAuthorization(client, sessionId: 's1');
      await scope.start();
      carrier.link.push(scheduleQuestionFrame('leaving'));
      await _flush();
      final old = scope.requests.firstWhere((request) => request.eventId == 'leaving');
      final before = carrier.results.length;
      scope.dispose();
      await scope.answer(old, [
        QuestionAnswer(old.questions.single.id, selected: ['授权 / Authorize']),
      ]);
      await _flush();
      final cancellations = carrier.results.skip(before).toList();
      _check(cancellations.every((r) => (r['outcome']! as Map)['kind'] == 'rejected'), 'retired scope authorized');
      _check(cancellations.any((r) => r['eventId'] == 'leaving'), 'page exit left its request hanging');
      _check(!cancellations.any((r) => r['eventId'] == 'other-session'), 'cancelled another session');
      _check(!cancellations.any((r) => r['eventId'] == 'ordinary'), 'cancelled an ordinary question');
      _check(nextCarrier.results.isEmpty, 'old event id was sent to the new Host');
      carrier.link.push(scheduleQuestionFrame('after-exit'));
      await _flush();
      _check(scope.requests.isEmpty && next.requests.isEmpty, 'retired listener kept capturing requests');
    } finally {
      next.dispose();
      await nextClient.close();
    }
  } finally {
    scope?.dispose();
    await client.close();
  }
}

Future<void> main() async {
  await runScheduleAuthorizationChecks();
  stdout.writeln('schedule authorization: $_checks checks passed');
}
