// 技能 › 「在对话里用」 and 「新对话里用」. As in the official client, a skill is
// applied by its literal `/name` in the message (see state/composer_insert.dart),
// so both buttons put `/name ` into a composer and go back to the chat; nothing
// is sent.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart' show hostSessionsProvider;
import '../../state/composer_insert.dart';
import '../../state/workspaces_state.dart';
import '../engine_settings/field_sheets.dart' show SheetActions;
import 'phone_skill_use.dart';

/// Which composer gets the skill.
enum SkillUse {
  /// The conversation the skill list belongs to.
  here,

  /// A new conversation.
  fresh,
}

/// The skill sheet's footer: 「新对话里用」 (outlined) beside 「在对话里用」
/// (the one primary), at equal width and height. A subagent's conversation
/// takes no `/name` of its own, so there only 「新对话里用」 is offered.
class SkillUseActions extends ConsumerWidget {
  const SkillUseActions({super.key, required this.skill, required this.sessionId});

  final SkillInfo skill;

  /// The conversation whose skill list this is.
  final String sessionId;

  static String get hereLabel => appL10n.featuresSkillUseHere;
  static String get freshLabel => appL10n.featuresSkillUseNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final subagent = ref.watch(hostSessionsProvider.select((all) => all[sessionId]?.isSubagent ?? false));
    void use(SkillUse how) => useSkill(context, skill: skill, sessionId: sessionId, use: how);

    Widget label(String text) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    final primaryStyle = FilledButton.styleFrom(minimumSize: const Size.fromHeight(SheetActions.height));
    if (subagent) {
      return SheetActions(
        primary: FilledButton(
          style: primaryStyle,
          onPressed: () => use(SkillUse.fresh),
          child: label(l10n.featuresSkillUseNew),
        ),
      );
    }
    final actions = SheetActions(
      secondary: OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(SheetActions.height)),
        onPressed: () => use(SkillUse.fresh),
        child: label(l10n.featuresSkillUseNew),
      ),
      primary: FilledButton(
        style: primaryStyle,
        onPressed: () => use(SkillUse.here),
        child: label(l10n.featuresSkillUseHere),
      ),
    );
    if (!RegExp(r'^phone-task-[a-f0-9]{32}$').hasMatch(skill.name)) return actions;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      actions,
      TextButton(onPressed: () async {
        final prepared = await preparePhoneSkillUse(context, skillId: skill.name, sessionId: sessionId);
        if (prepared == null) return;
        if (!context.mounted) { unawaited(prepared.discard()); return; }
        final container = ProviderScope.containerOf(context, listen: false);
        if (!prepared.origin.current(container)) { unawaited(prepared.discard()); return; }
        Navigator.of(context).popUntil((route) => route.isFirst);
        container.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(prepared));
      }, child: Text(l10n.phoneSkillReplayReview)),
    ]);
  }
}

/// Puts `/name ` into a composer and returns to the chat (the sheet and the
/// pages above the chat close). [SkillUse.fresh] opens the new-chat screen —
/// in the conversation's workspace when the skill belongs to that workspace,
/// so the new conversation can load it too.
void useSkill(BuildContext context, {required SkillInfo skill, required String sessionId, required SkillUse use}) {
  final container = ProviderScope.containerOf(context, listen: false);
  unawaited(HapticFeedback.selectionClick());
  if (use == SkillUse.fresh) {
    final target = skillWorkspaceSwitch(
      skill: skill,
      sessionId: sessionId,
      workspaces: container.read(workspacesProvider).workspaces,
      selected: container.read(workspacePrefsProvider).selected,
    );
    if (target != null) {
      unawaited(container.read(workspacePrefsProvider.notifier).select(target));
    }
  }
  // Back to the chat first, then the request: the composer takes focus on
  // the route that is now on top, not under the closing pages.
  Navigator.of(context).popUntil((route) => route.isFirst);
  container
      .read(composerInsertProvider.notifier)
      .request(ComposerInsert.skill(skill.name, sessionId: use == SkillUse.here ? sessionId : null));
}

/// The workspace 「新对话里用」 must switch to, or null to start where a new
/// conversation starts now.
///
/// A skill from a workspace's own folder (`.dsh/skills` under it) only exists
/// in conversations of that workspace: when [sessionId] belongs to one, the
/// skill's `SKILL.md` lies inside it and [selected] is another (or 全部), the
/// answer is that workspace. Skills from `~/.dsh` or a plugin work anywhere.
String? skillWorkspaceSwitch({
  required SkillInfo skill,
  required String sessionId,
  required List<Workspace> workspaces,
  required String? selected,
}) {
  final path = skill.path;
  if (path == null || path.isEmpty) return null;
  for (final w in workspaces) {
    if (!w.sessionIds.contains(sessionId)) continue;
    if (w.workspaceId == selected || w.path.isEmpty) return null;
    final root = w.path.endsWith('/') ? w.path : '${w.path}/';
    return path.startsWith(root) ? w.workspaceId : null;
  }
  return null;
}
