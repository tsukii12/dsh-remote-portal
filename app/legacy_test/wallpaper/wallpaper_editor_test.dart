// 调整位置: the picture over the whole screen as the screen frames it; dragging moves it and 完成
// keeps where it is, 复原 centres it again, × leaves the stored framing alone. Its keys are
// symmetric about the screen. Golden:
//
//   flutter test --update-goldens test/wallpaper/wallpaper_editor_test.dart

import 'package:dsh_app/ui/wallpaper/wallpaper_editor_page.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

void main() {
  Future<void> pump(WidgetTester tester, CustomWallpaper stored) async {
    SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: jsonOf(stored)});
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(onPressed: () => showWallpaperEditor(context, stored), child: const Text('open')),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    await tester.tap(find.text('open'));
    await land(tester);
  }

  testWidgets('drag, 完成: the framing is stored', (tester) async {
    await pump(tester, fixtureWallpaper(brightFixture));
    // The picture (720 × 1280) covers the 390 × 844 screen with room to the sides.
    await tester.drag(find.byKey(const ValueKey('wallpaper-editor-view')), const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('wallpaper-editor-done')));
    await land(tester);
    expect(find.byType(WallpaperEditorPage), findsNothing);
    final stored = (await CustomWallpaper.load())!;
    expect(stored.zoom, 1);
    expect(stored.alignX, greaterThan(0.3), reason: 'dragged left: the right of the picture comes in');
    expect(stored.alignY, 0);
  });

  testWidgets('复原 centres it; × keeps what was stored', (tester) async {
    await pump(tester, fixtureWallpaper(brightFixture).copyWith(zoom: 2, alignX: -1, alignY: 1));
    await tester.tap(find.byKey(const ValueKey('wallpaper-editor-reset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wallpaper-editor-cancel')));
    await land(tester);
    final kept = (await CustomWallpaper.load())!;
    expect((kept.zoom, kept.alignX, kept.alignY), (2.0, -1.0, 1.0));

    await tester.tap(find.text('open'));
    await land(tester);
    await tester.tap(find.byKey(const ValueKey('wallpaper-editor-reset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wallpaper-editor-done')));
    await land(tester);
    final reset = (await CustomWallpaper.load())!;
    expect((reset.zoom, reset.alignX, reset.alignY), (1.0, 0.0, 0.0));
  });

  testWidgets('the keys sit 12 from the sides, the hint centred; golden', (tester) async {
    await pump(tester, fixtureWallpaper(darkFixture));
    final cancel = tester.getRect(find.byKey(const ValueKey('wallpaper-editor-cancel')));
    final done = tester.getRect(find.byKey(const ValueKey('wallpaper-editor-done')));
    expect(cancel.left, moreOrLessEquals(12, epsilon: 0.01));
    expect(390 - done.right, moreOrLessEquals(12, epsilon: 0.01));
    expect(cancel.center.dy, moreOrLessEquals(done.center.dy, epsilon: 0.01));
    final hint = tester.getRect(
      find.ancestor(of: find.byKey(const ValueKey('wallpaper-editor-reset')), matching: find.byType(Row)).first,
    );
    expect(hint.center.dx, moreOrLessEquals(195, epsilon: 0.01));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/editor_light.png'));
  });

  testWidgets('a picture that can no longer be read: says so, nothing to save', (tester) async {
    await pump(tester, fixtureWallpaper(brokenFixture));
    expect(find.text('无法读取这张图片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// The decode and the prefs are real I/O: until the editor shows its picture or says it can't
/// (however long a busy machine takes), or has closed.
Future<void> land(WidgetTester tester) async {
  bool landed() =>
      find.byType(WallpaperEditorPage).evaluate().isEmpty ||
      find.byKey(const ValueKey('wallpaper-editor-view')).evaluate().isNotEmpty ||
      find.text('无法读取这张图片').evaluate().isNotEmpty;
  // Waiting doesn't move the test clock; the fixed pumps after it do.
  for (var i = 0; i < 8 || (!landed() && i < 400); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
