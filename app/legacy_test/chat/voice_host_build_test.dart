import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('host change during real Composer build safely restores the persisted draft', (tester) async {
    SharedPreferences.setMockInitialValues({});
    usePhoneView(tester);
    final first = DshClient.withCarrier(FakeRpcCarrier({}));
    final replacement = DshClient.withCarrier(FakeRpcCarrier({}));
    final host = ValueNotifier<DshClient?>(first);
    final input = MentionTextController();
    final bridge = FakeVoiceBridge();
    final voice = VoiceInputController(
      input: input,
      bridge: bridge,
      client: () => host.value,
      observeLifecycle: false,
    );
    ProviderContainer? container;
    void saveDraft() => container!.read(draftStoreProvider.notifier).save('current', input.text, const []);
    addTearDown(() async {
      input.removeListener(saveDraft);
      await tester.pumpWidget(const SizedBox.shrink());
      voice.dispose();
      input.dispose();
      host.dispose();
      await first.close();
      await replacement.close();
    });
    await tester.pumpWidget(
      testApp(
        Consumer(
          builder: (context, ref, _) {
            ref.watch(draftStoreProvider);
            container = ProviderScope.containerOf(context);
            return Scaffold(
              body: ValueListenableBuilder<DshClient?>(
                valueListenable: host,
                builder: (context, _, child) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Composer(
                    controller: input,
                    connected: true,
                    running: false,
                    onSend: () {},
                    onStop: () {},
                    voice: voice,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    input.addListener(saveDraft);
    await voice.start();
    bridge.emit(const VoicePartial('independent draft fixture'));
    await tester.pump();
    expect(voice.phase, VoicePhase.listening);
    expect(container!.read(draftStoreProvider).drafts['current']?.text, 'independent draft fixture');
    host.value = replacement;
    await tester.pump();
    final failure = tester.takeException();
    // Keep the actual framework result in the raw log if the hypothesis fails.
    debugPrint('[P15_INDEPENDENT_BUILD] phase=${voice.phase.name} input=${input.text} exception=$failure');
    expect(failure, isNull, reason: 'Restoring the draft must not write provider state during Composer.build.');
    expect(voice.phase, VoicePhase.idle);
    expect(input.text, isEmpty);
    expect(container!.read(draftStoreProvider).drafts['current'], isNull);
    expect(bridge.calls.last, 'cancel');
  });
}
