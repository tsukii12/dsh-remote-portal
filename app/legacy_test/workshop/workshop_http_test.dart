import 'dart:async';
import 'dart:io';

import 'package:dsh_app/workshop/workshop_http.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _OpeningClient implements HttpClient {
  final opening = Completer<HttpClientRequest>();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => opening.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  var aborted = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #abort) { aborted = true; return null; }
    if (invocation.memberName == #headers) throw StateError('synthetic header failure');
    return null;
  }
}

class _UploadHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _UploadResponse extends StreamView<List<int>> implements HttpClientResponse {
  _UploadResponse() : super(const Stream<List<int>>.empty());
  @override
  HttpHeaders get headers => _UploadHeaders();
  @override
  int get statusCode => 200;
  @override
  int get contentLength => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _UploadRequest implements HttpClientRequest {
  _UploadRequest({this.flushAction, this.responseGate});
  final Future<void> Function()? flushAction;
  final Completer<HttpClientResponse>? responseGate;
  final chunks = <List<int>>[];
  var aborted = false, closed = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #headers) {
      return _UploadHeaders();
    }
    if (invocation.memberName == #add) {
      chunks.add(List<int>.of(invocation.positionalArguments.single as List<int>));
      return null;
    }
    if (invocation.memberName == #flush) {
      return flushAction?.call() ?? Future<void>.value();
    }
    if (invocation.memberName == #close) {
      closed = true;
      return responseGate?.future ?? Future<HttpClientResponse>.value(_UploadResponse());
    }
    if (invocation.memberName == #abort) {
      aborted = true;
      return null;
    }
    return null;
  }
}

void main() {
  test('upload reports bounded flushed chunks and waits for the response after full byte progress', () async {
    final responseGate = Completer<HttpClientResponse>(), bodyDone = Completer<void>();
    final request = _UploadRequest(responseGate: responseGate), client = _OpeningClient();
    client.opening.complete(request);
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    final bytes = List<int>.generate(2 * 64 * 1024 + 3, (i) => i % 251), progress = <List<int>>[];
    var completed = false;
    final pending = http.upload(workshopTestOrigin.resolve('/api/workshop/v1/submissions/id/archive'), body: bytes,
      onProgress: (sent, total) {
        progress.add([sent, total]);
        if (sent == total && !bodyDone.isCompleted) {
          bodyDone.complete();
        }
      });
    final settled = pending.then<void>((_) { completed = true; }, onError: (Object _, StackTrace _) { completed = true; });
    try {
      await Future.any<void>([bodyDone.future, pending.then<void>((_) {
        if (!bodyDone.isCompleted) {
          fail('upload ended before its byte progress signal');
        }
      })]).timeout(const Duration(seconds: 10));
      await Future<void>(() {});
      expect(completed, isFalse);
      expect(progress, [[0, bytes.length], [65536, bytes.length], [131072, bytes.length], [bytes.length, bytes.length]]);
      expect(request.chunks.map((chunk) => chunk.length), [65536, 65536, 3]);
      expect(request.chunks.expand((chunk) => chunk).toList(), bytes);
      responseGate.complete(_UploadResponse());
      final response = await pending;
      await response.discard();
      expect(response.status, 200);
      expect(request.aborted, isFalse);
    } finally {
      if (!responseGate.isCompleted) {
        responseGate.complete(_UploadResponse());
      }
      await settled;
    }
  });

  test('an upload flush failure aborts and does not report or queue the remaining bytes', () async {
    final request = _UploadRequest(flushAction: () => Future<void>.error(const HttpException('synthetic flush failure')));
    final client = _OpeningClient()..opening.complete(request);
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    final progress = <List<int>>[];
    await expectLater(http.upload(workshopTestOrigin.resolve('/upload'), body: List<int>.filled(65537, 1),
      onProgress: (sent, total) => progress.add([sent, total])), throwsA(isA<HttpException>()));
    expect(request.aborted, isTrue);
    expect(request.closed, isFalse);
    expect(request.chunks, hasLength(1));
    expect(progress, [[0, 65537]]);
  });

  test('a late upload flush after timeout cannot resume writes, progress or close', () async {
    final flushGate = Completer<void>();
    final request = _UploadRequest(flushAction: () => flushGate.future), client = _OpeningClient();
    client.opening.complete(request);
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    final progress = <List<int>>[];
    final pending = http.upload(workshopTestOrigin.resolve('/upload'), body: List<int>.filled(65537, 1),
      timeout: Duration.zero, onProgress: (sent, total) => progress.add([sent, total]));
    final settled = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      await expectLater(pending, throwsA(isA<TimeoutException>()));
      expect(request.aborted, isTrue);
      expect(request.chunks, hasLength(1));
    } finally {
      if (!flushGate.isCompleted) {
        flushGate.complete();
      }
      await settled;
      // One event turn lets the released flush and its guarded continuation
      // settle; this is not a timing or network throughput measurement.
      await Future<void>(() {});
    }
    expect(request.chunks, hasLength(1));
    expect(request.closed, isFalse);
    expect(progress, [[0, 65537]]);
  });

  test('an openUrl result arriving after timeout is aborted', () async {
    final client = _OpeningClient(), request = _Request();
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    await expectLater(http.get(workshopTestOrigin.resolve('/market/workshop.json'), timeout: Duration.zero), throwsA(isA<TimeoutException>()));
    client.opening.complete(request);
    await Future<void>.delayed(Duration.zero);
    expect(request.aborted, isTrue);
  });

  test('a synchronous header failure aborts the acquired request', () async {
    final client = _OpeningClient(), request = _Request();
    client.opening.complete(request);
    final http = IoWorkshopHttp(workshopTestOrigin, client: client);
    addTearDown(http.close);
    await expectLater(http.get(workshopTestOrigin.resolve('/market/workshop.json')), throwsA(isA<StateError>()));
    expect(request.aborted, isTrue);
  });
}
