import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'delta.dart';
import 'release.dart';
import 'update_config.dart';
import 'update_http.dart';

/// Lowercase hex SHA-256 of a file.
typedef Sha256Hasher = Future<String> Function(File file);

/// Hashes off the UI isolate (an APK is ~180 MB).
Future<String> sha256OfFile(File file) {
  final path = file.path;
  return Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
}

class DownloadProgress {
  const DownloadProgress({required this.received, required this.total, required this.source});

  final int received;
  final int? total;

  /// Mirror label ("GitHub", "ghfast.top").
  final String source;
}

enum DownloadFailure {
  /// Every URL failed to connect or kept dropping.
  network,

  /// Servers answered, but not with the file (404, 5xx…).
  unavailable,

  /// The file arrived but its SHA-256 didn't match, from every source.
  checksum,

  /// Couldn't write the file (disk full).
  storage,
}

sealed class DownloadOutcome {
  const DownloadOutcome();
}

final class DownloadDone extends DownloadOutcome {
  const DownloadDone(this.file, this.from);

  final File file;

  /// Where it came from; null when an earlier download was reused.
  final DownloadUrl? from;
}

final class DownloadCancelled extends DownloadOutcome {
  const DownloadCancelled();
}

final class DownloadFailed extends DownloadOutcome {
  const DownloadFailed(this.failure);

  final DownloadFailure failure;
}

/// Cancels a running [ApkDownloader.download]; the partial file is kept so
/// the next try resumes.
class CancelToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

enum _Step { complete, cancelled, interrupted, oversized, unreachable, rejected, storage }

/// Downloads one file into [directory], resuming `<name>.part` with HTTP
/// ranges, falling through the URLs in order, and only hands it over once
/// its SHA-256 matches.
class ApkDownloader {
  ApkDownloader({
    required this.http,
    required this.directory,
    this.hasher = sha256OfFile,
    this.idleTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 15),
    this.retriesPerUrl = 2,
    this.progressStep = 512 * 1024,
  });

  final UpdateHttp http;
  final Directory directory;
  final Sha256Hasher hasher;

  /// No byte for this long counts as a dropped connection.
  final Duration idleTimeout;
  final Duration connectTimeout;

  /// Extra resumes on the same URL after a drop mid-file.
  final int retriesPerUrl;

  /// Bytes between progress callbacks.
  final int progressStep;

  Future<DownloadOutcome> download({
    required String fileName,
    required String sha256,
    required List<DownloadUrl> urls,
    int? expectedSize,
    void Function(DownloadProgress progress)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    final File target;
    final File part;
    try {
      await directory.create(recursive: true);
      target = File('${directory.path}/$fileName');
      part = File('${target.path}.part');
      if (await target.exists()) {
        if (cancel?.isCancelled ?? false) return const DownloadCancelled();
        onVerifying?.call();
        if (await hasher(target) == sha256) return DownloadDone(target, null);
        await target.delete();
      }
    } on FileSystemException {
      return const DownloadFailed(DownloadFailure.storage);
    }

    var failure = DownloadFailure.network;
    for (final url in urls) {
      var attempt = 0;
      while (true) {
        if (cancel?.isCancelled ?? false) return const DownloadCancelled();
        final step = await _fetch(url, part, expectedSize, onProgress, cancel);
        if (step == _Step.cancelled) return const DownloadCancelled();
        if (step == _Step.storage) return const DownloadFailed(DownloadFailure.storage);
        if (step == _Step.complete) {
          // The UI can still cancel while the file is closing or being renamed.
          if (cancel?.isCancelled ?? false) return const DownloadCancelled();
          try {
            await part.rename(target.path);
            if (cancel?.isCancelled ?? false) return const DownloadCancelled();
            onVerifying?.call();
            if (await hasher(target) == sha256) return DownloadDone(target, url);
            // Corrupt or tampered: start over from the next source.
            await target.delete();
          } on FileSystemException {
            return const DownloadFailed(DownloadFailure.storage);
          }
          failure = DownloadFailure.checksum;
          break;
        }
        if (step == _Step.rejected) {
          if (failure != DownloadFailure.checksum) failure = DownloadFailure.unavailable;
          break;
        }
        if (step == _Step.unreachable || ++attempt > retriesPerUrl) break;
        // _Step.interrupted: resume on the same URL.
      }
    }
    return DownloadFailed(failure);
  }

  /// [fileName] built from [base] (the installed APK) and [patch], which is
  /// downloaded from [urls] like any file (resume, fallbacks, its SHA-256).
  /// The result lands where [download] would leave [fileName], only once it
  /// is [expectedSize] bytes hashing to [sha256]; the patch is deleted after.
  /// Failed when anything goes wrong: the caller downloads the whole file.
  Future<DownloadOutcome> downloadPatched({
    required ReleasePatch patch,
    required File base,
    required String fileName,
    required String sha256,
    required List<DownloadUrl> urls,
    int? expectedSize,
    void Function(DownloadProgress progress)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    final got = await download(
      fileName: patch.name,
      sha256: patch.sha256,
      urls: urls,
      expectedSize: patch.size,
      onProgress: onProgress,
      onVerifying: onVerifying,
      cancel: cancel,
    );
    if (got is! DownloadDone) return got;
    final target = File('${directory.path}/$fileName');
    // Built in the full download's `.part`: a build cut short leaves the start
    // of the APK, which that download resumes (and still checks).
    final part = File('${target.path}.part');
    try {
      await applyDeltaPatch(
        base: base,
        patch: got.file,
        out: part,
        baseSha256: patch.from,
        targetSha256: sha256,
        targetSize: expectedSize,
      );
      await part.rename(target.path);
      return DownloadDone(target, got.from);
    } on Object {
      // Another base, a broken patch, or no room to build it.
      return const DownloadFailed(DownloadFailure.checksum);
    } finally {
      await _deleteQuietly(got.file);
    }
  }

  Future<_Step> _fetch(
    DownloadUrl url,
    File part,
    int? expectedSize,
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancel,
  ) async {
    var offset = 0;
    try {
      offset = await part.exists() ? await part.length() : 0;
      if (expectedSize != null && offset > expectedSize) {
        await part.delete();
        offset = 0;
      }
    } on FileSystemException {
      return _Step.storage;
    }
    if (expectedSize != null && offset == expectedSize && offset > 0) return _Step.complete;

    // A failed cache check or prior source may have left the caller verifying.
    // Report the actual resume point before waiting for response headers.
    onProgress?.call(DownloadProgress(received: offset, total: expectedSize, source: url.label));
    if (cancel?.isCancelled ?? false) return _Step.cancelled;

    final UpdateHttpResponse response;
    try {
      response = await http.get(
        url.url,
        headers: {
          ...url.headers,
          // Ranges count raw bytes; no transparent gzip.
          'accept-encoding': 'identity',
          'range': ?(offset > 0 ? 'bytes=$offset-' : null),
        },
        timeout: connectTimeout,
      );
    } on Object {
      return (cancel?.isCancelled ?? false) ? _Step.cancelled : _Step.unreachable;
    }
    // Cancellation can arrive while get is waiting for response headers.
    if (cancel?.isCancelled ?? false) {
      final body = response.body.listen(null, onError: (Object _) {});
      unawaited(body.cancel().catchError((Object _) {}));
      return _Step.cancelled;
    }

    var append = false;
    switch (response.status) {
      case 206:
        final start = RegExp(r'bytes (\d+)-').firstMatch(response.headers['content-range'] ?? '')?.group(1);
        if (start != null && int.tryParse(start) != offset) {
          await response.discard();
          await _deleteQuietly(part);
          return _Step.interrupted;
        }
        append = true;
      case 200:
        offset = 0;
      case 416:
        await response.discard();
        // Nothing past the end: either already complete or the part is junk.
        if (expectedSize != null && offset == expectedSize) return _Step.complete;
        await _deleteQuietly(part);
        return _Step.interrupted;
      default:
        await response.discard();
        return _Step.rejected;
    }

    final total = expectedSize ?? (response.contentLength == null ? null : offset + response.contentLength!);
    var received = offset;
    var reported = received;
    onProgress?.call(DownloadProgress(received: received, total: total, source: url.label));

    final IOSink sink;
    try {
      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    } on FileSystemException {
      await response.discard();
      return _Step.storage;
    }
    final done = Completer<_Step>();
    // File writes fail asynchronously. Catch the sink's error while the
    // response is still streaming, before it escapes as an unhandled error.
    unawaited(
      sink.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (!done.isCompleted) done.complete(_Step.storage);
        },
      ),
    );
    late final StreamSubscription<List<int>> sub;
    sub = response.body
        .timeout(idleTimeout)
        .listen(
          (chunk) {
            if (done.isCompleted) return;
            if (total != null && chunk.length > total - received) {
              done.complete(_Step.oversized);
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            if (received - reported >= progressStep) {
              reported = received;
              onProgress?.call(DownloadProgress(received: received, total: total, source: url.label));
            }
          },
          onError: (Object error) {
            if (!done.isCompleted) done.complete(_Step.interrupted);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(_Step.complete);
          },
          cancelOnError: true,
        );
    unawaited(
      cancel?.whenCancelled.then((_) {
        if (done.isCompleted) return;
        done.complete(_Step.cancelled);
        unawaited(sub.cancel());
      }),
    );
    var step = await done.future;
    if (step == _Step.storage || step == _Step.oversized) {
      // Stop an unfinished response without waiting for its producer cleanup
      // before reporting this failed attempt, or leaving its error loose.
      unawaited(sub.cancel().catchError((Object _) {}));
    }
    try {
      // close waits for buffered writes too. flush can wait forever after an
      // earlier write error has already completed sink.done.
      await sink.close();
    } on FileSystemException {
      return _Step.storage;
    }
    if (step == _Step.oversized) {
      await _deleteQuietly(part);
      return _Step.interrupted;
    }
    if (step == _Step.complete) {
      onProgress?.call(DownloadProgress(received: received, total: total, source: url.label));
      if (total != null && received < total) step = _Step.interrupted;
    }
    return step;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Overwritten on the next 200 anyway.
    }
  }

  /// Deletes every file in [directory] except those in [keep] (and their `.part`).
  Future<void> clean({Iterable<String> keep = const []}) async {
    try {
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (keep.any((k) => name == k || name == '$k.part')) continue;
        await entity.delete(recursive: true);
      }
    } on FileSystemException {
      // Cache dir; the system may clear it anyway.
    }
  }
}

/// The asset's SHA-256 from the release's `SHA256SUMS`, tried through [urls]
/// (each a mirror of the same file). Null when no source has it.
Future<String?> fetchSha256FromSums(UpdateHttp http, List<DownloadUrl> urls, String assetName) async {
  for (final url in urls) {
    try {
      final response = await http.get(url.url, headers: url.headers, timeout: const Duration(seconds: 12));
      if (response.status != HttpStatus.ok) {
        await response.discard();
        continue;
      }
      final sums = parseSha256Sums(await response.text(maxBytes: 64 * 1024));
      if (sums[assetName] case final hex?) return hex;
    } on Object {
      continue;
    }
  }
  return null;
}
