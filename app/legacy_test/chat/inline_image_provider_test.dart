import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  test('inline decoding uses physical reading bounds and never requests upscaling', () {
    final source = MemoryImage(Uint8List(0));
    final resized = inlineImageProvider(source, 3, null) as ResizeImage;
    expect((resized.width, resized.height, resized.policy), (2160, 1440, ResizeImagePolicy.fit));
    expect(resized.allowUpscaling, isFalse);
    final hinted = inlineImageProvider(source, 3, const Size(200, 100)) as ResizeImage;
    expect((hinted.width, hinted.height), (600, 300));
    expect((inlineImageProvider(source, 3, const Size(1000, 100)) as ResizeImage).width, 2160);
  });
  testWidgets('a large source decodes within the requested width', (tester) async {
    await tester.runAsync(() async {
      final source = MemoryImage(await png(4000, 3000));
      final provider = inlineImageProvider(source, 3, null);
      final done = Completer<ImageInfo>();
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((image, _) => done.complete(image), onError: done.completeError);
      stream.addListener(listener);
      final decoded = await done.future;
      expect(decoded.image.width, lessThanOrEqualTo(2160));
      expect(decoded.image.height, lessThanOrEqualTo(1440));
      stream.removeListener(listener);
      decoded.dispose();
      await provider.evict();
    });
  });
  testWidgets('opening an inline bitmap passes the original provider to the viewer', (tester) async {
    late Uint8List bytes;
    await tester.runAsync(() async {
      bytes = await png(40, 30);
    });
    final url = 'data:image/png;base64,${base64Encode(bytes)}';
    await tester.pumpWidget(
      testApp(
        Scaffold(body: MarkdownImage(url: url)),
        overrides: [activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))],
      ),
    );
    final context = tester.element(find.byType(MarkdownImage));
    final inline = tester.widget<Image>(find.byType(Image)).image;
    await tester.runAsync(() => precacheImage(inline, context));
    await pumpFrames(tester, 4);
    await tester.tap(find.byType(Image));
    await pumpFrames(tester, 4);
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.image, isA<MemoryImage>());
    expect((viewer.image as MemoryImage).bytes, orderedEquals(bytes));
  });
}
