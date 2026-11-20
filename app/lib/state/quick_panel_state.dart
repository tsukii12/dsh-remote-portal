// 快捷入口, the panel a left swipe over the chat pulls in from the right:
// whether the swipe opens it and which destinations it lists, in order, kept
// across launches. Only the destinations' names are stored.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drawer_destination.dart';

class QuickPanelPrefs {
  const QuickPanelPrefs({this.swipe = true, this.items = defaultItems});

  /// What an install that never chose anything lists.
  static const defaultItems = [DrawerDestination.remote, DrawerDestination.settings];

  /// A left swipe over the chat opens the panel.
  final bool swipe;

  /// What the panel lists, in order.
  final List<DrawerDestination> items;

  /// There is a panel to pull: the swipe is on and it would list something.
  bool get available => swipe && items.isNotEmpty;

  QuickPanelPrefs copyWith({bool? swipe, List<DrawerDestination>? items}) =>
      QuickPanelPrefs(swipe: swipe ?? this.swipe, items: items ?? this.items);
}

class QuickPanelController extends Notifier<QuickPanelPrefs> {
  static const swipeKey = 'quick_panel_swipe';
  static const itemsKey = 'quick_panel_items';

  late Future<void> _loaded;

  @override
  QuickPanelPrefs build() {
    _loaded = _load();
    return const QuickPanelPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final stored = prefs.getStringList(itemsKey);
      state = QuickPanelPrefs(
        swipe: prefs.getBool(swipeKey) ?? true,
        // An id no destination answers to (one that was removed) is dropped.
        items: stored == null
            ? QuickPanelPrefs.defaultItems
            : {for (final id in stored) ?DrawerDestination.values.asNameMap()[id]}.toList(),
      );
    } catch (_) {
      // No preferences backend: the defaults, for this run.
    }
  }

  /// Applies after the stored values are in, so a late load can't undo a
  /// change made right after launch.
  Future<void> setSwipe(bool on) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(swipe: on);
    try {
      await (await SharedPreferences.getInstance()).setBool(swipeKey, on);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setItems(List<DrawerDestination> items) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(items: List.unmodifiable(items));
    try {
      await (await SharedPreferences.getInstance()).setStringList(itemsKey, [for (final d in items) d.name]);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final quickPanelProvider = NotifierProvider<QuickPanelController, QuickPanelPrefs>(QuickPanelController.new);
