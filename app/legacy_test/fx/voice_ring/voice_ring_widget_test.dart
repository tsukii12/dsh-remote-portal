import 'package:dsh_app/ui/fx/voice_ring/voice_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget ring, {bool reduced = false, Brightness brightness = Brightness.dark}) => MaterialApp(
  theme: ThemeData(brightness: brightness, colorSchemeSeed: const Color(0xFF4D6BFE)),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Center(child: ring),
    ),
  ),
);

Future<void> _frames(WidgetTester tester, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 17));
  }
}

void main() {
  testWidgets('runs through every state and type without trouble', (tester) async {
    var level = 0.0;
    for (final type in VoiceRingType.values) {
      for (final brightness in Brightness.values) {
        for (final state in VoiceRingState.values) {
          level = state == VoiceRingState.idle ? 0 : 0.8;
          await tester.pumpWidget(
            _host(
              VoiceRing(type: type, state: state, size: 280, level: () => VoiceRingLevel.mic(level)),
              brightness: brightness,
            ),
          );
          await _frames(tester);
          expect(tester.takeException(), isNull);
          expect(tester.hasRunningAnimations, isTrue);
        }
      }
    }
    // an emotion and a side to lean to (the edge lens is skipped in tests)
    await tester.pumpWidget(
      _host(
        VoiceRing(
          state: VoiceRingState.speaking,
          size: 340,
          level: () => 0.9,
          emotion: VoiceRingEmotion.positive,
          direction: 1,
        ),
      ),
    );
    await _frames(tester, 180);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_host(const SizedBox()));
  });

  testWidgets('reduced motion with nothing to hear is one still frame', (tester) async {
    await tester.pumpWidget(_host(const VoiceRing(state: VoiceRingState.idle), reduced: true));
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);

    // a voice still shows: the loop runs with the clocks held
    await tester.pumpWidget(_host(VoiceRing(level: () => 0.5), reduced: true));
    expect(tester.hasRunningAnimations, isTrue);
    await _frames(tester, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused and hidden rings do not tick', (tester) async {
    await tester.pumpWidget(_host(VoiceRing(level: () => 0.5, paused: true)));
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(_host(TickerMode(enabled: false, child: VoiceRing(level: () => 0.5))));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
