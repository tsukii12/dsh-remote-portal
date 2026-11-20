// The on-device voice model: SenseVoiceSmall INT8 and Silero VAD, as the
// engine's own recognizer (`@deepseek-ai/dsh-experimental-speech-to-text-
// sensevoice`) expects them. Which files, how big and their SHA-256 come from
// the lock it ships (`runtime/assets.json` in the rootfs), so a newer engine
// with other files is never fed old ones.
//
// The provider downloads from huggingface.co and hf-mirror.com; from mainland
// China both end at Hugging Face's own CDN (hf-mirror answers 308 to
// huggingface.co) and fail or crawl. Byte-identical copies sit on ModelScope:
// the app downloads those into the provider's cache first, and the provider
// accepts a cached file whose size and SHA-256 match (`matchesAsset`), so its
// own download is skipped. Unknown hashes have no mirror: the provider then
// downloads itself.

import 'dart:convert';
import 'dart:io';

/// The recognizer id the voice-input bundle registers (`sensevoice-local`).
const voiceModelProviderId = 'sensevoice-local';

/// The optional DSH bundle that serves `speech/*` with that recognizer.
const voiceInputBundle = '@deepseek-ai/dsh-experimental-voice-input-bundle';

/// Guest paths (DSH home is `/root/.dsh`; the bundle sets the provider's
/// `dataRoot` to `dshHomePath('speech-to-text', 'sensevoice')`).
abstract final class VoiceModelPaths {
  static const dataRoot = '/root/.dsh/speech-to-text/sensevoice';
  static const models = '$dataRoot/models';
  static const recognizerDir = '$models/sensevoice-onnx';
  static const vadDir = '$models/silero';
  static const lock =
      '/opt/dsh/node_modules/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice/runtime/assets.json';

  /// Suffix of the app's resumable partial files (the provider's own are `.<uuid>.part`).
  static const partSuffix = '.dsh-go.part';

  /// Where 重新下载 puts the new files (laid out as under [models]) until
  /// every one is in and checked. The same file system as [models], so each
  /// takes its place with a rename; outside it, so the provider never sees
  /// a half-downloaded copy.
  static const staging = '$dataRoot/dsh-go-staging';
}

/// Mirror URLs by SHA-256: ModelScope copies, pinned to a revision.
/// Checked 2026-10-28: same size and SHA-256 as the 0.2.1-rc.2 lock.
const voiceModelMirrors = <String, List<String>>{
  // model.int8.onnx, 239 233 841 bytes
  'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51': [
    'https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/73eca47697f980daa3d16112404174b6b950b514/model.int8.onnx',
  ],
  // tokens.txt, 315 894 bytes
  'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc': [
    'https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/73eca47697f980daa3d16112404174b6b950b514/tokens.txt',
  ],
  // silero_vad.onnx (v4), 1 807 522 bytes
  'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28': [
    'https://www.modelscope.cn/models/pengzhendong/silero-vad/resolve/370539c71ec0ac703627938064cf31c1852186d7/v4/silero_vad.onnx',
  ],
};

/// One pinned file of the model.
class VoiceModelAsset {
  const VoiceModelAsset({required this.name, required this.bytes, required this.sha256, required this.guestDir});

  final String name;
  final int bytes;
  final String sha256;

  /// Guest directory the provider reads it from.
  final String guestDir;

  String get guestPath => '$guestDir/$name';

  /// ModelScope copies; empty when this exact file has none.
  List<Uri> get mirrors => [for (final url in voiceModelMirrors[sha256] ?? const <String>[]) Uri.parse(url)];
}

/// The files of the INT8 model, from the provider's lock (null: unreadable,
/// or a lock this app does not understand).
List<VoiceModelAsset>? parseVoiceModelLock(String json) {
  try {
    final lock = jsonDecode(json);
    if (lock is! Map) return null;
    VoiceModelAsset? asset(Object? raw, String dir) {
      if (raw is! Map) return null;
      final name = raw['name'];
      final bytes = raw['bytes'];
      final sha = raw['sha256'];
      if (name is! String || bytes is! int || sha is! String) return null;
      // A plain file name: the lock never places files elsewhere.
      if (name.isEmpty || name.contains('/') || name.startsWith('.') || bytes <= 0) return null;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
      return VoiceModelAsset(name: name, bytes: bytes, sha256: sha, guestDir: dir);
    }

    final models = lock['models'];
    final assets = [
      asset(models is Map ? models['int8'] : null, VoiceModelPaths.recognizerDir),
      asset(lock['tokens'], VoiceModelPaths.recognizerDir),
      asset(lock['vad'], VoiceModelPaths.vadDir),
    ];
    if (assets.any((a) => a == null)) return null;
    return assets.cast<VoiceModelAsset>();
  } catch (_) {
    return null;
  }
}

/// The model's files inside one rootfs (`filesDir/runtime/rootfs`).
class VoiceModelFiles {
  VoiceModelFiles(this.rootfs);

  final Directory rootfs;

  File host(String guestPath) => File('${rootfs.path}/${guestPath.replaceFirst(RegExp(r'^/+'), '')}');

  /// The provider's lock in this runtime; null when the runtime has no voice bundle.
  List<VoiceModelAsset>? assets() {
    try {
      final lock = host(VoiceModelPaths.lock);
      if (!lock.existsSync()) return null;
      return parseVoiceModelLock(lock.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Bytes already in place: complete files count whole (size matches; the
  /// provider checks the hash), partial ones by their length.
  int presentBytes(List<VoiceModelAsset> assets) {
    var total = 0;
    for (final a in assets) {
      final file = host(a.guestPath);
      final part = File('${file.path}${VoiceModelPaths.partSuffix}');
      try {
        if (file.existsSync() && file.lengthSync() == a.bytes) {
          total += a.bytes;
        } else if (part.existsSync()) {
          total += part.lengthSync().clamp(0, a.bytes);
        }
      } catch (_) {}
    }
    return total;
  }

  /// Every file is there at its pinned size.
  bool complete(List<VoiceModelAsset> assets) => assets.every((a) {
    try {
      final file = host(a.guestPath);
      return file.existsSync() && file.lengthSync() == a.bytes;
    } catch (_) {
      return false;
    }
  });

  /// Removes the models (also the provider's and the app's partial files,
  /// and a 重新下载 copy in [VoiceModelPaths.staging]).
  Future<void> delete() async {
    await clearStaging();
    final dir = Directory(host(VoiceModelPaths.models).path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Where [asset] comes in during 重新下载.
  File staged(VoiceModelAsset asset) {
    final under = asset.guestPath.startsWith('${VoiceModelPaths.models}/')
        ? asset.guestPath.substring(VoiceModelPaths.models.length)
        : '/${asset.name}';
    return host('${VoiceModelPaths.staging}$under');
  }

  /// Removes a 重新下载 copy, finished or not.
  Future<void> clearStaging() async {
    final dir = Directory(host(VoiceModelPaths.staging).path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// The staged files take the model's place, each with one rename: a reader
  /// sees the old file or the new one, never a part of either (one that has
  /// the old one open keeps it until it closes it).
  Future<void> promoteStaged(List<VoiceModelAsset> assets) async {
    for (final a in assets) {
      final target = host(a.guestPath);
      await target.parent.create(recursive: true);
      await staged(a).rename(target.path);
    }
    await clearStaging();
  }
}
