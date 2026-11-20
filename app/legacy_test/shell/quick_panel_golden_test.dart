// Golden screenshots of 快捷入口 over the real chat, and of the sheet that picks
// its rows: at a phone's width, then at 320 dp with 1.3× text, some in English
// (its labels are the longest), every destination listed.
//
//   flutter test --update-goldens test/shell/quick_panel_golden_test.dart

import 'dart:ui' show GestureSettings;

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/quick_panel_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/settings/quick_panel_items_sheet.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart' show DrawerDestination;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../support/english_preview.dart';
import 'adaptive/support.dart';

const _everything = DrawerDestination.values;

/// The home screen, panel closed, as [homeApp] builds it, English on request.
Future<void> _pumpHome(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  double textScale = 1,
  bool english = false,
  List<DrawerDestination>? items,
}) async {
  if (english) useEnglish();
  SharedPreferences.setMockInitialValues({QuickPanelController.itemsKey: ?items?.map((d) => d.name).toList()});
  useWindow(tester, size);
  // Android's touch slop, as the swipe sees it on a phone.
  tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 16);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  mockClipboard(tester);
  final home = HomeShell(chatBuilder: (openDrawer) => ChatScreen(onOpenDrawer: openDrawer, backdrop: false));
  await tester.pumpWidget(
    testApp(
      english ? inEnglish(home) : home,
      brightness: brightness,
      overrides: homeOverrides(prefs: const LayoutPrefs(loaded: true)),
    ),
  );
  await pumpFrames(tester, 8);
}

/// The panel pulled all the way over, by a real swipe.
Future<void> _pullPanel(WidgetTester tester, Size size) async {
  final finger = await tester.startGesture(Offset(size.width * 0.75, size.height / 2));
  for (var i = 0; i < 40; i++) {
    await finger.moveBy(const Offset(-8, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 400));
  await finger.up();
  await pumpFrames(tester, 10);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(freezeClocks);
  tearDown(thawClocks);

  const phone = Size(390, 844);
  const narrow = Size(320, 640);

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('quick_panel ($mode)', (tester) async {
      await _pumpHome(tester, size: phone, brightness: brightness);
      await _pullPanel(tester, phone);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/quick_panel_$mode.png'));
    });

    testWidgets('quick_panel_320 ($mode)', (tester) async {
      await _pumpHome(tester, size: narrow, brightness: brightness, textScale: 1.3);
      await _pullPanel(tester, narrow);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/quick_panel_320_$mode.png'));
    });

    testWidgets('en_quick_panel_320, every destination ($mode)', (tester) async {
      await _pumpHome(tester, size: narrow, brightness: brightness, textScale: 1.3, english: true, items: _everything);
      await _pullPanel(tester, narrow);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_quick_panel_320_$mode.png'));
    });

    testWidgets('quick_panel_items_320 ($mode)', (tester) async {
      await _pumpHome(tester, size: narrow, brightness: brightness, textScale: 1.3);
      await _openItems(tester);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/quick_panel_items_320_$mode.png'));
    });

    testWidgets('en_quick_panel_items_320 ($mode)', (tester) async {
      await _pumpHome(tester, size: narrow, brightness: brightness, textScale: 1.3, english: true);
      await _openItems(tester);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_quick_panel_items_320_$mode.png'));
    });
  }
}

Future<void> _openItems(WidgetTester tester) async {
  showQuickPanelItems(tester.element(find.byType(HomeShell)));
  await pumpFrames(tester, 10);
}
