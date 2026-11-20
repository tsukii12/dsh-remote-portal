// The tabs of 对话详情, on their own so the layout state (which tab the page, the
// sheet and the panel show) can name them without importing the page.

import '../l10n/l10n.dart';

/// The tabs of 对话详情.
enum SessionTab {
  trajectory,
  changes,
  files,
  progress,
  context,
  subagents,

  /// The host's plugin tabs for the conversation; only while it has some.
  plugins;

  String get label => switch (this) {
    SessionTab.trajectory => appL10n.hubTabTrajectory,
    SessionTab.changes => appL10n.hubTabChanges,
    SessionTab.files => appL10n.hubTabFiles,
    SessionTab.progress => appL10n.hubTabProgress,
    SessionTab.context => appL10n.hubTabContext,
    SessionTab.subagents => appL10n.hubTabSubagents,
    SessionTab.plugins => appL10n.hubPlugins,
  };
}
