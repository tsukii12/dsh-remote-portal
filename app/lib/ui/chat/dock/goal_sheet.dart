// The goal bar's actions: a sheet with the whole goal and 编辑 / 暂停 / 恢复 /
// 清除 (DSH GoalBar's icon actions), the multi-line editor, and the 清除
// confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/goal_dock_state.dart';
import '../../common/app_dialog.dart';
import '../../common/app_sheet.dart';
import '../../common/sheet_title_bar.dart';
import '../../settings/settings_widgets.dart' show SettingsTile;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'goal_bar.dart';

enum GoalAction { edit, pause, resume, clear }

/// The goal sheet of [sessionId]; resolves to the action picked, or null.
/// It follows the goal live and closes by itself when the goal goes away.
Future<GoalAction?> showGoalSheet(BuildContext context, String sessionId) =>
    showAppSheet<GoalAction>(context, isScrollControlled: true, builder: (_) => GoalSheet(sessionId: sessionId));

/// 弹层:标题「目标」→ 完整的目标文字 → 一行状态(进行中 · 第 3 / 256 轮;
/// 受阻时下面是原因)→ 一组操作。
class GoalSheet extends ConsumerWidget {
  const GoalSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    ref.listen(goalDockProvider(sessionId), (_, next) {
      if (next == null && context.mounted) Navigator.of(context).maybePop();
    });
    final goal = ref.watch(goalDockProvider(sessionId));
    if (goal == null) return const SizedBox(height: 120);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final look = GoalLook.of(goal, colors: colors, dsh: dsh);
    final rounds = goal.projection.roundsStarted;
    final max = goal.goal.maxGoalRounds;
    final status = [
      look.status,
      if (rounds > 0) max > 0 ? l10n.chatGoalRoundLimit(rounds, max) : l10n.chatGoalRound(rounds),
    ].join(' · ');
    final enabled = goal.canChange && !goal.busy;
    void pick(GoalAction action) => Navigator.of(context).pop(action);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.chatGoal),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(goal.goal.objective, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.6)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(look.icon, size: 16, color: look.iconColor),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          status,
                          style: AppType.tabular(
                            theme.textTheme.bodySmall!.copyWith(color: look.stateColor ?? dsh.textTertiary),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (goal.goal.blockedReason case final reason?) ...[
                    const SizedBox(height: 4),
                    Text(reason.message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
                  ],
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: enabled ? 1 : 0.4,
              duration: AppMotion.of(context, AppMotion.quick),
              child: SheetGroup(
                children: [
                  SettingsTile(
                    tinted: false,
                    chevron: false,
                    icon: AppIcons.edit,
                    title: l10n.chatEditGoal,
                    onTap: enabled ? () => pick(GoalAction.edit) : null,
                  ),
                  if (goal.canPause)
                    SettingsTile(
                      tinted: false,
                      chevron: false,
                      icon: AppIcons.pause,
                      title: l10n.chatPauseGoal,
                      subtitle: l10n.chatPauseGoalHint,
                      onTap: enabled ? () => pick(GoalAction.pause) : null,
                    ),
                  if (goal.canResume)
                    SettingsTile(
                      tinted: false,
                      chevron: false,
                      icon: AppIcons.play,
                      title: l10n.chatResumeGoal,
                      subtitle: l10n.chatResumeGoalHint,
                      onTap: enabled ? () => pick(GoalAction.resume) : null,
                    ),
                  SettingsTile(
                    tinted: false,
                    chevron: false,
                    danger: true,
                    icon: AppIcons.delete,
                    title: l10n.chatClearGoal,
                    onTap: enabled ? () => pick(GoalAction.clear) : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

/// 「编辑目标」:多行输入,保留换行;空的或没改时不能保存。Resolves to the
/// new text (trimmed), or null.
Future<String?> showGoalEditor(BuildContext context, {required String initial}) => showAppDialog<String>(
  context: context,
  builder: (_) => _GoalEditor(initial: initial),
);

class _GoalEditor extends StatefulWidget {
  const _GoalEditor({required this.initial});

  final String initial;

  @override
  State<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends State<_GoalEditor> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection.collapsed(offset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave {
    final text = _controller.text.trim();
    return text.isNotEmpty && text != widget.initial.trim();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.chatEditGoal),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 6,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration(hintText: l10n.chatGoalHint),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _canSave ? () => Navigator.pop(context, _controller.text.trim()) : null,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// 「清除目标？」,目标文字作正文;确认键是危险色。
Future<bool> confirmClearGoal(BuildContext context, String objective) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.chatClearGoalTitle),
      content: Text(objective, maxLines: 4, overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.commonClear),
        ),
      ],
    ),
  );
  return ok == true;
}

/// What tapping the goal bar does: the sheet, then the picked action
/// (editor / confirmation first), a toast when the Host says no.
Future<void> runGoalActions(BuildContext context, WidgetRef ref, String sessionId) async {
  final action = await showGoalSheet(context, sessionId);
  if (action == null || !context.mounted) return;
  final controller = ref.read(goalDockProvider(sessionId).notifier);
  final goal = ref.read(goalDockProvider(sessionId));
  if (goal == null) return;
  final String? problem;
  switch (action) {
    case GoalAction.edit:
      final text = await showGoalEditor(context, initial: goal.goal.objective);
      if (text == null || !context.mounted) return;
      problem = await controller.edit(text);
    case GoalAction.pause:
      problem = await controller.pause();
    case GoalAction.resume:
      problem = await controller.resume();
    case GoalAction.clear:
      if (!await confirmClearGoal(context, goal.goal.objective)) return;
      problem = await controller.clear();
  }
  if (problem != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problem)));
  }
}
