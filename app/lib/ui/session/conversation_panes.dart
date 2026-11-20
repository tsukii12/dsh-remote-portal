// What can be shown about a conversation, in one place: every form that shows it (the
// side panel a left swipe pulls in, the page behind the title, the column beside the
// chat on a wide window) picks from these instead of keeping a list of its own.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import 'conversation_overview.dart';
import 'session_detail_page.dart';
import 'workspace_files.dart';

/// One thing to see about a conversation.
class ConversationPane {
  const ConversationPane({required this.id, required this.icon, required this.label, required this.build, this.tab});

  final String id;
  final IconData icon;
  final String Function() label;
  final Widget Function(String sessionId) build;

  /// Its tab on 对话详情; null when it is only in the side panel.
  final SessionTab? tab;

  static final overview = ConversationPane(
    id: 'overview',
    icon: AppIcons.info,
    label: () => appL10n.shellPanelOverview,
    build: (id) => ConversationOverview(sessionId: id),
  );

  static ConversationPane _ofTab(SessionTab tab, IconData icon, Widget Function(String) build) =>
      ConversationPane(id: tab.name, icon: icon, label: () => tab.label, build: build, tab: tab);

  static final Map<SessionTab, ConversationPane> _tabs = {
    SessionTab.files: _ofTab(SessionTab.files, AppIcons.files, (id) => WorkspaceFilesTab(sessionId: id)),
    SessionTab.trajectory: _ofTab(SessionTab.trajectory, AppIcons.trajectory, (id) => TrajectoryTab(sessionId: id)),
    SessionTab.changes: _ofTab(SessionTab.changes, AppIcons.diff, (id) => ChangesTab(sessionId: id)),
    SessionTab.progress: _ofTab(SessionTab.progress, AppIcons.todo, (id) => ProgressTab(sessionId: id)),
    SessionTab.context: _ofTab(SessionTab.context, AppIcons.file, (id) => ContextTab(sessionId: id)),
    SessionTab.subagents: _ofTab(SessionTab.subagents, AppIcons.subagents, (id) => SubagentsTab(sessionId: id)),
  };

  /// The pane behind [tab].
  static ConversationPane ofTab(SessionTab tab) => _tabs[tab]!;
}
