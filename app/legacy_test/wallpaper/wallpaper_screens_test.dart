// Where the wallpaper shows: the chat (首页 is its empty state) and the drawer over it, light and
// dark, on the bright picture and the dark one; settings pages keep the gradient. A picture that
// can't be read, or whose file is gone, leaves the default backdrop and nothing breaks. Goldens:
//
//   flutter test --update-goldens test/wallpaper/wallpaper_screens_test.dart

import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';
import '../shell/golden_harness.dart' as shell;
import 'wallpaper_contrast_test.dart' show bakeLands;
import 'support.dart';

/// The picture the backdrop under [under] paints; null: the gradient.
BackdropPicture? pictureUnder(WidgetTester tester, Finder under) {
  final backdrops = find.ancestor(of: under, matching: find.byType(AppBackdrop));
  return tester.widget<AppBackdrop>(backdrops.first).picture;
}

void main() {
  setUpAll(() async {
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
    runClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  Future<void> pumpChat(
    WidgetTester tester,
    CustomWallpaper? wallpaper,
    Brightness brightness, {
    bool home = false,
  }) async {
    SharedPreferences.setMockInitialValues({if (wallpaper != null) CustomWallpaper.prefsKey: jsonOf(wallpaper)});
    usePhoneView(tester);
    final harness = home ? ChatHarness() : ChatHarness(session: 's1', states: {'s1': conversationState()});
    await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
    await bakeLands(tester, find.byType(Scaffold).first);
    await pumpFrames(tester, 4);
  }

  for (final (name, path) in [('bright', brightFixture), ('dark', darkFixture)]) {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';

      testWidgets('golden: conversation on the $name picture ($mode)', (tester) async {
        await pumpChat(tester, fixtureWallpaper(path), brightness);
        expect(pictureUnder(tester, find.byType(Scaffold).first)?.image, isNotNull);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/chat_${name}_$mode.png'));
      });
    }
  }

  for (final (name, path, brightness) in [
    ('bright', brightFixture, Brightness.light),
    ('dark', darkFixture, Brightness.dark),
  ]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: 首页 (a new chat) on the $name picture ($mode)', (tester) async {
      await pumpChat(tester, fixtureWallpaper(path), brightness, home: true);
      expect(pictureUnder(tester, find.byType(Scaffold).first)?.image, isNotNull);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/home_${name}_$mode.png'));
    });
  }

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: the drawer over the wallpaper ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: jsonOf(fixtureWallpaper(brightFixture))});
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(
        shell.goldenApp(
          home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
          brightness: brightness,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => shell.FakeRuntime(const LocalRuntimeState(loaded: true, status: shell.runningStatus)),
            ),
            sessionsProvider.overrideWith(() => shell.FakeSessions(shell.sampleSessions())),
            currentSessionProvider.overrideWith(() => shell.FakeCurrentSession('s2')),
          ],
        ),
      );
      await bakeLands(tester, find.byType(Scaffold).first);
      expect(pictureUnder(tester, find.byType(Scaffold).first)?.image, isNotNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/drawer_$mode.png'));
    });
  }

  testWidgets('baked once: scrolling and frames after it draw the same picture, no new bake', (tester) async {
    await pumpChat(tester, fixtureWallpaper(darkFixture), Brightness.dark);
    final context = tester.element(find.byType(ChatScreen));
    final renderer = ProviderScope.containerOf(context).read(wallpaperRendererProvider);
    final picture = pictureUnder(tester, find.byType(Scaffold).first)!.image;
    final bakes = renderer.bakes;
    final decodes = renderer.decodes;
    expect(decodes, 1);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(renderer.bakes, bakes);
    expect(renderer.decodes, decodes);
    expect(pictureUnder(tester, find.byType(Scaffold).first)!.image, same(picture));
  });

  testWidgets('the system\'s high contrast: the plain page', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(highContrast: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpChat(tester, fixtureWallpaper(brightFixture), Brightness.light);
    expect(pictureUnder(tester, find.byType(Scaffold).first), isNull);
  });

  testWidgets('switched off: the gradient; the picture stays stored', (tester) async {
    await pumpChat(tester, fixtureWallpaper(brightFixture).copyWith(on: false), Brightness.light);
    expect(pictureUnder(tester, find.byType(Scaffold).first), isNull);
  });

  testWidgets('a broken picture, or its file gone: the gradient, nothing thrown', (tester) async {
    await pumpChat(tester, fixtureWallpaper(brokenFixture), Brightness.light);
    expect(pictureUnder(tester, find.byType(Scaffold).first), isNull);
    expect(tester.takeException(), isNull);

    final dir = Directory.systemTemp.createTempSync('wallpaper-gone');
    final file = File('${dir.path}/w.jpg')..writeAsBytesSync(File(brightFixture).readAsBytesSync());
    final stored = fixtureWallpaper(file.path);
    dir.deleteSync(recursive: true);
    await pumpChat(tester, stored, Brightness.dark);
    expect(pictureUnder(tester, find.byType(Scaffold).first), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings keep their own clean page', (tester) async {
    SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: jsonOf(fixtureWallpaper(brightFixture))});
    shell.usePhoneSurface(tester);
    await tester.pumpWidget(
      shell.goldenApp(
        home: const SettingsScreen(),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => shell.FakeRuntime(const LocalRuntimeState(loaded: true, status: shell.runningStatus)),
          ),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    for (final backdrop in tester.widgetList<AppBackdrop>(find.byType(AppBackdrop))) {
      expect(backdrop.picture, isNull);
    }
  });
}
