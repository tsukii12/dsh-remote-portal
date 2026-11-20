// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Preview frames, only when asked:
//   flutter test test/fx/metal/metal_preview_test.dart --dart-define=FX_PREVIEW_OUT=<dir>
// Writes <dir>/{dark,light}_NNN.png over ten seconds (the halo appearing and
// wandering, a press on the circle at 3 s, the light sweep from 5.4 s) and
// <dir>/sheet_flutter.png, a raw 140×40 crop of the material at t = 2 s for a
// pixel comparison with the numpy port of the shader.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/metal/metal_badge.dart';
import 'package:dsh_app/ui/fx/metal/metal_fx.dart';
import 'package:dsh_app/ui/fx/metal/metal_material.dart';
import 'package:dsh_app/ui/fx/metal/metal_shader.dart';
import 'package:dsh_app/ui/fx/metal/metal_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');

void main() {
  testWidgets('metal preview frames', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Directory(out).createSync(recursive: true);
    final program = await tester.runAsync(MetalShader.load);
    expect(program, isNotNull);

    final keys = {for (final b in Brightness.values) b: GlobalKey()};
    final sheetKey = GlobalKey();
    final shading = MetalShading()..shader = program!.fragmentShader();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in Brightness.values) _Card(brightness: b, boundary: keys[b]!),
            RepaintBoundary(
              key: sheetKey,
              child: CustomPaint(size: const Size(140, 40), painter: _SheetPainter(shading)),
            ),
          ],
        ),
      ),
    );

    Future<void> capture(GlobalKey key, String name, {double ratio = 3}) => tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });

    await tester.pump();
    await capture(sheetKey, 'sheet_flutter', ratio: 4);

    const stepMs = 16;
    const everySteps = 8; // a frame every 128 ms
    TestGesture? press;
    var frame = 0;
    for (var step = 0; step * stepMs <= 10000; step++) {
      final t = step * stepMs;
      if (t == 3008) {
        final circle = tester.getRect(find.byKey(const ValueKey('circle-dark')));
        press = await tester.startGesture(circle.topRight + const Offset(-8, 9));
      } else if (t > 3008 && t < 3600) {
        await press!.moveBy(const Offset(-0.4, 0.2));
      } else if (t == 3600) {
        await press!.up();
      }
      await tester.pump(const Duration(milliseconds: stepMs));
      if (step % everySteps == 0) {
        for (final b in Brightness.values) {
          await capture(keys[b]!, '${b.name}_${frame.toString().padLeft(3, '0')}');
        }
        frame++;
      }
    }
    expect(tester.takeException(), isNull);
  }, skip: out.isEmpty);
}

class _Card extends StatelessWidget {
  const _Card({required this.brightness, required this.boundary});

  final Brightness brightness;
  final GlobalKey boundary;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(brightness: brightness, colorSchemeSeed: const Color(0xFF3F6AD8));
    final dark = brightness == Brightness.dark;
    return MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 3),
      child: Theme(
        data: theme,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium!,
          child: RepaintBoundary(
            key: boundary,
            child: Container(
              width: 390,
              color: theme.colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MetalText(
                    '你好，欢迎回来',
                    style: theme.textTheme.displaySmall?.copyWith(height: 1.35),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('设置', style: theme.textTheme.titleMedium),
                      const SizedBox(width: 10),
                      const MetalBadge(text: '新'),
                      const SizedBox(width: 28),
                      const MetalBadge(),
                      const SizedBox(width: 28),
                      const MetalBadge(text: '新版本'),
                    ],
                  ),
                  const SizedBox(height: 40),
                  MetalFx(
                    child: SizedBox(
                      width: 180,
                      height: 44,
                      child: Center(child: Text('开始使用', style: theme.textTheme.titleSmall)),
                    ),
                  ),
                  const SizedBox(height: 36),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      MetalFx(
                        key: ValueKey('circle-${brightness.name}'),
                        variant: MetalFxVariant.circle,
                        innerShadow: true,
                        strength: 0.9,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          child: const SizedBox.square(dimension: 44, child: Icon(Icons.arrow_upward, size: 20)),
                        ),
                      ),
                      const SizedBox(width: 40),
                      MetalText(
                        'Pro',
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w500),
                        glow: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final p in MetalPreset.values)
                        MetalFx(
                          preset: p,
                          strength: p == MetalPreset.chromatic ? 0.7 : 1,
                          child: SizedBox(
                            width: 96,
                            height: 34,
                            child: Center(child: Text(p.name, style: theme.textTheme.labelMedium)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dark ? 'dark · theme graphite / chromatic · silver · gold' : 'light',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The raw material over a 140×40 box at shader scale 1.6, chromatic dark, t = 2 s.
class _SheetPainter extends CustomPainter {
  _SheetPainter(this.shading);

  final MetalShading shading;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final material = MetalMaterial.preset(MetalPreset.chromatic, Brightness.dark);
    canvas.drawRect(Offset.zero & size, shading.paint(material, MetalSheetMapping(size, 1.6), size, 2, 1, 4));
  }

  @override
  bool shouldRepaint(_SheetPainter oldDelegate) => false;
}
