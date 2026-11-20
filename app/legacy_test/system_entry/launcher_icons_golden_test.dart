// Golden of the launcher-shortcut icons and the Quick Settings tile glyph,
// drawn from the Android resources that ship (support/vector_drawable.dart)
// and masked the way a launcher shows them: a review aid for icons no Flutter
// screen draws. Regenerate with
// `flutter test --update-goldens test/system_entry/launcher_icons_golden_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show loadTestFonts, testTheme;
import 'support/vector_drawable.dart';

class _IconPainter extends CustomPainter {
  _IconPainter(this.glyph, this.background, this.foreground);

  final VectorGlyph glyph;
  final Color background;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    // Launchers show the middle 72dp of the 108dp canvas, masked (a circle here).
    final scale = size.width / 72;
    canvas
      ..save()
      ..clipPath(Path()..addOval(Offset.zero & size))
      ..drawRect(Offset.zero & size, Paint()..color = background)
      ..scale(scale)
      ..translate(-18, -18)
      ..drawPath(glyph.toPath(), Paint()..color = foreground)
      ..restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) => false;
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final VectorGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / glyph.viewport.width)
      ..drawPath(glyph.toPath(), Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => false;
}

/// The icons as a launcher's long-press menu and a Quick Settings panel
/// would hold them (the surroundings are neutral stand-ins).
class _IconSheet extends StatelessWidget {
  const _IconSheet({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final bg = resolveColor('@color/shortcut_icon_background', dark: dark);
    final fg = resolveColor('@color/shortcut_icon_glyph', dark: dark);
    final text = Theme.of(context).textTheme;
    final panel = dark ? const Color(0xFF1F2128) : const Color(0xFFF3F4F8);
    final ink = dark ? const Color(0xFFE6E8EF) : const Color(0xFF1B1E26);
    Widget icon(String name, String label) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size.square(48),
          painter: _IconPainter(VectorGlyph.load('ic_shortcut_${name}_glyph'), bg, fg),
        ),
        const SizedBox(height: 8),
        Text(label, style: text.labelMedium?.copyWith(color: ink)),
      ],
    );
    return ColoredBox(
      color: dark ? const Color(0xFF121318) : const Color(0xFFFFFFFF),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(24)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon('new_chat', '新对话'),
                  const SizedBox(width: 20),
                  icon('voice', '语音输入'),
                  const SizedBox(width: 20),
                  icon('chat', '修复登录…'),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 176,
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(32)),
              child: Row(
                children: [
                  CustomPaint(
                    size: const Size.square(24),
                    painter: _GlyphPainter(VectorGlyph.load('ic_tile_new_chat'), ink),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('新对话', style: text.titleSmall?.copyWith(color: ink)),
                      Text('DSH', style: text.bodySmall?.copyWith(color: ink.withValues(alpha: 0.7))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('launcher icons ($suffix)', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(360 * 3, 240 * 3);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: testTheme(brightness),
          home: _IconSheet(dark: brightness == Brightness.dark),
        ),
      );
      await tester.pump();
      await expectLater(find.byType(_IconSheet), matchesGoldenFile('goldens/launcher_icons_$suffix.png'));
    });
  }
}
