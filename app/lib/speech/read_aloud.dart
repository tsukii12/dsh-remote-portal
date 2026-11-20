// 朗读: one reply read aloud at a time, from the button under it (主对话) or
// its menu (酒馆). Tapping the one being read stops it; starting another,
// sending a message, or leaving the conversation stops it too.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_voice.dart';
import '../companion/companion_voice_source.dart';
import 'deepseek_speech.dart';
import 'speech_audio.dart';
import 'speech_out.dart';
import 'speech_settings.dart';

enum ReadAloudPhase { idle, loading, playing }

class ReadAloudState {
  const ReadAloudState({this.id, this.phase = ReadAloudPhase.idle});

  /// The reply being read (its message id), or null.
  final String? id;
  final ReadAloudPhase phase;

  ReadAloudPhase phaseOf(String messageId) => messageId == id ? phase : ReadAloudPhase.idle;
}

class ReadAloudController extends Notifier<ReadAloudState> {
  SpeechOut? _out;

  /// Goes up with every start and stop: a start that waited across one gives up.
  int _run = 0;
  StreamSubscription<SpeechOutEvent>? _sub;

  @override
  ReadAloudState build() {
    ref.onDispose(() {
      _out?.stop();
      unawaited(_sub?.cancel());
    });
    return const ReadAloudState();
  }

  /// Reads [markdown] (the reply [messageId]) aloud, or stops it when it is
  /// the one being read. [onError] hears why it could not.
  Future<void> toggle(String messageId, String markdown, {void Function(Object error)? onError}) async {
    final reading = state.id;
    stop();
    if (reading == messageId) return;
    // Keys and tokens were masked by the caller (readAloudReply).
    final text = speakable(markdown);
    if (text.isEmpty) {
      onError?.call(const DeepSeekSpeechError(DeepSeekSpeechFailure.rejected));
      return;
    }
    state = ReadAloudState(id: messageId, phase: ReadAloudPhase.loading);
    final run = ++_run;
    // The chosen voice, once the settings have been read (never a guess).
    final settings = await ref.read(speechVoiceSettingsProvider.notifier).ready();
    if (run != _run || !ref.mounted) return;
    final speaker = ref.read(speechSpeakerProvider);
    if (settings.source != CompanionVoiceSource.deepseek && !await speaker.ready(settings)) {
      if (run != _run || !ref.mounted) return;
      state = const ReadAloudState();
      onError?.call(const ReadAloudNotSetUp());
      return;
    }
    if (run != _run || !ref.mounted) return;
    final out = speechOutFor(
      settings,
      deepseek: ref.read(deepSeekSpeechProvider),
      audio: ref.read(speechAudioProvider),
      speaker: speaker,
      gap: ref.read(deepSeekSpeechGapProvider),
    );
    _out = out;
    _sub = out.events.listen((event) {
      if (!identical(_out, out)) return;
      switch (event) {
        case SpeechOutStarted():
          state = ReadAloudState(id: messageId, phase: ReadAloudPhase.playing);
        case SpeechOutDone():
          _clear(out);
        case SpeechOutFailed(:final error):
          _clear(out);
          onError?.call(error);
        case SpeechOutLevel():
          break;
      }
    });
    out
      ..add(text)
      ..finish();
  }

  void _clear(SpeechOut out) {
    if (!identical(_out, out)) return;
    _out = null;
    unawaited(_sub?.cancel());
    _sub = null;
    state = const ReadAloudState();
  }

  /// Stops reading when what is being read is one [reading] owns (a page closing).
  void stopWhere(bool Function(String id) reading) {
    // Called just after a page closes, by when the whole app may have gone.
    if (!ref.mounted) return;
    final id = state.id;
    if (id != null && reading(id)) stop();
  }

  /// Silence: nothing is read any more.
  void stop() {
    _run++;
    final out = _out;
    _out = null;
    unawaited(_sub?.cancel());
    _sub = null;
    out?.stop();
    if (state.id != null) state = const ReadAloudState();
  }
}

/// The chosen voice isn't filled in (a key, an address).
class ReadAloudNotSetUp implements Exception {
  const ReadAloudNotSetUp();
}

final readAloudProvider = NotifierProvider<ReadAloudController, ReadAloudState>(ReadAloudController.new);
