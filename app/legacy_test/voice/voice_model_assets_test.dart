import 'dart:io';

import 'package:dsh_app/voice/voice_model_assets.dart';
import 'package:flutter_test/flutter_test.dart';

/// `runtime/assets.json` of @deepseek-ai/dsh-experimental-speech-to-text-sensevoice 0.2.1-rc.2.
const rc2Lock = '''
{
  "models": {
    "int8": {
      "name": "model.int8.onnx",
      "url": "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx",
      "bytes": 239233841,
      "sha256": "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
    },
    "fp32": {
      "name": "model.onnx",
      "url": "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.onnx",
      "bytes": 937617178,
      "sha256": "977016bd9c79f9eb343430b5cc305e07ab64d5212dff41b0dcfa1694bee9a8cb"
    }
  },
  "tokens": {
    "name": "tokens.txt",
    "url": "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt",
    "bytes": 315894,
    "sha256": "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
  },
  "vad": {
    "name": "silero_vad.onnx",
    "url": "https://huggingface.co/csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx",
    "bytes": 1807522,
    "sha256": "a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28"
  }
}
''';

void main() {
  test('the rc2 lock: INT8 model, tokens and VAD, each with a mainland mirror', () {
    final assets = parseVoiceModelLock(rc2Lock)!;
    expect(assets.map((a) => a.guestPath), [
      '/root/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx/model.int8.onnx',
      '/root/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx/tokens.txt',
      '/root/.dsh/speech-to-text/sensevoice/models/silero/silero_vad.onnx',
    ]);
    expect(assets.fold<int>(0, (n, a) => n + a.bytes), 241357257);
    for (final a in assets) {
      expect(a.mirrors, isNotEmpty, reason: a.name);
      expect(a.mirrors.every((u) => u.scheme == 'https' && u.host == 'www.modelscope.cn'), isTrue);
    }
  });

  test('a file the app has no mirror for leaves the download to the engine', () {
    final other = rc2Lock.replaceAll('c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51', 'a' * 64);
    final assets = parseVoiceModelLock(other)!;
    expect(assets.first.mirrors, isEmpty);
  });

  test('a lock this app does not understand is refused', () {
    expect(parseVoiceModelLock('not json'), isNull);
    expect(parseVoiceModelLock('{"models": {}}'), isNull);
    // A path outside the model directory would be written where the lock says.
    expect(parseVoiceModelLock(rc2Lock.replaceFirst('"tokens.txt"', '"../tokens.txt"')), isNull);
    expect(parseVoiceModelLock(rc2Lock.replaceFirst('"bytes": 315894', '"bytes": "315894"')), isNull);
  });

  test('files on disk: complete, partial and deleted', () async {
    final root = await Directory.systemTemp.createTemp('voice-rootfs');
    addTearDown(() => root.delete(recursive: true));
    final files = VoiceModelFiles(root);
    final lock = files.host(VoiceModelPaths.lock)..createSync(recursive: true);
    // Small stand-ins: the sizes come from the lock.
    lock.writeAsStringSync(
      rc2Lock
          .replaceFirst('"bytes": 239233841', '"bytes": 10')
          .replaceFirst('"bytes": 315894', '"bytes": 4')
          .replaceFirst('"bytes": 1807522', '"bytes": 6'),
    );
    final assets = files.assets()!;
    expect(files.complete(assets), isFalse);
    expect(files.presentBytes(assets), 0);
    files.host(assets[0].guestPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(10, 1));
    File('${files.host(assets[1].guestPath).path}${VoiceModelPaths.partSuffix}').writeAsBytesSync([1, 2]);
    expect(files.presentBytes(assets), 12);
    expect(files.complete(assets), isFalse);
    files.host(assets[1].guestPath).writeAsBytesSync([1, 2, 3, 4]);
    files.host(assets[2].guestPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(6, 2));
    expect(files.complete(assets), isTrue);
    await files.delete();
    expect(files.complete(assets), isFalse);
    expect(lock.existsSync(), isTrue, reason: 'the engine itself stays');
  });

  test('no lock: this runtime has no voice bundle', () async {
    final root = await Directory.systemTemp.createTemp('voice-rootfs');
    addTearDown(() => root.delete(recursive: true));
    expect(VoiceModelFiles(root).assets(), isNull);
  });
}
