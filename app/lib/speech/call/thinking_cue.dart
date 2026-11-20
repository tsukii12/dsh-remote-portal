// The call's "still thinking" sound: two soft sine notes a fifth apart (E5,
// then B5), each with a quick rise and a long fall, quiet (about −20 dBFS).
// Played once a turn when no voice has come 1.2 s after the person finished,
// so a slow answer does not feel like a dropped line.

import 'dart:math' as math;
import 'dart:typed_data';

import '../speech_audio.dart';

/// The cue as 24 kHz mono 16-bit PCM.
Uint8List thinkingCuePcm({int rate = 24000}) {
  const notes = [(659.25, 0.0), (987.77, 0.11)];
  const length = 0.36;
  final n = (rate * length).round();
  final pcm = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    var v = 0.0;
    for (final (freq, at) in notes) {
      final local = t - at;
      if (local < 0) continue;
      // 8 ms up, then an exponential fall.
      final envelope = math.min(1.0, local / 0.008) * math.exp(-local / 0.07);
      v += math.sin(2 * math.pi * freq * local) * envelope;
    }
    pcm.setInt16(i * 2, (v * 0.1 * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return pcm.buffer.asUint8List();
}

int _cues = 0;

/// Plays the cue on the call's audio path.
Future<void> playThinkingCue(SpeechAudio audio) async {
  final id = 'cue${++_cues}';
  if (!await audio.open(id, call: true)) return;
  await audio.write(id, thinkingCuePcm());
  await audio.end(id);
}
