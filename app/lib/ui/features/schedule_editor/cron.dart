// SPDX-FileCopyrightText: 2026 DeepSeek
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// The five-field cron dialect the Host accepts, ported from the official
// `dsh-client-ui-schedule` (`task-cron.js`): parse an expression exactly as
// `@deepseek-ai/dsh-schedule` would (or refuse it), describe it in one
// Chinese sentence with the official zh copy, and recognise / spell the
// common shapes the builder edits. The Host still canonicalises and picks
// occurrences; this only keeps the form honest before a save.

import '../../../l10n/l10n.dart';

/// Field bounds, in `minute hour day-of-month month day-of-week` order.
List<({String name, int min, int max, int count, int? fold})> get _fields => [
  (name: appL10n.featuresCronMinute, min: 0, max: 59, count: 60, fold: null),
  (name: appL10n.featuresCronHour, min: 0, max: 23, count: 24, fold: null),
  (name: appL10n.featuresDate, min: 1, max: 31, count: 31, fold: null),
  (name: appL10n.featuresCronMonth, min: 1, max: 12, count: 12, fold: null),
  // Sunday is 0 or 7; 7 folds onto 0.
  (name: appL10n.featuresCronWeekday, min: 0, max: 7, count: 7, fold: 7),
];

final _step = RegExp(r'^\*/(\d+)$');
final _element = RegExp(r'^(\d+)(?:-(\d+))?(?:/(\d+))?$');

/// One parsed field: matched values, Vixie's star flag, coverage.
class CronField {
  const CronField(this.values, {required this.starred, required this.full});

  /// Unique ascending values; Sunday 7 folded onto 0.
  final List<int> values;

  /// The text starts with `*` (Vixie `DOM_STAR` / `DOW_STAR`).
  final bool starred;

  /// Every value the field can take.
  final bool full;

  bool get unrestricted => starred && full;
}

/// A parsed expression, in evaluation order.
class ParsedCron {
  const ParsedCron(this.minutes, this.hours, this.daysOfMonth, this.months, this.daysOfWeek);

  final CronField minutes;
  final CronField hours;
  final CronField daysOfMonth;
  final CronField months;

  /// Sunday 0 through Saturday 6.
  final CronField daysOfWeek;

  /// Whether a local date matches, under Vixie day-of-month / day-of-week
  /// semantics (either restricted day field suffices only when neither text
  /// starts with `*`). [weekday] is ISO (Monday 1 … Sunday 7).
  bool matchesDate(int month, int day, int weekday) {
    if (!months.values.contains(month)) return false;
    final dom = daysOfMonth.values.contains(day);
    final dow = daysOfWeek.values.contains(weekday % 7);
    if (!daysOfMonth.starred && !daysOfWeek.starred) return dom || dow;
    return dom && dow;
  }
}

/// Why [parseCron] refused an expression, in one short line.
class CronError {
  const CronError(this.message);
  final String message;
}

List<int>? _elementValues(String element, ({String name, int min, int max, int count, int? fold}) spec) {
  if (element.isEmpty) return null;
  List<int> range(int from, int to, int step) => [for (var v = from; v <= to; v += step) v];
  if (element == '*') return range(spec.min, spec.max, 1);
  if (element.startsWith('*')) {
    final step = int.tryParse(_step.firstMatch(element)?.group(1) ?? '');
    return step == null || step < 1 ? null : range(spec.min, spec.max, step);
  }
  final m = _element.firstMatch(element);
  if (m == null) return null;
  final start = int.tryParse(m.group(1)!);
  if (start == null || start < spec.min || start > spec.max) return null;
  final endText = m.group(2);
  final stepText = m.group(3);
  if (endText == null) return stepText == null ? [start] : null;
  final end = int.tryParse(endText);
  if (end == null || end < spec.min || end > spec.max || start > end) return null;
  final step = stepText == null ? 1 : int.tryParse(stepText);
  if (step == null || step < 1) return null;
  return range(start, end, step);
}

/// Parses [expression] in the Host's dialect: `*`, `n`, `a-b`, `*/n`,
/// `a-b/n` and comma lists of those; no names, no `?`/`L`/`W`. Returns the
/// parsed rule or the reason the Host would refuse it.
Object parseCron(String expression) {
  if (expression.trim().isEmpty) return CronError(appL10n.featuresCronRequired);
  if (expression.trim() != expression) return CronError(appL10n.featuresCronWhitespace);
  final parts = expression.split(RegExp(r'\s+'));
  if (parts.length != 5) return CronError(appL10n.featuresCronFieldCount(parts.length));
  final parsed = <CronField>[];
  for (final (i, raw) in parts.indexed) {
    final spec = _fields[i];
    final matched = <int>{};
    for (final element in raw.split(',')) {
      final values = _elementValues(element, spec);
      if (values == null) return CronError(appL10n.featuresCronInvalidField(i + 1, spec.name));
      for (final v in values) {
        matched.add(v == spec.fold ? spec.min : v);
      }
    }
    final values = matched.toList()..sort();
    parsed.add(CronField(values, starred: raw.startsWith('*'), full: values.length == spec.count));
  }
  return ParsedCron(parsed[0], parsed[1], parsed[2], parsed[3], parsed[4]);
}

/// [parseCron] when it succeeds.
ParsedCron? tryParseCron(String expression) => switch (parseCron(expression)) {
  final ParsedCron p => p,
  _ => null,
};

// ── Description (official zh copy: `frequency-locales.js`) ──────────────────

List<String> get _weekdayZh => [
  appL10n.featuresWeekdayMon,
  appL10n.featuresWeekdayTue,
  appL10n.featuresWeekdayWed,
  appL10n.featuresWeekdayThu,
  appL10n.featuresWeekdayFri,
  appL10n.featuresWeekdaySat,
  appL10n.featuresWeekdaySun,
];
List<String> get _monthZh => [
  appL10n.featuresMonthJan,
  appL10n.featuresMonthFeb,
  appL10n.featuresMonthMar,
  appL10n.featuresMonthApr,
  appL10n.featuresMonthMay,
  appL10n.featuresMonthJun,
  appL10n.featuresMonthJul,
  appL10n.featuresMonthAug,
  appL10n.featuresMonthSep,
  appL10n.featuresMonthOct,
  appL10n.featuresMonthNov,
  appL10n.featuresMonthDec,
];
String get _join => appL10n.featuresListSeparator;
const _timeListLimit = 6;

String _two(int v) => v.toString().padLeft(2, '0');

List<List<int>> _runs(List<int> values) {
  final runs = <List<int>>[];
  for (final v in values) {
    if (runs.isNotEmpty && runs.last.last + 1 == v) {
      runs.last.add(v);
    } else {
      runs.add([v]);
    }
  }
  return runs;
}

/// `周一至周五`, `周一、周三`.
String _weekdayText(List<int> values) {
  String name(int iso) => appL10n.featuresWeekdayName(_weekdayZh[iso - 1]);
  final iso = [for (final v in values) v == 0 ? 7 : v]..sort();
  return _runs(iso)
      .map(
        (run) => run.length >= 3
            ? appL10n.featuresCronWeekdayRange(name(run.first), name(run.last))
            : run.map(name).join(_join),
      )
      .join(_join);
}

String _monthSuffix(List<int> months) =>
    months.length == 12 ? '' : appL10n.featuresCronMonthSuffix(months.map((m) => _monthZh[m - 1]).join(_join));

/// Uniform step of a field covering its whole range, from [min].
int? _fullRangeStep(List<int> values, int min, int max) {
  if (values.length < 2 || values.first != min) return null;
  final step = values[1] - values[0];
  for (var i = 1; i < values.length; i++) {
    if (values[i] - values[i - 1] != step) return null;
  }
  return values.last + step > max ? step : null;
}

({bool everyDay, String text}) _dayText(ParsedCron p) {
  final months = _monthSuffix(p.months.values);
  final weekdays = _weekdayText(p.daysOfWeek.values);
  final days = p.daysOfMonth.values.join(_join);
  final dom = p.daysOfMonth;
  final dow = p.daysOfWeek;
  if (dom.starred || dow.starred) {
    if (dom.full && dow.full) return (everyDay: months.isEmpty, text: appL10n.featuresCronEveryDay(months));
    if (dom.full) return (everyDay: false, text: '$weekdays$months');
    if (dow.full) return (everyDay: false, text: appL10n.featuresCronMonthDays(days, months));
    return (everyDay: false, text: appL10n.featuresCronMonthDaysAndWeekdays(days, weekdays, months));
  }
  if (dom.full || dow.full) return (everyDay: months.isEmpty, text: appL10n.featuresCronEveryDay(months));
  return (everyDay: false, text: appL10n.featuresCronMonthDaysOrWeekdays(days, weekdays, months));
}

String _hourText(List<int> values) {
  final hours = values.map(_two).toList();
  return hours.length >= 2 && values.last - values.first == values.length - 1
      ? appL10n.featuresCronHourRange(hours.first, hours.last)
      : hours.join(_join);
}

({bool interval, String text}) _timeText(ParsedCron p) {
  final step = p.minutes.unrestricted ? null : _fullRangeStep(p.minutes.values, 0, 59);
  final minutes = p.minutes.values;
  if (p.hours.unrestricted) {
    if (p.minutes.unrestricted) return (interval: true, text: appL10n.featuresEveryMinute);
    if (step != null && step >= 2) return (interval: true, text: appL10n.featuresCronEveryMinutes(step));
    if (minutes.length == 1 && minutes.first == 0) return (interval: true, text: appL10n.featuresEveryHour);
    return (interval: false, text: appL10n.featuresCronHourlyMinutes(minutes.join(_join)));
  }
  final hours = _hourText(p.hours.values);
  if (p.minutes.unrestricted) return (interval: false, text: appL10n.featuresCronHoursEveryMinute(hours));
  if (step != null && step >= 2) return (interval: false, text: appL10n.featuresCronHoursEveryMinutes(hours, step));
  final hourStep = _fullRangeStep(p.hours.values, 0, 23);
  if (minutes.length == 1 && minutes.first == 0 && hourStep != null && hourStep >= 2) {
    return (interval: true, text: appL10n.featuresCronEveryHours(hourStep));
  }
  final times = [
    for (final h in p.hours.values)
      for (final m in minutes) '${_two(h)}:${_two(m)}',
  ];
  return (
    interval: false,
    text: times.length <= _timeListLimit
        ? times.join(_join)
        : appL10n.featuresCronHoursMinutes(hours, minutes.join(_join)),
  );
}

/// One sentence for [p], as the official page words it: `周一至周五 09:00`,
/// `每 15 分钟`, `每月 1 日 09:00`.
String cronPreview(ParsedCron p) {
  final day = _dayText(p);
  final time = _timeText(p);
  return day.everyDay && time.interval ? time.text : '${day.text} ${time.text}';
}

// ── Builder shapes ───────────────────────────────────────────────────────────

/// The structured shapes the builder edits (official `CronBuilderState`).
sealed class CronShape {
  const CronShape();
}

final class MinutelyShape extends CronShape {
  const MinutelyShape(this.step);
  final int step;
}

final class HourlyShape extends CronShape {
  const HourlyShape(this.step, this.minute);
  final int step;
  final int minute;
}

final class DailyShape extends CronShape {
  const DailyShape(this.hour, this.minute);
  final int hour;
  final int minute;
}

final class WeeklyShape extends CronShape {
  const WeeklyShape(this.weekdays, this.hour, this.minute);

  /// ISO weekdays, ascending.
  final List<int> weekdays;
  final int hour;
  final int minute;
}

final class MonthlyShape extends CronShape {
  const MonthlyShape(this.days, this.hour, this.minute);
  final List<int> days;
  final int hour;
  final int minute;
}

/// The shape [p] states, or null when only the raw expression can hold it.
CronShape? recognizeCronShape(ParsedCron p) {
  if (!p.months.full) return null;
  final minuteStep = p.minutes.unrestricted ? 1 : _fullRangeStep(p.minutes.values, 0, 59);
  final hourStep = p.hours.unrestricted ? 1 : _fullRangeStep(p.hours.values, 0, 23);
  final minute = p.minutes.values.length == 1 ? p.minutes.values.first : null;
  final hour = p.hours.values.length == 1 ? p.hours.values.first : null;
  if (p.daysOfWeek.unrestricted) {
    if (p.daysOfMonth.unrestricted) {
      if (minuteStep != null && p.hours.full) return MinutelyShape(minuteStep);
      if (minute != null && hourStep != null) return HourlyShape(hourStep, minute);
      if (minute != null && hour != null) return DailyShape(hour, minute);
      return null;
    }
    if (minute == null || hour == null) return null;
    return MonthlyShape(p.daysOfMonth.values, hour, minute);
  }
  if (!p.daysOfMonth.unrestricted || minute == null || hour == null) return null;
  return WeeklyShape([for (final v in p.daysOfWeek.values) v == 0 ? 7 : v]..sort(), hour, minute);
}

String _runField(List<int> values) =>
    _runs(values).map((run) => run.length >= 3 ? '${run.first}-${run.last}' : run.join(',')).join(',');

/// The expression [shape] saves as; [recognizeCronShape] reads it back as the
/// same shape.
String cronShapeExpression(CronShape shape) => switch (shape) {
  MinutelyShape(:final step) => step == 1 ? '* * * * *' : '*/$step * * * *',
  HourlyShape(:final step, :final minute) => step == 1 ? '$minute * * * *' : '$minute */$step * * *',
  DailyShape(:final hour, :final minute) => '$minute $hour * * *',
  WeeklyShape(:final weekdays, :final hour, :final minute) =>
    '$minute $hour * * ${_runField(({for (final d in weekdays) d % 7}.toList()..sort()))}',
  MonthlyShape(:final days, :final hour, :final minute) =>
    '$minute $hour ${_runField(days.toSet().toList()..sort())} * *',
};
