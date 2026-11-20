/// Destructive test data is confined to an explicitly supplied disposable Host.
/// DSH_TARGET_SCHEDULE_LIVE=1 DSH_LIVE_URL=launch-url dart test this-file
@Tags(['live'])
library;

import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('real rc.1 target schedules preserve destinations, revisions and conflict responses', () async {
    final launch = DshLaunchUrl.tryParse(Platform.environment['DSH_LIVE_URL']!)!;
    final client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
    addTearDown(client.close);
    final session = await client.createSession(cwd: Platform.environment['DSH_LIVE_CWD']);
    final created = <ScheduleTask>[];
    try {
      for (final target in [
        {'kind': 'session', 'sessionId': session.sessionId},
        {'kind': 'new_once'},
        {'kind': 'new'},
      ]) {
        final value = await client.rpc.call('schedule/create', {
          'request': {
            'title': 'Synthetic future reminder',
            'prompt': 'Synthetic test only',
            'timing': {'kind': 'every', 'every_seconds': 3600},
            'target': target,
          },
        });
        final task = ScheduleTask.fromJson(value)!;
        created.add(task);
        expect(task.target?['kind'], target['kind']);
        expect(task.sessionId, target['kind'] == 'session' ? session.sessionId : null);
        expect(task.updatedAt, isNotNull);
      }
      final catalog = await client.scheduleCatalog();
      expect(catalog.map((task) => task.id), containsAll(created.map((task) => task.id)));
      final forSession = await client.sessionSchedules(session.sessionId);
      expect(forSession.map((task) => task.id), contains(created.first.id));
      for (final task in created) {
        final changed = await client.updateSchedule(task, title: 'Renamed synthetic reminder');
        expect(changed.updated, true);
        expect(changed.task?.target?['kind'], task.target?['kind']);
        expect((await client.scheduleHistory(changed.task!)).runs, isEmpty);
        final conflict = await client.updateSchedule(task, prompt: 'Stale edit must not save');
        expect(conflict.updated, false);
        expect(conflict.code, 'schedule_conflict');
        expect(await client.deleteSchedule(changed.task!), true);
      }
      expect((await client.scheduleCatalog()).where((task) => created.any((old) => old.id == task.id)), isEmpty);
    } finally {
      // Cleanup reads fresh revisions; it does not replay a failed user write.
      for (final task in await client.scheduleCatalog()) {
        if (created.any((old) => old.id == task.id)) await client.deleteSchedule(task);
      }
    }
  }, skip: Platform.environment['DSH_TARGET_SCHEDULE_LIVE'] != '1' ? 'requires explicit disposable rc.1 Host' : null);
}
