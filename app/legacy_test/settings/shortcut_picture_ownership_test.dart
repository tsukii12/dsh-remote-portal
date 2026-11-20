import 'dart:ui' as ui;

import 'package:dsh_app/ui/settings/appearance/icon_shortcut_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shortcutBitmap releases its completed picture and retains the caller image', (tester) async {
    await tester.runAsync(() async {
      final fixtureRecorder = ui.PictureRecorder();
      ui.Canvas(fixtureRecorder).drawColor(const ui.Color(0xFF245678), ui.BlendMode.src);
      final fixturePicture = fixtureRecorder.endRecording();
      late final ui.Image input;
      try {
        input = await fixturePicture.toImage(8, 8);
      } finally {
        fixturePicture.dispose();
      }

      final previousCreate = ui.Picture.onCreate;
      final previousDispose = ui.Picture.onDispose;
      final created = <ui.Picture>[];
      final disposed = <ui.Picture>[];
      ui.Picture.onCreate = (picture) {
        created.add(picture);
        previousCreate?.call(picture);
      };
      ui.Picture.onDispose = (picture) {
        disposed.add(picture);
        previousDispose?.call(picture);
      };
      try {
        final png = await shortcutBitmap(input, const ui.Rect.fromLTWH(0, 0, 8, 8), const ui.Color(0xFFFFFFFF));
        expect(png.take(8), orderedEquals([137, 80, 78, 71, 13, 10, 26, 10]));
        expect(input.debugDisposed, isFalse, reason: 'the caller still owns the input image');
        expect(created, hasLength(1), reason: 'only the actual shortcut recording is observed');
        expect(created.single.debugDisposed, isTrue, reason: 'the public bitmap Future has completed');
        expect(disposed.where((picture) => identical(picture, created.single)), hasLength(1));
      } finally {
        try {
          for (final picture in created) {
            if (!picture.debugDisposed) picture.dispose();
          }
          if (!input.debugDisposed) input.dispose();
        } finally {
          ui.Picture.onCreate = previousCreate;
          ui.Picture.onDispose = previousDispose;
        }
      }
    });
    expect(tester.takeException(), isNull);
  });
}
