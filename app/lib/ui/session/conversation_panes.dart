// What can be shown about a conversation, in one place: every form that shows it (the
// side panel a left swipe pulls in, the page behind the title, the column beside the
// chat on a wide window) picks from these instead of keeping a list of its own.

import 'package:dsh_client/dsh_client.dart' show DshGoPanel;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../plugins/native/native_icons.dart';
import '../../plugins/native/native_model.dart';
import '../../plugins/native/native_state.dart';
import '../../plugins/seams/seat_planner.dart';
import '../plugins/native/chat_plugins_sheet.dart';
import '../plugins/native/native_panel.dart';
import '../plugins/seats/session_plugins_tab.dart';
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
    SessionTab.plugins: _ofTab(SessionTab.plugins, AppIcons.plugin, (id) => SessionPluginsTab(sessionId: id)),
  };

  /// The pane behind [tab].
  static ConversationPane ofTab(SessionTab tab) => _tabs[tab]!;

  /// A plugin's own panel, wherever it asked to be: in the side panel it is its own, with
  /// its own icon and name.
  static ConversationPane ofNative(NativePanel panel) => ConversationPane(
    id: 'native|${panel.package}|${panel.id}',
    icon: nativeIcon(panel.icon) ?? AppIcons.plugin,
    label: () => panel.title,
    build: (id) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      // One for 全部功能 only has no conversation to be about.
      children: [
        NativePanelView(
          panel: panel,
          sessionId: panel.placement.difference(const {DshGoPanel.features}).isEmpty ? null : id,
        ),
      ],
    ),
  );

  /// The web plugins, all in one: their chat-page parts share one island, and the pages of
  /// any plugin without such parts are a row away.
  static final webPlugins = ConversationPane(
    id: 'plugins',
    icon: AppIcons.plugin,
    label: () => appL10n.hubPlugins,
    tab: SessionTab.plugins,
    build: (id) => Builder(
      builder: (context) => ChatWebPluginsPane(
        sessionId: id,
        onOtherPages: () => SessionDetailPage.open(context, id, tab: SessionTab.plugins),
      ),
    ),
  );

  /// The side panel's 插件, for [sessionId]: every plugin panel, wherever it asked to be,
  /// each its own; then the web plugins.
  static List<ConversationPane> pluginsFor(WidgetRef ref, String sessionId) {
    final webParts = !ref.watch(chatWebPluginsProvider(sessionId)).isEmpty;
    // The page's tab holds native panels too: those are listed on their own here.
    final pages = ref.watch(sessionPluginPlanProvider(sessionId)).visible.any((item) => item.mode != SeatMode.native);
    return [
      // One that asked only for its detail page stays there.
      for (final panel in ref.watch(nativePanelsProvider))
        if (panel.placement.any((p) => p != DshGoPanel.pluginPage)) ofNative(panel),
      if (webParts) webPlugins else if (pages) ofTab(SessionTab.plugins),
    ];
  }
}
