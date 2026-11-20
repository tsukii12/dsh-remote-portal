import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/theme/typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<List<int>> raster(String text, TextStyle style) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, const Offset(4, 4));
  final picture = recorder.endRecording();
  final image = await picture.toImage(500, 70);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  painter.dispose();
  return bytes;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('actual JetBrains code rendering keeps operator glyphs separate', (tester) async {
    await tester.runAsync(() async {
      const source = '<= >= != ->';
      final actual = AppType.mono(size: 28, color: Colors.black);
      final separated = actual.copyWith(
        fontFeatures: const [ui.FontFeature.disable('calt'), ui.FontFeature.disable('liga')],
      );
      final fontDefault = actual.copyWith(fontFeatures: const []);
      final plainPixels = await raster(source, separated);
      final defaultPixels = await raster(source, fontDefault);
      expect(defaultPixels, isNot(plainPixels), reason: 'loaded real JetBrains font must exercise operator ligatures');
      expect(
        await raster(source, actual),
        plainPixels,
        reason: 'code style must preserve separate source characters visually',
      );
    });
  });

  testWidgets('copy preserves ASCII operators and literal Unicode without replacements', (tester) async {
    const source = 'if (a <= b && c >= d && e != f) { x->y; } // ≤ ≥ ≠ →';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: CodeBlock(code: source, language: 'cpp', replyActions: true),
        ),
      ),
    );
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copied, source);
    await tester.pump(const Duration(milliseconds: 1300));
  });
}
