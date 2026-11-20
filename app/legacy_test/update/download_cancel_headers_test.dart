import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/downloader.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

final _bytes = List<int>.generate(64, (i) => (i * 17) & 255);
final _prefix = _bytes.sublist(0, 16);
final _digest = sha256.convert(_bytes).toString();

// Return real clients unchanged; retain them only for deterministic teardown.
class _Clients extends HttpOverrides {
  final clients = <HttpClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    return client;
  }

  void close() {
    for (final client in clients) {
      client.close(force: true);
    }
  }
}

class _ObservedBody extends Stream<List<int>> {
  _ObservedBody(this.inner);
  final Stream<List<int>> inner;
  final activity = Completer<void>();
  bool cancelRequested = false;
  int bytes = 0;

  void notice() {
    if (!activity.isCompleted) activity.complete();
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = inner.listen(
      (chunk) {
        bytes += chunk.length;
        notice();
        onData?.call(chunk);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _ObservedSubscription(subscription, () {
      cancelRequested = true;
      notice();
    });
  }
}

class _ObservedSubscription implements StreamSubscription<List<int>> {
  _ObservedSubscription(this.inner, this.onCancel);
  final StreamSubscription<List<int>> inner;
  final void Function() onCancel;

  @override
  Future<void> cancel() {
    onCancel();
    return inner.cancel();
  }

  @override
  Future<E> asFuture<E>([E? value]) => inner.asFuture<E>(value);
  @override
  bool get isPaused => inner.isPaused;
  @override
  void onData(void Function(List<int>)? handleData) => inner.onData(handleData);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(handleDone);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
}

class _ObservedHttp implements UpdateHttp {
  _ObservedHttp(this.inner);
  final IoUpdateHttp inner;
  final ready = Completer<_ObservedBody>();

  @override
  Future<UpdateHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await inner.get(url, headers: headers, timeout: timeout);
    final body = _ObservedBody(response.body);
    ready.complete(body);
    return UpdateHttpResponse(
      status: response.status,
      headers: response.headers,
      contentLength: response.contentLength,
      body: body,
    );
  }
}

Future<void> _withDownload(
  Future<void> Function(Directory, IoUpdateHttp, StreamIterator<HttpRequest>, Uri) action,
) async {
  final directory = await Directory.systemTemp.createTemp('dsh_cancel_headers_');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = StreamIterator<HttpRequest>(server);
  final clients = _Clients();
  try {
    await File('${directory.path}/a.apk.part').writeAsBytes(_prefix);
    await HttpOverrides.runWithHttpOverrides(
      () => action(directory, IoUpdateHttp(), requests, Uri.parse('http://127.0.0.1:${server.port}/a.apk')),
      clients,
    );
  } finally {
    clients.close();
    await requests.cancel();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

Future<DownloadOutcome> _download(Directory directory, UpdateHttp http, Uri uri, {CancelToken? cancel}) =>
    ApkDownloader(http: http, directory: directory).download(
      fileName: 'a.apk',
      sha256: _digest,
      urls: [DownloadUrl(uri, mirrorId: null, label: 'loopback')],
      expectedSize: _bytes.length,
      cancel: cancel,
    );

Future<void> _reply(HttpRequest request, int status, {int start = 0}) async {
  final body = status == 200 || status == 206 ? _bytes.sublist(start) : utf8.encode('error $status');
  request.response
    ..statusCode = status
    ..contentLength = body.length;
  if (status == 206) {
    request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${_bytes.length - 1}/${_bytes.length}');
  }
  request.response.add(body);
  await request.response.close();
}

void main() {
  test('cancelled headers request cancellation of an unfinished real HTTP body', () async {
    await _withDownload((directory, http, requests, uri) async {
      final observed = _ObservedHttp(http);
      final cancel = CancelToken();
      final pending = _download(directory, observed, uri, cancel: cancel);
      expect(await requests.moveNext(), isTrue);
      final response = requests.current.response;
      cancel.cancel();
      response
        ..bufferOutput = false
        ..statusCode = HttpStatus.ok
        ..contentLength = _bytes.length
        ..add(_bytes.sublist(0, 8));
      final flushing = response.flush().catchError((Object _) {});
      try {
        final body = await observed.ready.future;
        // Either real first data or an actual cancellation advances the test.
        // A drain therefore fails finitely, without waiting for its 5s timer.
        await body.activity.future;
        expect(
          body.cancelRequested,
          isTrue,
          reason: 'an already-cancelled download must cancel its body, not drain it (${body.bytes} bytes observed)',
        );
        expect(await pending, isA<DownloadCancelled>());
      } finally {
        // Complete the finite producer even when checking the old draining path.
        try {
          response.add(_bytes.sublist(8));
          await response.close();
        } on Object {
          // The cancellation may already have closed the peer.
        }
        await flushing;
        await pending.then<void>((_) {}, onError: (Object _) {});
      }
    });
  });

  for (final status in [200, 206, 416, 503]) {
    test('cancellation before HTTP $status headers preserves the existing partial file', () async {
      await _withDownload((directory, http, requests, uri) async {
        final cancel = CancelToken();
        final pending = _download(directory, http, uri, cancel: cancel);
        expect(await requests.moveNext(), isTrue);
        final request = requests.current;
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=16-');

        // The server has the request, but has sent no response headers yet.
        cancel.cancel();
        await _reply(request, status);
        final outcome = await pending;
        final part = File('${directory.path}/a.apk.part');
        expect(part.existsSync(), isTrue, reason: 'a cancelled response must not delete the saved progress');
        expect(part.readAsBytesSync(), _prefix, reason: 'a cancelled response must not overwrite saved progress');
        expect(outcome, isA<DownloadCancelled>());
        expect(File('${directory.path}/a.apk').existsSync(), isFalse);

        // A fresh attempt can still use the same client and resume these bytes.
        final resumed = _download(directory, http, uri);
        expect(await requests.moveNext(), isTrue);
        expect(requests.current.headers.value(HttpHeaders.rangeHeader), 'bytes=16-');
        await _reply(requests.current, 206, start: 16);
        final completed = await resumed;
        expect(completed, isA<DownloadDone>());
        expect((completed as DownloadDone).file.readAsBytesSync(), _bytes);
        expect(part.existsSync(), isFalse);
      });
    });
  }

  for (final status in [200, 206]) {
    test('an active HTTP $status response still downloads and verifies the complete file', () async {
      await _withDownload((directory, http, requests, uri) async {
        final pending = _download(directory, http, uri);
        expect(await requests.moveNext(), isTrue);
        expect(requests.current.headers.value(HttpHeaders.rangeHeader), 'bytes=16-');
        await _reply(requests.current, status, start: status == 206 ? 16 : 0);
        final outcome = await pending;
        expect(outcome, isA<DownloadDone>());
        expect((outcome as DownloadDone).file.readAsBytesSync(), _bytes);
        expect(File('${directory.path}/a.apk.part').existsSync(), isFalse);
      });
    });
  }

  test('an active HTTP 503 remains unavailable and keeps the partial file', () async {
    await _withDownload((directory, http, requests, uri) async {
      final pending = _download(directory, http, uri);
      expect(await requests.moveNext(), isTrue);
      await _reply(requests.current, 503);
      final outcome = await pending;
      expect(outcome, isA<DownloadFailed>());
      expect((outcome as DownloadFailed).failure, DownloadFailure.unavailable);
      expect(File('${directory.path}/a.apk.part').readAsBytesSync(), _prefix);
      expect(File('${directory.path}/a.apk').existsSync(), isFalse);
    });
  });

  for (final cancelled in [false, true]) {
    test('a connection lost before headers preserves cancellation=$cancelled', () async {
      await _withDownload((directory, http, requests, uri) async {
        final cancel = CancelToken();
        final pending = _download(directory, http, uri, cancel: cancel);
        expect(await requests.moveNext(), isTrue);
        expect(requests.current.headers.value(HttpHeaders.rangeHeader), 'bytes=16-');
        if (cancelled) cancel.cancel();
        final socket = await requests.current.response.detachSocket(writeHeaders: false);
        socket.destroy();
        final outcome = await pending;
        if (cancelled) {
          expect(outcome, isA<DownloadCancelled>());
        } else {
          expect(outcome, isA<DownloadFailed>());
          expect((outcome as DownloadFailed).failure, DownloadFailure.network);
        }
        expect(File('${directory.path}/a.apk.part').readAsBytesSync(), _prefix);
        expect(File('${directory.path}/a.apk').existsSync(), isFalse);
      });
    });
  }
}
