// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// Preview frames of the author's three demos (sites/gooey PlusMenu, Tabs,
// DragCard) rebuilt on the port, in four columns: the author's colours light
// and dark, then the app theme's light and dark. Runs only with
// `--dart-define=FX_PREVIEW_OUT=<dir>`; writes `<dir>/<demo>/f###.png` plus a
// still for the filter comparison (`<dir>/compare_flutter.png`).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/gooey/gooey.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _out = String.fromEnvironment('FX_PREVIEW_OUT');
const _shotKey = ValueKey('shot');
const _paneW = 360.0;

class _Variant {
  const _Variant(this.brightness, {required this.lab});

  final Brightness brightness;
  final bool lab;

  bool get dark => brightness == Brightness.dark;
  ThemeData get theme => dark ? buildDarkTheme() : buildLightTheme();
}

const _variants = [
  _Variant(Brightness.light, lab: true),
  _Variant(Brightness.dark, lab: true),
  _Variant(Brightness.light, lab: false),
  _Variant(Brightness.dark, lab: false),
];

LiquidPalette _palette(BuildContext context, _Variant v) =>
    v.lab ? LiquidPalette.lab(v.brightness) : LiquidPalette.of(context);

/// The author's plus menu: three satellites bloom out of a 40 px ＋.
class _PlusMenuDemo extends StatefulWidget {
  const _PlusMenuDemo({required this.open, required this.variant});

  final bool open;
  final _Variant variant;

  @override
  State<_PlusMenuDemo> createState() => _PlusMenuDemoState();
}

class _PlusMenuDemoState extends State<_PlusMenuDemo> with SingleTickerProviderStateMixin {
  late final _clock = AnimationController(vsync: this, duration: LiquidMenu.anticipationDuration, value: 1);
  bool _toggled = false;

  @override
  void didUpdateWidget(_PlusMenuDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      _toggled = true;
      _clock.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette(context, widget.variant);
    final open = widget.open;
    return AnimatedBuilder(
      animation: _clock,
      builder: (context, _) {
        final ms = _clock.value * LiquidMenu.anticipationDuration.inMilliseconds;
        const ease = Cubic(0.25, 0.1, 0.25, 1);
        double icon(int i) {
          if (!_toggled) return open ? 1 : 0;
          if (open) {
            final start = LiquidMenu.iconDelay.inMilliseconds + i * LiquidMenu.openStagger.inMilliseconds;
            return ease.transform(((ms - start) / LiquidMenu.iconIn.inMilliseconds).clamp(0.0, 1.0));
          }
          return 1 - ease.transform((ms / LiquidMenu.iconOut.inMilliseconds).clamp(0.0, 1.0));
        }

        final turnT = _toggled
            ? Curves.easeInOut.transform((ms / LiquidMenu.plusTurn.inMilliseconds).clamp(0.0, 1.0))
            : 1.0;
        final turn = (open ? turnT : 1 - turnT) * 0.25 * 3.14159265;
        final dip = _toggled && !open ? LiquidMenu.anticipationAt(_clock.value) : 0.0;
        return Transform.translate(
          offset: Offset(0, dip),
          child: Liquid(
            fill: p.surface,
            shadows: LiquidShadows.figmaSoft(widget.variant.brightness),
            child: SizedBox(
              width: 200,
              height: 140,
              child: Stack(
                children: [
                  for (final (i, s) in LiquidMenu.satellites.indexed)
                    Positioned(
                      left: 80,
                      top: 80,
                      child: LiquidItem(
                        x: open ? s.dx : 0,
                        y: open ? s.dy : 0,
                        transition: open ? LiquidMenu.open : LiquidMenu.close,
                        delay: (open ? LiquidMenu.openStagger : LiquidMenu.closeStagger) * i,
                        radius: BorderRadius.circular(999),
                        child: SizedBox.square(
                          dimension: LiquidMenu.button,
                          child: Center(
                            child: ImageFiltered(
                              imageFilter: ui.ImageFilter.blur(
                                sigmaX: (1 - icon(i)) * LiquidMenu.iconBlur / 2,
                                sigmaY: (1 - icon(i)) * LiquidMenu.iconBlur / 2,
                              ),
                              child: Opacity(
                                opacity: icon(i),
                                child: Icon(
                                  [AppIcons.files, AppIcons.addImage, AppIcons.folder][i],
                                  size: 16,
                                  color: p.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 80,
                    top: 80,
                    child: LiquidItem(
                      radius: BorderRadius.circular(999),
                      child: SizedBox.square(
                        dimension: LiquidMenu.button,
                        child: Center(
                          child: Transform.rotate(
                            angle: turn,
                            child: Icon(AppIcons.add, size: 20, color: p.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The author's liquid tabs: the indicator slides on a 250 ms curve, the
/// liquid trails it.
class _TabsDemo extends StatelessWidget {
  const _TabsDemo({required this.active, required this.variant, this.move = const MoveTuning()});

  final int active;
  final _Variant variant;
  final MoveTuning move;

  static const _labels = ['Plan', 'Debug', 'Ask'];

  @override
  Widget build(BuildContext context) {
    final p = _palette(context, variant);
    final style = Theme.of(context).textTheme.labelLarge!
        .copyWith(fontSize: 13, fontWeight: FontWeight.w500, height: 1.4);
    final widths = [
      for (final l in _labels)
        (TextPainter(
              text: TextSpan(text: l, style: style),
              textDirection: TextDirection.ltr,
            )..layout()).width +
            26,
    ];
    final lefts = <double>[];
    var x = LiquidTabs.padding;
    for (final w in widths) {
      lefts.add(x);
      x += w + LiquidTabs.gap;
    }
    final label = variant.lab
        ? (variant.dark ? const Color.fromRGBO(251, 251, 251, 0.72) : const Color.fromRGBO(15, 15, 15, 0.8))
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: variant.dark ? 0.72 : 0.8);
    return Liquid(
      blur: LiquidTabs.blur,
      fill: p.indicator,
      shadows: LiquidShadows.tabPill(variant.brightness),
      child: SizedBox(
        width: x - LiquidTabs.gap + LiquidTabs.padding,
        height: LiquidTabs.height + LiquidTabs.padding * 2,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: LiquidTabs.slide,
              curve: LiquidTabs.slideCurve,
              left: lefts[active],
              top: LiquidTabs.padding,
              width: widths[active],
              height: LiquidTabs.height,
              child: LiquidItem(
                effect: LiquidEffect.move,
                move: move,
                radius: BorderRadius.circular(48),
                child: const SizedBox.expand(),
              ),
            ),
            for (var i = 0; i < _labels.length; i++)
              Positioned(
                left: lefts[i],
                top: LiquidTabs.padding,
                width: widths[i],
                height: LiquidTabs.height,
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    duration: LiquidTabs.slide,
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    style: style.copyWith(color: i == active ? p.onIndicator : label),
                    child: Text(_labels[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The author's drag card: a 261×46 pill whose liquid bows while dragged.
class _DragCardDemo extends StatelessWidget {
  const _DragCardDemo({required this.offset, required this.lift, required this.variant});

  final Offset offset;
  final double lift;
  final _Variant variant;

  @override
  Widget build(BuildContext context) {
    final p = _palette(context, variant);
    double lerp(double a, double b) => a + (b - a) * lift;
    final shadows = variant.lab && !variant.dark
        ? [
            const LiquidShadow(color: Color.fromRGBO(0, 0, 0, 0.08), spread: 1),
            LiquidShadow(color: const Color.fromRGBO(0, 0, 0, 0.04), offset: Offset(0, lerp(1, 3)), blur: lerp(3, 5)),
            LiquidShadow(
              color: Color.fromRGBO(0, 0, 0, 0.04 * lift),
              offset: Offset(0, lerp(0, 10)),
              blur: lerp(0, 24),
            ),
          ]
        : LiquidShadows.figmaSoft(variant.brightness);
    return Liquid(
      fill: p.surface,
      shadows: shadows,
      child: SizedBox(
        width: 340,
        height: 210,
        child: Center(
          child: Transform.translate(
            offset: offset,
            child: LiquidItem(
              effect: LiquidEffect.bend,
              radius: BorderRadius.circular(54),
              child: SizedBox(
                width: 261,
                height: 46,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, right: 16),
                  child: Row(
                    spacing: 8,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: ShapeDecoration(
                          color: variant.dark
                              ? const Color.fromRGBO(255, 255, 255, 0.06)
                              : const Color.fromRGBO(235, 235, 236, 0.3),
                          shape: CircleBorder(
                            side: BorderSide(
                              color: variant.dark
                                  ? const Color.fromRGBO(255, 255, 255, 0.08)
                                  : const Color.fromRGBO(0, 0, 0, 0.05),
                            ),
                          ),
                        ),
                        child: Icon(AppIcons.folder, size: 16, color: p.onSurface),
                      ),
                      Text(
                        'Gooey Project',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: p.onSurface),
                      ),
                      Text('45 files', style: TextStyle(fontSize: 13, color: p.onSurface.withValues(alpha: 0.5))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _row(double height, Widget Function(_Variant v) demo) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Align(
    alignment: Alignment.topLeft,
    child: RepaintBoundary(
      key: _shotKey,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in _variants)
            Theme(
              data: v.theme,
              child: Builder(
                builder: (context) => Material(
                  type: MaterialType.transparency,
                  child: ColoredBox(
                    color: v.lab
                        ? (v.dark ? const Color(0xFF131313) : const Color(0xFFEFEFF0))
                        : Theme.of(context).colorScheme.surface,
                    child: SizedBox(
                      width: _paneW,
                      height: height,
                      child: Center(child: demo(v)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);

Future<void> _save(WidgetTester tester, String path, {double ratio = 2}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _record(
  WidgetTester tester,
  String demo,
  double height,
  int frames,
  Widget Function(_Variant v, int frame) build,
) async {
  final dir = Directory('$_out/$demo')..createSync(recursive: true);
  for (final f in dir.listSync()) {
    f.deleteSync();
  }
  tester.view
    ..physicalSize = Size(_paneW * _variants.length, height)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  for (var frame = 0; frame < frames; frame++) {
    await tester.pumpWidget(_row(height, (v) => build(v, frame)), duration: const Duration(milliseconds: 16));
    if (frame.isEven) await _save(tester, '${dir.path}/f${(frame ~/ 2).toString().padLeft(3, '0')}.png');
  }
}

double _ease(double t) => Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));

void main() {
  testWidgets('gooey preview: plus menu (morph)', skip: _out.isEmpty, (tester) async {
    // Closed 4 frames, open at 4, close at 54 (with the dip).
    await _record(tester, 'plus_menu', 190, 110, (v, f) => _PlusMenuDemo(open: f >= 4 && f < 54, variant: v));
  });

  testWidgets('gooey preview: tabs (move)', skip: _out.isEmpty, (tester) async {
    await _record(
      tester,
      'tabs',
      80,
      110,
      (v, f) => _TabsDemo(
        active: f < 4
            ? 0
            : f < 54
            ? 2
            : 1,
        variant: v,
      ),
    );
  });

  testWidgets('gooey preview: tabs, doc recipe (move)', skip: _out.isEmpty, (tester) async {
    await _record(
      tester,
      'tabs_recipe',
      80,
      110,
      (v, f) => _TabsDemo(
        active: f < 4
            ? 0
            : f < 54
            ? 2
            : 1,
        variant: v,
        move: LiquidTabs.move,
      ),
    );
  });

  testWidgets('gooey preview: drag card (bend)', skip: _out.isEmpty, (tester) async {
    const release = Cubic(0.34, 1.40, 0.64, 1);
    Offset at(int f) {
      if (f < 5) return Offset.zero;
      if (f < 17) return Offset(0, 64 * _ease((f - 5) / 12));
      if (f < 31) return Offset(36 * Curves.easeInOut.transform((f - 17) / 14), 64);
      if (f < 37) return const Offset(36, 64);
      return const Offset(36, 64) * (1 - release.transform(((f - 37) / 25).clamp(0.0, 1.0)));
    }

    double lift(int f) {
      final dragging = f >= 5 && f < 37;
      final since = dragging ? f - 5 : f - 37;
      final t = Curves.easeInOutCubic.transform((since * 16 / 300).clamp(0.0, 1.0));
      if (f < 5) return 0;
      return dragging ? t : 1 - t;
    }

    await _record(tester, 'drag_card', 240, 90, (v, f) => _DragCardDemo(offset: at(f), lift: lift(f), variant: v));
  });

  testWidgets('gooey preview: filter comparison still', skip: _out.isEmpty, (tester) async {
    // Satellites 40 % of the way out, no shadows, #202020 on white: the numpy
    // run of the SVG chain (feGaussianBlur σ6 → alpha ×18 − 7) draws the same.
    tester.view
      ..physicalSize = const Size(200, 140)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: _shotKey,
          child: ColoredBox(
            color: Colors.white,
            child: Liquid(
              fill: const Color(0xFF202020),
              child: SizedBox(
                width: 200,
                height: 140,
                child: Stack(
                  children: [
                    for (final s in [...LiquidMenu.satellites, Offset.zero])
                      Positioned(
                        left: 80,
                        top: 80,
                        child: LiquidItem(
                          x: s.dx * 0.4,
                          y: s.dy * 0.4,
                          radius: BorderRadius.circular(999),
                          child: const SizedBox.square(dimension: 40),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Directory(_out).createSync(recursive: true);
    await _save(tester, '$_out/compare_flutter.png', ratio: 1);
  });
}
