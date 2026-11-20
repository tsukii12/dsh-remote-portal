import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  group('file mentions (dsh-file-reference grammar)', () {
    test('plain, quoted, folders', () {
      expect(formatFileMention('lib/main.dart'), '@lib/main.dart');
      expect(formatFileMention('lib/ui', directory: true), '@lib/ui/');
      expect(formatFileMention('lib/my file.dart'), '@"lib/my file.dart"');
      // A quoted folder keeps its quote open, as the official completion writes it.
      expect(formatFileMention('my dir', directory: true), '@"my dir/');
      expect(formatFileMention('lib', directory: true, preserveQuote: true), '@"lib/');
      expect(formatFileMention('a"b'), isNull);
      expect(formatFileMention('a\u0007b'), isNull);
    });
  });

  group('session mentions (dsh-session-reference URI)', () {
    test('matches what a 0.2.1-rc.2 Host returned', () {
      // `sessionReferenceResolver/candidates` on a throwaway `dsh web`.
      const id = 'session-82738f84-e2e3-4f58-aa10-83114d56ab4a';
      expect(
        formatSessionMention(id, '修复 登录] 问题'),
        r'@[修复 登录\] 问题](dsh-session:InNlc3Npb24tODI3MzhmODQtZTJlMy00ZjU4LWFhMTAtODMxMTRkNTZhYjRhIg)',
      );
      expect(
        decodeSessionReferenceUri('dsh-session:InNlc3Npb24tODI3MzhmODQtZTJlMy00ZjU4LWFhMTAtODMxMTRkNTZhYjRhIg'),
        id,
      );
      expect(decodeSessionReferenceUri('dsh-session:InNlc3Npb24'), isNull);
      expect(decodeSessionReferenceUri('dsh-session:not*base64'), isNull);
    });

    test('pattern and label escapes', () {
      final m = sessionMentionPattern.firstMatch(r'看 @[a\]b\\c](dsh-session:ImEi) 吧')!;
      expect(unescapeMentionLabel(m[1]!), r'a]b\c');
      expect(m[2], 'dsh-session:ImEi');
    });
  });

  group('wire calls', () {
    test('fileReferences/list and sessionReferenceResolver/candidates', () async {
      final carrier = _Carrier({
        'fileReferences/list': (_) => [
          {'path': 'lib', 'kind': 'directory'},
          {'path': 'lib/main.dart', 'kind': 'file'},
          {'path': '', 'kind': 'file'},
        ],
        'sessionReferenceResolver/candidates': (_) => [
          {
            'sessionId': 's1',
            'label': 'child',
            'displayTitle': '检查依赖',
            'sameWorkspace': true,
            'createdAt': 1792821424113,
            'mention': '@[检查依赖](dsh-session:InMxIg)',
          },
          {'sessionId': 's2', 'label': 'no mention'},
        ],
      });
      final client = DshClient.withCarrier(carrier);
      final files = await client.fileReferences('main', 'li');
      expect(carrier.calls.last.$1, 'fileReferences/list');
      expect(carrier.calls.last.$2, {'agentId': 'main', 'query': 'li'});
      expect(
        [for (final f in files) (f.path, f.isDirectory, f.name, f.parent)],
        [('lib', true, 'lib', ''), ('lib/main.dart', false, 'main.dart', 'lib')],
      );
      expect(files.first.mention, '@lib/');
      final sessions = await client.sessionReferences('main', '');
      expect(carrier.calls.last.$1, 'sessionReferenceResolver/candidates');
      expect(carrier.calls.last.$2, {'agentId': 'main', 'query': ''});
      expect(sessions, hasLength(1));
      expect(sessions.single.title, '检查依赖');
      expect(sessions.single.createdAt, DateTime.fromMillisecondsSinceEpoch(1792821424113));
    });

    test('speech: not served is null; ready catalog; transcribe sends canonical base64', () async {
      final off = DshClient.withCarrier(_Carrier({}));
      expect(await off.speechCatalog(), isNull);

      final carrier = _Carrier({
        'speech/catalog': (_) => {
          'providers': [
            {
              'id': 'sensevoice-local',
              'name': 'SenseVoice',
              'location': 'host-local',
              'languages': ['auto', 'zh'],
              'preparation': {'phase': 'standby'},
            },
          ],
          'selection': {'providerId': 'sensevoice-local', 'language': 'auto'},
          'maxAudioBytes': 4194304,
          'maxDurationSeconds': 120,
        },
        'speech/transcribe': (_) => {'text': ' 你好 ', 'audioSeconds': 1.5, 'inferenceSeconds': 0.2},
      });
      final client = DshClient.withCarrier(carrier);
      final catalog = (await client.speechCatalog())!;
      expect(catalog.selected?.usable, isTrue);
      expect(catalog.maxSeconds, 120);
      final wav = Uint8List.fromList([1, 2, 3, 4]);
      final transcript = await client.transcribe(wav, providerId: 'sensevoice-local', language: 'auto');
      expect(transcript.text, '你好');
      expect(carrier.calls.last.$1, 'speech/transcribe');
      expect(carrier.calls.last.$2, {
        'request': {'audioBase64': base64Encode(wav), 'providerId': 'sensevoice-local', 'language': 'auto'},
      });
    });

    test('speech preparation: download progress, failure details, prepare / cancel / configure args', () async {
      // Shapes as answered by DSH 0.2.1-rc.2 (`dsh web`, voice-input bundle on).
      final downloading = SpeechCatalog.fromJson({
        'providers': [
          {
            'id': 'sensevoice-local',
            'name': 'SenseVoiceSmall (INT8)',
            'location': 'host-local',
            'languages': ['auto', 'zh', 'en', 'yue', 'ja', 'ko'],
            'downloadSources': ['https://huggingface.co', 'https://hf-mirror.com'],
            'preparation': {
              'phase': 'downloading',
              'resource': 'model.int8.onnx',
              'completedBytes': 7095632,
              'totalBytes': 239233841,
              'step': 'model',
            },
          },
        ],
        'selection': {'providerId': 'sensevoice-local', 'language': 'auto'},
        'maxAudioBytes': 4194304,
        'maxDurationSeconds': 120,
      })!;
      final p = downloading.selected!;
      expect(p.usable, isFalse);
      expect(p.downloadSources, ['https://huggingface.co', 'https://hf-mirror.com']);
      expect(p.preparation.phase, 'downloading');
      expect(p.preparation.step, 'model');
      expect(p.preparation.resource, 'model.int8.onnx');
      expect(p.preparation.completedBytes, 7095632);
      expect(p.preparation.totalBytes, 239233841);

      final failed = SpeechProviderView.fromJson({
        'id': 'sensevoice-local',
        'preparation': {
          'phase': 'failed',
          'message': 'Unable to prepare model.int8.onnx from https://us.aws.cdn.hf.co: network (UND_ERR_SOCKET)',
          'download': {'resource': 'model.int8.onnx', 'source': 'https://us.aws.cdn.hf.co', 'reason': 'network', 'code': 'UND_ERR_SOCKET'},
        },
      })!;
      expect(failed.phase, 'failed');
      expect(failed.preparation.failure?.reason, 'network');
      expect(failed.preparation.failure?.code, 'UND_ERR_SOCKET');
      expect(failed.preparation.failure?.status, isNull);
      expect(failed.preparation.message, contains('UND_ERR_SOCKET'));

      final carrier = _Carrier({
        'speech/prepare': (_) => null,
        'speech/cancelPreparation': (_) => null,
        'speech/configure': (_) => null,
      });
      final client = DshClient.withCarrier(carrier);
      await client.prepareSpeech('sensevoice-local');
      await client.prepareSpeech('sensevoice-local', downloadSource: 'https://hf-mirror.com');
      await client.cancelSpeechPreparation('sensevoice-local');
      await client.configureSpeech(providerId: 'sensevoice-local');
      expect([for (final (endpoint, args) in carrier.calls) [endpoint, args]], [
        ['speech/prepare', {'providerId': 'sensevoice-local'}],
        [
          'speech/prepare',
          {
            'providerId': 'sensevoice-local',
            'options': {'downloadSource': 'https://hf-mirror.com'},
          },
        ],
        ['speech/cancelPreparation', {'providerId': 'sensevoice-local'}],
        [
          'speech/configure',
          {
            'patch': {'providerId': 'sensevoice-local'},
          },
        ],
      ]);
    });

    test('an unprepared recognizer is not usable', () {
      final catalog = SpeechCatalog.fromJson({
        'providers': [
          {
            'id': 'sensevoice-local',
            'preparation': {'phase': 'unprepared'},
          },
        ],
        'selection': {'providerId': 'sensevoice-local', 'language': 'auto'},
        'maxAudioBytes': 1000000,
        'maxDurationSeconds': 120,
      })!;
      expect(catalog.selected?.usable, isFalse);
      // The byte limit is the tighter one here.
      expect(catalog.maxSeconds, (1000000 - 44) ~/ 32000);
    });
  });
}

class _Carrier extends DshCarrier {
  _Carrier(this.handlers);
  final Map<String, Object? Function(Map<String, Object?>)> handlers;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  String get kind => 'test';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) throw DshHttpException(404, 'endpoint $endpoint is not served by this Host');
    return RpcOk(handler(args));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => Future.error(const DshTransportException('no mux'));

  @override
  Future<void> close() async {}
}
