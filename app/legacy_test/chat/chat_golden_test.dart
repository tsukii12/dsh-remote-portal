// Golden screenshots of the chat screen. Regenerate with
// `flutter test --update-goldens test/chat`.
//
// Real fonts are loaded (support/harness.dart): Roboto, Material Icons,
// JetBrains Mono, and Noto Sans CJK when the machine has it, so the PNGs show
// actual glyphs. Goldens are pixel-exact to this toolchain and font set.

import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/english_preview.dart';
import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
    // The activity pill's copy follows the date (holidays, weekends).
    runClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  // English smoke goldens (i18n): the same screens in English, light only.
  testWidgets('empty new chat (en)', (tester) async {
    useEnglish();
    usePhoneView(tester);
    final harness = ChatHarness();
    await tester.pumpWidget(testApp(inEnglish(const ChatScreen()), overrides: harness.overrides));
    await pumpFrames(tester);
    await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/en_empty_light.png'));
  });

  testWidgets('conversation with approval (en)', (tester) async {
    useEnglish();
    usePhoneView(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
    await tester.pumpWidget(testApp(inEnglish(const ChatScreen()), overrides: harness.overrides));
    await pumpFrames(tester, 10);
    await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/en_conversation_light.png'));
  });

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('empty new chat ($suffix)', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness();
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/empty_$suffix.png'));
    });

    testWidgets('conversation with approval ($suffix)', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester, 10);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/conversation_$suffix.png'));
    });

    // The whole conversation on one tall canvas: every row type at once.
    testWidgets('conversation, full transcript ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 3000);
      final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester, 10);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/conversation_full_$suffix.png'));
    });

    testWidgets('auto-approve mode ($suffix)', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': autoApproveState()});
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester, 10);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/auto_approve_$suffix.png'));
    });

    testWidgets('streaming answer ($suffix)', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(session: 's2', states: {'s2': streamingState()});
      await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: harness.overrides));
      await pumpFrames(tester, 10);
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/streaming_$suffix.png'));
    });
  }
}
