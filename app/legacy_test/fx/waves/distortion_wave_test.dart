// Portions derived from Libraries.dev Distortion waves (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_app/ui/fx/waves/distortion_wave.dart';
import 'package:dsh_app/ui/fx/waves/wave_front.dart';
import 'package:dsh_app/ui/fx/waves/wave_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Duration seconds(double s) => Duration(microseconds: (s * 1e6).round());

Widget screen(String label, Color color, {VoidCallback? onTap}) => ColoredBox(
  color: color,
  child: Center(
    child: GestureDetector(onTap: onTap, child: Text(label)),
  ),
);

Widget host(Widget child, {bool reduced = false}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child,
    ),
  ),
);

class _Flip extends StatefulWidget {
  const _Flip({required this.onFinish, this.onTapRevealed});

  final VoidCallback onFinish;
  final VoidCallback? onTapRevealed;

  @override
  State<_Flip> createState() => _FlipState();
}

class _FlipState extends State<_Flip> {
  var revealed = false;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(onPressed: () => setState(() => revealed = !revealed), child: const Text('flip')),
      Expanded(
        child: DistortionWave(
          isRevealed: revealed,
          onFinish: widget.onFinish,
          content: screen('review', Colors.white),
          revealed: screen('receipt', Colors.blueGrey, onTap: widget.onTapRevealed),
        ),
      ),
    ],
  );
}

void main() {
  // The tester loads the bundle's SkSL, so the widget tests below run the
  // shader path: snapshots, blurred copies, both shaders, the dots.
  setUpAll(WavePrograms.load);

  test('the shaders are compiled into the bundle and load', () {
    expect(WavePrograms.ready, isNotNull);
  });

  testWidgets('without the shaders the stage is a crossfade', (tester) async {
    final progress = AnimationController(vsync: const TestVSync(), value: 0.25);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      host(
        WaveStage(
          progress: progress,
          style: DistortionWaveStyle.vertical,
          palette: DistortionWavePalette.colorful,
          programs: null,
          pixelRatio: 1,
          content: screen('a', Colors.white),
          revealed: screen('b', Colors.black),
        ),
      ),
    );
    final alphas = tester.layers.whereType<OpacityLayer>().map((l) => l.alpha).toList();
    expect(alphas, containsAll([64, 191]));
    // Mid-wave neither side takes touches.
    expect(find.text('a').hitTestable(), findsNothing);
    expect(find.text('b').hitTestable(), findsNothing);
    progress.value = 1;
    await tester.pump();
    expect(find.text('b').hitTestable(), findsOneWidget);
    expect(find.text('a'), findsOneWidget, reason: 'the hidden side stays mounted');
  });

  testWidgets('flips out and back, finishing once each way', (tester) async {
    var finished = 0;
    var taps = 0;
    await tester.pumpWidget(host(_Flip(onFinish: () => finished++, onTapRevealed: () => taps++)));
    expect(find.text('review').hitTestable(), findsOneWidget);
    expect(find.text('receipt').hitTestable(), findsNothing);

    await tester.tap(find.text('flip'));
    await tester.pump();
    await tester.pump(seconds(1));
    // Mid-wave neither side takes touches.
    expect(find.text('review').hitTestable(), findsNothing);
    expect(find.text('receipt').hitTestable(), findsNothing);
    expect(finished, 0);

    await tester.pump(seconds(DistortionWaveStyle.vertical.duration));
    expect(finished, 1);
    expect(find.text('receipt').hitTestable(), findsOneWidget);
    await tester.tap(find.text('receipt'));
    expect(taps, 1);

    // The way back is quicker.
    await tester.tap(find.text('flip'));
    await tester.pump();
    await tester.pump(seconds(DistortionWaveStyle.vertical.duration / DistortionWaveStyle.vertical.returnSpeed + 0.05));
    expect(finished, 2);
    expect(find.text('review').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an interrupted run does not finish', (tester) async {
    var finished = 0;
    await tester.pumpWidget(host(_Flip(onFinish: () => finished++)));
    await tester.tap(find.text('flip'));
    await tester.pump();
    await tester.pump(seconds(0.8));
    await tester.tap(find.text('flip'));
    await tester.pumpAndSettle();
    expect(finished, 1);
    expect(find.text('review').hitTestable(), findsOneWidget);
  });

  testWidgets('reduced motion is a short crossfade', (tester) async {
    var finished = 0;
    await tester.pumpWidget(host(_Flip(onFinish: () => finished++), reduced: true));
    await tester.tap(find.text('flip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final opacity = tester.layers.whereType<OpacityLayer>().map((l) => l.alpha).toList();
    expect(opacity, isNotEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(finished, 1);
    expect(find.text('receipt').hitTestable(), findsOneWidget);
  });

  testWidgets('every type and a held scrub render', (tester) async {
    for (final style in [DistortionWaveStyle.vertical, DistortionWaveStyle.horizontal, DistortionWaveStyle.center]) {
      for (final p in [0.0, 0.1, 0.3, 0.6, 1.0]) {
        await tester.pumpWidget(
          host(
            DistortionWave(
              isRevealed: false,
              scrub: p,
              style: style.copyWith(palette: DistortionWavePalette.colorful),
              focus: const Offset(300, 700),
              content: screen('a', Colors.white),
              revealed: screen('b', Colors.black),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('the route carries a page in and collapses back', (tester) async {
    late NavigatorState navigator;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            navigator = Navigator.of(context);
            return screen('home', Colors.white);
          },
        ),
      ),
    );
    final route = DistortionWaveRoute<void>(
      builder: (_) => screen('companion', Colors.indigo),
      source: const Rect.fromLTWH(20, 500, 760, 58),
      settings: const RouteSettings(name: 'mode:companion'),
    );
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Still gathering: the new page isn't on screen yet, and takes no touches.
    expect(find.text('companion').hitTestable(), findsNothing);
    await tester.pump(seconds(1.4));
    // The front has crossed: the page takes touches while its edges clear.
    expect(find.text('companion').hitTestable(), findsOneWidget);
    expect(route.animation!.isCompleted, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsNothing);
    expect(route.isCurrent, isTrue);

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('home'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('companion'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('under reduced motion the route is a short crossfade', (tester) async {
    late NavigatorState navigator;
    await tester.pumpWidget(
      MaterialApp(
        // Above the navigator, where the route asks.
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: Builder(
          builder: (context) {
            navigator = Navigator.of(context);
            return screen('home', Colors.white);
          },
        ),
      ),
    );
    final route = DistortionWaveRoute<void>(builder: (_) => screen('tavern', Colors.brown));
    navigator.push(route);
    await tester.pump();
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 320));
    expect(route.animation!.isCompleted, isTrue);
    expect(find.text('tavern').hitTestable(), findsOneWidget);
  });

  testWidgets('reduced motion turned on while the page is up makes the way back a crossfade', (tester) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    late NavigatorState navigator;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ValueListenableBuilder(
          valueListenable: reduced,
          builder: (context, on, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: on),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) {
            navigator = Navigator.of(context);
            return screen('home', Colors.white);
          },
        ),
      ),
    );
    final route = DistortionWaveRoute<void>(builder: (_) => screen('tavern', Colors.brown));
    navigator.push(route);
    await tester.pumpAndSettle();
    expect(route.transitionDuration, seconds(DistortionWaveStyle.vertical.duration));

    reduced.value = true;
    await tester.pump();
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(route.animation!.isDismissed, isTrue);
    expect(find.text('tavern'), findsNothing);
  });

  testWidgets('the outgoing side keeps its mask until the front has crossed, swell or not', (tester) async {
    // A linear easing: the swell dies (x ≥ 0.55) well before the front crosses.
    final style = DistortionWaveStyle.vertical.copyWith(easing: const DistortionWaveEasing(0, 0, 1, 1));
    final p = (style.anticipation + 0.7 * style.travel) / style.duration;
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final front = WaveFront(progress: p, source: waveDefaultSource(style.type, view), size: view, style: style);
    expect(front.launched && front.energy == 0 && !front.hasCleared, isTrue);

    final outgoing = GlobalKey();
    await tester.pumpWidget(
      host(
        DistortionWave(
          isRevealed: false,
          scrub: p,
          style: style,
          content: RepaintBoundary(key: outgoing, child: screen('a', Colors.white)),
          revealed: screen('b', Colors.black),
        ),
      ),
    );
    // Drawn through the shader from a snapshot, not composited as it is.
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(outgoing));
    expect(boundary.debugLayer!.parent, isNull);
  });
}
