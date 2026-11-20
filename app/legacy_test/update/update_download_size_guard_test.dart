// Owner-adopted draft for app/test/update; not executed in the author environment.
// The response bodies are finite (6–9 bytes). File writes/close/rename/SHA are real.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/downloader.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _bytes = utf8.encode('PKdemo');
const _name = 'bounded.apk';
DownloadUrl _url(String host) => DownloadUrl(Uri.parse('https://$host/$_name'), mirrorId: host, label: host);

// Observe the actual closed part before production can delete or rename it.
// No write, close, delete, or cancellation result is replaced.
class _ObservedSink implements IOSink {
  _ObservedSink(this.inner, this.file, this.closedLengths);

  final IOSink inner;
  final File file;
  final List<int> closedLengths;

  @override
  void add(List<int> bytes) => inner.add(bytes);

  @override
  Future<void> get done => inner.done;

  @override
  Future<void> close() async {
    await inner.close();
    closedLengths.add(await file.length());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _ObservedPart implements File {
  _ObservedPart(this.inner, this.closedLengths);

  final File inner;
  final List<int> closedLengths;

  @override
  String get path => inner.path;

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<int> length() => inner.length();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => inner.delete(recursive: recursive);

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _ObservedSink(inner.openWrite(mode: mode, encoding: encoding), inner, closedLengths);

  @override
  Future<File> rename(String newPath) => inner.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

final class _Files extends IOOverrides {
  _Files(this.partPath, this.closedLengths);

  final String partPath;
  final List<int> closedLengths;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == partPath ? _ObservedPart(file, closedLengths) : file;
  }
}

Future<DownloadOutcome> _download(
  Directory dir,
  FakeHttp http,
  List<DownloadUrl> urls,
  List<int> closedLengths, {
  required List<int> expectedBytes,
  int? expectedSize,
}) => IOOverrides.runWithIOOverrides(
  () => ApkDownloader(
    http: http,
    directory: dir,
    retriesPerUrl: 0,
    progressStep: 1,
  ).download(fileName: _name, sha256: sha256.convert(expectedBytes).toString(), expectedSize: expectedSize, urls: urls),
  _Files('${dir.path}/$_name.part', closedLengths),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dsh_update_size_guard_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a 200 body larger than the known asset is stopped before an oversized part is written', () async {
    final lengths = <int>[];
    final overlong = [..._bytes.sublist(4), 88, 89, 90];
    final http = FakeHttp({
      'https://first/$_name': (_, _) => UpdateHttpResponse(
        status: 200,
        contentLength: 4 + overlong.length,
        body: Stream<List<int>>.fromIterable([_bytes.sublist(0, 4), overlong]),
      ),
      'https://next/$_name': fileRoute(_bytes),
    });
    final result = await _download(
      dir,
      http,
      [_url('first'), _url('next')],
      lengths,
      expectedBytes: _bytes,
      expectedSize: _bytes.length,
    );
    expect(result, isA<DownloadDone>());
    final done = result as DownloadDone;
    expect(done.from!.mirrorId, 'next');
    expect(done.file.readAsBytesSync(), _bytes);
    expect(lengths, [4, _bytes.length], reason: 'the rejected chunk must never enter the real file sink');
    expect(http.requests.last.$2['range'], isNull, reason: 'an oversized attempt discards its part before fallback');
    expect(File('${dir.path}/$_name.part').existsSync(), isFalse);
  });

  test('a 206 response with trailing data rejects the attempt even after reaching the exact size', () async {
    File('${dir.path}/$_name.part').writeAsBytesSync(_bytes.sublist(0, 4));
    final lengths = <int>[];
    final http = FakeHttp({
      'https://first/$_name': (_, _) => UpdateHttpResponse(
        status: 206,
        headers: const {'content-range': 'bytes 4-6/7'},
        contentLength: 3,
        body: Stream<List<int>>.fromIterable([
          _bytes.sublist(4),
          [88],
        ]),
      ),
      'https://next/$_name': fileRoute(_bytes),
    });
    final result = await _download(
      dir,
      http,
      [_url('first'), _url('next')],
      lengths,
      expectedBytes: _bytes,
      expectedSize: _bytes.length,
    );
    expect(result, isA<DownloadDone>());
    final done = result as DownloadDone;
    expect(done.from!.mirrorId, 'next');
    expect(done.file.readAsBytesSync(), _bytes);
    expect(http.requests.first.$2['range'], 'bytes=4-');
    expect(http.requests.last.$2['range'], isNull);
    expect(lengths, [
      _bytes.length,
      _bytes.length,
    ], reason: 'the extra byte is rejected, not written or accepted as EOF');
  });

  test('an exact 206 remainder still resumes and verifies without another request', () async {
    File('${dir.path}/$_name.part').writeAsBytesSync(_bytes.sublist(0, 4));
    final lengths = <int>[];
    final http = FakeHttp({'https://first/$_name': fileRoute(_bytes)});
    final result = await _download(
      dir,
      http,
      [_url('first')],
      lengths,
      expectedBytes: _bytes,
      expectedSize: _bytes.length,
    );
    expect(result, isA<DownloadDone>());
    expect((result as DownloadDone).file.readAsBytesSync(), _bytes);
    expect(lengths, [_bytes.length]);
    expect(http.requests, hasLength(1));
    expect(http.requests.single.$2['range'], 'bytes=4-');
  });

  test('a body with no known size keeps the existing finite download and SHA contract', () async {
    final bytes = [..._bytes, 88, 89, 90];
    final lengths = <int>[];
    final http = FakeHttp({
      'https://first/$_name': (_, _) => UpdateHttpResponse(
        status: 200,
        body: Stream<List<int>>.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
      ),
    });
    final result = await _download(dir, http, [_url('first')], lengths, expectedBytes: bytes);
    expect(result, isA<DownloadDone>());
    expect((result as DownloadDone).file.readAsBytesSync(), bytes);
    expect(lengths, [bytes.length]);
    expect(http.requests, hasLength(1));
  });
}
