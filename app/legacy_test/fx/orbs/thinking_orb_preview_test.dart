// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Preview frames for eyeballing the port against the original. Runs only when
// asked: flutter test --dart-define=FX_PREVIEW_OUT=<dir> test/fx/orbs/thinking_orb_preview_test.dart
//
// - grid_<ink>_<theme>_<size>.png: every state (rows) frozen at the golden
//   instants 0.6 / 1.7 / 3.3 / 5.1 (columns), at 3x.
// - anim/NNN.png: the live ticker, 25 fps, 64 and 20 beside a label, light and
//   dark app themes.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/orbs/thinking_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');

const _times = [0.6, 1.7, 3.3, 5.1];
const _seed = Color(0xFF4B67B4);

const _labels = {
  OrbState.working: '正在处理',
  OrbState.searching: '正在搜索',
  OrbState.solving: '正在运行代码',
  OrbState.listening: '正在听',
  OrbState.connecting: '正在连接',
  OrbState.weaving: '正在规划',
  OrbState.composing: '正在写',
  OrbState.breathing: '正在思考',
  OrbState.shaping: '正在设计',
};

Future<void> _save(WidgetTester tester, GlobalKey key, String path, double ratio) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _grid(OrbSize size, bool dark, OrbInk ink) {
  final cell = size.px + 16;
  return ColoredBox(
    color: dark ? const Color(0xFF111214) : const Color(0xFFFFFFFF),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final state in OrbState.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in _times)
                SizedBox.square(
                  dimension: cell,
                  child: Center(
                    child: OrbFrozenTime(
                      t: t,
                      child: ThinkingOrb(
                        state: state,
                        size: size,
                        theme: dark ? OrbTheme.dark : OrbTheme.light,
                        ink: ink,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    ),
  );
}

Widget _panel(Brightness brightness) {
  final theme = ThemeData(brightness: brightness, colorSchemeSeed: _seed);
  return Theme(
    data: theme,
    child: Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  children: [
                    for (final state in OrbState.values)
                      SizedBox(
                        width: 84,
                        height: 84,
                        child: Center(child: ThinkingOrb(state: state)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final state in OrbState.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        ThinkingOrb(state: state, size: OrbSize.px20),
                        const SizedBox(width: 8),
                        Text('${_labels[state]}…', style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

void main() {
  testWidgets('preview frames', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    for (final (name, ink) in [('mono', const OrbInk.mono()), ('theme', const OrbInk.theme())]) {
      for (final dark in [true, false]) {
        for (final size in OrbSize.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(colorSchemeSeed: _seed),
              home: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(key: key, child: _grid(size, dark, ink)),
              ),
            ),
          );
          final theme = dark ? 'dark' : 'light';
          await _save(tester, key, '$out/grid_${name}_${theme}_${size.px.toInt()}.png', 3);
        }
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 280, child: _panel(Brightness.light)),
                SizedBox(width: 280, child: _panel(Brightness.dark)),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await _save(tester, key, '$out/anim/${i.toString().padLeft(3, '0')}.png', 2);
    }
  }, skip: out.isEmpty);
}
