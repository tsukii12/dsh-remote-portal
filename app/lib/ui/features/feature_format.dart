// Chinese wording for the native mirrors of official DSH Web pages: schedule
// rules, job states, preset names. Rule wording follows the official
// `dsh-client-ui-schedule` / `dsh-client-ui-permission-presets` /
// `dsh-client-ui-agent-preset` copy where it exists.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_error_text.dart';
import '../chat/run_info.dart';
import 'schedule_editor/schedule_draft.dart' show taskRuleText;

/// A short reason for a failed request, or null when there is nothing worth
/// saying; host diagnostics stay in the debug log.
String? featureErrorReason(Object error) {
  debugPrint('Feature request failed: $error');
  return engineErrorReason(error);
}

/// 「没能删除」, or 「没能删除：原因」 when there is one.
String featureErrorText(String title, Object error) {
  final reason = featureErrorReason(error);
  return reason == null ? title : appL10n.featuresErrorReason(title, reason);
}

/// How often a task runs, in the one rule wording the editor preview uses
/// too (`ruleText`): `每天 09:00`, `每个工作日 09:00`, `每周一、三 18:30`,
/// `每 2 小时`, `仅一次`, cron rules in words.
String scheduleRule(ScheduleTask task) => taskRuleText(task);

/// A moment in the device's time zone, relative to [now]: `今天 09:00`,
/// `明天 09:00`, `昨天 21:15`, `10月25日 09:00`, `2025年1月3日 09:00`.
String formatWhen(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final clock = DateTime.now();
  final today = now ?? clock;
  final hm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final dayDiff = DateTime(
    local.year,
    local.month,
    local.day,
  ).difference(DateTime(today.year, today.month, today.day)).inDays;
  return switch (dayDiff) {
    0 => appL10n.featuresTodayTime(hm),
    1 => appL10n.featuresTomorrowTime(hm),
    -1 => appL10n.featuresYesterdayTime(hm),
    _ when local.year == today.year => '${appL10n.monthDay(local)} $hm',
    _ => '${appL10n.featuresYearDate(local.year, appL10n.monthDay(local))} $hm',
  };
}

/// One list line under a task's title.
String scheduleSummary(ScheduleTask task, {DateTime? now}) {
  final rule = scheduleRule(task);
  if (task.active) {
    final next = task.scheduledAt;
    return next == null ? rule : appL10n.featuresScheduleSummaryNext(rule, formatWhen(next, now: now));
  }
  final last = task.lastDeliveredAt;
  return last == null ? appL10n.featuresEnded : appL10n.featuresScheduleSummaryEnded(formatWhen(last, now: now));
}

/// `运行中`, `正在停止`, `已完成`, `已停止`, `失败`.
String jobStatusLabel(String status) => switch (status) {
  'running' => appL10n.commonRunning,
  'stopping' => appL10n.commonStopping,
  'completed' => appL10n.commonCompleted,
  'killed' => appL10n.commonStopped,
  'failed' => appL10n.commonFailed,
  _ => status,
};

/// Under a job's command line: status and time.
String jobSummary(JobInfo job, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final started = job.startedAt;
  final parts = <String>[jobStatusLabel(job.status)];
  if (started != null) {
    final end = job.finishedAt ?? clock;
    final span = formatSpan(end.difference(started));
    parts.add(job.live ? appL10n.featuresJobElapsed(span) : appL10n.featuresJobDuration(span));
  }
  if (job.progress case final p? when p.trim().isNotEmpty) parts.add(p.trim());
  return parts.join(' · ');
}

/// Official names of the built-in permission presets.
String permissionName(String value, [String? hostName]) => switch (value) {
  'read-only' => appL10n.featuresPermissionReadOnly,
  'workspace-write' => appL10n.featuresPermissionWorkspaceWrite,
  'danger-full-access' => appL10n.featuresPermissionFullAccess,
  'auto' => appL10n.featuresPermissionAutoReview,
  'custom' => appL10n.featuresPermissionCustom,
  _ => hostName == null || hostName.isEmpty ? value : hostName,
};

/// One line under each permission preset.
String? permissionHint(String value, [String? hostDescription]) => switch (value) {
  'read-only' => appL10n.featuresPermissionReadOnlyHint,
  'workspace-write' => appL10n.featuresPermissionWorkspaceWriteHint,
  'danger-full-access' => appL10n.featuresPermissionFullAccessHint,
  'auto' => appL10n.featuresPermissionAutoReviewHint,
  _ => hostDescription,
};

/// Official names of the built-in agent presets.
String agentPresetName(AgentPresetInfo preset) =>
    switch (preset.id) {
      'standard' => appL10n.featuresPresetStandard,
      'ptc' => appL10n.featuresPresetPtc,
      'minimal' => appL10n.featuresPresetMinimal,
      'cordis' => appL10n.featuresPresetCreator,
      _ => null,
    } ??
    (preset.name?.trim().isNotEmpty ?? false ? preset.name!.trim() : preset.id);

/// Official descriptions of the built-in agent presets.
String? agentPresetDescription(AgentPresetInfo preset) =>
    switch (preset.id) {
      'standard' => appL10n.featuresPresetStandardDescription,
      'ptc' => appL10n.featuresPresetPtcDescription,
      'minimal' => appL10n.featuresPresetMinimalDescription,
      'cordis' => appL10n.featuresPresetCreatorDescription,
      _ => null,
    } ??
    preset.description;
