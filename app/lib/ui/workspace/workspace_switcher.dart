// The drawer's workspace switcher: one quiet row above the conversations
// (「全部对话 ⌄」 / 「dsh-app ⌄」) that opens a sheet of the host's workspaces —
// pinned first, then groups, then the rest — with 「添加工作区」 and
// 「管理工作区」. Picking one filters the drawer and new conversations start
// there (official sidebar: `dsh-client-ui-workspace`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/drawer_view_state.dart';
import '../../state/sessions_state.dart';
import '../../state/workspaces_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/row_marks.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workspace_actions.dart';
import 'workspace_format.dart';

/// The row in the drawer. Hidden until the host's workspace list arrives
/// (and on hosts without one).
class WorkspaceSwitcher extends ConsumerWidget {
  const WorkspaceSwitcher({super.key, required this.onManage});

  /// Opens the management page (the drawer closes behind it).
  final VoidCallback onManage;

  /// Row height; the label sits on the drawer's 20 text line, the pressed
  /// highlight on its 10 edge line.
  static const height = 36.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final ready = ref.watch(workspacesProvider.select((s) => s.ready));
    final scope = !ready ? ref.watch(drawerScopeProvider) : null;
    final retained = scope?.readOnly == true ? scope : null;
    if (!ready && retained == null) return const SizedBox(width: double.infinity);
    final selected = ref.watch(selectedWorkspaceProvider);
    final theme = Theme.of(context);
    final tertiary = DshColors.of(context).textTertiary;
    final retainedLabel = retained?.workspaceLabel;
    final label = retainedLabel != null
        ? retainedLabel == 'default-workspace'
              ? defaultWorkspaceTitle
              : retainedLabel
        : selected == null
        ? l10n.remoteWorkspaceAllChats
        : workspaceTitle(selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          enabled: ready,
          label: l10n.remoteWorkspaceSwitcherSemantics(label),
          excludeSemantics: true,
          child: InkWell(
            onTap: ready ? () => showWorkspaceSheet(context, onManage: onManage) : null,
            customBorder: Squircle.border(AppShape.md),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected == null && retained?.scoped != true ? AppIcons.conversations : AppIcons.workspace,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(AppIcons.expand, size: 18, color: tertiary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _SheetAction { add, manage }

/// 「工作区」: 全部对话, the host's workspaces, 「添加工作区」, 「管理工作区」.
Future<void> showWorkspaceSheet(BuildContext context, {required VoidCallback onManage}) async {
  final action = await showAppSheet<_SheetAction>(
    context,
    isScrollControlled: true,
    builder: (_) => const WorkspaceSheet(),
  );
  if (!context.mounted) return;
  switch (action) {
    case _SheetAction.add:
      await addWorkspace(context);
    case _SheetAction.manage:
      onManage();
    case null:
      break;
  }
}

class WorkspaceSheet extends ConsumerWidget {
  const WorkspaceSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final workspaces = ref.watch(workspacesProvider.select((s) => s.workspaces));
    final sections = ref.watch(workspaceSectionsProvider);
    final selected = ref.watch(selectedWorkspaceProvider)?.workspaceId;
    final counts = ref.watch(workspaceCountsProvider);
    final total = ref.watch(sessionsProvider.select((s) => s.value?.length ?? 0));
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? true));
    final prefs = ref.read(workspacePrefsProvider.notifier);

    void pick(String? id) {
      prefs.select(id);
      Navigator.of(context).pop();
    }

    const margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.remoteWorkspace),
              SheetGroup(
                margin: margin,
                children: [
                  _ChoiceRow(
                    icon: AppIcons.conversations,
                    title: l10n.remoteWorkspaceAllChats,
                    count: total,
                    selected: selected == null,
                    onTap: () => pick(null),
                  ),
                ],
              ),
              for (final section in sections)
                SheetGroup(
                  title: section.title,
                  margin: margin,
                  children: [
                    for (final w in section.items)
                      _ChoiceRow(
                        icon: AppIcons.workspace,
                        title: workspaceTitle(w),
                        subtitle: displayPath(w.path, local: local),
                        count: counts[w.workspaceId] ?? 0,
                        selected: selected == w.workspaceId,
                        onTap: () => pick(w.workspaceId),
                        onLongPress: () => showWorkspaceActions(context, w),
                      ),
                  ],
                ),
              SheetGroup(
                margin: margin,
                children: [
                  ListPageRow(
                    icon: AppIcons.newFolder,
                    title: l10n.remoteWorkspaceAdd,
                    chevron: false,
                    onTap: () => Navigator.of(context).pop(_SheetAction.add),
                  ),
                  if (workspaces.isNotEmpty)
                    ListPageRow(
                      icon: AppIcons.configure,
                      title: l10n.remoteWorkspaceManage,
                      onTap: () => Navigator.of(context).pop(_SheetAction.manage),
                    ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row of the switcher: glyph, title (+ path), conversation count, and a
/// check on the one shown.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.count,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ListPageRow(
          icon: icon,
          title: title,
          subtitle: subtitle,
          meta: count == 0 ? null : '$count',
          // The ✓'s ink ends on the edge 「管理工作区」's › ends on.
          trailing: RowCheck(visible: selected),
          onTap: onTap,
        ),
      ),
    );
  }
}
