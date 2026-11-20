// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/beam/beam_painter.dart';
import 'package:dsh_app/ui/fx/beam/border_beam.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

const _childKey = Key('child');

Widget _app(Widget beam, {bool reduced = false, ThemeData? theme}) => MaterialApp(
  theme: theme,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Center(child: beam),
    ),
  ),
);

Widget _beam({
  BorderBeamSize size = BorderBeamSize.md,
  BorderBeamColorVariant? variant,
  bool active = true,
  VoidCallback? onActivate,
  VoidCallback? onDeactivate,
}) => BorderBeam(
  size: size,
  colorVariant: variant,
  active: active,
  borderRadius: 16,
  onActivate: onActivate,
  onDeactivate: onDeactivate,
  child: const SizedBox(key: _childKey, width: 240, height: 64),
);

CustomPaint _paint(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.descendant(of: find.byType(BorderBeam), matching: find.byType(CustomPaint)).first);

BeamFrame _frame(WidgetTester tester) => (_paint(tester).foregroundPainter! as BeamPainter).frame;

void main() {
  testWidgets('wraps the child without changing its layout', (tester) async {
    for (final size in BorderBeamSize.values) {
      await tester.pumpWidget(_app(_beam(size: size)));
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.getSize(find.byKey(_childKey)), const Size(240, 64));
      expect(tester.getSize(find.byType(BorderBeam)), const Size(240, 64));
      expect(_paint(tester).foregroundPainter, isA<BeamPainter>());
      expect(_paint(tester).painter, size == BorderBeamSize.pulseOutside ? isA<BeamPainter>() : isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('every type and palette paints on dark and light', (tester) async {
    for (final brightness in Brightness.values) {
      for (final size in BorderBeamSize.values) {
        for (final variant in [null, ...BorderBeamColorVariant.values]) {
          await tester.pumpWidget(
            _app(
              KeyedSubtree(
                key: ValueKey('$size$variant'),
                child: _beam(size: size, variant: variant),
              ),
              theme: ThemeData(brightness: brightness),
            ),
          );
          await tester.pump(const Duration(milliseconds: 800));
          await tester.pump(const Duration(milliseconds: 900));
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('fades in, runs, fades out and stops', (tester) async {
    var activated = 0;
    var deactivated = 0;
    Widget beam(bool active) => _beam(active: active, onActivate: () => activated++, onDeactivate: () => deactivated++);

    await tester.pumpWidget(_app(beam(true)));
    await tester.pump();
    expect(_frame(tester).fade, 0);
    await tester.pump(const Duration(milliseconds: 300));
    final midFade = _frame(tester).fade;
    expect(midFade, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_frame(tester).fade, 1);
    expect(activated, 1);
    final t = _frame(tester).t;
    await tester.pump(const Duration(milliseconds: 500));
    expect(_frame(tester).t, greaterThan(t)); // the beam keeps moving
    expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(_app(beam(false)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_paint(tester).foregroundPainter, isNotNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(_paint(tester).foregroundPainter, isNull);
    expect(deactivated, 1);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);

    // Switching back on fades in again from nothing.
    await tester.pumpWidget(_app(beam(true)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_frame(tester).fade, inExclusiveRange(0, 0.5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(activated, 2);
  });

  testWidgets('reduced motion shows a still frame and runs no loop', (tester) async {
    var activated = 0;
    var deactivated = 0;
    for (final size in BorderBeamSize.values) {
      await tester.pumpWidget(
        _app(
          KeyedSubtree(
            key: ValueKey(size),
            child: _beam(size: size, onActivate: () => activated++, onDeactivate: () => deactivated++),
          ),
          reduced: true,
        ),
      );
      await tester.pump();
      expect(_frame(tester).still, isTrue);
      expect(_frame(tester).fade, 1);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
    }
    expect(activated, BorderBeamSize.values.length);

    await tester.pumpWidget(
      _app(
        KeyedSubtree(
          key: const ValueKey(BorderBeamSize.pulseInner),
          child: _beam(size: BorderBeamSize.pulseInner, active: false, onDeactivate: () => deactivated++),
        ),
        reduced: true,
      ),
    );
    await tester.pump();
    expect(_paint(tester).foregroundPainter, isNull);
    expect(deactivated, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pauses while TickerMode is off', (tester) async {
    await tester.pumpWidget(_app(TickerMode(enabled: false, child: _beam())));
    await tester.pump(const Duration(seconds: 1));
    expect(_frame(tester).fade, 0);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('does not take taps from what is under it', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        BorderBeam(
          size: BorderBeamSize.pulseOutside,
          borderRadius: 16,
          child: SizedBox(
            width: 200,
            height: 48,
            child: TextButton(onPressed: () => taps++, child: const Text('Go')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.text('Go'));
    expect(taps, 1);
  });
}
