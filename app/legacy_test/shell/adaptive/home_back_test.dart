// Back on the home screen: multi-select in the conversation list ends first,
// the list stays; the next back closes the drawer as before. The same in the
// sidebar of a wide window.
//
//   flutter test test/shell/adaptive/home_back_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await pumpFrames(tester, 6);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('phone: back ends multi-select, the drawer stays open', (tester) async {
    useWindow(tester, const Size(390, 844));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp());
    await pumpFrames(tester, 6);
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await pumpFrames(tester, 6);
    expect(find.byType(SessionsDrawer), findsOneWidget);

    _container(tester).read(drawerSelectionProvider.notifier).start('s2');
    await pumpFrames(tester, 2);
    await _back(tester);
    expect(_container(tester).read(drawerSelectionProvider), isNull);
    expect(find.byType(SessionsDrawer), findsOneWidget);

    // Nothing selected: back closes the drawer, as before.
    await _back(tester);
    expect(find.byType(SessionsDrawer), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('wide window: back ends multi-select in the sidebar', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    await tester.pumpWidget(homeApp(prefs: const LayoutPrefs(loaded: true, panelOpen: false)));
    await pumpFrames(tester, 6);
    expect(find.byType(SessionsDrawer), findsOneWidget);

    _container(tester).read(drawerSelectionProvider.notifier).start('s2');
    await pumpFrames(tester, 2);
    await _back(tester);
    expect(_container(tester).read(drawerSelectionProvider), isNull);
    expect(find.byType(SessionsDrawer), findsOneWidget);
    expect(find.byType(HomeShell), findsOneWidget);
  });
}
