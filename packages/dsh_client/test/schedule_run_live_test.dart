/// Explicit disposable official rc.1 Host with a local synthetic LLM only.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'manual run delivers all three target kinds, records destinations and keeps the scheduled occurrence',
    () async {
      final client = await DshClient.connect(launchUrl: Platform.environment['DSH_LIVE_URL']);
      addTearDown(client.close);
      final session = await client.createSession(cwd: Platform.environment['DSH_LIVE_CWD']);
      final ids = <String>[];
      try {
        for (final kind in ['session', 'new_once', 'new']) {
          final raw = await client.rpc.call('schedule/create', {
            'request': {
              'title': 'Synthetic run $kind',
              'prompt': 'Synthetic run $kind; say the fixture result.',
              'timing': {'kind': 'every', 'every_seconds': 3600},
              'target': {'kind': kind, if (kind == 'session') 'sessionId': session.sessionId},
            },
          });
          final task = ScheduleTask.fromJson(raw)!;
          ids.add(task.id);
          await client.runScheduledTask(task);
          final history = await client.scheduleHistory(task);
          expect(history.runs, hasLength(1));
          final destination = history.runs.single.targetSessionId;
          expect(destination, isNotNull);
          expect(history.runs.single.prompt, contains('Synthetic run $kind'));
          if (kind == 'session') expect(destination, session.sessionId);
          if (kind == 'new_once') expect(destination, task.target!['sessionId']);
          if (kind == 'new') expect(destination, isNot(session.sessionId));
          await expectLater(
            client.runScheduledTask(task),
            throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'schedule_execution_pending')),
          );
          final after = (await client.scheduleCatalog()).singleWhere((t) => t.id == task.id);
          expect(after.scheduledAt, task.scheduledAt);
          final completed = await client.rpc.call('session/wait', {
            'request': {'sessionId': destination, 'timeoutMs': 10000},
          });
          expect(jsonEncode(completed), contains('SYNTHETIC_SCHEDULE_RESULT'));
        }
      } finally {
        for (final task in await client.scheduleCatalog()) {
          if (ids.contains(task.id)) await client.deleteSchedule(task);
        }
      }
    },
    skip: Platform.environment['DSH_SCHEDULE_RUN_LIVE'] != '1'
        ? 'requires explicit disposable Host and local LLM mock'
        : null,
  );
}
