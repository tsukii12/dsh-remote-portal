// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Renders preview frames of every beam type, palette and theme. Runs only when
// asked:
//   flutter test test/fx/beam/border_beam_preview_test.dart --dart-define=FX_PREVIEW_OUT=<dir>

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/beam/border_beam.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('FX_PREVIEW_OUT');

/// The iOS port's parity scene: a 348×122 card, radius 20, 60px around it.
const _card = Size(348, 122);
const _button = Size(132, 40);
const _pad = 60.0;

const _variants = <BorderBeamColorVariant?>[null, ...BorderBeamColorVariant.values];

Size _childSize(BorderBeamSize size) => size == BorderBeamSize.sm ? _button : _card;

Widget _cell({
  required BorderBeamSize size,
  required BorderBeamColorVariant? variant,
  required bool dark,
  bool active = true,
  Size? box,
  double? corner,
}) {
  final child = box ?? _childSize(size);
  final radius = corner ?? (size == BorderBeamSize.sm ? child.height / 2 : 20.0);
  return Theme(
    data: dark ? buildDarkTheme() : buildLightTheme(),
    child: ColoredBox(
      color: dark ? const Color(0xFF070707) : const Color(0xFFFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(_pad),
        child: BorderBeam(
          size: size,
          colorVariant: variant,
          active: active,
          borderRadius: radius,
          child: Container(
            width: child.width,
            height: child.height,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF181818) : const Color(0xFFF7F7F7),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: dark ? const Color(0xFF3D3D3D) : const Color(0xFFD9D9D9)),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('border beam preview frames', (tester) async {
    tester.view.physicalSize = const Size(4400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory(out)..createSync(recursive: true);
    final boundary = GlobalKey();

    Future<void> shot(String name, {double ratio = 1}) async {
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: ratio);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> show(Key key, Widget grid) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundary,
              child: KeyedSubtree(key: key, child: grid),
            ),
          ),
        ),
      );
      await tester.pump(); // first tick: the beam clock reads 0
    }

    Duration seconds(double s) => Duration(microseconds: (s * 1e6).round());

    // Every palette (theme-following first) on dark and light, at a moment
    // where the fade-in is done: the iOS port's freeze points (rotate 25% of a
    // turn, line mid-travel, pulse 0.8 s).
    const still = {
      BorderBeamSize.md: 1.96 + 0.49,
      BorderBeamSize.sm: 1.96 + 0.49,
      BorderBeamSize.line: 3.1 * 0.5,
      BorderBeamSize.pulseInner: 0.8,
      BorderBeamSize.pulseOutside: 0.8,
    };
    for (final size in BorderBeamSize.values) {
      await show(
        ValueKey('matrix-$size'),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final dark in [true, false])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final v in _variants) _cell(size: size, variant: v, dark: dark)],
              ),
          ],
        ),
      );
      await tester.pump(seconds(still[size]!));
      await shot('matrix_${size.name}');
    }

    // Motion: theme palette and Colorful, dark and light, from switching on
    // through a few cycles, then switching off. The last three are where the
    // app uses it: a chat composer while a reply streams, and a CTA button.
    final scenes = <(String, BorderBeamSize, Size?, double?)>[
      for (final size in BorderBeamSize.values) (size.name, size, null, null),
      ('composer_md', BorderBeamSize.md, const Size(360, 56), 24),
      ('composer_line', BorderBeamSize.line, const Size(360, 56), 24),
      ('cta_pulseInner', BorderBeamSize.pulseInner, const Size(180, 44), 22),
    ];
    for (final (name, size, box, corner) in scenes) {
      Widget grid(bool active) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final dark in [true, false])
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final v in const [null, BorderBeamColorVariant.colorful])
                  _cell(size: size, variant: v, dark: dark, active: active, box: box, corner: corner),
              ],
            ),
        ],
      );
      final key = ValueKey('motion-$name');
      await show(key, grid(true));
      final length = size.isPulse ? 4.6 : (size == BorderBeamSize.line ? 3.1 : 1.96 * 2);
      const step = 1 / 15;
      var i = 0;
      for (var t = 0.0; t < length; t += step) {
        await shot('motion_${name}_${(i++).toString().padLeft(3, '0')}');
        await tester.pump(seconds(step));
      }
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundary,
              child: KeyedSubtree(key: key, child: grid(false)),
            ),
          ),
        ),
      );
      for (var t = 0.0; t < 0.6; t += step) {
        await shot('motion_${name}_${(i++).toString().padLeft(3, '0')}');
        await tester.pump(seconds(step));
      }
    }
  }, skip: out.isEmpty);
}
