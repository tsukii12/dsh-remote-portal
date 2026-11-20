// The wide-screen choices (sidebar unfolded, detail panel shown) are kept
// across launches; the 对话详情 tab is one value for page, sheet and panel.
//
//   flutter test test/shell/adaptive/layout_prefs_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<LayoutPrefs> _loaded(ProviderContainer container) async {
  container.read(layoutPrefsProvider);
  for (var i = 0; i < 20 && !container.read(layoutPrefsProvider).loaded; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(layoutPrefsProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both start unfolded', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final prefs = await _loaded(container);
    expect(prefs.loaded, isTrue);
    expect(prefs.sidebarOpen, isTrue);
    expect(prefs.panelOpen, isTrue);
  });

  test('folding the panel is remembered by the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    await _loaded(first);
    await first.read(layoutPrefsProvider.notifier).setPanelOpen(false);
    await first.read(layoutPrefsProvider.notifier).setSidebarOpen(false);
    expect(first.read(layoutPrefsProvider).panelOpen, isFalse);
    first.dispose();

    final stored = await SharedPreferences.getInstance();
    expect(stored.getBool(LayoutPrefsController.panelKey), isFalse);
    expect(stored.getBool(LayoutPrefsController.sidebarKey), isFalse);

    final next = ProviderContainer();
    addTearDown(next.dispose);
    final prefs = await _loaded(next);
    expect(prefs.panelOpen, isFalse);
    expect(prefs.sidebarOpen, isFalse);
  });

  test('a toggle right after launch is not undone by the load', () async {
    SharedPreferences.setMockInitialValues({LayoutPrefsController.panelKey: true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Before the stored values are in.
    final toggled = container.read(layoutPrefsProvider.notifier).togglePanel();
    await toggled;
    expect(container.read(layoutPrefsProvider).panelOpen, isFalse);
    expect(container.read(layoutPrefsProvider).loaded, isTrue);
  });

  test('one 对话详情 tab, whichever form shows it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(sessionDetailTabProvider), SessionTab.trajectory);
    var changes = 0;
    container.listen(sessionDetailTabProvider, (_, _) => changes++);
    container.read(sessionDetailTabProvider.notifier).select(SessionTab.progress);
    container.read(sessionDetailTabProvider.notifier).select(SessionTab.progress);
    expect(container.read(sessionDetailTabProvider), SessionTab.progress);
    expect(changes, 1);
  });
}
