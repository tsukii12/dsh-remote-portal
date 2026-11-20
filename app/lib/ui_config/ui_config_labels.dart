// What a ui.json setting is called and what it says, in words for people (the
// 「界面配置」 sheet and 「来自 ui.json」).

import '../l10n/l10n.dart';
import 'ui_config_model.dart';

Map<String, String> get _presetNames => {
  'mist': appL10n.shellAccentMist,
  'daiqing': appL10n.shellAccentDaiqing,
  'dusk': appL10n.shellAccentDusk,
  'turquoise': appL10n.shellAccentTurquoise,
  'amber': appL10n.shellAccentAmber,
  'graphite': appL10n.shellAccentGraphite,
};

Map<UiHideItem, String> get _hideNames => {
  UiHideItem.turnFooter: appL10n.shellHideTurnFooter,
  UiHideItem.tokenCount: appL10n.shellHideTokenCount,
  UiHideItem.reasoningDetails: appL10n.shellHideReasoning,
  UiHideItem.activityStrip: appL10n.shellHideActivityStrip,
  UiHideItem.whaleTail: appL10n.shellHideWhaleTail,
  UiHideItem.todoPill: appL10n.shellHideTodoPill,
  UiHideItem.goalBar: appL10n.shellHideGoalBar,
  UiHideItem.pluginCapsule: appL10n.plugslotsChatEntry,
};

Map<String, String> get _groupNames => {
  'pinned': appL10n.commonPin,
  'folders': appL10n.shellFolders,
  'today': appL10n.shellToday,
  'yesterday': appL10n.commonYesterday,
  'thisWeek': appL10n.shellThisWeek,
  'earlier': appL10n.shellEarlier,
};

Map<String, String> get _seatNames => {
  'native': appL10n.shellSeatNative,
  'island': appL10n.shellSeatIsland,
  'web': appL10n.shellSeatWeb,
  'hidden': appL10n.commonHide,
};

/// `(name, value)` of an applied setting: 「外观模式 · 深色」.
(String, String) uiSettingLabel(UiConfigEntry entry) {
  final id = entry.key.id;
  final value = entry.value;
  int count() => value is List ? value.length : 0;
  if (id.startsWith('hide.')) {
    final item = UiHideItem.values.asNameMap()[id.substring(5)];
    return (appL10n.commonHide, _hideNames[item] ?? id.substring(5));
  }
  if (id.startsWith('plugins.seats|')) {
    final parts = id.split('|');
    return (appL10n.shellPlugins, '${parts.length > 2 ? parts[2] : ''} · ${_seatNames[value] ?? '$value'}');
  }
  return switch (id) {
    'header.actions' => (
      appL10n.shellHeaderActions,
      count() == 0 ? appL10n.shellAllHidden : appL10n.shellSettingCount(count()),
    ),
    'composer.quickActions' => (appL10n.shellQuickActions, appL10n.shellSettingCount(count())),
    'emptyState.suggestions' => (appL10n.shellSuggestionCards, appL10n.shellSuggestionCardCount(count())),
    'drawer.groups' => (
      appL10n.shellDrawerGroups,
      count() == 0
          ? appL10n.shellAllHidden
          : [for (final g in value! as List) _groupNames[g] ?? '$g'].join(appL10n.shellListSeparator),
    ),
    'drawer.sort' => (
      appL10n.shellDrawerSort,
      value == 'created' ? appL10n.shellCreatedTime : appL10n.shellRecentActivity,
    ),
    'drawer.filter' => (
      appL10n.shellDrawerFilter,
      switch (value) {
        'running' => appL10n.commonRunning,
        'pending' => appL10n.shellPending,
        'unread' => appL10n.shellUnread,
        _ => appL10n.shellAll,
      },
    ),
    'density' => (appL10n.shellDensity, value == 'compact' ? appL10n.shellCompact : appL10n.shellSpacious),
    'theme.mode' => (
      appL10n.shellThemeMode,
      switch (value) {
        'light' => appL10n.commonLight,
        'dark' => appL10n.commonDark,
        _ => appL10n.commonFollowSystem,
      },
    ),
    'theme.accent' => (appL10n.shellAccentColor, _presetNames[value] ?? '$value'),
    'pet' => (appL10n.shellPet, (value is Map ? value['id'] as String? : null) ?? appL10n.shellConfigured),
    'shortcuts' => (appL10n.shellShortcuts, appL10n.shellSettingCount(count())),
    _ => (id, entry.display),
  };
}
