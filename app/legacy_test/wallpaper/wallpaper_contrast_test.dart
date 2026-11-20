// Text on the wallpaper, measured on what is actually drawn: the preview's conversation (the
// chat's own materials) over a bright picture and a dark one, light page and dark, at the hardest
// settings (no blur, no tone of the person's own). Every text keeps 4.5:1 against the pixels
// behind it:
//
//   title and status line   on the header's glass        (the screenshot, beside the text)
//   composer placeholder    on the composer's glass      (the screenshot, beside the text)
//   the person's question   on their bubble              (the screenshot, beside the text)
//   a tool's row            on its card                  (the screenshot, beside the text)
//   answer, note, time      on the page                  (the bake, under the text)
//
// Goldens of the preview at the default settings, both pictures, both modes:
//
//   flutter test --update-goldens test/wallpaper/wallpaper_contrast_test.dart

import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/ui/wallpaper/wallpaper_backdrop.dart';
import 'package:dsh_app/ui/wallpaper/wallpaper_preview_page.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

final _shot = GlobalKey();

Future<void> _pumpPreview(WidgetTester tester, CustomWallpaper wallpaper, Brightness brightness) async {
  SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: jsonOf(wallpaper)});
  usePhoneSurface(tester);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: goldenApp(home: const WallpaperPreviewPage(), brightness: brightness),
    ),
  );
  await bakeLands(tester, find.byType(WallpaperSampleChat));
}

/// Waits for the bake (real I/O and GPU work), then its fade. The wait itself doesn't move the
/// test clock, so however long a busy machine takes, the screen's animations end up the same.
Future<void> bakeLands(WidgetTester tester, Finder under) async {
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    final context = tester.element(under);
    final frame = WallpaperBackdrop.frameOf(context);
    final baked = ProviderScope.containerOf(context).read(wallpaperImageProvider(frame));
    if (baked.hasValue && !baked.isLoading) break;
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// The bake behind [under] (what the page paints).
ui.Image bakeOf(WidgetTester tester, Finder under) {
  final context = tester.element(under);
  return ProviderScope.containerOf(context).read(wallpaperImageProvider(WallpaperBackdrop.frameOf(context))).value!;
}

void main() {
  for (final (name, path) in [('bright', brightFixture), ('dark', darkFixture)]) {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';

      testWidgets('$name picture, $mode: every text reads at 4.5:1 on what is behind it', (tester) async {
        await _pumpPreview(tester, fixtureWallpaper(path, blur: 0, tone: 0), brightness);
        final screen = (await tester.runAsync(() async {
          final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final pixels = await Pixels.of(image);
          image.dispose();
          return pixels;
        }))!;
        final bake = (await tester.runAsync(() => Pixels.of(bakeOf(tester, find.byType(WallpaperSampleChat)))))!;
        final l10n = appL10n;
        Rect px(Rect r, double k) => Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k);
        Color colorOf(Finder f) => tester.widget<Text>(f).style!.color!;
        final results = <String, double>{};

        // Glass and bubble: the pixels just beside the text, inside the piece's padding.
        void beside(String label, Finder text, Finder piece, {double inset = 6, Finder? lead}) {
          final t = tester.getRect(text);
          final p = tester.getRect(piece);
          // Up to the text, or to whatever leads it (an icon).
          final end = lead == null ? t.left : tester.getRect(lead).left;
          final strip = Rect.fromLTRB(p.left + inset, t.top + 1, end - 2, t.bottom - 1);
          expect(strip.width, greaterThan(2), reason: label);
          results[label] = screen.worstContrast(colorOf(text), px(strip, 2));
        }

        // 10 in from the capsule's end: clear of its hairline where the end curves.
        final title = find.byKey(const ValueKey('wallpaper-sample-title'));
        beside('title', find.text(l10n.wallpaperSampleTitle), title, inset: 10);
        beside('status line', find.descendant(of: title, matching: find.text(l10n.wallpaperPreview)), title, inset: 10);
        beside(
          'composer placeholder',
          find.text(l10n.chatComposerHint),
          find.byKey(const ValueKey('wallpaper-sample-composer')),
          inset: 10,
        );
        beside(
          'card',
          find.byKey(const ValueKey('wallpaper-sample-tool')),
          find.byKey(const ValueKey('wallpaper-sample-card')),
          inset: 3,
          lead: find.descendant(of: find.byKey(const ValueKey('wallpaper-sample-card')), matching: find.byType(Icon)),
        );
        beside(
          'bubble',
          find.text(l10n.wallpaperSampleQuestion),
          find.byKey(const ValueKey('wallpaper-sample-bubble')),
          inset: 4,
        );

        // The page: the bake under the text.
        final k = bake.width / 390;
        for (final (label, key) in [
          ('answer', 'wallpaper-sample-answer'),
          ('note', 'wallpaper-sample-note'),
          ('time', 'wallpaper-sample-meta'),
        ]) {
          final f = find.byKey(ValueKey(key));
          results[label] = bake.worstContrast(colorOf(f), px(tester.getRect(f), k));
        }

        debugPrint(
          'contrast $name/$mode: ${results.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(2)}').join(', ')}',
        );
        for (final MapEntry(:key, :value) in results.entries) {
          expect(value, greaterThanOrEqualTo(4.5), reason: '$key on the $name picture, $mode: $value');
        }
      });

      testWidgets('golden: preview, $name picture ($mode)', (tester) async {
        await _pumpPreview(tester, fixtureWallpaper(path), brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/preview_${name}_$mode.png'));
      });
    }
  }
}
