// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Preview frames, run on demand:
//   flutter test test/fx/image_gen/image_generation_preview_test.dart \
//     --dart-define=FX_PREVIEW_OUT=<dir> [--dart-define=FX_PREVIEW_IMAGES=<a.jpg>,<b.jpg>]
// Writes <variant>_<frame>.png: mosaic, reveal, hold, regenerate churn, handoff.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/image_gen/image_generation.dart';
import 'package:dsh_app/ui/fx/image_gen/renderer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = String.fromEnvironment('FX_PREVIEW_OUT');
const _images = String.fromEnvironment('FX_PREVIEW_IMAGES');

class _Decoded extends ImageProvider<_Decoded> {
  const _Decoded(this.image, this.name);

  final ui.Image image;
  final String name;

  @override
  Future<_Decoded> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Decoded key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));

  @override
  bool operator ==(Object other) => other is _Decoded && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A stand-in picture when no photos are given: a soft two-tone gradient.
Future<ui.Image> _gradient(Color a, Color b) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 400, 300),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(400, 300), [a, b]),
  );
  return recorder.endRecording().toImage(400, 300);
}

void main() {
  testWidgets('image generation preview frames', skip: _out.isEmpty, (tester) async {
    final dir = Directory(_out)..createSync(recursive: true);
    final paths = _images.isEmpty ? <String>[] : _images.split(',');
    final pics = (await tester.runAsync(() async {
      if (paths.length >= 2) {
        return [
          for (final p in paths.take(2))
            (await (await ui.instantiateImageCodec(File(p).readAsBytesSync())).getNextFrame()).image,
        ];
      }
      return [
        await _gradient(const Color(0xFF2E6B4F), const Color(0xFFE2C48A)),
        await _gradient(const Color(0xFF6A4E8C), const Color(0xFFF0A58C)),
      ];
    }))!;
    final a = _Decoded(pics[0], 'a'), b = _Decoded(pics[1], 'b');
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(600, 500) * 2;
    addTearDown(tester.view.reset);

    final variants = [
      for (final preset in ImageGenerationPreset.values)
        for (final b in [Brightness.dark, Brightness.light]) (preset, b, true, true),
      (ImageGenerationPreset.pixelsOrganic, Brightness.dark, false, true),
      (ImageGenerationPreset.pixelsMechanic, Brightness.light, false, true),
      (ImageGenerationPreset.pixelsOrganic, Brightness.dark, true, false),
    ];
    for (final (preset, brightness, themed, gpu) in variants) {
      final programs = FxPrograms.ready;
      if (!gpu) FxPrograms.ready = null;
      final name = '${preset.name}-${brightness.name}-${themed ? 'themed' : 'preset'}${gpu ? '' : '-cpu'}';
      ImageGeneration.debugSeed = 11;
      final key = GlobalKey();
      final dark = brightness == Brightness.dark;
      Future<void> show(ImageProvider? image, bool generating) => tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: dark ? const Color(0xFF97B1F0) : const Color(0xFF4B67B4),
              brightness: brightness,
            ),
          ),
          home: Material(
            color: dark ? const Color(0xFF111318) : Colors.white,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 280,
                  height: 210,
                  child: ImageGeneration(
                    key: ValueKey(name),
                    image: image,
                    generating: generating,
                    preset: preset,
                    themed: themed,
                    cardBg: themed ? (dark ? const Color(0xFF1A1E26) : const Color(0xFFE7EBF3)) : null,
                    borderRadius: BorderRadius.circular(14),
                    child: generating && image == null
                        ? Center(
                            child: Text(
                              '生成中 · 42%',
                              style: TextStyle(fontSize: 12, color: dark ? Colors.white54 : Colors.black45),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      var frame = 0;
      Future<void> run(int steps) async {
        for (var i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            File('${dir.path}/${name}_${(frame++).toString().padLeft(3, '0')}.png')
                .writeAsBytesSync(png!.buffer.asUint8List());
          });
        }
      }

      await show(null, true);
      await run(12); // mosaic
      await show(a, false);
      await run(34); // reveal (3 s) and hold
      await show(a, true);
      await run(28); // regenerate churn
      await show(b, false);
      await run(30); // handoff into the next image
      await tester.pumpWidget(const SizedBox());
      FxPrograms.ready = programs;
    }
    ImageGeneration.debugSeed = null;
    for (final p in pics) {
      p.dispose();
    }
  });
}
