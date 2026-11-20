import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';

Future<void> settleVoice(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  for (final code in [5, 11]) {
    testWidgets('system failure $code starts one engine recording despite old end', (tester) async {
      // Not ready at the start (a ready model is used directly), ready by the fallback.
      var phase = 'unprepared';
      final carrier = FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog(phase: phase)});
      final client = DshClient.withCarrier(carrier);
      final bridge = FakeVoiceBridge();
      final input = TextEditingController();
      final voice = VoiceInputController(input: input, bridge: bridge, client: () => client, observeLifecycle: false);
      addTearDown(voice.dispose);
      addTearDown(input.dispose);
      await voice.start();
      phase = 'standby';
      bridge.emit(VoiceError(code));
      bridge.emit(const VoiceEnd());
      await settleVoice(tester);
      expect(bridge.calls.where((call) => call.startsWith('recorder:')).length, 1);
      expect(voice.engine, VoiceEngine.engine);
      expect(voice.phase, VoicePhase.listening);
      await voice.cancel();
    });
  }

  testWidgets('fallback restores the selected draft before asking to speak again', (tester) async {
    var phase = 'unprepared';
    final client = DshClient.withCarrier(FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog(phase: phase)}));
    final bridge = FakeVoiceBridge();
    final input = TextEditingController.fromValue(
      const TextEditingValue(text: 'hello draft world', selection: TextSelection(baseOffset: 6, extentOffset: 11)),
    );
    final base = input.value;
    final voice = VoiceInputController(input: input, bridge: bridge, client: () => client, observeLifecycle: false);
    addTearDown(voice.dispose);
    addTearDown(input.dispose);
    await voice.start();
    phase = 'standby';
    bridge.emit(const VoicePartial('partial'));
    await tester.pump();
    bridge.emit(const VoiceError(5));
    bridge.emit(const VoiceEnd());
    await settleVoice(tester);
    expect(input.value, base);
    expect(voice.engine, VoiceEngine.engine);
    await voice.cancel();
  });
}
