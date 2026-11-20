// Downloads the voice model's files into the engine's model cache: resumable
// (`<file>.dsh-go.part` + an HTTP range), checked against the pinned size and
// SHA-256 before the file takes its final name, and stopped by a stall rather
// than by a total deadline (a 240 MB file on a slow line is fine; a dead one
// is not). Runs in its own isolate: hashing 240 MB must not touch the UI.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Why a download stopped.
enum VoiceDownloadError { network, timeout, certificate, http, integrity, storage, cancelled, unknown }

class VoiceDownloadException implements Exception {
  const VoiceDownloadException(this.kind, {this.status, this.file});

  final VoiceDownloadError kind;

  /// HTTP status, for [VoiceDownloadError.http].
  final int? status;

  /// The file it stopped at.
  final String? file;

  @override
  String toString() =>
      'VoiceDownloadException(${kind.name}${status == null ? '' : ' $status'}${file == null ? '' : ' $file'})';
}

/// One file: where it goes, what it must be, where to get it (tried in order).
class VoiceDownloadJob {
  const VoiceDownloadJob({required this.urls, required this.path, required this.bytes, required this.sha256});

  final List<Uri> urls;
  final String path;
  final int bytes;
  final String sha256;

  String get partPath => '$path.dsh-go.part';

  List<Object> toWire() => [path, bytes, sha256, ...urls.map((u) => u.toString())];

  static VoiceDownloadJob fromWire(List<Object?> w) => VoiceDownloadJob(
    path: w[0]! as String,
    bytes: w[1]! as int,
    sha256: w[2]! as String,
    urls: [for (final u in w.skip(3)) Uri.parse(u! as String)],
  );
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Downloads [jobs] in order. [onProgress] gets the bytes in place across all
/// jobs (complete files plus partial ones), at most every [progressEvery].
/// Throws [VoiceDownloadException]; partial files stay for the next run
/// unless their content proved wrong.
Future<void> downloadVoiceFiles(
  List<VoiceDownloadJob> jobs, {
  required void Function(int done) onProgress,
  bool Function()? cancelled,
  HttpClient Function()? clientFactory,
  Duration stall = const Duration(seconds: 30),
  Duration progressEvery = const Duration(milliseconds: 250),
}) async {
  final client = (clientFactory ?? HttpClient.new)()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 5)
    ..userAgent = 'dsh-go';
  bool stop() => cancelled?.call() ?? false;
  var finished = 0;
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  void report(int current, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(last) < progressEvery) return;
    last = now;
    onProgress(finished + current);
  }

  try {
    for (final job in jobs) {
      if (stop()) throw const VoiceDownloadException(VoiceDownloadError.cancelled);
      final target = File(job.path);
      if (target.existsSync() && target.lengthSync() == job.bytes) {
        finished += job.bytes;
        report(0, force: true);
        continue;
      }
      VoiceDownloadException? failure;
      for (final url in job.urls) {
        try {
          await _fetch(client, job, url, stall: stall, stop: stop, report: report);
          failure = null;
          break;
        } on VoiceDownloadException catch (e) {
          // A cancel can surface as a broken connection (the client is closed under it).
          if (stop()) throw VoiceDownloadException(VoiceDownloadError.cancelled, file: e.file);
          if (e.kind == VoiceDownloadError.cancelled || e.kind == VoiceDownloadError.storage) rethrow;
          failure = e;
        }
      }
      if (job.urls.isEmpty) failure = VoiceDownloadException(VoiceDownloadError.unknown, file: _name(job.path));
      if (failure != null) throw failure;
      finished += job.bytes;
      report(0, force: true);
    }
  } finally {
    client.close(force: true);
  }
}

String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

Future<void> _fetch(
  HttpClient client,
  VoiceDownloadJob job,
  Uri url, {
  required Duration stall,
  required bool Function() stop,
  required void Function(int current, {bool force}) report,
}) async {
  final name = _name(job.path);
  final part = File(job.partPath);
  IOSink? sink;
  try {
    await part.parent.create(recursive: true);
    var offset = part.existsSync() ? part.lengthSync() : 0;
    if (offset > job.bytes) {
      await part.delete();
      offset = 0;
    }
    final digestOut = _DigestSink();
    var hasher = sha256.startChunkedConversion(digestOut);
    if (offset > 0) {
      await for (final chunk in part.openRead()) {
        hasher.add(chunk);
      }
    }
    if (offset < job.bytes) {
      final request = await client.getUrl(url).timeout(stall);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (offset > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(stall);
      if (response.statusCode == HttpStatus.ok) {
        // No range support (or a fresh start): from the first byte.
        offset = 0;
        hasher = sha256.startChunkedConversion(digestOut);
        sink = part.openWrite();
      } else if (response.statusCode == HttpStatus.partialContent && _rangeStart(response) == offset) {
        sink = part.openWrite(mode: FileMode.append);
      } else {
        // Not read: an error body can be held open without a byte forever
        // (no stall applies to it). Cancelling closes the connection.
        await response.listen(null).cancel().catchError((_) {});
        throw VoiceDownloadException(VoiceDownloadError.http, status: response.statusCode, file: name);
      }
      var received = offset;
      report(received, force: true);
      // Await the file consumer so an asynchronous write failure reaches this catch.
      await sink.addStream(
        response.timeout(stall).map((chunk) {
          if (stop()) throw VoiceDownloadException(VoiceDownloadError.cancelled, file: name);
          received += chunk.length;
          if (received > job.bytes) throw VoiceDownloadException(VoiceDownloadError.integrity, file: name);
          hasher.add(chunk);
          report(received);
          return chunk;
        }),
      );
      await sink.close();
      sink = null;
    }
    // A cancel that came with the last chunk still wins; the whole .part is reused next time.
    if (stop()) throw VoiceDownloadException(VoiceDownloadError.cancelled, file: name);
    hasher.close();
    if (part.lengthSync() != job.bytes || digestOut.value.toString() != job.sha256) {
      await part.delete().catchError((_) => part);
      throw VoiceDownloadException(VoiceDownloadError.integrity, file: name);
    }
    await part.rename(job.path);
  } on VoiceDownloadException {
    rethrow;
  } on TimeoutException {
    throw VoiceDownloadException(VoiceDownloadError.timeout, file: name);
  } on HandshakeException {
    throw VoiceDownloadException(VoiceDownloadError.certificate, file: name);
  } on TlsException {
    throw VoiceDownloadException(VoiceDownloadError.certificate, file: name);
  } on FileSystemException catch (e) {
    // ENOSPC (28) and EDQUOT (122): out of room.
    final code = e.osError?.errorCode;
    throw VoiceDownloadException(
      code == 28 || code == 122 ? VoiceDownloadError.storage : VoiceDownloadError.unknown,
      file: name,
    );
  } on SocketException {
    throw VoiceDownloadException(VoiceDownloadError.network, file: name);
  } on HttpException {
    throw VoiceDownloadException(VoiceDownloadError.network, file: name);
  } catch (_) {
    throw VoiceDownloadException(VoiceDownloadError.unknown, file: name);
  } finally {
    await sink?.close().catchError((_) {});
  }
}

int? _rangeStart(HttpClientResponse response) {
  final range = response.headers.value(HttpHeaders.contentRangeHeader);
  final match = RegExp(r'^bytes (\d+)-').firstMatch(range ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// [downloadVoiceFiles] in a background isolate.
class VoiceDownloadTask {
  VoiceDownloadTask._(this._control, this.progress, this.done);

  SendPort? _control;

  /// Bytes in place so far (same as [downloadVoiceFiles]'s `onProgress`).
  final Stream<int> progress;

  /// Completes when every file is in place; errors with [VoiceDownloadException].
  final Future<void> done;

  /// Stops at the next chunk; [done] then errors with `cancelled`.
  void cancel() => _control?.send('cancel');

  static Future<VoiceDownloadTask> start(List<VoiceDownloadJob> jobs) async {
    final port = ReceivePort();
    final progress = StreamController<int>.broadcast();
    final done = Completer<void>();
    final control = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort) {
        control.complete(message);
      } else if (message is int) {
        progress.add(message);
      } else if (message is List && message.isNotEmpty) {
        if (message[0] == 'ok') {
          if (!done.isCompleted) done.complete();
        } else if (!done.isCompleted) {
          final kind = VoiceDownloadError.values.firstWhere(
            (k) => k.name == message[1],
            orElse: () => VoiceDownloadError.unknown,
          );
          done.completeError(VoiceDownloadException(kind, status: message[2] as int?, file: message[3] as String?));
        }
        port.close();
        unawaited(progress.close());
      }
    });
    try {
      await Isolate.spawn(_main, [port.sendPort, for (final j in jobs) j.toWire()], debugName: 'voice-model-download');
    } catch (_) {
      port.close();
      unawaited(progress.close());
      rethrow;
    }
    final task = VoiceDownloadTask._(null, progress.stream, done.future);
    task._control = await control.future;
    return task;
  }

  static Future<void> _main(List<Object?> args) async {
    final out = args[0]! as SendPort;
    final jobs = [for (final w in args.skip(1)) VoiceDownloadJob.fromWire(w! as List<Object?>)];
    final control = ReceivePort();
    var cancelled = false;
    HttpClient? client;
    control.listen((m) {
      if (m != 'cancel') return;
      cancelled = true;
      // Ends a stalled read now instead of at the stall timeout.
      client?.close(force: true);
    });
    out.send(control.sendPort);
    try {
      await downloadVoiceFiles(
        jobs,
        onProgress: out.send,
        cancelled: () => cancelled,
        clientFactory: () => client = HttpClient(),
      );
      out.send(const ['ok']);
    } on VoiceDownloadException catch (e) {
      out.send(['error', e.kind.name, e.status, e.file]);
    } catch (_) {
      out.send(['error', VoiceDownloadError.unknown.name, null, null]);
    } finally {
      control.close();
    }
  }
}
