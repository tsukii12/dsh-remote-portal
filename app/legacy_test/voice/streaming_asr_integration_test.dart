import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/voice/streaming_asr.dart';

void main() {
  final modelDirectory = Platform.environment['DSH_ASR_MODEL_DIR'];
  test('real bilingual Zipformer emits partials and a final through the production isolate', () async {
    final root = modelDirectory!;
    final asr = StreamingAsr();
    final events = <StreamingAsrEvent>[];
    final subscription = asr.events.listen(events.add);
    try {
      await asr.start(
        StreamingAsrModel(
          encoder: '$root/encoder-epoch-99-avg-1.int8.onnx',
          decoder: '$root/decoder-epoch-99-avg-1.int8.onnx',
          joiner: '$root/joiner-epoch-99-avg-1.int8.onnx',
          tokens: '$root/tokens.txt',
        ),
      );
      final pcm = _readPcm(File('$root/test_wavs/1.wav').readAsBytesSync());
      Future<void> feedRecording() async {
        for (var offset = 0; offset < pcm.length; offset += 640) {
          await asr.feed(Uint8List.sublistView(pcm, offset, min(offset + 640, pcm.length)));
        }
      }

      await feedRecording();
      final silence = Uint8List(640);
      for (var i = 0; i < 100; i++) {
        await asr.feed(silence);
      }
      expect(events.whereType<StreamingAsrFinal>(), hasLength(1));
      await feedRecording();
      await asr.stop();
      final partials = events.whereType<StreamingAsrPartial>().toList();
      final finals = events.whereType<StreamingAsrFinal>().toList();
      expect(partials, isNotEmpty);
      expect(finals, hasLength(2));
      for (final result in finals) {
        expect(result.text, contains('第一种'));
        expect(result.text.toUpperCase(), contains('ALWAYS'));
      }
      expect(asr.active, isFalse);
    } finally {
      await asr.dispose();
      await subscription.cancel();
    }
  }, skip: modelDirectory == null ? 'Set DSH_ASR_MODEL_DIR and load the matching sherpa native library' : false);
}

Uint8List _readPcm(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
  expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final name = String.fromCharCodes(wav.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (name == 'fmt ') {
      expect(data.getUint16(offset + 8, Endian.little), 1);
      expect(data.getUint16(offset + 10, Endian.little), 1);
      expect(data.getUint32(offset + 12, Endian.little), 16000);
      expect(data.getUint16(offset + 22, Endian.little), 16);
    }
    if (name == 'data') return Uint8List.sublistView(wav, offset + 8, offset + 8 + size);
    offset += 8 + size + (size & 1);
  }
  throw const FormatException('WAV has no data chunk');
}
