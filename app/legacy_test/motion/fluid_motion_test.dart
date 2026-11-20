import 'dart:math' as math;

import 'package:dsh_app/ui/chat/widgets/stream_motion.dart';
import 'package:dsh_app/ui/common/app_dialog.dart';
import 'package:dsh_app/ui/common/fade_in.dart';
import 'package:dsh_app/ui/common/fluid_bits.dart';
import 'package:dsh_app/ui/common/pressable.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/common/tile_grid.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app's shell, as far as motion goes: the theme and scope `lib/app.dart` puts
/// around every page.
Widget shell(Widget home, {required bool fluid, bool reduced = false, ThemeMode mode = ThemeMode.light}) => MaterialApp(
  theme: buildLightTheme(fluid: fluid, instantPages: reduced),
  darkTheme: buildDarkTheme(fluid: fluid, instantPages: reduced),
  themeMode: mode,
  themeAnimationStyle: AnimationStyle.noAnimation,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: AppMotionScope(
      fluid: fluid,
      child: ThemeRevealHost(child: child!),
    ),
  ),
  home: home,
);

void main() {
  group('AppMotion.fluid', () {
    Future<bool> read(WidgetTester tester, Widget Function(Widget) wrap) async {
      late bool value;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              value = AppMotion.fluid(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return value;
    }

    testWidgets('off without a scope: previews and tests stay on the standard tier', (tester) async {
      expect(await read(tester, (child) => child), isFalse);
    });

    testWidgets('on under a fluid scope, and never with animations removed', (tester) async {
      expect(await read(tester, (child) => AppMotionScope(fluid: true, child: child)), isTrue);
      expect(await read(tester, (child) => AppMotionScope(fluid: false, child: child)), isFalse);
      expect(
        await read(
          tester,
          (child) => MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AppMotionScope(fluid: true, child: child),
          ),
        ),
        isFalse,
      );
    });
  });

  group('SpringCurve', () {
    test('runs from 0 to 1 and a bouncing one passes 1 on the way', () {
      final curve = SpringCurve(SpringDescription.withDurationAndBounce(bounce: 0.2));
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      final samples = [for (var i = 1; i < 100; i++) curve.transform(i / 100)];
      expect(samples.reduce(math.max), greaterThan(1));
      expect((samples.last - 1).abs(), lessThan(0.01));
    });

    test('the end of the curve joins 1 without a visible step', () {
      final curve = SpringCurve(AppMotion.riseSpring);
      expect((curve.transform(0.999) - 1).abs(), lessThan(0.003));
      expect((AppMotion.popCurve.transform(0.999) - 1).abs(), lessThan(0.012));
    });

    test('a bounce-free one never passes 1', () {
      final curve = SpringCurve(SpringDescription.withDurationAndBounce());
      for (var i = 1; i < 100; i++) {
        expect(curve.transform(i / 100), lessThanOrEqualTo(1));
      }
    });

    test('its duration is about how long the spring takes to rest', () {
      expect(AppMotion.popCurve.duration.inMilliseconds, inInclusiveRange(200, 450));
      expect(AppMotion.riseCurve.duration.inMilliseconds, inInclusiveRange(300, 900));
    });
  });

  group('FrameClock', () {
    const frame = Duration(microseconds: 16667);

    test('leaves time alone while off', () {
      final clock = FrameClock();
      expect(clock.adjust(Duration.zero), Duration.zero);
      expect(clock.adjust(const Duration(milliseconds: 200)), const Duration(milliseconds: 200));
    });

    test('a stalled frame only moves the clock by one step', () {
      final clock = FrameClock()..enabled = true;
      var raw = Duration.zero;
      clock.adjust(raw);
      raw += const Duration(milliseconds: 200);
      expect(clock.adjust(raw), clock.maxStep);
    });

    test('steady frames pass through untouched, at any refresh rate down to 30', () {
      for (final step in [frame, const Duration(microseconds: 8333), const Duration(microseconds: 33333)]) {
        final clock = FrameClock()..enabled = true;
        var raw = const Duration(seconds: 3);
        clock.adjust(raw);
        for (var i = 0; i < 100; i++) {
          raw += step;
          expect(clock.adjust(raw), raw);
        }
      }
    });

    test('after a stall time keeps its pace and never runs backwards', () {
      final clock = FrameClock()..enabled = true;
      var raw = Duration.zero;
      var last = clock.adjust(raw);
      for (final step in [frame, const Duration(milliseconds: 500), frame, frame, const Duration(seconds: 90), frame]) {
        raw += step;
        final now = clock.adjust(raw);
        expect(now, greaterThan(last));
        if (step == frame) expect(now - last, frame);
        last = now;
      }
    });

    test('turning it off keeps what was skipped, so nothing jumps ahead', () {
      final clock = FrameClock()..enabled = true;
      var raw = Duration.zero;
      clock.adjust(raw);
      raw += const Duration(milliseconds: 500);
      final before = clock.adjust(raw);
      clock.enabled = false;
      raw += frame;
      expect(clock.adjust(raw) - before, frame);
    });
  });

  group('AppInkGlow', () {
    Widget well({VoidCallback? onTap}) => Center(
      child: SizedBox(
        width: 200,
        height: 100,
        child: Material(child: InkWell(onTap: onTap ?? () {})),
      ),
    );

    testWidgets('the fluid theme glows from the finger and is gone after the tap', (tester) async {
      await tester.pumpWidget(shell(well(), fluid: true));
      final box = tester.renderObject<RenderBox>(find.byType(Material).last);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(InkWell)));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 50));
      expect(box, paints..circle());
      await gesture.up();
      await tester.pumpAndSettle();
      expect(box, isNot(paints..circle()));
    });

    testWidgets('a quick tap still shows before it fades', (tester) async {
      await tester.pumpWidget(shell(well(), fluid: true));
      final box = tester.renderObject<RenderBox>(find.byType(Material).last);
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(box, paints..circle());
      await tester.pumpAndSettle();
      expect(box, isNot(paints..circle()));
    });

    testWidgets('a scroll taking the pointer fades it, leaving nothing running', (tester) async {
      await tester.pumpWidget(
        shell(
          ListView(
            children: [
              SizedBox(height: 200, child: well()),
              const SizedBox(height: 2000),
            ],
          ),
          fluid: true,
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.byType(InkWell)));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('leaving the page mid-glow is clean', (tester) async {
      await tester.pumpWidget(shell(well(), fluid: true));
      await tester.startGesture(tester.getCenter(find.byType(InkWell)));
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the standard theme keeps the platform ripple', (tester) async {
      await tester.pumpWidget(shell(well(), fluid: false));
      final context = tester.element(find.byType(InkWell));
      expect(Theme.of(context).splashFactory, isNot(AppInkGlow.splashFactory));
    });

    testWidgets('rows without a ripple only glow on the fluid tier', (tester) async {
      Future<InteractiveInkFeatureFactory> factoryFor({required bool fluid}) async {
        await tester.pumpWidget(shell(const SizedBox(key: Key('probe')), fluid: fluid));
        return rowSplash(tester.element(find.byKey(const Key('probe'))));
      }

      expect(await factoryFor(fluid: true), AppInkGlow.splashFactory);
      expect(await factoryFor(fluid: false), NoSplash.splashFactory);
    });
  });

  group('showAppDialog', () {
    Widget opener({bool dismissible = true}) => Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showAppDialog<void>(
            context: context,
            barrierDismissible: dismissible,
            builder: (_) => const AlertDialog(content: Text('hello', key: Key('body'))),
          ),
          child: const Text('open'),
        ),
      ),
    );

    double widthOfBody(WidgetTester tester) => tester.getRect(find.byType(AlertDialog)).width;

    testWidgets('pops in on a spring on the fluid tier, passing its size and settling on it', (tester) async {
      await tester.pumpWidget(shell(opener(), fluid: true));
      await tester.tap(find.text('open'));
      await tester.pump();
      final widths = <double>[];
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        widths.add(widthOfBody(tester));
      }
      await tester.pumpAndSettle();
      final rest = widthOfBody(tester);
      expect(widths.first, lessThan(rest * 0.99));
      expect(widths.reduce(math.max), greaterThan(rest * 1.001));
      expect(widths.last, closeTo(rest, 0.01));
    });

    testWidgets('stays a plain dialog on the standard tier', (tester) async {
      await tester.pumpWidget(shell(opener(), fluid: false));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final early = widthOfBody(tester);
      await tester.pumpAndSettle();
      expect(early, widthOfBody(tester));
    });

    testWidgets('barrierDismissible reaches the dialog on both tiers', (tester) async {
      for (final fluid in [true, false]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(shell(opener(dismissible: false), fluid: fluid));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('body')), findsOneWidget);
      }
    });

    testWidgets('it closes and hands back its value', (tester) async {
      Object? result;
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showAppDialog<String>(
                    context: context,
                    builder: (dialog) => AlertDialog(
                      actions: [TextButton(onPressed: () => Navigator.of(dialog).pop('yes'), child: const Text('ok'))],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
          fluid: true,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ok'));
      await tester.pumpAndSettle();
      expect(result, 'yes');
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('Pressable', () {
    double scaleOf(WidgetTester tester) => tester.getRect(find.byKey(const Key('content'))).width / 200;

    Widget button() => Center(
      child: Pressable(
        onTap: () {},
        child: const SizedBox(key: Key('content'), width: 200, height: 80),
      ),
    );

    Future<List<double>> release(WidgetTester tester) async {
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('content'))));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), closeTo(AppMotion.pressScale, 0.001));
      await gesture.up();
      final scales = <double>[];
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        scales.add(scaleOf(tester));
      }
      return scales;
    }

    testWidgets('a fluid release passes 1 a little and lands on it', (tester) async {
      await tester.pumpWidget(shell(button(), fluid: true));
      final scales = await release(tester);
      expect(scales.reduce(math.max), inExclusiveRange(1.001, 1.01));
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
    });

    testWidgets('a standard release never passes 1', (tester) async {
      await tester.pumpWidget(shell(button(), fluid: false));
      final scales = await release(tester);
      expect(scales.reduce(math.max), lessThanOrEqualTo(1));
      expect(scales.last, 1);
    });
  });

  group('StreamFadeIn.rise', () {
    double yOf(WidgetTester tester) => tester.getBottomRight(find.byKey(const Key('bubble'))).dy;

    Widget row({required bool rise}) => Align(
      alignment: Alignment.topCenter,
      child: StreamFadeIn(
        rise: rise,
        child: const Align(
          alignment: Alignment.centerRight,
          heightFactor: 1,
          child: SizedBox(key: Key('bubble'), width: 100, height: 40),
        ),
      ),
    );

    testWidgets('a sent bubble comes up from below and settles exactly', (tester) async {
      await tester.pumpWidget(shell(row(rise: true), fluid: true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final early = yOf(tester);
      await tester.pumpAndSettle();
      final rest = yOf(tester);
      expect(early, greaterThan(rest + 10));
      expect(rest, 40);
    });

    testWidgets('its row is not cut while it grows, only then is it at rest', (tester) async {
      await tester.pumpWidget(shell(row(rise: true), fluid: true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.widget<ClipRect>(find.byType(ClipRect).first).clipBehavior, Clip.none);
      await tester.pumpAndSettle();
      expect(tester.widget<ClipRect>(find.byType(ClipRect).first).clipBehavior, Clip.none);
    });

    testWidgets('on the standard tier it is the same entrance as any other row', (tester) async {
      await tester.pumpWidget(shell(row(rise: true), fluid: false));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<ClipRect>(find.byType(ClipRect).first).clipBehavior, Clip.hardEdge);
      await tester.pumpAndSettle();
    });
  });

  group('lists', () {
    testWidgets('AppPage bounces past its top on the fluid tier only', (tester) async {
      Future<double> pull({required bool fluid}) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          shell(
            AppPage.list(title: 'Title', children: const [SizedBox(height: 3000)]),
            fluid: fluid,
          ),
        );
        await tester.pump();
        final gesture = await tester.startGesture(const Offset(200, 300));
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
        final pixels = position.pixels;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(position.pixels, 0);
        return pixels;
      }

      expect(await pull(fluid: true), lessThan(-10));
      expect(await pull(fluid: false), 0);
    });
  });

  group('SegmentedPill', () {
    Widget pill(int selected, {required ValueChanged<int> onChanged}) => Center(
      child: SizedBox(
        width: 300,
        child: SegmentedPill<int>(
          segments: const [PillSegment(0, 'a'), PillSegment(1, 'b'), PillSegment(2, 'c')],
          selected: selected,
          onChanged: onChanged,
        ),
      ),
    );

    testWidgets('a drag to the next segment ticks once', (tester) async {
      var ticks = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') ticks++;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      var picked = 0;
      await tester.pumpWidget(shell(pill(0, onChanged: (v) => picked = v), fluid: true));
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(SegmentedPill<int>)) + const Offset(40, 15),
      );
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(picked, 1);
      expect(ticks, 1);
    });

    testWidgets('its thumb overshoots on the fluid tier and still lands on the segment', (tester) async {
      await tester.pumpWidget(shell(pill(0, onChanged: (_) {}), fluid: true));
      double leftOf() => tester.getTopLeft(find.byType(DecoratedBox).at(1)).dx;
      await tester.pumpWidget(shell(pill(2, onChanged: (_) {}), fluid: true));
      var furthest = 0.0;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        furthest = furthest > leftOf() ? furthest : leftOf();
      }
      await tester.pumpAndSettle();
      expect(furthest, greaterThan(leftOf()));
    });
  });

  group('small motions', () {
    testWidgets('HoldLift sinks while held, passes its size on landing and fires once', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        shell(
          Center(
            child: HoldLift(
              onLongPress: () => fired++,
              child: const ColoredBox(key: Key('body'), color: Colors.red, child: SizedBox(width: 200, height: 100)),
            ),
          ),
          fluid: true,
        ),
      );
      double scale() => tester.getRect(find.byKey(const Key('body'))).width / 200;
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('body'))));
      var least = 1.0;
      for (var i = 0; i < 26; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        least = math.min(least, scale());
      }
      expect(least, lessThan(0.99));
      await tester.pump(kLongPressTimeout);
      expect(fired, 1);
      var most = 0.0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        most = math.max(most, scale());
      }
      await gesture.up();
      expect(most, greaterThan(1.002));
      await tester.pumpAndSettle();
      expect(scale(), 1);
    });

    testWidgets('HoldLift lets a scroll go without a lasting sink', (tester) async {
      await tester.pumpWidget(
        shell(
          ListView(
            children: [
              HoldLift(
                onLongPress: () => fail('a scroll is no long press'),
                child: const ColoredBox(key: Key('body'), color: Colors.red, child: SizedBox(height: 100)),
              ),
              const SizedBox(height: 2000),
            ],
          ),
          fluid: true,
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('body'))));
      await tester.pump(const Duration(milliseconds: 40));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('body'))).width, 800);
    });

    for (final action in ['release', 'cancel', 'scroll']) {
      for (final afterFirstFrame in [false, true]) {
        testWidgets('HoldLift $action settles when the sink has ${afterFirstFrame ? 'moved' : 'just started'}', (
          tester,
        ) async {
          var fired = 0;
          await tester.pumpWidget(
            shell(
              ListView(
                children: [
                  Center(
                    child: HoldLift(
                      onLongPress: () => fired++,
                      child: const ColoredBox(
                        key: Key('body'),
                        color: Colors.red,
                        child: SizedBox(width: 200, height: 100),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
              fluid: true,
            ),
          );
          double scale() => tester.getRect(find.byKey(const Key('body'))).width / 200;
          final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('body'))));
          // The timer starts the animation, but its first frame still paints
          // the original size. Pointer events may cancel it before the next one.
          await tester.pump(const Duration(milliseconds: 110));
          expect(scale(), 1);
          expect(tester.hasRunningAnimations, isTrue);
          if (afterFirstFrame) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(scale(), lessThan(1));
          }
          if (action == 'cancel') {
            await gesture.cancel();
          } else {
            if (action == 'scroll') {
              await gesture.moveBy(const Offset(0, -40));
              await gesture.moveBy(const Offset(0, -40));
            }
            await gesture.up();
          }
          await tester.pumpAndSettle();
          if (action == 'scroll') {
            expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels, greaterThan(0));
          }
          expect(fired, 0);
          expect(scale(), 1);
          expect(tester.hasRunningAnimations, isFalse);
        });
      }
    }

    testWidgets('HoldLift on the standard tier is only the long press', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        shell(
          Center(
            child: HoldLift(
              onLongPress: () => fired++,
              child: const ColoredBox(key: Key('body'), color: Colors.red, child: SizedBox(width: 200, height: 100)),
            ),
          ),
          fluid: false,
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('body'))));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(find.byKey(const Key('body'))).width, 200);
      await tester.pump(kLongPressTimeout);
      await gesture.up();
      expect(fired, 1);
    });

    testWidgets('a tall reply sinks by a few points, not a few percent', (tester) async {
      await tester.pumpWidget(
        shell(
          SingleChildScrollView(
            child: HoldLift(
              onLongPress: () {},
              child: const ColoredBox(key: Key('body'), color: Colors.red, child: SizedBox(width: 700, height: 3000)),
            ),
          ),
          fluid: true,
        ),
      );
      final gesture = await tester.startGesture(const Offset(400, 300));
      for (var i = 0; i < 26; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.getRect(find.byKey(const Key('body'))).height, greaterThan(3000 - 14));
      await gesture.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('DrawnCheck draws itself and holds', (tester) async {
      await tester.pumpWidget(shell(const Center(child: DrawnCheck(size: 24, color: Colors.black)), fluid: true));
      expect(tester.getSize(find.byType(DrawnCheck)), const Size.square(24));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    group('FluidTextSwap', () {
      Widget swap(String text, {required bool fluid}) => shell(
        Center(
          child: FluidTextSwap(value: text, child: Text(text)),
        ),
        fluid: fluid,
      );

      testWidgets('the old text fades out under the new, then is gone', (tester) async {
        await tester.pumpWidget(swap('本机', fluid: true));
        await tester.pumpWidget(swap('生成中', fluid: true));
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.text('本机'), findsOneWidget);
        expect(find.text('生成中'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.text('本机'), findsNothing);
        expect(find.text('生成中'), findsOneWidget);
      });

      testWidgets('is the text alone on the standard tier', (tester) async {
        await tester.pumpWidget(swap('本机', fluid: false));
        await tester.pumpWidget(swap('生成中', fluid: false));
        expect(find.text('本机'), findsNothing);
        expect(find.byType(AnimatedSwitcher), findsNothing);
      });
    });

    group('FluidFadeIn', () {
      Widget fade({required bool fluid}) => shell(const FluidFadeIn(child: Text('对话')), fluid: fluid);

      testWidgets('fades in once and leaves no layer behind', (tester) async {
        await tester.pumpWidget(fade(fluid: true));
        await tester.pump(const Duration(milliseconds: 50));
        final during = tester.widget<Opacity>(find.ancestor(of: find.text('对话'), matching: find.byType(Opacity)).first);
        expect(during.opacity, inExclusiveRange(0, 1));
        await tester.pumpAndSettle();
        final after = tester.widget<Opacity>(find.ancestor(of: find.text('对话'), matching: find.byType(Opacity)).first);
        expect(after.opacity, 1);
      });

      testWidgets('is the child alone on the standard tier', (tester) async {
        await tester.pumpWidget(fade(fluid: false));
        expect(find.ancestor(of: find.text('对话'), matching: find.byType(TweenAnimationBuilder<double>)), findsNothing);
      });
    });

    group('RollingCount', () {
      Widget count(String text, {required bool fluid}) => shell(Center(child: RollingCount(text)), fluid: fluid);

      testWidgets('rolls only the digit that changed, then is plain text again', (tester) async {
        await tester.pumpWidget(count('19', fluid: true));
        expect(find.text('19'), findsOneWidget);
        await tester.pumpWidget(count('20', fluid: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('20'), findsNothing);
        expect(find.text('1'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.text('20'), findsOneWidget);
        expect(find.text('2'), findsNothing);
      });

      testWidgets('a longer number and a label roll without trouble', (tester) async {
        await tester.pumpWidget(count('9', fluid: true));
        await tester.pumpWidget(count('10', fluid: true));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpWidget(count('99+', fluid: true));
        await tester.pumpAndSettle();
        expect(find.text('99+'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      test('a capped count is worth more than the digits it shows', () {
        expect(rollingCountValue('99+'), 100);
        expect(rollingCountValue('99'), 99);
        expect(rollingCountValue('新'), isNull);
      });

      testWidgets('is plain text at once on the standard tier', (tester) async {
        await tester.pumpWidget(count('19', fluid: false));
        await tester.pumpWidget(count('20', fluid: false));
        expect(find.text('20'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
      });
    });

    group('FadeSlideIn', () {
      testWidgets('comes from further down on a spring, passes its place and lands on it', (tester) async {
        await tester.pumpWidget(
          shell(
            const Align(
              alignment: Alignment.topLeft,
              child: FadeSlideIn(child: SizedBox(key: Key('row'), width: 100, height: 40)),
            ),
            fluid: true,
          ),
        );
        double y() => tester.getTopLeft(find.byKey(const Key('row'))).dy;
        expect(y(), closeTo(AppMotion.rise * 2.5, 0.01));
        var highest = 100.0;
        for (var i = 0; i < 50; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          highest = math.min(highest, y());
        }
        expect(highest, lessThan(0));
        await tester.pumpAndSettle();
        expect(y(), 0);
      });

      testWidgets('stays the plain rise on the standard tier', (tester) async {
        await tester.pumpWidget(
          shell(
            const Align(
              alignment: Alignment.topLeft,
              child: FadeSlideIn(child: SizedBox(key: Key('row'), width: 100, height: 40)),
            ),
            fluid: false,
          ),
        );
        expect(tester.getTopLeft(find.byKey(const Key('row'))).dy, closeTo(AppMotion.rise, 0.01));
        await tester.pumpAndSettle();
      });
    });
  });

  group('pages from cards', () {
    const window = Size(800, 600);

    Widget home({VoidCallback? instead}) => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: SizedBox(
            key: const Key('card'),
            width: 200,
            height: 120,
            child: FeatureCard(
              icon: Icons.star,
              title: 'card',
              onTap:
                  instead ??
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(key: Key('page'), body: Text('page')),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );

    Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(Key(key), skipOffstage: false));

    testWidgets('the page grows out of the card and the page below stays put', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: true));
      final card = rectOf(tester, 'card');
      await tester.tap(find.byType(FeatureCard));
      await tester.pump();
      await tester.pump();
      final start = rectOf(tester, 'page');
      expect(start.width, closeTo(card.width, 40));
      expect(start.center.dx, closeTo(card.center.dx, 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(rectOf(tester, 'card').topLeft, card.topLeft, reason: 'the page below does not recede');
      await tester.pumpAndSettle();
      expect(rectOf(tester, 'page'), Offset.zero & window);
    });

    testWidgets('it shrinks back into the card on the way out', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: true));
      final card = rectOf(tester, 'card');
      await tester.tap(find.byType(FeatureCard));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(rectOf(tester, 'page').width, lessThan(window.width));
      expect(rectOf(tester, 'card').topLeft, card.topLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page')), findsNothing);
      expect(rectOf(tester, 'card'), card);
    });

    testWidgets('a back swipe follows the finger and can leave', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: true));
      await tester.tap(find.byType(FeatureCard));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(4, 300));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(300, 0));
      await tester.pump();
      expect(rectOf(tester, 'page').width, lessThan(window.width));
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page')), findsNothing);
    });

    testWidgets('a tap that opens no page leaves the next push a normal one', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        shell(
          home(
            instead: () {
              // Nothing pushed.
            },
          ),
          fluid: true,
        ),
      );
      context = tester.element(find.byKey(const Key('card')));
      await tester.tap(find.byType(FeatureCard));
      await tester.pump();
      await tester.pump();
      unawaitedPush(context);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(rectOf(tester, 'page').width, window.width, reason: 'slides in whole instead of growing');
      await tester.pumpAndSettle();
    });

    testWidgets('on the standard tier a card pushes like everything else', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: false));
      final card = rectOf(tester, 'card');
      await tester.tap(find.byType(FeatureCard));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(rectOf(tester, 'page').width, window.width);
      expect(rectOf(tester, 'card').left, lessThan(card.left));
      await tester.pumpAndSettle();
    });

    testWidgets('with animations removed a card opens instantly', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: false, reduced: true));
      await tester.tap(find.byType(FeatureCard));
      await tester.pump();
      await tester.pump();
      expect(rectOf(tester, 'page'), Offset.zero & window);
    });
  });

  group('the page underneath', () {
    Widget home() => Builder(
      builder: (context) => Scaffold(
        key: const Key('below'),
        body: TextButton(
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('page')))),
          child: const Text('open'),
        ),
      ),
    );

    bool snapshotting(WidgetTester tester) {
      final widgets = tester.widgetList<SnapshotWidget>(find.byType(SnapshotWidget, skipOffstage: false));
      return widgets.any((widget) => widget.controller.allowSnapshotting);
    }

    testWidgets('is a snapshot only while it moves, on the fluid tier', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: true));
      expect(snapshotting(tester), isFalse);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(snapshotting(tester), isTrue);
      await tester.pumpAndSettle();
      expect(snapshotting(tester), isFalse, reason: 'a covered page holds no full-screen image');
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(snapshotting(tester), isTrue);
      await tester.pumpAndSettle();
      expect(snapshotting(tester), isFalse);
    });

    testWidgets('is always live on the standard tier', (tester) async {
      await tester.pumpWidget(shell(home(), fluid: false));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(snapshotting(tester), isFalse);
      await tester.pumpAndSettle();
    });
  });

  group('ThemeRevealHost', () {
    Widget app({required bool fluid, required ThemeMode start, required ThemeMode to}) {
      var mode = start;
      return StatefulBuilder(
        builder: (context, setState) => shell(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => ThemeRevealHost.run(context, () async {
                  // As the real setter: the new mode lands after a wait.
                  await Future<void>.delayed(Duration.zero);
                  setState(() => mode = to);
                }),
                child: const Text('switch'),
              ),
            ),
          ),
          fluid: fluid,
          mode: mode,
        ),
      );
    }

    Finder overlay() => find.descendant(of: find.byType(ThemeRevealHost), matching: find.byType(IgnorePointer));

    Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('going dark opens from the finger, then lets go of the screenshot', (tester) async {
      await tester.pumpWidget(app(fluid: true, start: ThemeMode.light, to: ThemeMode.dark));
      final before = overlay().evaluate().length;
      await tester.tap(find.text('switch'));
      await pumpUntil(tester, () => ThemeRevealHost.active);
      expect(ThemeRevealHost.active, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(overlay().evaluate().length, before + 1);
      expect(Theme.of(tester.element(find.text('switch'))).brightness, Brightness.dark, reason: 'new colours below');
      await pumpUntil(tester, () => !ThemeRevealHost.active);
      await tester.pumpAndSettle();
      expect(ThemeRevealHost.active, isFalse);
      expect(overlay().evaluate().length, before);
    });

    testWidgets('a change that fails takes the screenshot away again', (tester) async {
      Object? caught;
      await tester.pumpWidget(
        shell(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  try {
                    await ThemeRevealHost.run(context, () async => throw StateError('no'));
                  } catch (error) {
                    caught = error;
                  }
                },
                child: const Text('switch'),
              ),
            ),
          ),
          fluid: true,
        ),
      );
      final before = overlay().evaluate().length;
      await tester.tap(find.text('switch'));
      await pumpUntil(tester, () => caught != null);
      await tester.pump();
      expect(caught, isStateError);
      expect(ThemeRevealHost.active, isFalse);
      expect(overlay().evaluate().length, before);
    });

    double hole(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: overlay().last, matching: find.byType(CustomPaint)).first,
      );
      return ((paint.painter! as dynamic).progress as Animation<double>).value;
    }

    /// One switch, with the new mode landing some frames after the change returns, as
    /// Riverpod's settings do. Every frame from the tap on: the old colours stay fully
    /// covered until the new ones are there, and then the reveal really plays.
    Future<void> toggleAndCheck(WidgetTester tester, int base) async {
      Brightness now() => Theme.of(tester.element(find.byType(ThemeRevealHost))).brightness;
      bool covered() => overlay().evaluate().length > base;
      final before = now();
      await tester.tap(find.text('switch'));
      var changed = false;
      var moved = false;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!changed && now() != before) {
          changed = true;
          expect(covered(), isTrue, reason: 'the new colours must not show before the reveal');
          expect(hole(tester), 0, reason: 'nor through a hole left by the last one');
        }
        if (covered() && hole(tester) > 0) {
          expect(changed, isTrue, reason: 'no hole before there is something to reveal');
          moved = true;
        }
        if (changed && !covered()) break;
      }
      expect(changed, isTrue, reason: 'the colours changed');
      expect(moved, isTrue, reason: 'it played');
      await tester.pumpAndSettle();
      expect(ThemeRevealHost.active, isFalse);
      expect(covered(), isFalse);
      expect(Theme.of(tester.element(find.text('switch'))).brightness, now(), reason: 'the page ends up in it too');
    }

    Widget lateApp({required int late}) {
      var mode = ThemeMode.light;
      return StatefulBuilder(
        builder: (context, setState) => shell(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => ThemeRevealHost.run(context, () async {
                  final next = mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
                  void land(int left) {
                    if (left == 0) {
                      setState(() => mode = next);
                    } else {
                      WidgetsBinding.instance.addPostFrameCallback((_) => land(left - 1));
                      WidgetsBinding.instance.scheduleFrame();
                    }
                  }

                  land(late);
                }),
                child: const Text('switch'),
              ),
            ),
          ),
          fluid: true,
          mode: mode,
        ),
      );
    }

    for (final late in [0, 1, 3, 6]) {
      testWidgets('every switch plays, covered until it starts (colours land $late frames late)', (tester) async {
        await tester.pumpWidget(lateApp(late: late));
        final base = overlay().evaluate().length;
        for (var i = 0; i < 4; i++) {
          await toggleAndCheck(tester, base);
        }
      });
    }

    testWidgets('switching again mid-reveal takes over and ends clean', (tester) async {
      await tester.pumpWidget(lateApp(late: 1));
      final before = overlay().evaluate().length;
      await tester.tap(find.text('switch'));
      await pumpUntil(tester, () => ThemeRevealHost.active);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(hole(tester), greaterThan(0));
      await tester.tap(find.text('switch'));
      for (var i = 0; i < 80 && overlay().evaluate().length > before; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(ThemeRevealHost.active, isFalse);
      expect(overlay().evaluate().length, before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the same brightness has nothing to reveal', (tester) async {
      await tester.pumpWidget(app(fluid: true, start: ThemeMode.light, to: ThemeMode.light));
      final before = overlay().evaluate().length;
      await tester.tap(find.text('switch'));
      await pumpUntil(tester, () => ThemeRevealHost.active);
      await pumpUntil(tester, () => !ThemeRevealHost.active);
      await tester.pump();
      expect(overlay().evaluate().length, before);
      await tester.pumpAndSettle();
    });

    testWidgets('on the standard tier the change is all that happens', (tester) async {
      await tester.pumpWidget(app(fluid: false, start: ThemeMode.light, to: ThemeMode.dark));
      final before = overlay().evaluate().length;
      await tester.tap(find.text('switch'));
      await tester.pump();
      expect(ThemeRevealHost.active, isFalse);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();
      expect(ThemeRevealHost.active, isFalse);
      expect(overlay().evaluate().length, before);
      expect(Theme.of(tester.element(find.text('switch'))).brightness, Brightness.dark);
    });
  });
}

void unawaitedPush(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(key: Key('page'), body: Text('page')),
    ),
  );
}
