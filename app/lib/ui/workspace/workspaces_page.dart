// 「工作区」 (a list page): the host's workspaces as the official sidebar
// keeps them — pinned first, then groups, then the rest — each with its
// folder and how many conversations it holds. A row opens the workspace's
// sheet (rename, pin, group, new conversation there, remove); 「＋」 adds one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/workspaces_state.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'workspace_actions.dart';
import 'workspace_format.dart';

class WorkspacesPage extends ConsumerWidget {
  const WorkspacesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(workspacesProvider);
    final sections = ref.watch(workspaceSectionsProvider);
    final counts = ref.watch(workspaceCountsProvider);
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? true));

    void add() => addWorkspace(context);

    final List<Widget> body;
    switch (state.status) {
      case WorkspacesStatus.offline:
        body = const [FeatureOffline()];
      case WorkspacesStatus.failed:
        body = [
          FeatureMessage(
            icon: AppIcons.error,
            title: l10n.remoteWorkspaceErrLoad,
            action: (l10n.commonRetry, () => ref.invalidate(workspacesProvider)),
          ),
        ];
      case WorkspacesStatus.loading:
        body = const [FeatureLoading()];
      case WorkspacesStatus.ready when state.workspaces.isEmpty:
        body = [
          FeatureMessage(
            tile: FeatureKind.workspace,
            title: l10n.remoteWorkspaceEmpty,
            body: l10n.remoteWorkspaceEmptyHint,
            action: (l10n.remoteWorkspaceAdd, add),
          ),
        ];
      case WorkspacesStatus.ready:
        var index = 0;
        body = [
          for (final section in sections)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: ListPageCard(
                title: section.title,
                children: [
                  for (final w in section.items)
                    FadeSlideIn(
                      index: index++,
                      child: ListPageRow(
                        icon: AppIcons.workspace,
                        title: workspaceTitle(w),
                        subtitle: displayPath(w.path, local: local),
                        meta: conversationCountLabel(counts[w.workspaceId] ?? 0),
                        onTap: () => showWorkspaceActions(
                          context,
                          w,
                          onNewConversation: () {
                            startConversationIn(ref, w.workspaceId);
                            Navigator.of(context).popUntil((route) => route.isFirst);
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ];
    }

    return AppPage.list(
      title: l10n.remoteWorkspace,
      subtitle: state.ready && state.workspaces.isNotEmpty
          ? Text(l10n.remoteWorkspaceCount(state.workspaces.length))
          : null,
      actions: [
        // The empty state carries its own 「添加工作区」.
        if (state.ready && state.workspaces.isNotEmpty)
          GlassIconButton(icon: AppIcons.add, tooltip: l10n.remoteWorkspaceAdd, onPressed: add),
      ],
      children: body,
    );
  }
}
