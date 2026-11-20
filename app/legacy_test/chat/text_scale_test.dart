import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> pumpScreen(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

double scaleIn(WidgetTester tester, Finder finder) => MediaQuery.textScalerOf(tester.element(finder)).scale(10) / 10;

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double size) => size * (size < 18 ? 2 : 1.3);
  @override
  double get textScaleFactor => 2;
}

void main() {
  setUpAll(() => chatClock = () => DateTime(2026, 10, 23, 9));

  for (final (factor, label) in chatTextScales) {
    testWidgets('nonlinear system scale stays nonlinear at $label', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final harness = ChatHarness(
        session: 's1',
        settings: AppSettings(loaded: true, apiKey: testKey, chatTextScale: factor),
      );
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const _NonlinearScaler()),
              child: const ChatScreen(),
            ),
          ),
          overrides: harness.overrides,
        ),
      );
      await pumpFrames(tester);
      final scaler = MediaQuery.textScalerOf(tester.element(find.byType(ChatList)));
      expect(scaler.scale(10), closeTo(20 * factor, 1e-9));
      expect(scaler.scale(20), closeTo(26 * factor, 1e-9));
      expect(MediaQuery.textScalerOf(tester.element(find.byType(ChatHeader))), isA<_NonlinearScaler>());
    });
  }

  test('copyWith keeps the size (changing it, or anything else)', () {
    const base = AppSettings();
    expect(base.copyWith(chatTextScale: 1.3).chatTextScale, 1.3);
    final big = base.copyWith(chatTextScale: 1.15);
    expect(big.copyWith(themeMode: ThemeMode.dark).chatTextScale, 1.15);
    expect(big.copyWith(foldCompletedTurns: false).chatTextScale, 1.15);
    expect(big.copyWith(chatTextScale: 0.9).foldCompletedTurns, isTrue);
  });

  for (final (scale, label) in chatTextScales) {
    testWidgets('对话字号 $label scales the chat only', (tester) async {
      await pumpScreen(
        tester,
        ChatHarness(
          session: 's1',
          states: {'s1': const ChatState(loading: false)},
          settings: AppSettings(loaded: true, apiKey: testKey, chatTextScale: scale),
        ),
      );
      expect(scaleIn(tester, find.byType(ChatList)), closeTo(scale, 1e-9));
      expect(scaleIn(tester, find.byType(ChatHeader)), 1.0);
    });
  }
}
