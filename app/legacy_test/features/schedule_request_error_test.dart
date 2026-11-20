import 'dart:async';

import 'package:dsh_app/state/schedule_editor_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart';

Future<List<Object>> _zoneErrors(Future<void> Function() action) async {
  final finished = Completer<void>();
  final errors = <Object>[];
  runZonedGuarded(() async {
    try {
      await action();
      finished.complete();
    } catch (error, stack) {
      finished.completeError(error, stack);
    }
  }, (error, _) => errors.add(error));
  await finished.future;
  return errors;
}

void main() {
  for (final rejectPrompt in [false, true]) {
    test('early session error stays on returned Future when prompt ${rejectPrompt ? "rejects" : "accepts"}', () async {
      final leaked = await _zoneErrors(() async {
        final carrier = FakePluginCarrier();
        final client = DshClient.withCarrier(carrier);
        final entered = Completer<void>();
        final reply = Completer<Object?>();
        carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
        carrier.handlers['session/prompt'] = (_) {
          entered.complete();
          return reply.future;
        };
        try {
          await client.mux.ready();
          final result = requestSchedule(
            client,
            sessionId: 's',
            title: 'daily',
            request: 'create daily task',
          ).then<Object?>((task) => task, onError: (Object error) => error);
          await entered.future;
          final delivered = Completer<void>();
          final events = client.hostEvents.listen((event) {
            if (event is SessionErrorEvent) delivered.complete();
          });
          carrier.link!.push({
            'type': 'emit',
            'event': 'api-session/error',
            'args': ['s', 'model failed'],
          });
          await delivered.future;
          await Future<void>.value();
          await events.cancel();
          // Both transports finish. No permanently pending request or real sleep.
          if (rejectPrompt) {
            reply.completeError(const DshRemoteException('session/not-found', 'gone'));
          } else {
            reply.complete({'accepted': true});
          }
          expect(await result, rejectPrompt ? isA<DshRemoteException>() : isA<ScheduleCreateFailure>());
        } finally {
          if (!reply.isCompleted) reply.complete({'accepted': true});
          await client.close();
        }
      });
      expect(leaked, isEmpty, reason: 'the caller already observes requestSchedule; no internal error may escape');
    });
  }

  test('prompt refusal without a session event still reaches the caller', () async {
    final leaked = await _zoneErrors(() async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
      carrier.handlers['session/prompt'] = (_) => throw const DshRemoteException('session/not-found', 'gone');
      try {
        await client.mux.ready();
        await expectLater(
          requestSchedule(client, sessionId: 's', title: 'daily', request: 'create daily task'),
          throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/not-found')),
        );
      } finally {
        await client.close();
      }
    });
    expect(leaked, isEmpty);
  });
}
