// Chinese copy for the results of DSH's built-in slash commands. The English
// strings are the official packages' own (0.2.1-rc.2: command-compact,
// command-goal, command-feedback, plan-mode, permission-presets); only a
// whole-result match is replaced, so a plugin command with the same name keeps
// its own text.

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../features/feature_format.dart' show permissionName;
import '../usage_sheet.dart' show formatTokens;

/// 内置斜杠指令执行结果的中文说法;认不出的(插件、新版本的措辞)返回 null,
/// 照原文显示。
String? commandResultCopy(CommandNotice notice) {
  final text = notice.text?.trim();
  if (text == null) return null;
  switch (notice.name) {
    case 'compact':
      final match = RegExp(r'^Compacted (\d+) history items \(~(\d+) tokens\)\.$').firstMatch(text);
      if (match != null) {
        return appL10n.chatCommandCompacted(int.parse(match[1]!), formatTokens(int.parse(match[2]!)));
      }
      return _compact[text];
    case 'plan':
      return _plan[text];
    case 'permission':
      String name(String value) =>
          // l10n:keep Strip a legacy suffix from permission display text.
          permissionName(value).replaceAll('（实验性）', '');
      final selected = RegExp(r'^preset ([\w.-]+)$').firstMatch(text);
      if (selected != null) {
        return appL10n.chatCommandPermissionChanged(name(selected[1]!));
      }
      final current = RegExp(r'^current preset ([\w.-]+) \(available: ([\w.-]+(?:, [\w.-]+)*)\)$').firstMatch(text);
      if (current != null) {
        return appL10n.chatCommandCurrentPermission(name(current[1]!));
      }
      final unknown = RegExp(r'^unknown preset "([^"\n]+)" \(available: ([\w.-]+(?:, [\w.-]+)*)\)$').firstMatch(text);
      if (unknown != null) return appL10n.chatCommandUnknownPermission;
      return null;
    case 'goal':
      return _goalCopy(text);
    case 'feedback':
      if (text == 'Feedback text is required. Usage: /feedback <text>') {
        return appL10n.chatCommandFeedbackRequired;
      }
      if (RegExp(r'^Feedback recorded for session [^\n]+\nAnonymous user: [^\n]+\.$').hasMatch(text)) {
        return appL10n.chatCommandFeedbackSubmitted;
      }
      return null;
  }
  return null;
}

Map<String, String> get _compact => {
  'No compactable history yet.': appL10n.chatCommandNothingToCompact,
  'Compaction cancelled.': appL10n.chatCommandCompactionCancelled,
  'Compaction is unavailable because this process has an active compaction, or the agent is not idle.':
      appL10n.chatCommandCompactionBusy,
  'Compaction finished, but the session could not be saved.': appL10n.chatCommandCompactedSaveFailed,
  'Usage: /compact (no arguments)': appL10n.chatCommandCompactUsage,
  'The history selected for compaction changed before it could be replaced. The attempt is recorded in the session log.':
      appL10n.chatCommandHistoryChanged,
  'Compaction could not produce a useful summary. The attempt is recorded in the session log.':
      appL10n.chatCommandCompactionFailed,
  'Compaction did not finish cleanly; some session history may have changed. Inspect the current session state before retrying.':
      appL10n.chatCommandCompactionIncomplete,
};

Map<String, String> get _plan => {
  'Plan mode on. Use /plan off to leave.': appL10n.chatCommandPlanEnabled,
  'Entering plan mode (applies from the next step). Use /plan off to leave.': appL10n.chatCommandPlanEnabling,
  'Plan mode off.': appL10n.chatCommandPlanDisabled,
  'Leaving plan mode (applies from the next step).': appL10n.chatCommandPlanDisabling,
  'Plan mode entry cancelled.': appL10n.chatCommandPlanCancelled,
  'Plan mode is already inactive.': appL10n.chatCommandPlanInactive,
  'Attachments cannot accompany /plan off.': appL10n.chatCommandPlanNoAttachments,
};

const _goalUsage = 'Usage: /goal [<objective>|clear|edit <objective>|pause|resume]';

String? _goalCopy(String text) {
  final fixed = <String, String>{
    'No goal is currently set.\n$_goalUsage': appL10n.chatCommandNoGoal,
    'Goal editing requires a replacement objective.\n$_goalUsage': appL10n.chatCommandGoalRequired,
    'Attachments only accompany a goal objective: /goal <objective> or /goal edit <objective>.':
        appL10n.chatCommandGoalAttachments,
    'No goal to clear.': appL10n.chatCommandNoGoal,
    'Goal cleared.': appL10n.chatCommandGoalCleared,
    'The goal command is not valid for the current state. Run /goal to view available commands.':
        appL10n.chatCommandGoalInvalid,
    for (final action in ['edit', 'pause', 'resume'])
      'No goal is currently set; /goal $action requires one. $_goalUsage': appL10n.chatCommandNoGoal,
  };
  if (fixed[text] case final copy?) return copy;
  if (RegExp(
    r'^A goal is already (active|paused|blocked|complete)\. Use /goal edit <objective> to change it or /goal clear before replacing it\.$',
  ).hasMatch(text)) {
    return appL10n.chatCommandGoalExists;
  }
  final match = RegExp(
    r'^(Goal(?: created| updated| paused| resumed)?)\nStatus: (active|paused|blocked|complete)\n'
    r'(?:Blocker: [^\n]+\n)?Objective: ([\s\S]+)\nRounds: (\d+)/(\d+)\n'
    r'Activation: [\w-]+\n\nCommands: (/goal edit <objective>, /goal (?:pause|resume), /goal clear|/goal <objective>, /goal clear)$',
  ).firstMatch(text);
  if (match == null) return null;
  final title = switch (match[1]) {
    'Goal created' => appL10n.chatCommandGoalCreated,
    'Goal updated' => appL10n.chatCommandGoalUpdated,
    'Goal paused' => appL10n.chatCommandGoalPaused,
    'Goal resumed' => appL10n.chatCommandGoalResumed,
    _ => appL10n.chatCommandCurrentGoal,
  };
  final status = switch (match[2]) {
    'active' => appL10n.commonInProgress,
    'paused' => appL10n.commonPaused,
    'blocked' => appL10n.chatCommandGoalBlocked,
    _ => appL10n.commonCompleted,
  };
  final objective = match[3]!.replaceAll(RegExp(r'\r?\n'), ' ');
  return appL10n.chatCommandGoalSummary(title, objective, status, int.parse(match[4]!), int.parse(match[5]!));
}
