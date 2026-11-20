// The streaming recognizer's model: sherpa-onnx's bilingual Chinese–English
// zipformer (int8, Apache-2.0), four files fetched one by one from Hugging Face
// (its mirror when that does not answer), each resumable and checked against its
// pinned SHA-256 once, as it lands. About 198 MB.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'native_trial.dart';
import 'streaming_asr_model.dart';

class StreamingAsrFile {
  const StreamingAsrFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

class StreamingAsrModelManifest {
  const StreamingAsrModelManifest({
    required this.hosts,
    required this.repository,
    required this.revision,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  /// Tried in order for each file.
  final List<String> hosts;
  final String repository;
  final String revision;
  final StreamingAsrFile encoder;
  final StreamingAsrFile decoder;
  final StreamingAsrFile joiner;
  final StreamingAsrFile tokens;

  List<StreamingAsrFile> get files => [encoder, decoder, joiner, tokens];
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);

  Uri url(String host, StreamingAsrFile file) => Uri.parse('$host/$repository/resolve/$revision/${file.name}');

  StreamingAsrModel paths(String directory) => StreamingAsrModel(
    encoder: '$directory/${encoder.name}',
    decoder: '$directory/${decoder.name}',
    joiner: '$directory/${joiner.name}',
    tokens: '$directory/${tokens.name}',
  );
}

const streamingAsrDefaultBytes = 198270793;

const streamingAsrDefaultManifest = StreamingAsrModelManifest(
  // huggingface.co, then hf-mirror.com (often the only one reachable in China).
  hosts: ['https://huggingface.co', 'https://hf-mirror.com'],
  repository: 'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20',
  revision: '98590b7ed6443e77b714204da2757d75e1a642f4',
  encoder: StreamingAsrFile(
    'encoder-epoch-99-avg-1.int8.onnx',
    181895032,
    '8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b',
  ),
  decoder: StreamingAsrFile(
    'decoder-epoch-99-avg-1.int8.onnx',
    13091040,
    '1a70c593d71e53f023f5f55b0b4cfff5055abb786ee3992e5f63dc2e273cc4fa',
  ),
  joiner: StreamingAsrFile(
    'joiner-epoch-99-avg-1.int8.onnx',
    3228404,
    '1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0',
  ),
  tokens: StreamingAsrFile('tokens.txt', 56317, 'a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3'),
);

enum StreamingAsrDownloadPhase { downloading, verifying }

class StreamingAsrDownloadProgress {
  const StreamingAsrDownloadProgress(this.phase, this.doneBytes, this.totalBytes);
  final StreamingAsrDownloadPhase phase;
  final int doneBytes;
  final int totalBytes;
}

class StreamingAsrDownloadCancelled implements Exception {}

/// One owner writes this directory. Cancel keeps the `.part` files; delete waits for the writer.
/// The ONNX Runtime sherpa-onnx brings (pubspec.yaml); a trial is per version.
const streamingAsrNativeKey = 'ort-1.27.0';

class StreamingAsrModelStore {
  StreamingAsrModelStore(this.directory, {this.manifest = streamingAsrDefaultManifest});

  final Directory directory;
  final StreamingAsrModelManifest manifest;
  Future<StreamingAsrModel>? _running;
  Future<void>? _deleting;
  HttpClient? _client;
  bool _cancelled = false;

  /// The recognizer's first run here; its marks go when the model is deleted.
  late final trial = NativeTrial(directory, streamingAsrNativeKey);

  File _file(StreamingAsrFile file) => File('${directory.path}/${file.name}');
  File _part(StreamingAsrFile file) => File('${directory.path}/${file.name}.part');

  /// Ready when every file is there at its size (each was checked as it landed).
  Future<StreamingAsrModel?> installed() async {
    for (final file in manifest.files) {
      final local = _file(file);
      if (!await local.exists() || await local.length() != file.bytes) return null;
    }
    return manifest.paths(directory.path);
  }

  /// Bytes already here: whole files and the parts of the one under way.
  Future<int> downloadedBytes() async {
    var done = 0;
    for (final file in manifest.files) {
      final local = _file(file);
      final part = _part(file);
      if (await local.exists()) {
        done += await local.length();
      } else if (await part.exists()) {
        done += await part.length();
      }
    }
    return done;
  }

  Future<StreamingAsrModel> download({void Function(StreamingAsrDownloadProgress)? onProgress}) {
    final deleting = _deleting;
    if (deleting != null) return deleting.then((_) => download(onProgress: onProgress));
    final running = _running;
    if (running != null) return running;
    _cancelled = false;
    late final Future<StreamingAsrModel> run;
    run = _download(onProgress).whenComplete(() {
      if (identical(_running, run)) _running = null;
    });
    _running = run;
    return run;
  }

  Future<void> cancel() async {
    _cancelled = true;
    _client?.close(force: true);
    try {
      await _running;
    } catch (_) {
      // The download reports its own end; cancelling only waits for it.
    }
  }

  Future<void> delete() {
    final deleting = _deleting;
    if (deleting != null) return deleting;
    late final Future<void> run;
    run =
        (() async {
          await cancel();
          if (await directory.exists()) await directory.delete(recursive: true);
        })().whenComplete(() {
          if (identical(_deleting, run)) _deleting = null;
        });
    _deleting = run;
    return run;
  }

  void _checkCancelled() {
    if (_cancelled) throw StreamingAsrDownloadCancelled();
  }

  Future<StreamingAsrModel> _download(void Function(StreamingAsrDownloadProgress)? progress) async {
    try {
      await directory.create(recursive: true);
      var before = 0;
      for (final file in manifest.files) {
        final local = _file(file);
        if (!await local.exists() || await local.length() != file.bytes) {
          await _fetchFile(file, before, progress);
          _checkCancelled();
          progress?.call(
            StreamingAsrDownloadProgress(StreamingAsrDownloadPhase.verifying, before + file.bytes, manifest.bytes),
          );
          final part = _part(file).path;
          final digest = await Isolate.run(() async => (await sha256.bind(File(part).openRead()).first).toString());
          _checkCancelled();
          if (digest != file.sha256) {
            await File(part).delete();
            throw FormatException('Streaming ASR model checksum mismatch: ${file.name}');
          }
          await File(part).rename(local.path);
        }
        before += file.bytes;
      }
      return manifest.paths(directory.path);
    } catch (error) {
      if (_cancelled) throw StreamingAsrDownloadCancelled();
      rethrow;
    }
  }

  /// [file] into its `.part` from the first host that serves it.
  Future<void> _fetchFile(
    StreamingAsrFile file,
    int before,
    void Function(StreamingAsrDownloadProgress)? progress,
  ) async {
    Object? failure;
    for (final host in manifest.hosts) {
      try {
        await _fetch(manifest.url(host, file), file, before, progress);
        return;
      } catch (error) {
        if (_cancelled) rethrow;
        failure = error;
      }
    }
    throw failure!;
  }

  Future<void> _fetch(
    Uri url,
    StreamingAsrFile file,
    int before,
    void Function(StreamingAsrDownloadProgress)? progress,
  ) async {
    final part = _part(file);
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > file.bytes) offset = 0;
    if (offset == file.bytes) return;
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(url);
      if (offset > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(const Duration(seconds: 30));
      _checkCancelled();
      if (response.statusCode == HttpStatus.ok) {
        offset = 0; // The server ignored the range: start over.
      } else if (response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final output = await part.open(mode: offset == 0 ? FileMode.write : FileMode.append);
      var done = offset;
      var tooLong = false;
      var reportedAt = -250;
      final clock = Stopwatch()..start();
      try {
        await for (final bytes in response.timeout(const Duration(seconds: 30))) {
          _checkCancelled();
          if (done + bytes.length > file.bytes) {
            tooLong = true;
            break;
          }
          await output.writeFrom(bytes);
          done += bytes.length;
          if (clock.elapsedMilliseconds - reportedAt >= 250) {
            reportedAt = clock.elapsedMilliseconds;
            progress?.call(
              StreamingAsrDownloadProgress(StreamingAsrDownloadPhase.downloading, before + done, manifest.bytes),
            );
          }
        }
      } finally {
        await output.close();
      }
      if (tooLong) {
        // Not the file it should be: nothing of it is kept.
        await part.delete();
        throw HttpException('Larger than expected: ${file.name}', uri: url);
      }
      if (done != file.bytes) throw HttpException('Incomplete ${file.name}', uri: url);
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }
}
