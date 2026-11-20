// The live activity in words (lib/notify/live_activity.dart): the pet's mood,
// the conversation it names, the chip, and when it says nothing.

import 'package:dsh_app/notify/live_activity.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_test/flutter_test.dart';

const _local = HostRef.none;
const _ssh = HostRef.portal('lab');
final _t0 = DateTime(2026, 11, 1, 9);

PetRun _run(String id, {HostRef host = _local, String? root, bool subagent = false, int at = 0, String? title}) =>
    PetRun(
      host,
      id,
      root: root,
      subagent: subagent,
      since: _t0.add(Duration(seconds: at)),
      title: title,
    );

PetState _pet(PetStateName state, {PetTarget? target, bool foreground = false}) =>
    PetState(state: state, target: target, foreground: foreground, packId: 'deepy');

void main() {
  const a = PetTarget(_local, 'a');

  test('nothing runs and nothing waits: nothing to show', () {
    expect(liveActivityOf(pet: _pet(PetStateName.idle), runs: const [], pending: const []), isNull);
    expect(
      liveActivityOf(
        pet: _pet(PetStateName.sleeping, target: a),
        runs: const [],
        pending: const [],
      ),
      isNull,
    );
  });

  test('a run names its conversation and counts from its start', () {
    final live = liveActivityOf(
      pet: _pet(PetStateName.working, target: a),
      runs: [
        _run('a', at: 5, title: '修登录页'),
        _run('sub', root: 'a', subagent: true, at: 2),
      ],
      pending: const [],
    )!;
    expect(live.kind, LiveKind.running);
    expect(live.title, '修登录页');
    expect(live.text, '正在干活');
    expect(live.chip, '干活中');
    expect(live.publicText, 'DSH 正在干活');
    expect(live.mood, PetStateName.working);
    // The subagent started first: the conversation has been at it since then.
    expect(live.since, _t0.add(const Duration(seconds: 2)));
    expect(live.target, a);
  });

  test('other conversations running are counted, across hosts', () {
    final live = liveActivityOf(
      pet: _pet(PetStateName.thinking, target: a),
      runs: [
        _run('a', title: 'A'),
        _run('b'),
        _run('c', host: _ssh),
      ],
      pending: const [],
    )!;
    expect(live.text, '正在思考 · 3 个对话在跑');
  });

  test('titles are masked, and an untitled one says so', () {
    final secret = liveActivityOf(
      pet: _pet(PetStateName.working, target: a),
      runs: [_run('a', title: '部署 sk-abcdefghijklmnopqrstuvwxyz0123')],
      pending: const [],
    )!;
    expect(secret.title, isNot(contains('qrstuvwxyz0123')));
    final untitled = liveActivityOf(
      pet: _pet(PetStateName.working, target: a),
      runs: [_run('a')],
      pending: const [],
    )!;
    expect(untitled.title, isNotEmpty);
  });

  test('a waiting request says which kind and carries its event', () {
    final approval = liveActivityOf(
      pet: _pet(PetStateName.notification, target: a),
      runs: [_run('a', title: 'A')],
      pending: [const PetPending(host: _local, sessionId: 'a', key: 'e1')],
    )!;
    expect(approval.kind, LiveKind.waiting);
    expect(approval.text, '等你确认');
    expect(approval.chip, '待确认');
    expect(approval.eventId, 'e1');
    expect(approval.since, _t0);

    final question = liveActivityOf(
      pet: _pet(PetStateName.notification, target: a),
      runs: [_run('a', title: 'A')],
      pending: [const PetPending(host: _local, sessionId: 'a', key: 'q1', question: true)],
    )!;
    expect(question.chip, '待回答');
    expect(question.eventId, 'q1');
  });

  test('done and failed show only while the app is away, and only when their notifications are on', () {
    final titles = {a: '修登录页'};
    final done = liveActivityOf(
      pet: _pet(PetStateName.attention, target: a),
      runs: const [],
      pending: const [],
      titles: titles,
    )!;
    expect(done.kind, LiveKind.done);
    expect(done.title, '修登录页');
    expect(done.chip, '完成');
    expect(done.since, isNull);

    final failed = liveActivityOf(
      pet: _pet(PetStateName.error, target: a),
      runs: const [],
      pending: const [],
      titles: titles,
    )!;
    expect(failed.kind, LiveKind.failed);

    expect(
      liveActivityOf(
        pet: _pet(PetStateName.attention, target: a, foreground: true),
        runs: const [],
        pending: const [],
      ),
      isNull,
    );
    expect(
      liveActivityOf(
        pet: _pet(PetStateName.attention, target: a),
        runs: const [],
        pending: const [],
        showDone: false,
      ),
      isNull,
    );
    // Another conversation still runs: back to that.
    final other = liveActivityOf(
      pet: _pet(PetStateName.attention, target: a, foreground: true),
      runs: [_run('b', title: 'B')],
      pending: const [],
    )!;
    expect(other.kind, LiveKind.running);
  });

  test('titles are remembered from runs, newest kept', () {
    final titles = <PetTarget, String>{};
    learnLiveTitles(titles, [_run('a', title: 'A'), _run('sub', root: 'a', subagent: true, title: 'A'), _run('b')]);
    expect(titles, {a: 'A'});
    learnLiveTitles(titles, [for (var i = 0; i < 40; i++) _run('s$i', title: 'S$i')], max: 32);
    expect(titles.length, 32);
    expect(titles.containsKey(a), isFalse);
    expect(titles[const PetTarget(_local, 's39')], 'S39');
  });

  test('the push carries the pet and the conversation the way native reads it', () {
    final live = liveActivityOf(
      pet: _pet(PetStateName.working, target: a),
      runs: [_run('a', title: 'A')],
      pending: const [],
    )!;
    final map = LivePush(enabled: true, packId: 'deepy', activity: live).toMap();
    expect(map['enabled'], true);
    expect(map['packId'], 'deepy');
    final activity = map['activity']! as Map<String, Object?>;
    expect(activity['kind'], 'running');
    expect(activity['mood'], 'working');
    expect(activity['sessionId'], 'a');
    expect(activity['host'], _local.encode());
    expect(activity['sinceMs'], _t0.millisecondsSinceEpoch);
    expect(const LivePush(enabled: false).toMap(), {'enabled': false});
  });
}
