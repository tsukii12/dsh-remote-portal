// What the person chose about the wide-screen columns (sidebar unfolded,
// detail panel shown), kept across launches, and the one 对话详情 tab shared
// by the page, the sheet and the panel.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_tab.dart';

/// The person's choices for wide windows. Both start unfolded.
class LayoutPrefs {
  const LayoutPrefs({this.sidebarOpen = true, this.panelOpen = true, this.loaded = false});

  /// The conversation list unfolds into a sidebar when it fits.
  final bool sidebarOpen;

  /// 对话详情 stays open beside the chat.
  final bool panelOpen;

  /// The stored values are in (until then, the defaults show).
  final bool loaded;

  LayoutPrefs copyWith({bool? sidebarOpen, bool? panelOpen, bool? loaded}) => LayoutPrefs(
    sidebarOpen: sidebarOpen ?? this.sidebarOpen,
    panelOpen: panelOpen ?? this.panelOpen,
    loaded: loaded ?? this.loaded,
  );

  @override
  bool operator ==(Object other) =>
      other is LayoutPrefs &&
      other.sidebarOpen == sidebarOpen &&
      other.panelOpen == panelOpen &&
      other.loaded == loaded;

  @override
  int get hashCode => Object.hash(sidebarOpen, panelOpen, loaded);
}

class LayoutPrefsController extends Notifier<LayoutPrefs> {
  static const sidebarKey = 'layout_sidebar_open';
  static const panelKey = 'layout_detail_panel_open';

  late Future<void> _loaded;

  @override
  LayoutPrefs build() {
    _loaded = _load();
    return const LayoutPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = LayoutPrefs(
        sidebarOpen: prefs.getBool(sidebarKey) ?? true,
        panelOpen: prefs.getBool(panelKey) ?? true,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend: the defaults, for this run.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Applies after the stored values are in, so a late load can't undo a
  /// toggle made right after launch.
  Future<void> _save(String key, bool value, LayoutPrefs next) async {
    await _loaded;
    if (!ref.mounted) return;
    state = next;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setSidebarOpen(bool open) => _save(sidebarKey, open, state.copyWith(sidebarOpen: open));

  Future<void> setPanelOpen(bool open) => _save(panelKey, open, state.copyWith(panelOpen: open));

  Future<void> togglePanel() async {
    await _loaded;
    await setPanelOpen(!state.panelOpen);
  }
}

final layoutPrefsProvider = NotifierProvider<LayoutPrefsController, LayoutPrefs>(LayoutPrefsController.new);

/// The 对话详情 tab on screen. One value for every form the detail takes, so
/// folding a sheet into the panel, or reopening the panel, keeps the tab.
class SessionDetailTabController extends Notifier<SessionTab> {
  @override
  SessionTab build() => SessionTab.trajectory;

  void select(SessionTab tab) {
    if (state != tab) state = tab;
  }
}

final sessionDetailTabProvider = NotifierProvider<SessionDetailTabController, SessionTab>(
  SessionDetailTabController.new,
);
