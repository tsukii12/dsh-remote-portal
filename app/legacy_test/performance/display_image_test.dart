import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/common/display_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> resolveImage(ImageProvider provider, {bool evict = true}) async {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) => result.complete(info), onError: result.completeError);
  stream.addListener(listener);
  ImageInfo? info;
  try {
    info = await result.future;
    return info.image.clone();
  } finally {
    stream.removeListener(listener);
    info?.dispose();
    if (evict) await provider.evict();
  }
}

Future<Uint8List> solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  return bytes;
}

class _RetryImage extends ImageProvider<_RetryImage> {
  const _RetryImage(this.bytes);
  final Future<Uint8List> Function() bytes;

  @override
  Future<_RetryImage> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(_RetryImage key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(
    codec: bytes().then(ui.ImmutableBuffer.fromUint8List).then((buffer) => decode(buffer)),
    scale: 1,
  );
}

Future<ui.Image> renderCover(ui.Image input) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final inputSize = Size(input.width.toDouble(), input.height.toDouble());
  const outputSize = Size.square(64);
  final fit = applyBoxFit(BoxFit.cover, inputSize, outputSize);
  canvas.drawImageRect(
    input,
    Alignment.center.inscribe(fit.source, Offset.zero & inputSize),
    Alignment.center.inscribe(fit.destination, Offset.zero & outputSize),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  return image;
}

void main() {
  // The first three cases preserve the independent review's exact counterexamples.
  for (final dimensions in [(1024, 64), (64, 1024), (64, 64), (2048, 128), (128, 2048), (2049, 129), (129, 2049)]) {
    testWidgets('cover preserves visible stripe detail for ${dimensions.$1}x${dimensions.$2}', (tester) async {
      await tester.runAsync(() async {
        final width = dimensions.$1;
        final height = dimensions.$2;
        final vertical = width >= height;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..color = const Color(0xFFFFFFFF),
        );
        for (var coordinate = 0.0; coordinate < (vertical ? width : height); coordinate += 16) {
          canvas.drawRect(
            vertical
                ? Rect.fromLTWH(coordinate, 0, 8, height.toDouble())
                : Rect.fromLTWH(0, coordinate, width.toDouble(), 8),
            Paint()..color = const Color(0xFF000000),
          );
        }
        final picture = recorder.endRecording();
        final full = await picture.toImage(width, height);
        picture.dispose();
        final bytes = (await full.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        full.dispose();
        final original = await resolveImage(MemoryImage(bytes));
        final candidate = await resolveImage(imageForDisplay(MemoryImage(bytes), width: 64, height: 64, pixelRatio: 1));
        final outputPath = Platform.environment['A4_REVIEW_OUTPUT'];
        final output = outputPath == null ? null : Directory(outputPath);
        if (output != null) await output.create(recursive: true);
        final record = <String, Object?>{
          'source': [width, height],
          'display': [64, 64],
          'cases': <String, Object?>{},
        };
        final ranges = <int>[];
        for (final item in [('original', original), ('candidate', candidate)]) {
          final rendered = await renderCover(item.$2);
          final rgba = (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          final red = [for (var i = 8; i < 56; i++) rgba[((vertical ? 32 * 64 + i : i * 64 + 32) * 4)]];
          final range = red.reduce((a, b) => a > b ? a : b) - red.reduce((a, b) => a < b ? a : b);
          ranges.add(range);
          (record['cases'] as Map<String, Object?>)[item.$1] = {
            'decoded': [item.$2.width, item.$2.height],
            'range': range,
            'red': red,
          };
          final png = (await rendered.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          if (output != null) await File('${output.path}/${width}x$height-${item.$1}.png').writeAsBytes(png);
          rendered.dispose();
        }
        original.dispose();
        candidate.dispose();
        if (output != null) {
          await File('${output.path}/${width}x$height.json')
              .writeAsString('${const JsonEncoder.withIndent('  ').convert(record)}\n');
        }
        expect(
          ranges.first,
          greaterThan(200),
          reason: 'The existing full decode keeps the visible eight-pixel stripes',
        );
        expect(ranges.last, greaterThan(200), reason: 'A display-size decoder must preserve detail in the cover crop');
      });
    });
  }
  for (final dimensions in [(1024, 1), (1, 1024)]) {
    testWidgets('display decoder accepts valid ${dimensions.$1}x${dimensions.$2} input', (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          Rect.fromLTWH(0, 0, dimensions.$1.toDouble(), dimensions.$2.toDouble()),
          Paint()..color = const Color(0xFFFFFFFF),
        );
        final picture = recorder.endRecording();
        final full = await picture.toImage(dimensions.$1, dimensions.$2);
        picture.dispose();
        final bytes = (await full.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        full.dispose();
        final original = await resolveImage(MemoryImage(bytes));
        final record = <String, Object?>{
          'source': [dimensions.$1, dimensions.$2],
          'originalDecoded': [original.width, original.height],
        };
        original.dispose();
        try {
          final resized = await resolveImage(imageForDisplay(MemoryImage(bytes), width: 64, height: 64, pixelRatio: 1));
          record['candidateDecoded'] = [resized.width, resized.height];
          expect(resized.width, dimensions.$1);
          expect(resized.height, dimensions.$2);
          resized.dispose();
        } catch (error) {
          record['candidateError'] = error.toString();
          rethrow;
        } finally {
          final outputPath = Platform.environment['A4_REVIEW_OUTPUT'];
          if (outputPath != null) {
            final output = Directory(outputPath);
            await output.create(recursive: true);
            await File('${output.path}/${dimensions.$1}x${dimensions.$2}.json')
                .writeAsString('${const JsonEncoder.withIndent('  ').convert(record)}\n');
          }
        }
      });
    });
  }

  for (final (w, h, displayW, displayH, dpr, decodedW, decodedH) in [
    (1024, 512, 32, 32, 3, 192, 96),
    (512, 1024, 32, 32, 3, 96, 192),
    (400, 200, 80, 20, 1, 80, 40),
    (200, 400, 20, 80, 1, 40, 80),
    (64, 32, 128, 128, 1, 64, 32),
    (1024, 3, 1, 1, 1, 342, 1),
    (3, 1024, 1, 1, 1, 1, 342),
    (1, 1, 64, 64, 3, 1, 1),
  ]) {
    testWidgets('cover decoder $w x $h into $displayW x $displayH at $dpr DPR', (tester) async {
      await tester.runAsync(() async {
        final image = await resolveImage(
          imageForDisplay(
            MemoryImage(await solidPng(w, h)),
            width: displayW.toDouble(),
            height: displayH.toDouble(),
            pixelRatio: dpr.toDouble(),
          ),
        );
        expect(image.width, decodedW);
        expect(image.height, decodedH);
        image.dispose();
      });
    });
  }

  testWidgets('cache keys reuse equal physical boxes and separate different sizes and source keys', (tester) async {
    await tester.runAsync(() async {
      final bytes = await solidPng(1024, 512);
      final source = MemoryImage(bytes);
      final small = imageForDisplay(source, width: 32, height: 32, pixelRatio: 1);
      final large = imageForDisplay(source, width: 64, height: 64, pixelRatio: 1);
      final equivalent = imageForDisplay(MemoryImage(bytes), width: 32, height: 32, pixelRatio: 2);
      final scaledSource = imageForDisplay(MemoryImage(bytes, scale: 2), width: 64, height: 64, pixelRatio: 1);
      final key = await large.obtainKey(ImageConfiguration.empty);
      expect(await equivalent.obtainKey(ImageConfiguration.empty), key);
      expect(await small.obtainKey(ImageConfiguration.empty), isNot(key));
      expect(await scaledSource.obtainKey(ImageConfiguration.empty), isNot(key));
      expect(await source.obtainKey(ImageConfiguration.empty), isNot(key));
      final first = await resolveImage(small, evict: false);
      final second = await resolveImage(large, evict: false);
      expect((first.width, first.height), (64, 32));
      expect((second.width, second.height), (128, 64));
      first.dispose();
      second.dispose();
      await small.evict();
      await large.evict();
    });
  });

  testWidgets('a decoding error reaches the caller and a later request can retry', (tester) async {
    await tester.runAsync(() async {
      final valid = await solidPng(128, 64);
      var attempts = 0;
      final source = _RetryImage(() async => ++attempts == 1 ? Uint8List.fromList([1, 2, 3]) : valid);
      final provider = imageForDisplay(source, width: 32, height: 32, pixelRatio: 1);
      await expectLater(resolveImage(provider, evict: false), throwsA(isA<Exception>()));
      await Future<void>.delayed(Duration.zero);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      expect(PaintingBinding.instance.imageCache.statusForKey(key).pending, isFalse);
      expect(PaintingBinding.instance.imageCache.statusForKey(key).keepAlive, isFalse);
      final image = await resolveImage(provider);
      expect(attempts, 2);
      expect((image.width, image.height), (64, 32));
      image.dispose();
    });
  });

  testWidgets('invalid layout values never request an empty decode', (tester) async {
    await tester.runAsync(() async {
      final source = MemoryImage(await solidPng(8, 4));
      for (final (width, height, dpr) in [
        (0.0, 0.0, 1.0),
        (-1.0, double.infinity, 2.0),
        (64.0, 64.0, double.nan),
        (64.0, 64.0, 0.0),
      ]) {
        final image = await resolveImage(imageForDisplay(source, width: width, height: height, pixelRatio: dpr));
        expect((image.width, image.height), (2, 1));
        image.dispose();
      }
    });
  });

  for (final (w, h, boxW, boxH, decodedW, decodedH) in [
    (9, 7, 9, 7, 9, 7),
    (7, 9, 7, 9, 7, 9),
    (9, 14, 64, 64, 9, 14),
    (14, 9, 64, 64, 14, 9),
    (18, 28, 9, 14, 9, 14),
    (28, 18, 14, 9, 14, 9),
    (9, 7, 8, 6, 8, 7),
    (7, 9, 6, 8, 7, 8),
    (13, 17, 5, 5, 5, 7),
    (17, 13, 5, 5, 7, 5),
  ]) {
    testWidgets('integer cover rounding $w x $h into $boxW x $boxH', (tester) async {
      await tester.runAsync(() async {
        final decoded = await resolveImage(
          imageForDisplay(
            MemoryImage(await solidPng(w, h)),
            width: boxW.toDouble(),
            height: boxH.toDouble(),
            pixelRatio: 1,
          ),
        );
        expect((decoded.width, decoded.height), (decodedW, decodedH));
        decoded.dispose();
      });
    });
  }

  testWidgets('cover keeps every source pixel when no decode reduction is possible', (tester) async {
    await tester.runAsync(() async {
      for (final (w, h, boxW, boxH) in [(9, 7, 9, 7), (9, 14, 64, 64), (14, 9, 64, 64), (9, 14, 9, 3)]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final color = 0xFF000000 | (((x * 31 + y * 17) % 256) << 16) | ((x * 29 % 256) << 8) | (y * 43 % 256);
            canvas.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), Paint()..color = Color(color));
          }
        }
        final picture = recorder.endRecording();
        final raster = await picture.toImage(w, h);
        picture.dispose();
        final bytes = (await raster.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        raster.dispose();
        final source = MemoryImage(bytes);
        final original = await resolveImage(source);
        final decoded = await resolveImage(
          imageForDisplay(source, width: boxW.toDouble(), height: boxH.toDouble(), pixelRatio: 1),
        );
        expect((decoded.width, decoded.height), (w, h));
        final before = (await original.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        final after = (await decoded.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        expect(after, orderedEquals(before), reason: '$w x $h into $boxW x $boxH must not resample the source');
        original.dispose();
        decoded.dispose();
      }
    });
  });

  for (final (w, h) in [
    (1, 1),
    (1, 7),
    (7, 1),
    (2, 3),
    (3, 2),
    (3, 1024),
    (1024, 3),
    (7, 9),
    (9, 7),
    (9, 14),
    (14, 9),
    (18, 28),
    (28, 18),
    (21, 35),
    (35, 21),
    (29, 43),
    (43, 29),
    (63, 64),
    (64, 63),
    (127, 255),
    (255, 127),
  ]) {
    testWidgets('actual codec obeys the rational cover bounds for $w x $h', (tester) async {
      await tester.runAsync(() async {
        final source = MemoryImage(await solidPng(w, h));
        final records = <Map<String, Object>>[];
        for (final (boxW, boxH) in <(int, int)>{
          (1, 1),
          (1, 3),
          (3, 1),
          (2, 2),
          (2, 5),
          (5, 2),
          (3, 7),
          (7, 3),
          (5, 5),
          (6, 8),
          (8, 6),
          (7, 9),
          (9, 7),
          (9, 14),
          (14, 9),
          (11, 5),
          (5, 11),
          (17, 19),
          (19, 17),
          (31, 32),
          (32, 31),
          (64, 64),
          (w, h),
          (w * 2, h * 2),
        }) {
          final decoded = await resolveImage(
            imageForDisplay(source, width: boxW.toDouble(), height: boxH.toDouble(), pixelRatio: 1),
          );
          final dw = decoded.width;
          final dh = decoded.height;
          decoded.dispose();
          final reason = '$w x $h into $boxW x $boxH decoded $dw x $dh';
          if (boxW >= w || boxH >= h) {
            expect((dw, dh), (w, h), reason: reason);
          } else {
            expect(dw, inInclusiveRange(boxW, w), reason: reason);
            expect(dh, inInclusiveRange(boxH, h), reason: reason);
            // Check the exact rational inequalities against the real codec result,
            // rather than duplicating the implementation's division expression.
            final widthAnchored = dw == boxW && (dh - 1) * w < h * boxW && h * boxW <= dh * w;
            final heightAnchored = dh == boxH && (dw - 1) * h < w * boxH && w * boxH <= dw * h;
            expect(widthAnchored || heightAnchored, isTrue, reason: '$reason must round only the other axis by <1px');
          }
          records.add({
            'source': [w, h],
            'box': [boxW, boxH],
            'decoded': [dw, dh],
          });
        }
        final outputPath = Platform.environment['A4_REVIEW_OUTPUT'];
        if (outputPath != null) {
          final output = Directory('$outputPath/rounding-matrix');
          await output.create(recursive: true);
          await File('${output.path}/${w}x$h.json').writeAsString('${jsonEncode(records)}\n');
        }
      });
    });
  }
}
