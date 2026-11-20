// The run-time builder's state: a friendly repeat choice (每天 / 工作日 /
// 每周 / 每月 / 间隔 / 仅一次 / 高级) that maps onto the Host's rule kinds,
// with validation, a one-line description and the next runs. Monthly rules
// save as cron (the Host has no monthly kind), like the official builder.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../../../l10n/l10n.dart';
import 'cron.dart';
import 'time_zones.dart';

enum RepeatKind { daily, weekdays, weekly, monthly, interval, once, cron }

/// Labels of the repeat choices, in display order.
Map<RepeatKind, String> get repeatLabels => {
  RepeatKind.daily: appL10n.featuresRepeatDaily,
  RepeatKind.weekdays: appL10n.featuresRepeatWeekdays,
  RepeatKind.weekly: appL10n.featuresRepeatWeekly,
  RepeatKind.monthly: appL10n.featuresRepeatMonthly,
  RepeatKind.interval: appL10n.featuresRepeatInterval,
  RepeatKind.once: appL10n.featuresRepeatOnce,
  RepeatKind.cron: appL10n.featuresRepeatAdvanced,
};

enum IntervalUnit {
  second(1),
  minute(60),
  hour(3600);

  const IntervalUnit(this.seconds);
  final int seconds;

  String get label => switch (this) {
    IntervalUnit.second => appL10n.featuresIntervalSeconds,
    IntervalUnit.minute => appL10n.featuresCronMinute,
    IntervalUnit.hour => appL10n.featuresCronHour,
  };
}

List<String> get weekdayNames => [
  appL10n.featuresWeekdayMon,
  appL10n.featuresWeekdayTue,
  appL10n.featuresWeekdayWed,
  appL10n.featuresWeekdayThu,
  appL10n.featuresWeekdayFri,
  appL10n.featuresWeekdaySat,
  appL10n.featuresWeekdaySun,
];

String _two(int v) => v.toString().padLeft(2, '0');

@immutable
class ScheduleDraft {
  const ScheduleDraft({
    required this.kind,
    required this.hour,
    required this.minute,
    this.second = 0,
    this.weekdays = const {1, 2, 3, 4, 5},
    this.monthDays = const {1},
    this.interval = 1,
    this.unit = IntervalUnit.hour,
    required this.date,
    this.expression = '0 9 * * 1-5',
    required this.timeZone,
  });

  /// A new task: every day at 09:00 in [timeZone]; the one-shot date starts
  /// tomorrow, the weekly day on today's weekday.
  factory ScheduleDraft.initial({required String timeZone, required DateTime now}) {
    final local = inZone(now, timeZone) ?? now;
    final today = DateTime.utc(local.year, local.month, local.day);
    return ScheduleDraft(
      kind: RepeatKind.daily,
      hour: 9,
      minute: 0,
      weekdays: {today.weekday},
      monthDays: {local.day},
      date: today.add(const Duration(days: 1)),
      timeZone: timeZone,
    );
  }

  /// The stored rule of [task], read into the builder. Cron rules the builder
  /// can state (daily, weekly, monthly shapes) open as those; the rest stay
  /// 「高级」. One-shots read their target in [deviceZone] (the Host stores
  /// no zone for them).
  factory ScheduleDraft.fromTask(ScheduleTask task, {required String deviceZone, required DateTime now}) {
    final zone = task.timeZone ?? deviceZone;
    final base = ScheduleDraft.initial(timeZone: zone, now: now);
    final (h, m, s) = _clock(task.time);
    switch (task.kind) {
      case 'daily':
        return base.copyWith(kind: RepeatKind.daily, hour: h, minute: m, second: s);
      case 'weekly':
        final days = {...task.weekdays.where((d) => d >= 1 && d <= 7)};
        final kind = _setEquals(days, const {1, 2, 3, 4, 5})
            ? RepeatKind.weekdays
            : days.length == 7
            ? RepeatKind.daily
            : RepeatKind.weekly;
        return base.copyWith(
          kind: kind,
          hour: h,
          minute: m,
          second: s,
          weekdays: kind == RepeatKind.weekly ? days : null,
        );
      case 'cron':
        final expression = task.expression ?? '';
        final parsed = tryParseCron(expression);
        final shape = parsed == null ? null : recognizeCronShape(parsed);
        final cron = base.copyWith(kind: RepeatKind.cron, expression: expression);
        return switch (shape) {
          DailyShape(:final hour, :final minute) => cron.copyWith(kind: RepeatKind.daily, hour: hour, minute: minute),
          WeeklyShape(:final weekdays, :final hour, :final minute) => cron.copyWith(
            kind: _setEquals(weekdays.toSet(), const {1, 2, 3, 4, 5})
                ? RepeatKind.weekdays
                : weekdays.length == 7
                ? RepeatKind.daily
                : RepeatKind.weekly,
            weekdays: weekdays.toSet(),
            hour: hour,
            minute: minute,
          ),
          MonthlyShape(:final days, :final hour, :final minute) => cron.copyWith(
            kind: RepeatKind.monthly,
            monthDays: days.toSet(),
            hour: hour,
            minute: minute,
          ),
          _ => cron,
        };
      case 'every':
        final seconds = task.everySeconds ?? 3600;
        final unit = seconds % 3600 == 0
            ? IntervalUnit.hour
            : seconds % 60 == 0
            ? IntervalUnit.minute
            : IntervalUnit.second;
        return base.copyWith(kind: RepeatKind.interval, interval: seconds ~/ unit.seconds, unit: unit);
      default:
        final target = task.scheduledAt == null ? null : inZone(task.scheduledAt!, zone);
        if (target == null) return base.copyWith(kind: RepeatKind.once);
        return base.copyWith(
          kind: RepeatKind.once,
          date: DateTime.utc(target.year, target.month, target.day),
          hour: target.hour,
          minute: target.minute,
          second: target.second,
        );
    }
  }

  final RepeatKind kind;
  final int hour;
  final int minute;

  /// Kept from a stored rule that has seconds; the builder edits minutes.
  final int second;

  /// ISO weekdays for 每周.
  final Set<int> weekdays;

  /// Days of the month for 每月.
  final Set<int> monthDays;
  final int interval;
  final IntervalUnit unit;

  /// Calendar date (UTC midnight of the local date) for 仅一次.
  final DateTime date;

  /// Raw five-field expression for 高级.
  final String expression;

  /// IANA zone the wall-clock rules use.
  final String timeZone;

  ScheduleDraft copyWith({
    RepeatKind? kind,
    int? hour,
    int? minute,
    int? second,
    Set<int>? weekdays,
    Set<int>? monthDays,
    int? interval,
    IntervalUnit? unit,
    DateTime? date,
    String? expression,
    String? timeZone,
  }) => ScheduleDraft(
    kind: kind ?? this.kind,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    second: second ?? (hour != null || minute != null ? 0 : this.second),
    weekdays: weekdays ?? this.weekdays,
    monthDays: monthDays ?? this.monthDays,
    interval: interval ?? this.interval,
    unit: unit ?? this.unit,
    date: date ?? this.date,
    expression: expression ?? this.expression,
    timeZone: timeZone ?? this.timeZone,
  );

  /// Switches the repeat choice, carrying the clock over; entering 高级
  /// writes the current rule as an expression, leaving it reads one back.
  ScheduleDraft withKind(RepeatKind next) {
    if (next == kind) return this;
    if (next == RepeatKind.cron) {
      final shape = switch (kind) {
        RepeatKind.daily => DailyShape(hour, minute),
        RepeatKind.weekdays => WeeklyShape(const [1, 2, 3, 4, 5], hour, minute),
        RepeatKind.weekly when weekdays.isNotEmpty => WeeklyShape(weekdays.toList()..sort(), hour, minute),
        RepeatKind.monthly when monthDays.isNotEmpty => MonthlyShape(monthDays.toList()..sort(), hour, minute),
        RepeatKind.interval when unit == IntervalUnit.minute && interval >= 1 && interval < 60 && 60 % interval == 0 =>
          MinutelyShape(interval),
        RepeatKind.interval when unit == IntervalUnit.hour && interval >= 1 && interval < 24 && 24 % interval == 0 =>
          HourlyShape(interval, 0),
        _ => DailyShape(hour, minute),
      };
      return copyWith(kind: next, expression: cronShapeExpression(shape));
    }
    if (kind == RepeatKind.cron) {
      final parsed = tryParseCron(expression.trim());
      final shape = parsed == null ? null : recognizeCronShape(parsed);
      final back = switch (shape) {
        DailyShape(:final hour, :final minute) ||
        MonthlyShape(:final hour, :final minute) => copyWith(hour: hour, minute: minute),
        WeeklyShape(:final hour, :final minute, :final weekdays) => copyWith(
          hour: hour,
          minute: minute,
          weekdays: weekdays.toSet(),
        ),
        _ => this,
      };
      return back.copyWith(kind: next, monthDays: shape is MonthlyShape ? shape.days.toSet() : null);
    }
    return copyWith(kind: next);
  }

  /// `HH:mm:ss` of the wall-clock time.
  String get clock => '${_two(hour)}:${_two(minute)}:${_two(second)}';

  /// `09:00`, or `09:00:30` when the stored rule had seconds.
  String get clockLabel => second == 0 ? '${_two(hour)}:${_two(minute)}' : clock;

  int get intervalSeconds => interval * unit.seconds;

  /// Why this can't be saved, or null.
  String? validate(DateTime now) {
    if (kind != RepeatKind.interval && !isKnownZone(timeZone)) return appL10n.featuresZoneUnavailable;
    switch (kind) {
      case RepeatKind.weekly when weekdays.isEmpty:
      case RepeatKind.monthly when monthDays.isEmpty:
        return appL10n.featuresChooseDay;
      case RepeatKind.interval:
        if (interval < 1) return appL10n.featuresIntervalMinimum;
        if (intervalSeconds < EveryTiming.minSeconds) return appL10n.featuresMinimumMinute;
        return null;
      case RepeatKind.once:
        final at = zonedInstant(timeZone, date.year, date.month, date.day, hour, minute, second);
        if (at == null) return appL10n.featuresTimeDoesNotExist;
        if (!at.isAfter(now)) return appL10n.featuresChooseFutureTime;
        return null;
      case RepeatKind.cron:
        final parsed = parseCron(expression.trim());
        if (parsed is CronError) return parsed.message;
        if (nextRuns(now, count: 1).isEmpty) return appL10n.featuresCronNeverRuns;
        return null;
      default:
        return null;
    }
  }

  /// The rule to save; null when [validate] fails.
  ScheduleTiming? toTiming() => switch (kind) {
    RepeatKind.daily => DailyTiming(time: clock, timeZone: timeZone),
    RepeatKind.weekdays => WeeklyTiming(time: clock, timeZone: timeZone, weekdays: const [1, 2, 3, 4, 5]),
    RepeatKind.weekly =>
      weekdays.isEmpty ? null : WeeklyTiming(time: clock, timeZone: timeZone, weekdays: weekdays.toList()..sort()),
    RepeatKind.monthly =>
      monthDays.isEmpty
          ? null
          : CronTiming(
              expression: cronShapeExpression(MonthlyShape(monthDays.toList()..sort(), hour, minute)),
              timeZone: timeZone,
            ),
    RepeatKind.interval => intervalSeconds < EveryTiming.minSeconds ? null : EveryTiming(intervalSeconds),
    RepeatKind.once => AtTiming(
      date: '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}',
      time: clock,
      timeZone: timeZone,
    ),
    RepeatKind.cron =>
      tryParseCron(_normalized) == null ? null : CronTiming(expression: _normalized, timeZone: timeZone),
  };

  String get _normalized => expression.trim().split(RegExp(r'\s+')).join(' ');

  /// [ruleText], plus the date of a one-shot: `仅一次 · 10月25日 09:00`.
  String describe({DateTime? now}) {
    if (kind != RepeatKind.once) return ruleText(this);
    final withYear = now == null || (inZone(now, timeZone)?.year ?? now.year) != date.year;
    final day = appL10n.monthDay(date);
    final label = withYear ? appL10n.featuresYearDate(date.year, day) : day;
    return appL10n.featuresOnceDescription(ruleText(this), label, clockLabel);
  }

  /// The next [count] runs after [now], as UTC instants. [anchor] is the
  /// committed target of an unchanged fixed-rate rule; without it a fixed
  /// rate counts from [now], like a save does.
  List<DateTime> nextRuns(DateTime now, {int count = 3, DateTime? anchor}) {
    final runs = <DateTime>[];
    switch (kind) {
      case RepeatKind.interval:
        final step = Duration(seconds: intervalSeconds);
        if (step.inSeconds < EveryTiming.minSeconds) return runs;
        var next = anchor ?? now.add(step);
        while (!next.isAfter(now)) {
          next = next.add(step);
        }
        for (var i = 0; i < count; i++) {
          runs.add(next.toUtc());
          next = next.add(step);
        }
        return runs;
      case RepeatKind.once:
        final at = zonedInstant(timeZone, date.year, date.month, date.day, hour, minute, second);
        return at != null && at.isAfter(now) ? [at] : runs;
      default:
        break;
    }
    final ParsedCron? cron;
    final List<(int, int, int)> times;
    final int horizonDays;
    switch (kind) {
      case RepeatKind.cron:
        cron = tryParseCron(expression.trim());
        if (cron == null) return runs;
        times = [
          for (final h in cron.hours.values)
            for (final m in cron.minutes.values) (h, m, 0),
        ];
        horizonDays = 366 * 8;
      default:
        cron = null;
        times = [(hour, minute, second)];
        horizonDays = kind == RepeatKind.monthly ? 366 * 2 : 15;
    }
    bool matches(DateTime day) => switch (kind) {
      RepeatKind.daily => true,
      RepeatKind.weekdays => day.weekday <= 5,
      RepeatKind.weekly => weekdays.contains(day.weekday),
      RepeatKind.monthly => monthDays.contains(day.day),
      _ => cron!.matchesDate(day.month, day.day, day.weekday),
    };
    final start = inZone(now, timeZone);
    if (start == null) return runs;
    var day = DateTime.utc(start.year, start.month, start.day);
    for (var i = 0; i < horizonDays && runs.length < count; i++, day = day.add(const Duration(days: 1))) {
      if (!matches(day)) continue;
      for (final (h, m, s) in times) {
        final at = zonedInstant(timeZone, day.year, day.month, day.day, h, m, s);
        if (at == null || !at.isAfter(now)) continue;
        runs.add(at);
        if (runs.length == count) break;
      }
    }
    return runs;
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleDraft &&
      other.kind == kind &&
      other.hour == hour &&
      other.minute == minute &&
      other.second == second &&
      _setEquals(other.weekdays, weekdays) &&
      _setEquals(other.monthDays, monthDays) &&
      other.interval == interval &&
      other.unit == unit &&
      other.date == date &&
      other.expression == expression &&
      other.timeZone == timeZone;

  @override
  int get hashCode => Object.hash(
    kind,
    hour,
    minute,
    second,
    Object.hashAllUnordered(weekdays),
    Object.hashAllUnordered(monthDays),
    interval,
    unit,
    date,
    expression,
    timeZone,
  );
}

bool _setEquals(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);

/// `09:00:30.000` → (9, 0, 30); missing parts are zero.
(int, int, int) _clock(String? time) {
  final parts = (time ?? '09:00').split('.').first.split(':');
  int at(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
  return (at(0).clamp(0, 23), at(1).clamp(0, 59), at(2).clamp(0, 59));
}

/// The one wording of a rule, used by the list, the detail page and the
/// editor preview: `每天 09:00`, `每个工作日 09:00`, `每周一、三 18:30`,
/// `每个周末 10:00`, `每月 1、15 日 09:00`, `每 30 分钟`, `仅一次`; other cron
/// rules in the official sentence (`周一至周五 每 15 分钟`).
String ruleText(ScheduleDraft d) {
  final time = d.clockLabel;
  switch (d.kind) {
    case RepeatKind.daily:
      return appL10n.featuresRuleDaily(time);
    case RepeatKind.weekdays:
      return appL10n.featuresRuleWeekdays(time);
    case RepeatKind.weekly:
      final days = d.weekdays.toList()..sort();
      if (days.isEmpty) return appL10n.featuresRepeatWeekly;
      if (days.length == 7) return appL10n.featuresRuleDaily(time);
      if (_setEquals(days.toSet(), const {1, 2, 3, 4, 5})) return appL10n.featuresRuleWeekdays(time);
      if (_setEquals(days.toSet(), const {6, 7})) return appL10n.featuresRuleWeekends(time);
      return appL10n.featuresRuleWeekly(days.map((d) => weekdayNames[d - 1]).join(appL10n.featuresListSeparator), time);
    case RepeatKind.monthly:
      final days = d.monthDays.toList()..sort();
      return days.isEmpty
          ? appL10n.featuresRepeatMonthly
          : appL10n.featuresRuleMonthly(days.join(appL10n.featuresListSeparator), time);
    case RepeatKind.interval:
      return switch ((d.unit, d.interval)) {
        (IntervalUnit.hour, 1) => appL10n.featuresEveryHour,
        (IntervalUnit.minute, 1) => appL10n.featuresEveryMinute,
        (IntervalUnit.second, _) => appL10n.featuresRuleIntervalSeconds(d.interval),
        (IntervalUnit.minute, _) => appL10n.featuresRuleIntervalMinutes(d.interval),
        (IntervalUnit.hour, _) => appL10n.featuresRuleIntervalHours(d.interval),
      };
    case RepeatKind.once:
      return appL10n.featuresRepeatOnce;
    case RepeatKind.cron:
      final parsed = tryParseCron(d.expression.trim());
      return parsed == null ? appL10n.featuresRepeatAdvanced : cronPreview(parsed);
  }
}

/// A rule the builder can't state: `rrule`, what the 0.2.2 assistant tool
/// writes. Named 「自定义」 as on the official page, and left as stored.
bool isCustomRule(ScheduleTask task) => task.kind == 'rrule';

/// [ruleText] of a stored task.
String taskRuleText(ScheduleTask task) => isCustomRule(task)
    ? appL10n.featuresRepeatCustom
    : ruleText(ScheduleDraft.fromTask(task, deviceZone: task.timeZone ?? 'UTC', now: DateTime.now()));

/// A run time in [zone]'s wall clock, relative to [now]: `今天 09:00`,
/// `明天 09:00`, `10月27日 周一 09:00`, `2027年1月4日 周一 09:00`.
String formatRun(DateTime instant, String zone, DateTime now) {
  final at = inZone(instant, zone);
  final today = inZone(now, zone);
  if (at == null || today == null) return instant.toLocal().toString();
  final day = DateTime.utc(at.year, at.month, at.day);
  final diff = day.difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final clock = '${_two(at.hour)}:${_two(at.minute)}${at.second == 0 ? '' : ':${_two(at.second)}'}';
  final week = appL10n.featuresWeekdayName(weekdayNames[day.weekday - 1]);
  return switch (diff) {
    0 => appL10n.featuresTodayTime(clock),
    1 => appL10n.featuresTomorrowTime(clock),
    _ when at.year == today.year => appL10n.featuresDateWeekdayTime(appL10n.monthDay(at), week, clock),
    _ => appL10n.featuresDateWeekdayTime(appL10n.featuresYearDate(at.year, appL10n.monthDay(at)), week, clock),
  };
}
