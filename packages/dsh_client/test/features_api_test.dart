import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

/// `schedule/catalog` entries as DSH 0.2.1-rc.2 returns them.
const _daily = {
  'id': 'sch-daily',
  'kind': 'daily',
  'title': '日报提醒',
  'prompt': '整理今天的提交，写一段日报。',
  'time': '09:00',
  'timeZone': 'Asia/Shanghai',
  'scheduledAt': '2026-10-25T01:00:00.000Z',
  'sessionId': 'session-1',
  'status': 'active',
  'lastDelivery': {
    'scheduledAt': '2026-10-24T01:00:00.000Z',
    'deliveredAt': '2026-10-24T01:00:01.200Z',
    'messageId': 'msg-1',
  },
};

const _legacyAt = {
  'id': 'sch-at',
  'kind': 'at',
  'prompt': '看一下构建结果\n然后告诉我',
  'scheduledAt': '2026-10-20T08:00:00.000Z',
  'sessionId': 'session-2',
  'status': 'inactive',
};

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(client.close);
    return client;
  }

  test('watchJobs cancelled before ready never opens job/list', () async {
    final client = await connect();
    host.rejectWebSocket = true;
    client.mux.reconnect();
    final opened = <String>[];
    host.onOpen = (_, _, endpoint, _) => opened.add(endpoint);
    final sub = client.watchJobs('session-1').listen((_) {});
    await sub.cancel();
    host.rejectWebSocket = false;
    client.mux.reconnect();
    await client.mux.ready();
    await Future<void>.delayed(Duration.zero);
    expect(opened, isNot(contains('job/list')));
  });

  group('schedule', () {
    test('catalog parses tasks; untitled ones fall back to the first prompt line', () async {
      host.handlers['schedule/catalog'] = (_) => ok([
        _daily,
        _legacyAt,
        {'id': 'no-session'},
      ]);
      final tasks = await (await connect()).scheduleCatalog();
      expect(tasks, hasLength(2));
      final daily = tasks.first;
      expect(daily.title, '日报提醒');
      expect(daily.kind, 'daily');
      expect(daily.active, isTrue);
      expect(daily.recurring, isTrue);
      expect(daily.time, '09:00');
      expect(daily.timeZone, 'Asia/Shanghai');
      expect(daily.scheduledAt, DateTime.utc(2026, 10, 25, 1));
      expect(daily.lastDeliveredAt, DateTime.utc(2026, 10, 24, 1, 0, 1, 200));
      expect(daily.record.containsKey('sessionId'), isFalse);
      expect(daily.record.containsKey('status'), isFalse);
      expect(daily.record['title'], '日报提醒');

      final at = tasks.last;
      expect(at.title, '看一下构建结果');
      expect(at.active, isFalse);
      expect(at.recurring, isFalse);
    });

    test('history, update and delete send the session and the stored record', () async {
      host.handlers['schedule/catalog'] = (_) => ok([_daily]);
      host.handlers['schedule/history'] = (args) {
        expect(args, {
          'request': {'sessionId': 'session-1', 'id': 'sch-daily', 'limit': 20},
        });
        return ok({
          'id': 'sch-daily',
          'records': [
            {
              'scheduledAt': '2026-10-24T01:00:00.000Z',
              'deliveredAt': '2026-10-24T01:00:01.200Z',
              'messageId': 'msg-1',
              'prompt': '整理今天的提交，写一段日报。',
            },
          ],
          'earlierRecordsUnavailable': false,
          'earlierRecordsPruned': true,
          'retention': {'days': 30, 'records': 200},
          'nextBefore': 'cursor-1',
        });
      };
      host.handlers['schedule/update'] = (args) {
        final request = args['request']! as Map;
        expect(request['title'], '早报提醒');
        expect(request.containsKey('prompt'), isFalse);
        expect((request['expected']! as Map)['title'], '日报提醒');
        expect((request['expected']! as Map).containsKey('status'), isFalse);
        return ok({
          'id': 'sch-daily',
          'updated': true,
          'record': {...(request['expected']! as Map), 'title': '早报提醒'},
        });
      };
      host.handlers['schedule/delete'] = (args) {
        expect(args, {
          'request': {'sessionId': 'session-1', 'id': 'sch-daily'},
        });
        return ok({'id': 'sch-daily', 'deleted': true});
      };
      final client = await connect();
      final task = (await client.scheduleCatalog()).single;

      final history = await client.scheduleHistory(task);
      expect(history.missing, isNull);
      expect(history.runs.single.prompt, '整理今天的提交，写一段日报。');
      expect(history.nextBefore, 'cursor-1');
      expect(history.pruned, isTrue);
      expect(history.retentionDays, 30);

      final update = await client.updateSchedule(task, title: '早报提醒');
      expect(update.updated, isTrue);
      expect(update.task!.title, '早报提醒');
      expect(update.task!.sessionId, 'session-1');

      expect(await client.deleteSchedule(task), isTrue);
    });

    test('a stale update reports its code; a missing task reports it in history', () async {
      host.handlers['schedule/catalog'] = (_) => ok([_daily]);
      host.handlers['schedule/update'] = (_) => ok({'id': 'sch-daily', 'updated': false, 'code': 'schedule_conflict'});
      host.handlers['schedule/history'] = (_) => ok({'id': 'sch-daily', 'code': 'schedule_not_found'});
      final client = await connect();
      final task = (await client.scheduleCatalog()).single;
      final update = await client.updateSchedule(task, prompt: '新的指令');
      expect(update.updated, isFalse);
      expect(update.code, 'schedule_conflict');
      expect((await client.scheduleHistory(task)).missing, 'schedule_not_found');
    });
  });

  group('jobs', () {
    test('watchJobs streams whole sets; followJob yields opened, output, status', () async {
      final opened = <String, Map<String, Object?>>{};
      host.onOpen = (socket, streamId, endpoint, payload) {
        opened[endpoint] = payload;
        final job = {
          'id': 'job-1',
          'kind': 'bash',
          'label': 'npm run dev',
          'status': 'running',
          'startedAt': 1761300000000,
          'output': {'total': 12, 'earliest': 0},
        };
        if (endpoint == 'job/list') {
          socket.item(streamId, {
            'type': 'rows',
            'jobs': [job],
          });
          socket.item(streamId, {
            'type': 'rows',
            'jobs': [
              {...job, 'status': 'completed', 'finishedAt': 1761300005000},
            ],
          });
        } else if (endpoint == 'job/follow') {
          socket.item(streamId, {'type': 'opened', 'job': job, 'from': 0});
          socket.item(streamId, {
            'type': 'output',
            'chunks': [
              {'at': 0, 'text': 'ready\n', 'channel': 'stdout'},
              {'at': 6, 'text': 'warn\n', 'channel': 'stderr', 'gapBefore': true},
            ],
            'next': 12,
          });
          socket.item(streamId, {
            'type': 'status',
            'job': {...job, 'status': 'killed'},
          });
          socket.send({'type': 'end', 'streamId': streamId});
        }
      };
      host.handlers['job/kill'] = (args) {
        expect(args, {
          'request': {'sessionId': 'session-1', 'jobId': 'job-1'},
        });
        return ok({'outcome': 'requested'});
      };
      final client = await connect();

      final sets = await client.watchJobs('session-1').take(2).toList();
      expect(opened['job/list'], {
        'args': {
          'request': {'sessionId': 'session-1'},
        },
      });
      expect(sets.first.single.live, isTrue);
      expect(sets.first.single.label, 'npm run dev');
      expect(sets.first.single.startedAt, DateTime.fromMillisecondsSinceEpoch(1761300000000));
      expect(sets.last.single.status, 'completed');
      expect(sets.last.single.live, isFalse);

      final frames = await client.followJob('session-1', 'job-1').toList();
      expect(frames[0], isA<JobOpened>());
      final output = frames[1] as JobOutput;
      expect(output.chunks.map((c) => c.text).join(), 'ready\nwarn\n');
      expect(output.chunks.last.channel, 'stderr');
      expect(output.chunks.last.gapBefore, isTrue);
      expect((frames[2] as JobStatusChanged).job.status, 'killed');

      expect(await client.killJob('session-1', 'job-1'), isTrue);
    });
  });

  group('skills, presets, settings', () {
    test('listSkills keeps named skills', () async {
      host.handlers['skills/list'] = (args) {
        expect(args, {
          'request': {'sessionId': 'session-1'},
        });
        return ok({
          'skills': [
            {
              'name': 'release-notes',
              'description': '写发布说明',
              'modelInvocable': false,
              'path': '/w/.dsh/skills/r/SKILL.md',
            },
            {'name': 'review', 'description': '代码评审', 'whenToUse': '提交前'},
            {'description': 'no name'},
          ],
        });
      };
      final skills = await (await connect()).listSkills('session-1');
      expect(skills.map((s) => s.name), ['release-notes', 'review']);
      expect(skills.first.modelInvocable, isFalse);
      expect(skills.last.whenToUse, '提交前');
    });

    test('agent presets: ordered list, read, default via settings/update', () async {
      host.handlers['agentPresets/list'] = (_) => ok({
        'presets': [
          // The actual Host already returns its authoritative order.
          {'id': 'standard', 'order': 1, 'isDefault': true},
          {'id': 'ptc', 'order': 2, 'isDefault': false},
          {'id': 'mine', 'name': '我的', 'broken': 'bad yaml'},
        ],
      });
      host.handlers['agentPresets/read'] = (args) {
        expect(args, {'agentPreset': 'standard'});
        return ok({'agentPreset': 'standard', 'content': 'tools: []\n'});
      };
      host.handlers['settings/describe'] = (_) => ok({
        'writable': true,
        'hasDocument': true,
        'namespaces': [
          {'ns': 'agent-preset-registry', 'value': <String, Object?>{}, 'revision': 3, 'schema': <String, Object?>{}},
          {
            'ns': 'permission',
            'value': {'defaultPreset': 'read-only'},
            'revision': 1,
            'schema': <String, Object?>{},
          },
        ],
      });
      Map<String, Object?>? update;
      host.handlers['settings/update'] = (args) {
        update = args;
        return ok({'ns': 'agent-preset-registry', 'value': args['patch'], 'revision': 4});
      };
      Map<String, Object?>? mutate;
      host.handlers['settings/mutate'] = (args) {
        mutate = args;
        return ok({
          'ns': 'permission',
          'value': {'defaultPreset': 'workspace-write'},
          'revision': 2,
        });
      };
      final client = await connect();

      final presets = await client.listAgentPresets();
      expect(presets.map((p) => p.id), ['standard', 'ptc', 'mine']);
      expect(presets.first.isDefault, isTrue);
      expect(presets.last.broken, 'bad yaml');
      expect((await client.readAgentPreset('standard')).content, 'tools: []\n');

      await client.setDefaultAgentPreset('ptc');
      expect(update, {
        'ns': 'agent-preset-registry',
        'patch': {'selectedDefault': 'ptc'},
        'expectedRevision': 3,
      });

      final permission = await client.settingsSection('permission');
      expect(permission!.value['defaultPreset'], 'read-only');
      expect(await client.settingsSection('nope'), isNull);
      final next = await client.setSetting(
        'permission',
        ['defaultPreset'],
        'workspace-write',
        expectedRevision: permission.revision,
      );
      expect(mutate, {
        'ns': 'permission',
        'ops': [
          {
            'op': 'set',
            'path': ['defaultPreset'],
            'value': 'workspace-write',
          },
        ],
        'expectedRevision': 1,
      });
      expect(next.revision, 2);
    });
  });
}
