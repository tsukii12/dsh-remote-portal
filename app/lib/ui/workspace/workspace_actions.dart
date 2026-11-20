// What can be done to a workspace, shared by the drawer's switcher and the
// management page: add one (folder picker → `workspace/create`), and the
// per-workspace sheet (rename, pin, group, new conversation there, remove).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/sessions_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'directory_picker.dart';
import 'text_prompt.dart';
import 'workspace_format.dart';
import '../common/brief_notice.dart';

/// Picks a folder and registers it as a workspace, then shows that
/// workspace in the drawer. Returns it, or null when dismissed or failed.
Future<Workspace?> addWorkspace(BuildContext context) async {
  final l10n = context.l10n;
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final path = await showDirectoryPicker(context, title: l10n.remoteWorkspaceAdd, confirmLabel: l10n.commonAdd);
  if (path == null) return null;
  try {
    final workspace = await container.read(workspacesProvider.notifier).add(path);
    final prefs = container.read(workspacePrefsProvider.notifier);
    if (parentFolder(path) case final parent?) await prefs.remember(parent);
    await prefs.select(workspace.workspaceId);
    messenger?.showBriefNotice(l10n.remoteWorkspaceAdded(workspaceTitle(workspace)));
    return workspace;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(workspaceErrorText(e, fallback: l10n.remoteWorkspaceErrAdd))));
    return null;
  }
}

/// Conversation counts per workspace among the drawer's conversations.
final workspaceCountsProvider = Provider<Map<String, int>>((ref) {
  final visible = [for (final s in ref.watch(sessionsProvider).value ?? const <SessionSummary>[]) s.sessionId];
  return {
    for (final w in ref.watch(workspacesProvider).workspaces) w.workspaceId: workspaceConversationCount(w, visible),
  };
});

/// 「N 个对话」, or 「没有对话」.
String conversationCountLabel(int n) => n == 0 ? appL10n.remoteWorkspaceNoChats : appL10n.remoteWorkspaceChatCount(n);

/// The per-workspace sheet. [onNewConversation] starts a conversation there
/// (the caller decides where the chat is).
Future<void> showWorkspaceActions(BuildContext context, Workspace workspace, {VoidCallback? onNewConversation}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SheetNavigator(
      root: (_) => _WorkspaceActions(
        workspaceId: workspace.workspaceId,
        onRename: () async {
          Navigator.of(sheet).pop();
          await _rename(context, container, messenger, workspace.workspaceId);
        },
        onRemove: () async {
          Navigator.of(sheet).pop();
          await _remove(context, container, messenger, workspace.workspaceId);
        },
        onNewConversation: onNewConversation == null
            ? null
            : () {
                Navigator.of(sheet).pop();
                onNewConversation();
              },
      ),
    ),
  );
}

Future<void> _rename(
  BuildContext context,
  ProviderContainer container,
  ScaffoldMessengerState? messenger,
  String id,
) async {
  final l10n = context.l10n;
  final current = container.read(workspacesProvider).byId(id);
  if (current == null || !context.mounted) return;
  final title = await askWorkspaceTitle(context, workspaceTitle(current));
  if (title == null || title.isEmpty || title == current.title) return;
  try {
    await container.read(workspacesProvider.notifier).rename(id, title);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(workspaceErrorText(e, fallback: l10n.remoteWorkspaceErrRename))));
  }
}

Future<void> _remove(
  BuildContext context,
  ProviderContainer container,
  ScaffoldMessengerState? messenger,
  String id,
) async {
  final l10n = context.l10n;
  final current = container.read(workspacesProvider).byId(id);
  if (current == null || !context.mounted) return;
  final name = workspaceTitle(current);
  final ok = await confirmRemoveWorkspace(context, name);
  if (!ok) return;
  try {
    await container.read(workspacesProvider.notifier).remove(id);
    messenger?.showBriefNotice(l10n.remoteWorkspaceRemoved(name));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(workspaceErrorText(e, fallback: l10n.remoteWorkspaceErrRemove))));
  }
}

/// 「重命名工作区」: the new title, or null.
Future<String?> askWorkspaceTitle(BuildContext context, String initial) => showTextPrompt(
  context,
  title: context.l10n.remoteWorkspaceRename,
  initial: initial,
  hint: context.l10n.remoteWorkspaceName,
  maxLength: 80,
  validate: (v) => v.isEmpty ? context.l10n.remoteWorkspaceNameRequired : null,
);

/// 「移除「name」？」 — the folder and its conversations stay.
Future<bool> confirmRemoveWorkspace(BuildContext context, String name) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.remoteWorkspaceRemoveTitle(name)),
      content: Text(l10n.remoteWorkspaceRemoveBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.remoteWorkspaceRemove),
        ),
      ],
    ),
  );
  return ok == true;
}

class _WorkspaceActions extends ConsumerWidget {
  const _WorkspaceActions({
    required this.workspaceId,
    required this.onRename,
    required this.onRemove,
    this.onNewConversation,
  });

  final String workspaceId;
  final VoidCallback onRename;
  final VoidCallback onRemove;
  final VoidCallback? onNewConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final workspace = ref.watch(workspacesProvider.select((s) => s.byId(workspaceId)));
    final prefs = ref.watch(workspacePrefsProvider);
    final count = ref.watch(workspaceCountsProvider.select((c) => c[workspaceId] ?? 0));
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? true));
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    if (workspace == null) {
      // Removed elsewhere while the sheet was open.
      return SafeArea(top: false, child: SheetTitleBar(l10n.remoteWorkspace));
    }
    final pinned = prefs.pinned.contains(workspaceId);
    final group = prefs.groups[workspaceId];
    const margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(workspaceTitle(workspace)),
            // Where it is and what's in it, quietly under the title.
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayPath(workspace.path, local: local),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoLabel(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    conversationCountLabel(count),
                    style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary)),
                  ),
                ],
              ),
            ),
            SheetGroup(
              margin: margin,
              children: [
                if (onNewConversation != null)
                  ListPageRow(
                    icon: AppIcons.newChat,
                    title: l10n.remoteWorkspaceNewChatHere,
                    chevron: false,
                    onTap: onNewConversation,
                  ),
                ListPageRow(icon: AppIcons.rename, title: l10n.commonRename, chevron: false, onTap: onRename),
                ListPageRow(
                  icon: pinned ? AppIcons.pinActive : AppIcons.pin,
                  title: pinned ? l10n.remoteWorkspaceUnpin : l10n.commonPin,
                  chevron: false,
                  onTap: () => ref.read(workspacePrefsProvider.notifier).setPinned(workspaceId, !pinned),
                ),
                ListPageRow(
                  icon: AppIcons.workspaceGroup,
                  title: l10n.remoteWorkspaceGroup,
                  value: group ?? l10n.remoteWorkspaceUngrouped,
                  onTap: () => SheetNavigator.of(context).push((_) => _GroupPicker(workspaceId: workspaceId)),
                ),
              ],
            ),
            SheetGroup(
              margin: margin,
              children: [
                ListPageRow(
                  icon: AppIcons.remove,
                  title: l10n.remoteWorkspaceRemoveAction,
                  danger: true,
                  chevron: false,
                  onTap: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 「分组」: no group, the groups in use, or a new one.
class _GroupPicker extends ConsumerWidget {
  const _GroupPicker({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final groups = ref.watch(workspaceGroupsProvider);
    final current = ref.watch(workspacePrefsProvider.select((p) => p.groups[workspaceId]));
    final scheme = Theme.of(context).colorScheme;
    final prefs = ref.read(workspacePrefsProvider.notifier);
    final sheet = SheetNavigator.of(context);

    Widget check(bool on) => on ? Icon(AppIcons.selected, size: 20, color: scheme.primary) : const SizedBox(width: 20);

    Future<void> pick(String? group) async {
      await prefs.setGroup(workspaceId, group);
      sheet.pop();
    }

    Future<void> create() async {
      final name = await askGroupName(context);
      if (name == null || name.isEmpty) return;
      await pick(name);
    }

    const margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.remoteWorkspaceGroup),
            SheetGroup(
              margin: margin,
              children: [
                Semantics(
                  key: const ValueKey('workspace-group-ungrouped'),
                  selected: current == null,
                  inMutuallyExclusiveGroup: true,
                  child: ListPageRow(
                    icon: AppIcons.workspace,
                    title: l10n.remoteWorkspaceUngrouped,
                    trailing: check(current == null),
                    onTap: () => pick(null),
                  ),
                ),
                for (final g in groups)
                  Semantics(
                    key: ValueKey('workspace-group-$g'),
                    selected: current == g,
                    inMutuallyExclusiveGroup: true,
                    child: ListPageRow(
                      icon: AppIcons.workspaceGroup,
                      title: g,
                      trailing: check(current == g),
                      onTap: () => pick(g),
                    ),
                  ),
              ],
            ),
            SheetGroup(
              margin: margin,
              children: [
                ListPageRow(icon: AppIcons.add, title: l10n.remoteWorkspaceNewGroup, chevron: false, onTap: create),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 「新建分组」: the group's name, or null.
Future<String?> askGroupName(BuildContext context) => showTextPrompt(
  context,
  title: context.l10n.remoteWorkspaceNewGroup,
  hint: context.l10n.remoteWorkspaceGroupName,
  confirm: context.l10n.commonCreate,
  maxLength: 24,
  validate: (v) => v.isEmpty ? context.l10n.remoteWorkspaceNameRequired : null,
);

/// Shows [workspaceId] in the drawer and opens a new conversation (created
/// there on the first message).
void startConversationIn(WidgetRef ref, String workspaceId) {
  unawaited(ref.read(workspacePrefsProvider.notifier).select(workspaceId));
  ref.read(currentSessionProvider.notifier).select(null);
}
