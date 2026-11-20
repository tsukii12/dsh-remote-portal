// Wording of the header clock and its sheet. The official surfaces pair each
// run's time on the reader's clock with its distance (`nextRunParts`:
// `9月19日 15:51（3小时后）`); here in the app's own voice: `今天 21:30`,
// `3 小时后`, `已逾期 5 分钟`.

import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../features/schedule_editor/schedule_draft.dart';
import '../features/schedule_editor/time_zones.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// A run on this phone's clock, relative to [now]: `今天 21:30`,
/// `明天 09:00`, `昨天 21:15`, `周五 09:00` (later this week), `10月30日 09:00`,
/// `2027年1月4日 09:00`.
String scheduleStamp(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = now.toLocal();
  final clock = '${_two(local.hour)}:${_two(local.minute)}';
  // Whole calendar days apart, immune to a daylight-saving hour.
  final days = DateTime.utc(
    local.year,
    local.month,
    local.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  return switch (days) {
    0 => appL10n.viewScheduleToday(clock),
    1 => appL10n.viewScheduleTomorrow(clock),
    -1 => appL10n.viewScheduleYesterday(clock),
    > 1 && < 7 => appL10n.viewScheduleWeekday(appL10n.viewScheduleWeekdayName(local.weekday.toString()), clock),
    _ when local.year == today.year => appL10n.viewScheduleDate(appL10n.monthDay(local), clock),
    _ => appL10n.viewScheduleYearDate(local.year.toString(), appL10n.monthDay(local), clock),
  };
}

/// How long until [scheduleStamp] may read differently: the next midnight on
/// this phone's clock.
Duration untilNextDay(DateTime now) {
  final local = now.toLocal();
  final midnight = DateTime(local.year, local.month, local.day + 1);
  return midnight.difference(local);
}

const _dayMs = 86400000;
const _units = [3600, 60, 1];

/// The largest whole unit [seconds] reaches (seconds below one).
int _unitFor(double seconds) => _units.firstWhere((unit) => seconds >= unit, orElse: () => _units.last);

/// Calendar days from [from] to [to] on this phone's clock (at least one).
int _calendarDays(DateTime from, DateTime to) {
  final a = from.toLocal();
  final b = to.toLocal();
  final days = DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
  return math.max(1, days);
}

/// How far [at] is from [now]: `3 小时后`, `45 分钟后`, `已逾期 5 分钟`;
/// `即将运行` on the dot.
///
/// Under a day it is the official `formatScheduleRelative`: the largest whole
/// unit, a distance ahead rounded up, an overdue one down, never below one.
/// From a day on it counts calendar days (`3 天后`), so it agrees with
/// [scheduleStamp]'s 「明天 / 周二」 instead of rounding 30 hours to two days.
String scheduleRelative(DateTime at, DateTime now) {
  final ms = at.difference(now).inMilliseconds;
  if (ms == 0) return appL10n.viewScheduleDue;
  final abs = ms.abs();
  if (abs >= _dayMs) {
    final days = ms > 0 ? _calendarDays(now, at) : _calendarDays(at, now);
    return ms > 0 ? appL10n.viewScheduleDaysAhead(days) : appL10n.viewScheduleDaysOverdue(days);
  }
  final seconds = abs / 1000;
  final unit = _unitFor(seconds);
  final value = math.max(1, ms > 0 ? (seconds / unit).ceil() : (seconds / unit).floor());
  return switch (unit) {
    3600 => ms > 0 ? appL10n.viewScheduleHoursAhead(value) : appL10n.viewScheduleHoursOverdue(value),
    60 => ms > 0 ? appL10n.viewScheduleMinutesAhead(value) : appL10n.viewScheduleMinutesOverdue(value),
    1 => ms > 0 ? appL10n.viewScheduleSecondsAhead(value) : appL10n.viewScheduleSecondsOverdue(value),
    _ => throw StateError('Unknown time unit'),
  };
}

/// How long until [scheduleRelative] reads differently (at least 1 ms).
Duration scheduleRelativeChangesIn(DateTime at, DateTime now) {
  final ms = at.difference(now).inMilliseconds;
  if (ms == 0) return const Duration(milliseconds: 1);
  final abs = ms.abs();
  if (abs >= _dayMs) {
    // Calendar days turn at midnight; ahead, under a day it reads in hours.
    var wait = untilNextDay(now).inMilliseconds;
    if (ms > 0) wait = math.min(wait, abs - _dayMs + 1);
    return Duration(milliseconds: math.max(1, wait));
  }
  final unit = _unitFor(abs / 1000) * 1000;
  final int wait;
  if (ms > 0) {
    // Ahead: `k` (rounded up) holds until the distance is down to k − 1
    // units; at exactly one unit it is about to drop to the next unit down.
    final k = (abs / unit).ceil();
    final boundary = k > 1 ? (k - 1) * unit : (unit > 1000 ? unit - 1 : 0);
    wait = abs - boundary;
  } else {
    // Overdue: the shown count (rounded down, at least one) grows at the
    // next whole unit; unit changes (up to a day) fall on those boundaries.
    final shown = math.max(1, abs ~/ unit);
    wait = (shown + 1) * unit - abs;
  }
  return Duration(milliseconds: math.max(1, wait));
}

/// The next [count] runs of [task]: the Host's committed target first, then
/// what its rule gives after it. A one-shot has the one. [deviceZone] reads
/// a rule that stores no zone of its own.
List<DateTime> scheduleNextRuns(ScheduleTask task, {required String deviceZone, int count = 3}) {
  final first = task.scheduledAt;
  if (first == null) return const [];
  if (!task.recurring || isCustomRule(task) || count <= 1) return [first];
  final draft = ScheduleDraft.fromTask(task, deviceZone: deviceZone, now: first);
  return [first, ...draft.nextRuns(first, count: count - 1, anchor: task.kind == 'every' ? first : null)];
}

/// The rule as the editor words it (`每天 09:00`, `每 2 小时`), naming its
/// zone when that clock isn't this phone's: `每天 09:00（东京 · UTC+09:00）`.
String scheduleRuleLine(ScheduleTask task, {String? deviceZone, DateTime? at}) {
  final rule = taskRuleText(task);
  final zone = task.timeZone;
  if (zone == null || deviceZone == null || zone == deviceZone) return rule;
  final offset = zoneOffset(zone, at: at);
  // Another name for the same clock reads the same.
  if (offset == null || offset == zoneOffset(deviceZone, at: at)) return rule;
  return appL10n.viewScheduleZone(rule, zoneCity(zone), formatUtcOffset(offset));
}

/// What the header clock reads out: `自动化任务：日报提醒，下次今天 21:30`,
/// or `2 个自动化任务，下次今天 21:30`.
String headerScheduleLabel(List<ScheduleTask> tasks, DateTime now) {
  final next = tasks.firstOrNull?.scheduledAt;
  if (tasks.length == 1) {
    final title = tasks.single.title;
    final name = title.isEmpty ? appL10n.viewScheduleUntitled : title;
    return next == null
        ? appL10n.viewScheduleSingleLabel(name)
        : appL10n.viewScheduleSingleNextLabel(name, scheduleStamp(next, now));
  }
  return next == null
      ? appL10n.viewScheduleCountLabel(tasks.length)
      : appL10n.viewScheduleCountNextLabel(tasks.length, scheduleStamp(next, now));
}
