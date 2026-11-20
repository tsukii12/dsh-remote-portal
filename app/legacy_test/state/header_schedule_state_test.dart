// The header clock's source: one conversation's active tasks from
// `schedule/catalog`, read once the Host is ready, again on `schedule/changed`
// and on a new ready generation; a failed read keeps the last tasks and isn't
// retried.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart';

class _Current extends CurrentSessionController {
  _Current(this.id);
  final String? id;

  @override
  String? build() => id;
}

Map<String, Object?> _record(String id, String title, String next) => {
  'id': id,
  'kind': 'daily',
  'title': title,
  'prompt': '$title：整理一下',
  'time': '09:00:00.000',
  'timeZone': 'Asia/Shanghai',
  'scheduledAt': next,
  'sessionId': 's1',
  'status': 'active',
};

ScheduleTask _task(String id, DateTime? next) => ScheduleTask(
  id: id,
  sessionId: 's1',
  kind: 'at',
  title: id,
  prompt: id,
  active: true,
  record: {'id': id},
  scheduledAt: next,
);

void main() {
  late FakePluginCarrier carrier;
  late DshClient client;
  late ProviderContainer container;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    carrier = FakePluginCarrier();
    client = DshClient.withCarrier(carrier);
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
        currentSessionProvider.overrideWith(() => _Current('s1')),
      ],
    );
    final sub = container.listen(headerSchedulesProvider, (_, _) {});
    addTearDown(() async {
      sub.close();
      container.dispose();
      await client.close();
    });
  });

  test('waits for the Host, then reads the conversation soonest first', () async {
    carrier.handlers['schedule/catalog'] = (_) => [
      _record('late', '晚报', '2026-10-25T13:30:00.000Z'),
      _record('early', '早报', '2026-10-25T01:00:00.000Z'),
    ];
    expect(await container.read(sessionSchedulesProvider('s1').future), isNull, reason: 'not ready yet: nothing asked');
    expect(carrier.argsOf('schedule/catalog'), isEmpty);
    expect(container.read(headerSchedulesProvider).shown, isFalse);

    await client.mux.start();
    await settle();
    final tasks = await container.read(sessionSchedulesProvider('s1').future);
    expect(tasks!.map((t) => t.id), ['early', 'late']);
    expect(carrier.argsOf('schedule/catalog'), hasLength(1));
    final header = container.read(headerSchedulesProvider);
    expect(header.shown, isTrue);
    expect(header.sessionId, 's1');
    expect(header.tasks.first.title, '早报');
    expect(header.failed, isFalse);
  });

  test("only this conversation's active tasks, on either protocol", () async {
    carrier.handlers['schedule/catalog'] = (_) => [
      _record('mine', '早报', '2026-10-25T01:00:00.000Z'),
      {..._record('other', '别处', '2026-10-25T01:00:00.000Z'), 'sessionId': 's2'},
      {..._record('paused', '暂停', '2026-10-25T01:00:00.000Z'), 'status': 'inactive'},
      {
        ..._record('involved', '涉及', '2026-10-25T02:00:00.000Z'),
        'target': {'kind': 'new'},
        'involvedSessionIds': ['s1'],
        'updatedAt': '2026-10-24T00:00:00.000Z',
      },
      {
        ..._record('apart', '无关', '2026-10-25T02:00:00.000Z'),
        'target': {'kind': 'new'},
        'involvedSessionIds': ['s2'],
        'updatedAt': '2026-10-24T00:00:00.000Z',
      },
    ];
    await client.mux.start();
    await settle();
    final tasks = await container.read(sessionSchedulesProvider('s1').future);
    expect(tasks!.map((t) => t.id), ['mine', 'involved']);
  });

  test('schedule/changed reads again', () async {
    carrier.handlers['schedule/catalog'] = (_) => [_record('a', '日报', '2026-10-25T01:00:00.000Z')];
    await client.mux.start();
    await settle();
    await container.read(sessionSchedulesProvider('s1').future);
    expect(container.read(headerSchedulesProvider).tasks, hasLength(1));

    carrier.handlers['schedule/catalog'] = (_) => <Object?>[];
    carrier.emit('schedule/changed', {'sessionId': 's1'});
    await settle();
    await container.read(sessionSchedulesProvider('s1').future);
    expect(carrier.argsOf('schedule/catalog'), hasLength(2));
    expect(container.read(headerSchedulesProvider).shown, isFalse);
  });

  test('a failed refresh keeps the last tasks and is not retried', () async {
    carrier.handlers['schedule/catalog'] = (_) => [_record('a', '日报', '2026-10-25T01:00:00.000Z')];
    await client.mux.start();
    await settle();
    await container.read(sessionSchedulesProvider('s1').future);

    carrier.handlers['schedule/catalog'] = (_) => throw const DshRemoteException('internal_error', 'boom');
    carrier.emit('schedule/changed', {'sessionId': 's1'});
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final header = container.read(headerSchedulesProvider);
    expect(header.failed, isTrue);
    expect(header.shown, isTrue, reason: 'the clock keeps its last tasks');
    expect(header.tasks.single.title, '日报');
    expect(carrier.argsOf('schedule/catalog'), hasLength(2), reason: 'no automatic retry');
  });

  test('a first read that fails shows nothing', () async {
    carrier.handlers['schedule/catalog'] = (_) => throw const DshRemoteException('gateway/method-not-found', 'no');
    await client.mux.start();
    await settle();
    final header = container.read(headerSchedulesProvider);
    expect(header.failed, isTrue);
    expect(header.shown, isFalse);
  });

  test('no conversation, no clock', () {
    final empty = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
        currentSessionProvider.overrideWith(() => _Current(null)),
      ],
    );
    addTearDown(empty.dispose);
    expect(empty.read(headerSchedulesProvider).shown, isFalse);
    expect(empty.read(headerSchedulesProvider).sessionId, isNull);
  });

  test('soonestFirst: by next run, undated last, ties in Host order', () {
    final ordered = soonestFirst([
      _task('none', null),
      _task('b', DateTime.utc(2026, 10, 25, 9)),
      _task('a', DateTime.utc(2026, 10, 24, 9)),
      _task('b2', DateTime.utc(2026, 10, 25, 9)),
    ]);
    expect(ordered.map((t) => t.id), ['a', 'b', 'b2', 'none']);
  });
}
