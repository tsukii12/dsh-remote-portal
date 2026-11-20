import 'dart:ui' as ui;

import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_look.dart';
import 'package:dsh_app/wallpaper/wallpaper_render.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wallpaper bake releases both recordings while the caller owns its output', (tester) async {
    await tester.runAsync(() async {
      const wallpaper = CustomWallpaper(
        path: 'test/wallpaper/fixtures/landscape.png',
        width: 300,
        height: 200,
        blur: 0,
      );
      final frame = WallpaperFrame(
        size: const ui.Size(32, 24),
        pixelRatio: 1,
        look: WallpaperLook.forAccent(AppAccent.mist, ui.Brightness.light),
      );
      // 32 * 24 is below the renderer's 1 << 17 compute threshold.
      final renderer = WallpaperRenderer();
      final previousCreate = ui.Picture.onCreate;
      final previousDispose = ui.Picture.onDispose;
      final created = <ui.Picture>[];
      final disposed = <ui.Picture>[];
      ui.Image? output;
      ui.Picture.onCreate = (picture) {
        created.add(picture);
        previousCreate?.call(picture);
      };
      ui.Picture.onDispose = (picture) {
        disposed.add(picture);
        previousDispose?.call(picture);
      };
      try {
        output = await renderer.bake(wallpaper, frame, density: 1);
        expect(output, isNotNull, reason: 'the actual public bake Future must finish successfully');
        final image = output!;
        expect(image.width, 32);
        expect(image.height, 24);
        expect(image.debugDisposed, isFalse, reason: 'the returned image belongs to the caller');
        expect(renderer.decodes, 1);
        expect(created, hasLength(2), reason: 'the actual soften and compose recordings');
        expect(created.every((picture) => picture.debugDisposed), isTrue);
        for (final picture in created) {
          expect(disposed.where((event) => identical(event, picture)), hasLength(1));
        }
      } finally {
        try {
          final image = output;
          if (image != null && !image.debugDisposed) image.dispose();
          renderer.release();
          for (final picture in created) {
            if (!picture.debugDisposed) picture.dispose();
          }
        } finally {
          ui.Picture.onCreate = previousCreate;
          ui.Picture.onDispose = previousDispose;
        }
      }
    });
    expect(tester.takeException(), isNull);
  });
}
