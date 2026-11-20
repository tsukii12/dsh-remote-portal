import 'package:dsh_app/ui/fx/voice_glow/voice_beam.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduced = false, Brightness brightness = Brightness.dark}) => MaterialApp(
  theme: ThemeData(brightness: brightness, colorSchemeSeed: const Color(0xFF4A6CF7)),
  home: MediaQuery(
    data: MediaQueryData(size: const Size(400, 800), disableAnimations: reduced),
    child: Center(child: child),
  ),
);

Widget _composer(VoiceBeam Function(Widget card) wrap) => wrap(
  Container(
    width: 360,
    height: 96,
    decoration: BoxDecoration(color: const Color(0xFF1D1D1D), borderRadius: BorderRadius.circular(20)),
  ),
);

void main() {
  testWidgets('listens, gathers, pauses and fades out without errors', (tester) async {
    final level = ValueNotifier<double>(0);
    final motion = ValueNotifier(VoiceBeamMotion.rest);
    var active = true, paused = false;
    late StateSetter set;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return _composer(
              (card) => VoiceBeam(
                level: level,
                motion: motion,
                active: active,
                paused: paused,
                borderRadius: 20,
                foreground: const Center(child: Text('Ask anything')),
                child: card,
              ),
            );
          },
        ),
      ),
    );
    expect(find.text('Ask anything'), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      level.value = (i % 6) / 5;
      await tester.pump(const Duration(milliseconds: 40));
    }
    for (var i = 0; i < 30; i++) {
      motion.value = VoiceBeamMotion(gather: i / 29, offset: i / 29, cornerFollow: 0.5, heldLevel: 0.5);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.binding.hasScheduledFrame, isTrue);

    set(() => paused = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);

    set(() {
      paused = false;
      active = false;
    });
    // Fades out even though it was paused, then the ticker stops.
    final frames = await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(frames, inInclusiveRange(30, 40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('every type, palette and theme paints', (tester) async {
    final level = ValueNotifier<double>(0.7);
    for (final brightness in Brightness.values) {
      for (final type in VoiceBeamType.values) {
        for (final variant in <VoiceBeamColorVariant?>[null, ...VoiceBeamColorVariant.values]) {
          await tester.pumpWidget(
            _host(
              brightness: brightness,
              SizedBox(
                width: type == VoiceBeamType.pill ? 150 : 360,
                height: switch (type) {
                  VoiceBeamType.pill => 44,
                  VoiceBeamType.standard => 96,
                  VoiceBeamType.mobile => 700,
                },
                child: VoiceBeam(type: type, level: level, colorVariant: variant, child: const SizedBox.expand()),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion shows a still frame that still follows the level', (tester) async {
    final level = ValueNotifier<double>(0);
    await tester.pumpWidget(
      _host(
        reduced: true,
        _composer((card) => VoiceBeam(level: level, levelScale: VoiceLevelScale.callCapture, child: card)),
      ),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    level.value = 0.6;
    // The level repaints the frame; no loop starts.
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
