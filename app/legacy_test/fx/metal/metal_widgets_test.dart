// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/metal/metal_badge.dart';
import 'package:dsh_app/ui/fx/metal/metal_fx.dart';
import 'package:dsh_app/ui/fx/metal/metal_material.dart';
import 'package:dsh_app/ui/fx/metal/metal_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.dark, bool reduced = false}) => MaterialApp(
  theme: ThemeData(brightness: brightness, colorSchemeSeed: const Color(0xFF3F6AD8)),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

void main() {
  testWidgets('MetalFx animates, bends on a press and keeps its child tappable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        MetalFx(
          child: SizedBox(
            width: 160,
            height: 44,
            child: TextButton(onPressed: () => taps++, child: const Text('升级到 Pro')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.hasScheduledFrame, isTrue);

    final gesture = await tester.startGesture(tester.getCenter(find.text('升级到 Pro')) - const Offset(0, 14));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the circle variant and the presets render in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      for (final preset in [null, ...MetalPreset.values]) {
        await tester.pumpWidget(
          _host(
            MetalFx(
              variant: MetalFxVariant.circle,
              preset: preset,
              innerShadow: true,
              child: const SizedBox.square(dimension: 40, child: Icon(Icons.arrow_upward)),
            ),
            brightness: brightness,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion and paused show a still frame without a loop', (tester) async {
    await tester.pumpWidget(_host(const MetalText('欢迎回来', glow: true), reduced: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_host(const MetalBadge(text: '新', paused: true)));
    await tester.pump();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(_host(const MetalBadge(text: '新')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MetalText lays out like Text and reads as its text', (tester) async {
    const style = TextStyle(fontSize: 32);
    await tester.pumpWidget(
      _host(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MetalText('你好，欢迎回来', style: style, textAlign: TextAlign.center),
            Text('你好，欢迎回来', style: style, textAlign: TextAlign.center),
          ],
        ),
        brightness: Brightness.light,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final sizes = tester.renderObjectList<RenderBox>(find.byType(RichText)).map((b) => b.size).toList();
    expect(sizes[0], sizes[1]);
    expect(find.bySemanticsLabel('你好，欢迎回来'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MetalBadge keeps the Figma size and grows for longer labels', (tester) async {
    await tester.pumpWidget(_host(const MetalBadge()));
    // Within half a pixel: label widths differ a little between font builds.
    final first = tester.getSize(find.byType(MetalBadge));
    expect(first.width, moreOrLessEquals(45, epsilon: 0.5));
    expect(first.height, 25);
    await tester.pumpWidget(_host(const MetalBadge(text: '新版本可用', scale: 1.2)));
    final size = tester.getSize(find.byType(MetalBadge));
    expect(size.height, 30);
    expect(size.width, greaterThan(54));
    expect(find.text('新版本可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
