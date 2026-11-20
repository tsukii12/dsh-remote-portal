// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/orbs/thinking_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

final _shot = GlobalKey();

Widget _host(Widget orb, {Brightness brightness = Brightness.light, bool reduced = false}) => MaterialApp(
  theme: ThemeData(brightness: brightness, colorSchemeSeed: const Color(0xFF4B67B4)),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Center(
      child: RepaintBoundary(key: _shot, child: orb),
    ),
  ),
);

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return bytes!.buffer.asUint8List();
  }))!;
}

int _inked(Uint8List rgba) {
  var n = 0;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] > 0) n++;
  }
  return n;
}

void main() {
  testWidgets('every state and size paints and animates', (tester) async {
    for (final brightness in Brightness.values) {
      for (final size in OrbSize.values) {
        for (final state in OrbState.values) {
          await tester.pumpWidget(
            _host(
              ThinkingOrb(state: state, size: size),
              brightness: brightness,
            ),
          );
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.getSize(find.byType(ThinkingOrb)), Size.square(size.px));
          expect(tester.binding.transientCallbackCount, greaterThan(0), reason: '${state.name} ticks');
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('frames move while running and hold under reduced motion', (tester) async {
    await tester.pumpWidget(_host(const ThinkingOrb(state: OrbState.searching)));
    await tester.pump(const Duration(milliseconds: 16));
    final a = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final b = await _pixels(tester);
    expect(_inked(a), greaterThan(200));
    expect(a, isNot(equals(b)));

    await tester.pumpWidget(_host(const ThinkingOrb(state: OrbState.searching), reduced: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    final c = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(await _pixels(tester), equals(c));
    // the still frame is the same instant a frozen orb at 0.6 shows
    await tester.pumpWidget(_host(const OrbFrozenTime(t: 0.6, child: ThinkingOrb(state: OrbState.searching))));
    await tester.pump();
    expect(await _pixels(tester), equals(c));
  });

  testWidgets('paused, frozen and hidden orbs stop their ticker', (tester) async {
    await tester.pumpWidget(_host(const ThinkingOrb(paused: true)));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_host(const ThinkingOrb()));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(_host(const TickerMode(enabled: false, child: ThinkingOrb())));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_host(const OrbFrozenTime(t: 2, child: ThinkingOrb())));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('displaySize scales the tuned geometry into a different box', (tester) async {
    await tester.pumpWidget(
      _host(const OrbFrozenTime(t: 1.7, child: ThinkingOrb(size: OrbSize.px20, displaySize: 28))),
    );
    expect(tester.getSize(find.byType(ThinkingOrb)), const Size.square(28));
    expect(_inked(await _pixels(tester)), greaterThan(60));
  });

  testWidgets('a label puts the orb in the semantics tree; none keeps it out', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const ThinkingOrb(state: OrbState.listening, semanticLabel: '正在听')));
    expect(find.bySemanticsLabel('正在听'), findsOneWidget);
    await tester.pumpWidget(_host(const ThinkingOrb(state: OrbState.listening)));
    expect(find.bySemanticsLabel('正在听'), findsNothing);
    handle.dispose();
  });

  test('ink: mono is the stock white / black, theme keeps the primary hue but quiet', () {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4B67B4));
    expect(const OrbInk.mono().resolve(scheme, dark: true), const Color(0xFFFFFFFF));
    expect(const OrbInk.mono().resolve(scheme, dark: false), const Color(0xFF000000));
    expect(const OrbInk.tint(Color(0xFF336699)).resolve(scheme, dark: true), const Color(0xFF336699));

    final primary = HSLColor.fromColor(scheme.primary);
    for (final dark in [true, false]) {
      final ink = HSLColor.fromColor(const OrbInk.theme().resolve(scheme, dark: dark));
      // 8-bit channels at this lightness move the hue a degree or two
      expect(ink.hue, closeTo(primary.hue, 4));
      expect(ink.saturation, lessThanOrEqualTo(0.43));
      expect(ink.lightness, dark ? greaterThan(0.85) : lessThan(0.2));
    }
  });
}
