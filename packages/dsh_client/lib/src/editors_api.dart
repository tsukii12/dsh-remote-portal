/// What the native automation-task and Agent-preset editors need beyond
/// [FeaturesApi]: timing edits (`schedule/update` with `change`), the
/// `schedule_create` selector the creation request carries, the bundle that
/// declares a preset, and `agentPresets/select`.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-schedule` update and
/// create validators, `dsh-agent-preset-registry` Remote typings,
/// `dsh-plugin-manager` `listBundles`) and a throwaway `dsh web`.
///
/// The Host has no create Remote for either: a task is made by the model's
/// `schedule_create` tool in the conversation that will receive it, and a
/// preset by a bundle the creator mode (`cordis` preset) writes and installs.
library;

import 'features_api.dart';
import 'json.dart';
import 'plugins_api.dart';
import 'session_api.dart';

/// One run-time rule in the shape `schedule/update` (`change`) and
/// `schedule_create` (one selector member) accept.
sealed class ScheduleTiming {
  const ScheduleTiming();

  /// `at`, `every`, `daily`, `weekly` or `cron`.
  String get kind;

  /// The selector value (`{time, time_zone}`, seconds, …).
  Object get selector;

  /// The selector's member name in `schedule_create`.
  String get selectorKey => switch (kind) {
    'every' => 'every_seconds',
    _ => kind,
  };

  /// `ScheduleTimingChange` for `schedule/update`.
  Map<String, Object?> toChange() => {'kind': kind, selectorKey: selector};

  /// The single selector member of a `schedule_create` request.
  Map<String, Object?> toCreateSelector() => {selectorKey: selector};

  @override
  bool operator ==(Object other) => other is ScheduleTiming && _equal(toChange(), other.toChange());

  @override
  int get hashCode => Object.hash(kind, selector.toString());
}

bool _equal(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _equal(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// One-shot at a local date and time in [timeZone] (`LocalAtInput`); the
/// Host stores only the resulting instant.
final class AtTiming extends ScheduleTiming {
  const AtTiming({required this.date, required this.time, required this.timeZone});

  /// `YYYY-MM-DD`.
  final String date;

  /// `HH:mm:ss`.
  final String time;
  final String timeZone;

  @override
  String get kind => 'at';

  @override
  Object get selector => {'date': date, 'time': time, 'time_zone': timeZone};
}

/// Fixed rate, counted from the save; the Host refuses less than 60 seconds
/// (`frequency_too_high`).
final class EveryTiming extends ScheduleTiming {
  const EveryTiming(this.seconds);

  final int seconds;

  static const minSeconds = 60;

  @override
  String get kind => 'every';

  @override
  Object get selector => seconds;
}

final class DailyTiming extends ScheduleTiming {
  const DailyTiming({required this.time, required this.timeZone});

  /// `HH:mm:ss`.
  final String time;
  final String timeZone;

  @override
  String get kind => 'daily';

  @override
  Object get selector => {'time': time, 'time_zone': timeZone};
}

final class WeeklyTiming extends ScheduleTiming {
  const WeeklyTiming({required this.time, required this.timeZone, required this.weekdays});

  final String time;
  final String timeZone;

  /// ISO weekdays, Monday 1 through Sunday 7, ascending and unique.
  final List<int> weekdays;

  @override
  String get kind => 'weekly';

  @override
  Object get selector => {'time': time, 'time_zone': timeZone, 'weekdays': weekdays};
}

/// Five-field Vixie cron (`minute hour day-of-month month day-of-week`)
/// interpreted in [timeZone].
final class CronTiming extends ScheduleTiming {
  const CronTiming({required this.expression, required this.timeZone});

  final String expression;
  final String timeZone;

  @override
  String get kind => 'cron';

  @override
  Object get selector => {'expression': expression, 'time_zone': timeZone};
}

/// The full `schedule_create` arguments for [title], [prompt] and [timing].
Map<String, Object?> scheduleCreateArguments({
  required String title,
  required String prompt,
  required ScheduleTiming timing,
}) => {'title': title, 'prompt': prompt, ...timing.toCreateSelector()};

/// Built-in preset ids (`dsh-web-app` presets): never removable, and the
/// override of one replaces its whole plugin list.
const builtInAgentPresets = {'standard', 'ptc', 'minimal', 'cordis'};

/// The Loader module every preset declaration row names.
const agentPresetModule = '@deepseek-ai/dsh-agent-preset';

extension EditorsApi on DshClient {
  /// `schedule/update` with the stored record as `expected`: any of the
  /// name, the instruction and the run time ([timing]; omitted keeps the
  /// committed target). A rule kind may change; the Host recomputes the
  /// target. Rejections come back as [ScheduleUpdate.code]
  /// (`schedule_conflict`, `invalid_rule`, `not_future`, …).
  Future<ScheduleUpdate> editSchedule(
    ScheduleTask task, {
    String? title,
    String? prompt,
    ScheduleTiming? timing,
  }) async {
    if (task.usesTargetProtocol) {
      return updateTargetSchedule(task, {'title': ?title, 'prompt': ?prompt, 'timing': ?timing?.toChange()});
    }
    final value = asMapOrEmpty(
      await rpc.call('schedule/update', {
        'request': {
          'sessionId': task.sessionId,
          'id': task.id,
          'expected': task.record,
          'title': ?title,
          'prompt': ?prompt,
          'change': ?timing?.toChange(),
        },
      }),
    );
    final record = asMap(value['record']);
    if (record != null && value['code'] == null) {
      return ScheduleUpdate(
        updated: value['updated'] == true,
        task: ScheduleTask.fromJson({
          ...record,
          'sessionId': task.sessionId,
          'status': task.active ? 'active' : 'inactive',
          if (task.lastDeliveredAt case final last?) 'lastDelivery': {'deliveredAt': last.toUtc().toIso8601String()},
        }),
      );
    }
    return ScheduleUpdate(updated: false, code: asString(value['code']), message: asString(value['message']));
  }

  /// `agentPresets/select`: switches a blank session's preset (how the
  /// official creator entry turns a new conversation into 创造模式).
  Future<String> selectAgentPreset(String sessionId, String preset) async {
    final value = await rpc.call('agentPresets/select', {'agentId': sessionId, 'agentPreset': preset});
    return asString(value) ?? preset;
  }

  /// The removable profile bundle whose patch declares preset [id]: a
  /// `preset-<id>` row of [agentPresetModule]. Null for built-in presets,
  /// shipped bundles and declarations no single bundle owns.
  Future<PluginBundle?> agentPresetBundle(String id) async {
    if (builtInAgentPresets.contains(id)) return null;
    final owners = [
      for (final bundle in await listBundles())
        if (bundle.removable &&
            !bundle.official &&
            !bundle.optional &&
            bundle.rows.any((r) => r.moduleName == agentPresetModule && r.rowId == 'preset-$id'))
          bundle,
    ];
    return owners.length == 1 ? owners.single : null;
  }
}
