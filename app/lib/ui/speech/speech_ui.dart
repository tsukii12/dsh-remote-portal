// What the speech features say when something goes wrong, and the one way
// every 朗读 button starts reading.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../speech/call/voice_call.dart';
import '../../speech/deepseek_speech.dart';
import '../../speech/read_aloud.dart';
import '../chat/secret_mask.dart';
import '../common/brief_notice.dart';

/// Why speech failed, in a sentence. [listening] for 语音输入 / 通话 (a
/// refused recording means it heard nothing), else 朗读.
String speechErrorText(L10n l10n, Object error, {bool listening = false}) => switch (error) {
  ReadAloudNotSetUp() => l10n.speechNotSetUp,
  CallSendFailed() => l10n.speechCallSendFailed,
  DeepSeekSpeechError(:final failure) => switch (failure) {
    DeepSeekSpeechFailure.noCredential => l10n.speechNoCredential,
    DeepSeekSpeechFailure.accountUnusable => l10n.speechAccountUnusable,
    DeepSeekSpeechFailure.signIn => l10n.speechSignIn,
    DeepSeekSpeechFailure.unauthorized => l10n.speechUnauthorized,
    DeepSeekSpeechFailure.insufficientBalance => l10n.speechBalance,
    DeepSeekSpeechFailure.rateLimited => l10n.speechRateLimited,
    DeepSeekSpeechFailure.rejected => listening ? l10n.speechNotHeard : l10n.speechNothingToRead,
    DeepSeekSpeechFailure.tooLarge => l10n.speechTooLong,
    DeepSeekSpeechFailure.busy => l10n.speechBusy,
    DeepSeekSpeechFailure.network => l10n.speechNetwork,
    DeepSeekSpeechFailure.protocol => listening ? l10n.speechListenFailed : l10n.speechReadFailed,
    DeepSeekSpeechFailure.insecure => l10n.speechInsecure,
  },
  _ => listening ? l10n.speechListenFailed : l10n.speechReadFailed,
};

/// Reads the reply [id] ([markdown]) aloud, or stops it; failures as a brief notice.
void readAloudReply(BuildContext context, String id, String markdown) {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    ProviderScope.containerOf(context, listen: false)
        .read(readAloudProvider.notifier)
        .toggle(
          id,
          // Keys and tokens in a reply are neither sent to a voice nor spoken.
          maskSecrets(markdown, mark: ''),
          onError: (error) => messenger?.showBriefNotice(speechErrorText(l10n, error)),
        ),
  );
}
