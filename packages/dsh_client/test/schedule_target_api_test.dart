import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};
Map<String, Object?> task(String kind, {String status = 'active', String? updatedAt = '2026-11-05T00:00:00.000Z'}) => {
  'id': 'task-$kind',
  'kind': 'every',
  'title': 'Reminder',
  'prompt': 'Check',
  'everySeconds': 3600,
  'target': {
    'kind': kind,
    if (kind != 'new') 'sessionId': 'target-session',
    if (kind != 'session') 'create': <String, Object?>{},
  },
  'involvedSessionIds': ['actor-session', if (kind != 'new') 'target-session'],
  'status': status,
  'updatedAt': ?updatedAt,
};

void main() {
  late FakeDsh host;
  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());
  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    addTearDown(client.close);
    return client;
  }

  test('catalog preserves all targets and paused/ended state without fake session IDs', () async {
    host.handlers['schedule/catalog'] = (_) =>
        ok([task('session'), task('new_once', status: 'paused'), task('new', status: 'ended')]);
    final rows = await (await connect()).scheduleCatalog();
    expect(rows.map((row) => row.target?['kind']), ['session', 'new_once', 'new']);
    expect(rows.map((row) => row.sessionId), ['target-session', null, null]);
    expect(rows.map((row) => row.active), [true, false, false]);
    expect(rows.map((row) => row.status), ['active', 'paused', 'ended']);
    expect(rows[1].target?['sessionId'], 'target-session');
    expect(ScheduleTask.fromJson({...task('new'), 'kind': 'rrule'})!.recurring, true);
  });

  test('conversation filtering uses involvement and active state on both protocols', () async {
    host.handlers['schedule/catalog'] = (_) => ok([
      task('new'),
      task('new_once', status: 'paused'),
      {
        ...task('session'),
        'involvedSessionIds': ['someone-else'],
      },
      {'id': 'old', 'sessionId': 'actor-session', 'kind': 'at', 'prompt': 'old', 'status': 'active'},
      {'id': 'old-ended', 'sessionId': 'actor-session', 'kind': 'at', 'prompt': 'old', 'status': 'inactive'},
    ]);
    expect((await (await connect()).sessionSchedules('actor-session')).map((row) => row.id), ['task-new', 'old']);
  });

  test('update and timing edit use revision and target-aware response', () async {
    final original = task('new');
    final model = ScheduleTask.fromJson(original)!;
    var calls = 0;
    host.handlers['schedule/edit'] = (args) {
      final request = args['request'] as Map;
      expect(request['id'], model.id);
      expect(request['action'], 'update');
      expect(request['expectedUpdatedAt'], model.updatedAt);
      expect(request.containsKey('sessionId'), false);
      if (calls++ == 0) {
        expect(request['patch'], {'title': 'Renamed', 'prompt': 'Updated'});
      } else {
        expect(request['patch'], {
          'timing': {'kind': 'every', 'every_seconds': 7200},
        });
      }
      return ok({...original, 'title': 'Renamed'});
    };
    final client = await connect();
    final changed = await client.updateSchedule(model, title: 'Renamed', prompt: 'Updated');
    expect(changed.updated, true);
    expect(changed.task?.sessionId, null);
    expect(changed.task?.title, 'Renamed');
    expect((await client.editSchedule(model, timing: const EveryTiming(7200))).updated, true);
  });

  test('missing revision is explicit null and update conflict is not replayed', () async {
    host.handlers['schedule/edit'] = (args) {
      final request = args['request'] as Map;
      expect(request.containsKey('expectedUpdatedAt'), true);
      expect(request['expectedUpdatedAt'], null);
      return ok({'id': 'task-new', 'code': 'schedule_conflict'});
    };
    final result = await (await connect()).updateSchedule(
      ScheduleTask.fromJson(task('new', updatedAt: null))!,
      title: 'new',
    );
    expect(result.updated, false);
    expect(result.code, 'schedule_conflict');
  });

  test('history omits legacy ownership and run uses task identity', () async {
    final model = ScheduleTask.fromJson(task('new'))!;
    host.handlers['schedule/history'] = (args) {
      expect(args, {
        'request': {'id': model.id, 'limit': 20},
      });
      return ok({'records': [
        {'scheduledAt': '2026-11-05T00:00:00Z', 'deliveredAt': '2026-11-05T00:00:01Z', 'targetSessionId': 'created-by-run'},
        {'scheduledAt': '2026-11-04T00:00:00Z', 'deliveredAt': '2026-11-04T00:00:01Z'},
      ], 'earlierRecordsPruned': false});
    };
    host.handlers['schedule/run'] = (args) {
      expect(args, {
        'request': {'id': model.id},
      });
      return ok(task('new'));
    };
    final client = await connect();
    expect((await client.scheduleHistory(model)).runs.map((run) => run.targetSessionId), ['created-by-run', null]);
    await client.runScheduledTask(model);
    host.handlers['schedule/run'] = (_) => ok({'id': model.id, 'code': 'schedule_execution_pending'});
    await expectLater(client.runScheduledTask(model), throwsA(isA<DshRemoteException>()));
  });

  test('delete preserves compare-and-set and surfaces conflicts', () async {
    final model = ScheduleTask.fromJson(task('new_once'))!;
    host.handlers['schedule/edit'] = (args) {
      expect(args, {
        'request': {'id': model.id, 'action': 'delete', 'expectedUpdatedAt': model.updatedAt},
      });
      return ok({'id': model.id, 'deleted': true});
    };
    final client = await connect();
    expect(await client.deleteSchedule(model), true);
    host.handlers['schedule/edit'] = (_) => ok({'id': model.id, 'code': 'schedule_conflict'});
    await expectLater(client.deleteSchedule(model), throwsA(isA<DshRemoteException>()));
    host.handlers['schedule/edit'] = (_) => ok({'id': model.id, 'code': 'schedule_not_found'});
    expect(await client.deleteSchedule(model), false);
  });
}
