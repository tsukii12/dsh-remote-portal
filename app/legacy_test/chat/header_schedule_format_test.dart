// Wording of the header clock and its sheet: run times on the phone's clock,
// distances in the official rounding, when each next reads differently, the
// next runs a rule gives, and the rule line with a foreign zone.

import 'package:dsh_app/ui/chat/header_schedule_format.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Saturday afternoon, on this machine's clock.
final _now = DateTime(2026, 10, 24, 15, 20);

ScheduleTask _task(
  String kind, {
  String title = '日报提醒',
  DateTime? next,
  String? time,
  String? zone,
  List<int> weekdays = const [],
  int? every,
  String? expression,
}) => ScheduleTask(
  id: 'sch-$kind',
  sessionId: 's1',
  kind: kind,
  title: title,
  prompt: '整理一下',
  active: true,
  record: {'id': 'sch-$kind', 'kind': kind},
  scheduledAt: next,
  time: time,
  timeZone: zone,
  weekdays: weekdays,
  everySeconds: every,
  expression: expression,
);

void main() {
  group('scheduleStamp', () {
    final cases = {
      DateTime(2026, 10, 24, 21, 30): '今天 21:30',
      DateTime(2026, 10, 25, 9): '明天 09:00',
      DateTime(2026, 10, 23, 21, 15): '昨天 21:15',
      DateTime(2026, 10, 27, 9): '周二 09:00',
      DateTime(2026, 10, 30, 9): '周五 09:00',
      DateTime(2026, 10, 31, 9): '10月31日 09:00',
      DateTime(2026, 10, 20, 9): '10月20日 09:00',
      DateTime(2027, 1, 4, 9): '2027年1月4日 09:00',
    };
    for (final MapEntry(key: at, value: text) in cases.entries) {
      test(text, () => expect(scheduleStamp(at, _now), text));
    }

    test('a UTC instant reads on the local clock', () {
      final at = DateTime(2026, 10, 24, 21, 30);
      expect(scheduleStamp(at.toUtc(), _now), '今天 21:30');
    });

    test('the day turns at local midnight', () {
      expect(untilNextDay(_now), const Duration(hours: 8, minutes: 40));
      final lastSecond = DateTime(2026, 10, 24, 23, 59, 59);
      expect(untilNextDay(lastSecond), const Duration(seconds: 1));
    });
  });

  group('scheduleRelative', () {
    final cases = {
      const Duration(hours: 3): '3 小时后',
      const Duration(hours: 2, minutes: 30): '3 小时后',
      const Duration(hours: 1): '1 小时后',
      const Duration(minutes: 59): '59 分钟后',
      const Duration(hours: 23, minutes: 30): '24 小时后',
      // From a day on: calendar days, agreeing with 「明天 / 周二」.
      const Duration(days: 1, seconds: 1): '1 天后',
      const Duration(hours: 30): '1 天后',
      const Duration(days: 2, hours: 17, minutes: 40): '3 天后',
      const Duration(seconds: 10): '10 秒后',
      const Duration(milliseconds: 300): '1 秒后',
      const Duration(minutes: -5): '已逾期 5 分钟',
      const Duration(minutes: -5, seconds: -59): '已逾期 5 分钟',
      const Duration(hours: -26): '已逾期 1 天',
      const Duration(milliseconds: -500): '已逾期 1 秒',
      Duration.zero: '即将运行',
    };
    for (final MapEntry(key: offset, value: text) in cases.entries) {
      test('$offset → $text', () {
        expect(scheduleRelative(_now.add(offset), _now), text);
      });
    }
  });

  group('scheduleRelativeChangesIn', () {
    test('lands exactly on the next change', () {
      final offsets = [
        const Duration(hours: 2, minutes: 30),
        const Duration(hours: 1),
        const Duration(hours: 1, seconds: 1),
        const Duration(minutes: 59, seconds: 30),
        const Duration(seconds: 30),
        const Duration(milliseconds: 400),
        const Duration(days: 3, hours: 4),
        const Duration(hours: 24, minutes: 30),
        const Duration(hours: 23, minutes: 30),
        Duration.zero,
        const Duration(milliseconds: -500),
        const Duration(minutes: -5, seconds: -30),
        const Duration(minutes: -59),
        const Duration(hours: -23, minutes: -59),
      ];
      for (final offset in offsets) {
        final at = _now.add(offset);
        final wait = scheduleRelativeChangesIn(at, _now);
        expect(wait, greaterThan(Duration.zero), reason: '$offset');
        final before = _now.add(wait - const Duration(milliseconds: 1));
        expect(scheduleRelative(at, before), scheduleRelative(at, _now), reason: '$offset: still the same just before');
        expect(
          scheduleRelative(at, _now.add(wait)),
          isNot(scheduleRelative(at, _now)),
          reason: '$offset: changed at the boundary',
        );
      }
    });

    test('hours ahead wait for the hour, not a second', () {
      final at = _now.add(const Duration(hours: 2, minutes: 30));
      expect(scheduleRelativeChangesIn(at, _now), const Duration(minutes: 30));
    });

    test('days ahead wait for midnight', () {
      final at = DateTime(2026, 10, 27, 9);
      expect(scheduleRelativeChangesIn(at, _now), const Duration(hours: 8, minutes: 40));
    });
  });

  group('scheduleNextRuns', () {
    test('a custom rule has only the Host\'s committed run and reads 自定义', () {
      final task = ScheduleTask.fromJson({
        'id': 'r',
        'kind': 'rrule',
        'title': 'r',
        'prompt': 'r',
        'rrule': 'DTSTART;TZID=Asia/Shanghai:20261025T090000\nRRULE:FREQ=DAILY;COUNT=3',
        'scheduledAt': '2026-10-25T01:00:00.000Z',
        'target': {'kind': 'new'},
        'status': 'active',
      })!;
      expect(task.recurring, isTrue);
      expect(scheduleNextRuns(task, deviceZone: 'Asia/Shanghai'), [DateTime.parse('2026-10-25T01:00:00.000Z')]);
      expect(scheduleRuleLine(task), '自定义');
    });

    test('daily: the committed target, then the next days', () {
      final runs = scheduleNextRuns(
        _task('daily', time: '21:30:00.000', zone: 'Asia/Shanghai', next: DateTime.utc(2026, 10, 24, 13, 30)),
        deviceZone: 'Asia/Shanghai',
      );
      expect(runs, [
        DateTime.utc(2026, 10, 24, 13, 30),
        DateTime.utc(2026, 10, 25, 13, 30),
        DateTime.utc(2026, 10, 26, 13, 30),
      ]);
    });

    test('weekly: only the chosen days', () {
      final runs = scheduleNextRuns(
        _task('weekly', time: '09:00', zone: 'Asia/Shanghai', weekdays: [1, 3, 5], next: DateTime.utc(2026, 10, 26, 1)),
        deviceZone: 'Asia/Shanghai',
      );
      expect(runs, [DateTime.utc(2026, 10, 26, 1), DateTime.utc(2026, 10, 28, 1), DateTime.utc(2026, 10, 30, 1)]);
    });

    test('every: steps from the committed target', () {
      final runs = scheduleNextRuns(
        _task('every', every: 7200, next: DateTime.utc(2026, 10, 24, 8)),
        deviceZone: 'Asia/Shanghai',
      );
      expect(runs, [DateTime.utc(2026, 10, 24, 8), DateTime.utc(2026, 10, 24, 10), DateTime.utc(2026, 10, 24, 12)]);
    });

    test('cron: weekdays and monthly days', () {
      final weekdays = scheduleNextRuns(
        _task('cron', expression: '0 9 * * 1-5', zone: 'Asia/Shanghai', next: DateTime.utc(2026, 10, 30, 1)),
        deviceZone: 'Asia/Shanghai',
      );
      expect(weekdays, [DateTime.utc(2026, 10, 30, 1), DateTime.utc(2026, 11, 2, 1), DateTime.utc(2026, 11, 3, 1)]);
      final monthly = scheduleNextRuns(
        _task('cron', expression: '0 9 1,15 * *', zone: 'Asia/Shanghai', next: DateTime.utc(2026, 11, 1, 1)),
        deviceZone: 'Asia/Shanghai',
      );
      expect(monthly, [DateTime.utc(2026, 11, 1, 1), DateTime.utc(2026, 11, 15, 1), DateTime.utc(2026, 12, 1, 1)]);
    });

    test('a one-shot has its one run; no target, none', () {
      final at = DateTime.utc(2026, 10, 25, 2);
      expect(scheduleNextRuns(_task('at', next: at), deviceZone: 'Asia/Shanghai'), [at]);
      expect(scheduleNextRuns(_task('daily', time: '09:00'), deviceZone: 'UTC'), isEmpty);
    });
  });

  group('scheduleRuleLine', () {
    test('names a zone only when its clock differs from the phone', () {
      final shanghai = _task('daily', time: '21:30', zone: 'Asia/Shanghai');
      expect(scheduleRuleLine(shanghai, deviceZone: 'Asia/Shanghai'), '每天 21:30');
      // Same offset, another name: the same clock.
      expect(scheduleRuleLine(shanghai, deviceZone: 'Asia/Hong_Kong', at: _now), '每天 21:30');
      final tokyo = _task('daily', time: '09:00', zone: 'Asia/Tokyo');
      expect(scheduleRuleLine(tokyo, deviceZone: 'Asia/Shanghai', at: _now), '每天 09:00（东京 · UTC+09:00）');
      expect(scheduleRuleLine(tokyo), '每天 09:00');
    });

    test('interval and one-shot rules carry no zone', () {
      expect(scheduleRuleLine(_task('every', every: 7200), deviceZone: 'UTC'), '每 2 小时');
      expect(scheduleRuleLine(_task('at', next: DateTime.utc(2026, 10, 25)), deviceZone: 'UTC'), '仅一次');
    });
  });

  test('headerScheduleLabel names one task, counts more', () {
    final one = _task('daily', next: DateTime(2026, 10, 24, 21, 30));
    expect(headerScheduleLabel([one], _now), '自动化任务：日报提醒，下次今天 21:30');
    final other = _task('every', title: '检查构建');
    expect(headerScheduleLabel([one, other], _now), '2 个自动化任务，下次今天 21:30');
    expect(headerScheduleLabel([_task('daily', title: '')], _now), '自动化任务：未命名任务');
  });
}
