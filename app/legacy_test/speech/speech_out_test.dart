import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('speakable', () {
    test('drops code, tables, images and link addresses; keeps the words', () {
      const reply = '''
## 结果

先看**重点**：[文档](https://example.com/doc) 写得很清楚。

```dart
print('不读');
```

| 列 | 值 |
| --- | --- |
| a | 1 |

![图](x.png)
- 第一条
- 第二条 `inline` 也读
''';
      final text = speakable(reply);
      expect(text, contains('结果'));
      expect(text, contains('先看重点：文档 写得很清楚。'));
      expect(text, contains('第一条'));
      expect(text, contains('第二条 inline 也读'));
      expect(text, isNot(contains('print')));
      expect(text, isNot(contains('|')));
      expect(text, isNot(contains('example.com')));
      expect(text, isNot(contains('**')));
      expect(text, isNot(contains('#')));
    });

    test('nothing readable is empty', () => expect(speakable('```\ncode\n```'), isEmpty));
  });

  group('SpeechChunker', () {
    test('the first piece is short; later ones are grouped', () {
      final chunker = SpeechChunker(first: 3, target: 20, max: 60);
      chunker.add('好的。我来看看今天的天气情况。北京晴，');
      final now = chunker.take();
      expect(now, ['好的。']);
      chunker.add('最高二十度。上海有雨，记得带伞。');
      final rest = [...now.skip(1), ...chunker.take(final_: true)];
      expect(rest.join(), '我来看看今天的天气情况。北京晴，最高二十度。上海有雨，记得带伞。');
      for (final piece in rest.take(rest.length - 1)) {
        expect(piece.length, greaterThanOrEqualTo(12));
      }
    });

    test('waits for a sentence end while text is still coming', () {
      final chunker = SpeechChunker(first: 4);
      chunker.add('今天天气');
      expect(chunker.take(), isEmpty);
      chunker.add('很好。');
      expect(chunker.take(), ['今天天气很好。']);
    });

    test('a very long sentence is cut at a pause before max', () {
      final chunker = SpeechChunker(first: 4, max: 20);
      chunker.add('这是一个非常非常长的句子，里面没有句号一直说下去一直说下去');
      final pieces = chunker.take();
      expect(pieces.first, endsWith('，'));
      expect(pieces.first.length, lessThanOrEqualTo(20));
    });

    test('the first piece goes at a comma once long enough; later ones wait for a sentence', () {
      final chunker = SpeechChunker(first: 8, target: 20, max: 60);
      chunker.add('好的，这周末北京以晴为主，周六最高二十度');
      // 「好的，」 is too short to go alone; the next comma is far enough.
      expect(chunker.take(), ['好的，这周末北京以晴为主，']);
      chunker.add('，周日有小雨。');
      // Later pieces stop at sentence ends only.
      expect(chunker.take(), isEmpty);
      expect(chunker.take(final_: true), ['周六最高二十度，周日有小雨。']);
    });

    test('a number or a time is not a pause', () {
      final chunker = SpeechChunker(first: 4);
      chunker.add('门票是1,000元，3:30开门');
      expect(chunker.take(), ['门票是1,000元，']);
    });

    test('pieces with no letters or digits are dropped', () {
      final chunker = SpeechChunker(first: 1);
      chunker.add('……\n好。');
      expect(chunker.take(final_: true), ['好。']);
    });
  });

  group('DeepSeekOut', () {
    test('pending diagnostic persistence never reorders synthesis requests', () async {
      const channel = MethodChannel('dsh/diagnostics');
      final writes = Completer<void>();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => writes.future);
      addTearDown(() {
        if (!writes.isCompleted) writes.complete();
        messenger.setMockMethodCallHandler(channel, null);
      });
      final audio = FakeAudio();
      final speech = FakeDeepSeek();
      final out = DeepSeekOut(() async => speech, audio, call: true);
      out.add('今天北京是晴天。最高气温二十度，适合出门散步。');
      out.finish();
      await pumpEventQueue();
      expect(speech.asked, ['今天北京是晴天。', '最高气温二十度，适合出门散步。']);
      expect(writes.isCompleted, false);
      expect(audio.calls, ['open:${out.id}:call=true', 'end:${out.id}']);
      out.stop();
    });
    test('streams every piece, in order, into one native stream, then ends it', () async {
      final audio = FakeAudio();
      final speech = FakeDeepSeek();
      final out = DeepSeekOut(() async => speech, audio, call: true);
      final events = <SpeechOutEvent>[];
      out.events.listen(events.add);
      out.add('今天北京是晴天。最高气温二十度，');
      out.add('适合出门散步。');
      out.finish();
      await pumpEventQueue();
      expect(speech.asked.first, '今天北京是晴天。');
      expect(speech.asked, ['今天北京是晴天。', '最高气温二十度，适合出门散步。']);
      final id = out.id;
      expect(audio.calls, ['open:$id:call=true', 'end:$id']);
      final played = String.fromCharCodes([
        for (var i = 0; i + 1 < audio.written[id]!.length; i += 2)
          audio.written[id]![i] | (audio.written[id]![i + 1] << 8),
      ]);
      expect(played, speech.asked.join());
      audio.emit(PlayEvent(id, PlayPhase.start));
      audio.emit(PlayEvent(id, PlayPhase.done));
      await pumpEventQueue();
      expect(events.first, isA<SpeechOutStarted>());
      expect(events.last, isA<SpeechOutDone>());
      expect(out.ended, isTrue);
    });

    test('what was heard follows playback: whole pieces, then the share of the one playing', () async {
      final audio = FakeAudio();
      final out = DeepSeekOut(() async => _Seconds(), audio, call: true, levels: true);
      out
        ..add('第一句话说完了。')
        ..add('第二句也很长很长。')
        ..finish();
      await pumpEventQueue();
      expect(out.heard, '');
      // Each piece is 80 ms of audio here; each level tick is 40 ms heard.
      audio.emit(PlayLevel(out.id, 0.5));
      expect(out.heard, '第一句话');
      audio.emit(PlayLevel(out.id, 0.5));
      expect(out.heard, '第一句话说完了。');
      audio.emit(PlayLevel(out.id, 0.5));
      expect(out.heard, '第一句话说完了。第二句也');
      audio.emit(PlayEvent(out.id, PlayPhase.done));
      expect(out.heard, '第一句话说完了。第二句也很长很长。');
    });

    test('nobody to pay: fails before any sound', () async {
      final audio = FakeAudio();
      final out = DeepSeekOut(() async => null, audio);
      final events = <SpeechOutEvent>[];
      out.events.listen(events.add);
      out
        ..add('你好。')
        ..finish();
      await pumpEventQueue();
      expect(events.single, isA<SpeechOutFailed>());
      final error = (events.single as SpeechOutFailed).error;
      expect(error, isA<DeepSeekSpeechError>());
      expect((error as DeepSeekSpeechError).failure, DeepSeekSpeechFailure.noCredential);
      expect(audio.calls, isEmpty);
    });

    test('stop silences it and asks for nothing more', () async {
      final audio = FakeAudio();
      final speech = FakeDeepSeek();
      final out = DeepSeekOut(() async => speech, audio);
      final done = Completer<void>();
      out.events.listen((e) {
        if (e is SpeechOutDone) done.complete();
      });
      out.add('第一句已经够长了。');
      await pumpEventQueue();
      out.stop();
      out.add('第二句很长很长很长很长很长很长很长很长很长很长很长很长很长。');
      out.finish();
      await done.future;
      await pumpEventQueue();
      expect(audio.calls, contains('stop'));
      expect(speech.asked, ['第一句已经够长了。']);
    });
  });
}

/// Every piece is 80 ms of 24 kHz PCM.
class _Seconds implements DeepSeekSpeech {
  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    yield Uint8List(deepSeekTtsRate * 2 * 80 ~/ 1000);
  }

  @override
  Future<String> transcribe(Uint8List wav) async => '';

  @override
  void close() {}
}
