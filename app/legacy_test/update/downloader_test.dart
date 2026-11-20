import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/downloader.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _apk = utf8.encode('PK fake apk body, long enough to come in a few chunks.');
final _sha = sha256.convert(_apk).toString();

DownloadUrl _url(String host) => DownloadUrl(Uri.parse('https://$host/a.apk'), mirrorId: host, label: host);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dsh_update_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  ApkDownloader downloader(FakeHttp http, {int retries = 2}) =>
      ApkDownloader(http: http, directory: dir, retriesPerUrl: retries, progressStep: 8);

  Future<DownloadOutcome> run(
    ApkDownloader d,
    List<DownloadUrl> urls, {
    CancelToken? cancel,
    String? sha,
    List<DownloadProgress>? progress,
  }) => d.download(
    fileName: 'a.apk',
    sha256: sha ?? _sha,
    urls: urls,
    expectedSize: _apk.length,
    cancel: cancel,
    onProgress: progress?.add,
  );

  test('downloads, reports progress, verifies with the real SHA-256', () async {
    final http = FakeHttp({'https://one/a.apk': fileRoute(_apk)});
    final progress = <DownloadProgress>[];
    final outcome = await run(downloader(http), [_url('one')], progress: progress);
    expect(outcome, isA<DownloadDone>());
    final done = outcome as DownloadDone;
    expect(done.file.readAsBytesSync(), _apk);
    expect(done.from!.mirrorId, 'one');
    expect(File('${dir.path}/a.apk.part').existsSync(), isFalse);
    expect(progress.first.received, 0);
    expect(progress.last.received, _apk.length);
    expect(progress.last.total, _apk.length);
    expect(progress.map((p) => p.source).toSet(), {'one'});
    expect(http.requests.single.$2['accept-encoding'], 'identity');
  });

  test('a dropped connection resumes with a Range request on the same URL', () async {
    final starts = <int?>[];
    var calls = 0;
    final full = fileRoute(_apk, onRequest: starts.add);
    final dropping = fileRoute(_apk, dropAfter: 20, onRequest: starts.add);
    final http = FakeHttp({
      'https://one/a.apk': (url, headers) => calls++ == 0 ? dropping(url, headers) : full(url, headers),
    });
    final outcome = await run(downloader(http), [_url('one')]);
    expect(outcome, isA<DownloadDone>());
    expect((outcome as DownloadDone).file.readAsBytesSync(), _apk);
    expect(starts, [null, 20]);
  });

  test('a server that ignores Range restarts the file instead of appending', () async {
    File('${dir.path}/a.apk.part').writeAsBytesSync(_apk.sublist(0, 10));
    final http = FakeHttp({'https://one/a.apk': fileRoute(_apk, ranges: false)});
    final outcome = await run(downloader(http), [_url('one')]);
    expect((outcome as DownloadDone).file.readAsBytesSync(), _apk);
    expect(http.requests.single.$2['range'], 'bytes=10-');
  });

  test('unreachable host → next mirror without retrying it', () async {
    final http = FakeHttp({'https://two/a.apk': fileRoute(_apk)});
    final outcome = await run(downloader(http), [_url('one'), _url('two')]);
    expect((outcome as DownloadDone).from!.mirrorId, 'two');
    expect(http.urls, ['https://one/a.apk', 'https://two/a.apk']);
  });

  test('checksum mismatch: file deleted, next mirror from scratch; all bad → checksum failure', () async {
    final tampered = List<int>.of(_apk)..[3] ^= 0xff;
    final http = FakeHttp({'https://evil/a.apk': fileRoute(tampered), 'https://good/a.apk': fileRoute(_apk)});
    final outcome = await run(downloader(http), [_url('evil'), _url('good')]);
    expect((outcome as DownloadDone).from!.mirrorId, 'good');
    expect(outcome.file.readAsBytesSync(), _apk);
    expect(http.requests.last.$2.containsKey('range'), isFalse);

    outcome.file.deleteSync();
    final onlyBad = FakeHttp({'https://evil/a.apk': fileRoute(tampered)});
    final failed = await run(downloader(onlyBad), [_url('evil')]);
    expect((failed as DownloadFailed).failure, DownloadFailure.checksum);
    expect(dir.listSync(), isEmpty, reason: 'nothing unverified is left behind');
  });

  test('404 everywhere → unavailable; drops everywhere → network', () async {
    final missing = FakeHttp({
      'https://one/a.apk': (_, _) => textResponse('Not Found', status: 404),
      'https://two/a.apk': (_, _) => textResponse('Bad gateway', status: 502),
    });
    expect(
      ((await run(downloader(missing), [_url('one'), _url('two')])) as DownloadFailed).failure,
      DownloadFailure.unavailable,
    );

    final flaky = FakeHttp({'https://one/a.apk': fileRoute(_apk, dropAfter: 8, ranges: false)});
    final failed = await run(downloader(flaky, retries: 1), [_url('one')]);
    expect((failed as DownloadFailed).failure, DownloadFailure.network);
    expect(flaky.requests, hasLength(2));
  });

  test('cancel keeps the partial file; the next download resumes it', () async {
    final cancel = CancelToken();
    final gate = Completer<void>();
    final http = FakeHttp({
      'https://one/a.apk': (url, headers) {
        Stream<List<int>> body() async* {
          yield _apk.sublist(0, 16);
          await gate.future; // stalls until cancelled
        }

        return UpdateHttpResponse(status: 200, contentLength: _apk.length, body: body());
      },
    });
    final progress = <DownloadProgress>[];
    final pending = run(downloader(http), [_url('one')], cancel: cancel, progress: progress);
    while (progress.where((p) => p.received == 16).isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    cancel.cancel();
    expect(await pending, isA<DownloadCancelled>());
    expect(File('${dir.path}/a.apk.part').lengthSync(), 16);

    final resumed = FakeHttp({'https://one/a.apk': fileRoute(_apk)});
    final outcome = await run(downloader(resumed), [_url('one')]);
    expect((outcome as DownloadDone).file.readAsBytesSync(), _apk);
    expect(resumed.requests.single.$2['range'], 'bytes=16-');
  });

  test('an asynchronous write failure stops the response and reports storage', () async {
    // A deterministic ENOSPC without filling the test machine's disk.
    final part = Link('${dir.path}/a.apk.part');
    await part.create('/dev/full');
    var bodyCancelled = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(onListen: () => body.add(_apk), onCancel: () => bodyCancelled = true);
    final http = FakeHttp({
      'https://one/a.apk': (_, _) => UpdateHttpResponse(status: 200, contentLength: _apk.length, body: body.stream),
    });
    try {
      final outcome = await run(downloader(http), [_url('one')]).timeout(const Duration(seconds: 2));
      expect((outcome as DownloadFailed).failure, DownloadFailure.storage);
      expect(bodyCancelled, isTrue);
      expect(File('${dir.path}/a.apk').existsSync(), isFalse);
    } finally {
      await body.close();
      if (await part.exists()) await part.delete();
    }
  }, skip: !Platform.isLinux || !File('/dev/full').existsSync());

  test('an already downloaded, intact file is reused without the network', () async {
    File('${dir.path}/a.apk').writeAsBytesSync(_apk);
    final http = FakeHttp();
    final outcome = await run(downloader(http), [_url('one')]);
    expect(outcome, isA<DownloadDone>());
    expect((outcome as DownloadDone).from, isNull);
    expect(http.requests, isEmpty);
  });

  test('clean keeps only the current download', () async {
    File('${dir.path}/old.apk').writeAsStringSync('x');
    File('${dir.path}/a.apk.part').writeAsStringSync('y');
    await downloader(FakeHttp()).clean(keep: ['a.apk']);
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['a.apk.part']);
  });

  test('SHA256SUMS fallback reads the asset line through the first source that has it', () async {
    final http = FakeHttp({'https://two/SHA256SUMS': (_, _) => textResponse('$_sha  a.apk\n${'0' * 64}  b.apk\n')});
    final urls = [
      DownloadUrl(Uri.parse('https://one/SHA256SUMS'), mirrorId: 'one', label: 'one'),
      DownloadUrl(Uri.parse('https://two/SHA256SUMS'), mirrorId: 'two', label: 'two'),
    ];
    expect(await fetchSha256FromSums(http, urls, 'a.apk'), _sha);
    expect(await fetchSha256FromSums(http, urls, 'c.apk'), isNull);
  });
}
