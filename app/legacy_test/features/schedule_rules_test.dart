// The run-time builder's logic: the Host's cron dialect, the official zh
// descriptions, builder shapes, drafts read from stored tasks, the rules a
// save sends, validation and the next runs (in real IANA zones).

import 'package:dsh_app/ui/features/schedule_editor/cron.dart';
import 'package:dsh_app/ui/features/schedule_editor/schedule_draft.dart';
import 'package:dsh_app/ui/features/schedule_editor/time_zones.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Saturday 2026-10-24 15:20 in Shanghai.
final _now = DateTime.utc(2026, 10, 24, 7, 20);
const _sh = 'Asia/Shanghai';

ScheduleTask _task(String kind, Map<String, Object?> fields) => ScheduleTask.fromJson({
  'id': 'sch-1',
  'sessionId': 's1',
  'kind': kind,
  'title': '日报',
  'prompt': '写日报',
  'status': 'active',
  'scheduledAt': '2026-10-25T01:00:00.000Z',
  ...fields,
})!;

void main() {
  setUpAll(ensureTimeZones);

  group('cron dialect', () {
    test('accepts what the Host accepts', () {
      for (final ok in [
        '* * * * *',
        '0 9 * * 1-5',
        '*/15 * * * *',
        '0 9 1,15 * *',
        '30 8-18/2 * 1-6 0,7',
        '0 0 * * 7',
      ]) {
        expect(parseCron(ok), isA<ParsedCron>(), reason: ok);
      }
    });

    test('refuses names, out-of-range values, wrong field counts, padding', () {
      final cases = {
        '0 9 * * MON': '第 5 段（星期）写法不对',
        '0 9 32 * *': '第 3 段（日期）写法不对',
        '60 * * * *': '第 1 段（分钟）写法不对',
        '0 9 * *': '需要 5 段，现在是 4 段',
        ' 0 9 * * *': '首尾不能有空格',
        '0 9 5-1 * *': '第 3 段（日期）写法不对',
        '*/0 * * * *': '第 1 段（分钟）写法不对',
        '': '填写 5 段 Cron 表达式',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final result = parseCron(key);
        expect(result, isA<CronError>(), reason: key);
        expect((result as CronError).message, value, reason: key);
      }
    });

    test('folds Sunday 7 onto 0', () {
      expect(tryParseCron('0 9 * * 7')!.daysOfWeek.values, [0]);
    });

    test('describes with the official zh sentences', () {
      final cases = {
        '0 9 * * 1-5': '周一至周五 09:00',
        '*/15 * * * *': '每 15 分钟',
        '* * * * *': '每分钟',
        '0 * * * *': '每小时',
        '0 */2 * * *': '每 2 小时',
        '5 * * * *': '每天 每小时的第 5 分钟',
        '0 9 1 * *': '每月 1 日 09:00',
        '0 9 1 * 1': '每月 1 日或周一 09:00',
        '30 8 * * 1,3': '周一、周三 08:30',
        '0 9 * 1,7 *': '每天（一月、七月） 09:00',
        '0 9-17 * * *': '每天 09 至 17 点的第 0 分钟',
        '0 9,18 * * *': '每天 09:00、18:00',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(cronPreview(tryParseCron(key)!), value, reason: key);
      }
    });

    test('shapes round-trip through their expression', () {
      final shapes = <CronShape>[
        const MinutelyShape(15),
        const HourlyShape(2, 30),
        const DailyShape(9, 0),
        const WeeklyShape([1, 2, 3, 4, 5], 9, 0),
        const WeeklyShape([6, 7], 10, 30),
        const MonthlyShape([1, 2, 3, 15], 8, 0),
      ];
      final expressions = [for (final s in shapes) cronShapeExpression(s)];
      expect(expressions, [
        '*/15 * * * *',
        '30 */2 * * *',
        '0 9 * * *',
        '0 9 * * 1-5',
        '30 10 * * 0,6',
        '0 8 1-3,15 * *',
      ]);
      for (final (i, e) in expressions.indexed) {
        final back = recognizeCronShape(tryParseCron(e)!);
        expect(back.runtimeType, shapes[i].runtimeType, reason: e);
      }
      expect(recognizeCronShape(tryParseCron('0 9 1 * 1')!), isNull, reason: 'both day fields restrict');
    });
  });

  group('drafts from stored tasks', () {
    test('daily keeps its zone and seconds', () {
      final d = ScheduleDraft.fromTask(
        _task('daily', {'time': '07:15:30.000', 'timeZone': 'Europe/Berlin'}),
        deviceZone: _sh,
        now: _now,
      );
      expect(d.kind, RepeatKind.daily);
      expect(d.clock, '07:15:30');
      expect(d.timeZone, 'Europe/Berlin');
      expect(d.describe(), '每天 07:15:30');
    });

    test('weekly Mon–Fri opens as 工作日; other sets as 每周', () {
      final workdays = ScheduleDraft.fromTask(
        _task('weekly', {
          'time': '09:00:00.000',
          'timeZone': _sh,
          'weekdays': [1, 2, 3, 4, 5],
        }),
        deviceZone: _sh,
        now: _now,
      );
      expect(workdays.kind, RepeatKind.weekdays);
      expect(workdays.describe(), '每个工作日 09:00');
      final some = ScheduleDraft.fromTask(
        _task('weekly', {
          'time': '18:30:00.000',
          'timeZone': _sh,
          'weekdays': [1, 3, 5],
        }),
        deviceZone: _sh,
        now: _now,
      );
      expect(some.kind, RepeatKind.weekly);
      expect(some.describe(), '每周一、三、五 18:30');
    });

    test('cron opens as the shape it states, else stays 高级', () {
      ScheduleDraft cron(String e) =>
          ScheduleDraft.fromTask(_task('cron', {'expression': e, 'timeZone': _sh}), deviceZone: _sh, now: _now);
      expect(cron('0 9 1,15 * *').kind, RepeatKind.monthly);
      expect(cron('0 9 1,15 * *').monthDays, {1, 15});
      expect(cron('30 8 * * 1-5').kind, RepeatKind.weekdays);
      expect(cron('*/30 * * * *').kind, RepeatKind.cron, reason: 'aligned, not a fixed rate');
      expect(cron('0 9 1 * 1').kind, RepeatKind.cron);
    });

    test('fixed rate picks its unit', () {
      ScheduleDraft every(int s) =>
          ScheduleDraft.fromTask(_task('every', {'everySeconds': s}), deviceZone: _sh, now: _now);
      expect((every(7200).interval, every(7200).unit), (2, IntervalUnit.hour));
      expect((every(1800).interval, every(1800).unit), (30, IntervalUnit.minute));
      expect((every(90).interval, every(90).unit), (90, IntervalUnit.second));
      expect(every(3600).describe(), '每小时');
    });

    test('one-shot reads its instant in the device zone', () {
      final d = ScheduleDraft.fromTask(
        _task('at', {'scheduledAt': '2026-12-01T02:00:00.000Z'}),
        deviceZone: _sh,
        now: _now,
      );
      expect(d.kind, RepeatKind.once);
      expect((d.date, d.hour, d.minute), (DateTime.utc(2026, 12, 1), 10, 0));
      expect(d.describe(now: _now), '仅一次 · 12月1日 10:00');
    });
  });

  group('what a save sends', () {
    final base = ScheduleDraft.initial(timeZone: _sh, now: _now);

    test('each repeat choice maps to a Host rule', () {
      expect(base.toTiming()!.toChange(), {
        'kind': 'daily',
        'daily': {'time': '09:00:00', 'time_zone': _sh},
      });
      expect(base.withKind(RepeatKind.weekdays).toTiming()!.toChange(), {
        'kind': 'weekly',
        'weekly': {
          'time': '09:00:00',
          'time_zone': _sh,
          'weekdays': [1, 2, 3, 4, 5],
        },
      });
      expect(base.copyWith(kind: RepeatKind.monthly, monthDays: {15, 1}).toTiming()!.toChange(), {
        'kind': 'cron',
        'cron': {'expression': '0 9 1,15 * *', 'time_zone': _sh},
      });
      expect(base.copyWith(kind: RepeatKind.interval, interval: 30, unit: IntervalUnit.minute).toTiming()!.toChange(), {
        'kind': 'every',
        'every_seconds': 1800,
      });
      expect(
        base
            .copyWith(kind: RepeatKind.once, date: DateTime.utc(2026, 10, 26), hour: 8, minute: 5)
            .toTiming()!
            .toChange(),
        {
          'kind': 'at',
          'at': {'date': '2026-10-26', 'time': '08:05:00', 'time_zone': _sh},
        },
      );
      expect(base.copyWith(kind: RepeatKind.cron, expression: '0 9 * * MON').toTiming(), isNull);
      expect(base.copyWith(kind: RepeatKind.cron, expression: ' 0  9 * * 1-5 ').toTiming()!.toChange(), {
        'kind': 'cron',
        'cron': {'expression': '0 9 * * 1-5', 'time_zone': _sh},
      });
    });

    test('create arguments carry exactly one selector', () {
      expect(scheduleCreateArguments(title: '日报', prompt: '写日报', timing: const EveryTiming(3600)), {
        'title': '日报',
        'prompt': '写日报',
        'every_seconds': 3600,
      });
    });

    test('entering 高级 writes the rule; leaving reads it back', () {
      final weekly = base.copyWith(kind: RepeatKind.weekly, weekdays: {1, 3}, hour: 8, minute: 30);
      final cron = weekly.withKind(RepeatKind.cron);
      expect(cron.expression, '30 8 * * 1,3');
      final back = cron.copyWith(expression: '45 7 * * 2,4').withKind(RepeatKind.weekly);
      expect((back.hour, back.minute), (7, 45));
      expect(back.weekdays, {2, 4});
    });
  });

  group('validation', () {
    final base = ScheduleDraft.initial(timeZone: _sh, now: _now);

    test('short reasons', () {
      expect(base.validate(_now), isNull);
      expect(base.copyWith(kind: RepeatKind.weekly, weekdays: {}).validate(_now), '至少选一天');
      expect(
        base.copyWith(kind: RepeatKind.interval, interval: 30, unit: IntervalUnit.second).validate(_now),
        '至少 1 分钟',
      );
      expect(
        base.copyWith(kind: RepeatKind.once, date: DateTime.utc(2026, 10, 24), hour: 9, minute: 0).validate(_now),
        '选一个以后的时间',
      );
      expect(base.copyWith(kind: RepeatKind.cron, expression: '0 0 31 2 *').validate(_now), '这个表达式不会运行');
      expect(base.copyWith(kind: RepeatKind.cron, expression: '0 9 * *').validate(_now), '需要 5 段，现在是 4 段');
      expect(base.copyWith(timeZone: 'Mars/Base').validate(_now), '时区不可用');
    });
  });

  group('next runs', () {
    final base = ScheduleDraft.initial(timeZone: _sh, now: _now);
    String fmt(List<DateTime> runs, [String zone = _sh]) => runs.map((r) => formatRun(r, zone, _now)).join(' / ');

    test('weekdays skip the weekend', () {
      expect(
        fmt(base.withKind(RepeatKind.weekdays).nextRuns(_now)),
        '10月26日 周一 09:00 / 10月27日 周二 09:00 / 10月28日 周三 09:00',
      );
    });

    test('daily starts tomorrow once today has passed', () {
      expect(fmt(base.nextRuns(_now)), '明天 09:00 / 10月26日 周一 09:00 / 10月27日 周二 09:00');
      expect(fmt(base.copyWith(hour: 18).nextRuns(_now)), '今天 18:00 / 明天 18:00 / 10月26日 周一 18:00');
    });

    test('monthly skips months without the day', () {
      final d = base.copyWith(kind: RepeatKind.monthly, monthDays: {31});
      expect(fmt(d.nextRuns(_now)), '10月31日 周六 09:00 / 12月31日 周四 09:00 / 2027年1月31日 周日 09:00');
    });

    test('other zones resolve through their own rules', () {
      // 09:00 in New York is 21:00 in Shanghai until 1 November, then 22:00.
      final ny = base.copyWith(timeZone: 'America/New_York');
      expect(fmt(ny.nextRuns(_now, count: 3)), '今天 21:00 / 明天 21:00 / 10月26日 周一 21:00');
      final later = DateTime.utc(2026, 11, 2);
      expect(ny.nextRuns(later, count: 1).single, DateTime.utc(2026, 11, 2, 14));
    });

    test('fixed rate counts from the save, or from the committed target', () {
      final every = base.copyWith(kind: RepeatKind.interval, interval: 2, unit: IntervalUnit.hour);
      expect(every.nextRuns(_now), [
        _now.add(const Duration(hours: 2)),
        _now.add(const Duration(hours: 4)),
        _now.add(const Duration(hours: 6)),
      ]);
      final anchor = DateTime.utc(2026, 10, 24, 8);
      expect(every.nextRuns(_now, anchor: anchor).first, anchor);
    });

    test('cron in a zone', () {
      final d = base.copyWith(kind: RepeatKind.cron, expression: '30 8 * * 1-5');
      expect(fmt(d.nextRuns(_now)), '10月26日 周一 08:30 / 10月27日 周二 08:30 / 10月28日 周三 08:30');
    });

    test('one-shot runs once', () {
      final d = base.copyWith(kind: RepeatKind.once, date: DateTime.utc(2026, 10, 25), hour: 10, minute: 0);
      expect(fmt(d.nextRuns(_now)), '明天 10:00');
    });
  });

  group('time zones', () {
    test('offset labels and city names', () {
      expect(formatUtcOffset(const Duration(hours: 8)), 'UTC+08:00');
      expect(formatUtcOffset(const Duration(hours: -3, minutes: -30)), 'UTC−03:30');
      expect(zoneCity('Asia/Shanghai'), '上海');
      expect(zoneCity('Asia/Kathmandu'), 'Kathmandu');
      final zones = allZones(at: _now);
      expect(zones.any((z) => z.name == 'UTC'), isTrue);
      expect(zones.any((z) => z.name.startsWith('Etc/')), isFalse);
      final sh = zones.firstWhere((z) => z.name == _sh);
      expect(sh.offsetLabel, 'UTC+08:00');
      expect(sh.matches('上海'), isTrue);
      expect(sh.matches('shanghai'), isTrue);
      expect(sh.matches('+08'), isTrue);
    });
  });
}
