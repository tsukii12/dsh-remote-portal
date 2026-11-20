import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'speech_fakes.dart';

void main() {
  group('DirectDeepSeekSpeech', () {
    test('TTS asks for PCM with the key and the voice, and streams the audio', () async {
      late http.Request seen;
      final client = MockClient.streaming((request, body) async {
        seen = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = await body.toBytes();
        return http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
          200,
        );
      });
      final speech = DirectDeepSeekSpeech('sk-test', client: () => client);
      final chunks = await speech.synthesize('你好', voice: 'tide').toList();
      expect(chunks, [
        [1, 2, 3],
        [4, 5],
      ]);
      expect(seen.url.toString(), 'https://api.deepseek.com/v1/tools/tts');
      expect(seen.headers['authorization'], 'Bearer sk-test');
      final body = jsonDecode(utf8.decode(seen.bodyBytes)) as Map;
      expect(body, {'text': '你好', 'voice_id': 'tide', 'format': 'pcm', 'filter_markdown': true});
    });

    test('an unknown voice falls back to stella', () async {
      late Map body;
      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map;
        return http.Response.bytes([0, 0], 200);
      });
      await DirectDeepSeekSpeech('k', client: () => client).synthesize('a', voice: 'nope').toList();
      expect(body['voice_id'], 'stella');
    });

    for (final (status, failure) in [
      (401, DeepSeekSpeechFailure.unauthorized),
      (402, DeepSeekSpeechFailure.insufficientBalance),
      (400, DeepSeekSpeechFailure.rejected),
      (429, DeepSeekSpeechFailure.rateLimited),
      (503, DeepSeekSpeechFailure.busy),
    ]) {
      test('HTTP $status is ${failure.name}, with the service\'s words and no key', () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'reason $status'},
            }),
            status,
          ),
        );
        final speech = DirectDeepSeekSpeech('sk-secret', client: () => client);
        await expectLater(
          speech.synthesize('x').toList(),
          throwsA(
            isA<DeepSeekSpeechError>()
                .having((e) => e.failure, 'failure', failure)
                .having((e) => e.detail, 'detail', 'reason $status')
                .having((e) => e.toString(), 'text', isNot(contains('sk-secret'))),
          ),
        );
      });
    }

    test('ASR sends the WAV as multipart file and returns the text', () async {
      late http.Request seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'request_id': 'r', 'text': ' 上海今天天气怎么样？ ', 'duration_ms': 3200})),
          200,
        );
      });
      final text = await DirectDeepSeekSpeech('sk-a', client: () => client).transcribe(Uint8List(100));
      expect(text, '上海今天天气怎么样？');
      expect(seen.url.path, '/v1/tools/asr');
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      expect(seen.body, contains('name="file"; filename="speech.wav"'));
    });

    test('ASR refuses a recording over 8 MiB without asking', () async {
      var asked = false;
      final client = MockClient((_) async {
        asked = true;
        return http.Response('{}', 200);
      });
      await expectLater(
        DirectDeepSeekSpeech('k', client: () => client).transcribe(Uint8List(deepSeekAsrMaxBytes + 1)),
        throwsA(isA<DeepSeekSpeechError>().having((e) => e.failure, 'failure', DeepSeekSpeechFailure.tooLarge)),
      );
      expect(asked, isFalse);
    });
  });

  test('deepSeekWav wraps 24 kHz mono PCM16', () {
    final wav = deepSeekWav(Uint8List.fromList([1, 2, 3, 4, 5]));
    final data = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(40, Endian.little), 4); // An odd last byte is dropped.
    expect(wav.length, 48);
  });

  group('AccountThenKeySpeech', () {
    setUp(resetDeepSeekAccountRefusal);

    test('the account turned away before any audio: the key reads it, and every later request', () async {
      final account = FakeDeepSeek(fail: const DeepSeekSpeechError(DeepSeekSpeechFailure.signIn));
      final key = FakeDeepSeek();
      var keys = 0;
      final speech = AccountThenKeySpeech(account, () {
        keys++;
        return key;
      });
      expect(await speech.synthesize('你好').toList(), isNotEmpty);
      expect(await speech.transcribe(Uint8List(4)), '你好');
      expect(account.asked, ['你好']);
      expect(account.heard, isEmpty);
      expect(key.asked, ['你好']);
      expect(keys, 1);
      expect(account.closed, isFalse, reason: 'requests already on the account finish');
    });

    test('other failures are the account\'s own and are not retried with the key', () async {
      final account = FakeDeepSeek(fail: const DeepSeekSpeechError(DeepSeekSpeechFailure.insufficientBalance));
      final key = FakeDeepSeek();
      final speech = AccountThenKeySpeech(account, () => key);
      await expectLater(
        speech.synthesize('你好').toList(),
        throwsA(
          isA<DeepSeekSpeechError>().having((e) => e.failure, 'failure', DeepSeekSpeechFailure.insufficientBalance),
        ),
      );
      expect(key.asked, isEmpty);
    });
  });
}
