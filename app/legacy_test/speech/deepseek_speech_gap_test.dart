// Nobody can pay for DeepSeek speech: signed in, the account cannot here (an
// older DSH, or DSH Remote), and that is what is said, not "sign in".

import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/ui/speech/speech_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the recognizer says why nobody can pay', () async {
    final signedIn = DeepSeekVoiceCloud(() async => null, gap: () => DeepSeekSpeechFailure.accountUnusable);
    await expectLater(
      signedIn.transcribe(Uint8List(44)),
      throwsA(isA<DeepSeekSpeechError>().having((e) => e.failure, 'failure', DeepSeekSpeechFailure.accountUnusable)),
    );
    final nobody = DeepSeekVoiceCloud(() async => null);
    await expectLater(
      nobody.transcribe(Uint8List(44)),
      throwsA(isA<DeepSeekSpeechError>().having((e) => e.failure, 'failure', DeepSeekSpeechFailure.noCredential)),
    );
  });

  test('signed in, the message is about this connection, not about signing in', () {
    final l10n = appL10n;
    final text = speechErrorText(
      l10n,
      const DeepSeekSpeechError(DeepSeekSpeechFailure.accountUnusable),
      listening: true,
    );
    expect(text, l10n.speechAccountUnusable);
    expect(text, isNot(l10n.speechNoCredential));
  });
}
