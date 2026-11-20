import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _budget = Duration(milliseconds: 1731);

class _Deadline implements Timer {
  _Deadline(this.callback);
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) throw StateError('inactive deadline');
    _active = false;
    _tick++;
    callback();
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
}

Future<T> _withDeadline<T>(List<_Deadline> timers, Future<T> Function() action) => runZoned(
  action,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      if (duration != _budget) return parent.createTimer(zone, duration, callback);
      final timer = _Deadline(() => zone.runGuarded(callback));
      timers.add(timer);
      return timer;
    },
  ),
);

/// Observes cancellation without replacing HTTP, stream scheduling or bytes.
class _ObservedSubscription implements StreamSubscription<List<int>> {
  _ObservedSubscription(this.inner);
  final StreamSubscription<List<int>> inner;
  bool cancelRequested = false;
  bool cancelFinished = false;

  @override
  Future<void> cancel() {
    cancelRequested = true;
    return inner.cancel().then<void>((_) => cancelFinished = true);
  }

  @override
  void onData(void Function(List<int>)? handleData) => inner.onData(handleData);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture<E>(futureValue);
}

class _ObservedResponse extends Stream<List<int>> implements HttpClientResponse {
  _ObservedResponse(this.inner);
  final HttpClientResponse inner;
  final firstChunk = Completer<void>();
  late _ObservedSubscription subscription;
  int bytes = 0;

  @override
  HttpHeaders get headers => inner.headers;
  @override
  int get statusCode => inner.statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final actual = inner.listen(
      (chunk) {
        bytes += chunk.length;
        if (!firstChunk.isCompleted) firstChunk.complete();
        onData?.call(chunk);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return subscription = _ObservedSubscription(actual);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _ObservedRequest implements HttpClientRequest {
  _ObservedRequest(this.inner, this.onResponse);
  final HttpClientRequest inner;
  final void Function(_ObservedResponse) onResponse;

  @override
  HttpHeaders get headers => inner.headers;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => inner.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> close() async {
    final response = _ObservedResponse(await inner.close());
    onResponse(response);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _ObservedClient implements HttpClient {
  _ObservedClient(this.inner);
  final HttpClient inner;
  final firstResponse = Completer<_ObservedResponse>();
  final responses = <_ObservedResponse>[];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ObservedRequest(await inner.openUrl(method, url), (response) {
        responses.add(response);
        if (!firstResponse.isCompleted) firstResponse.complete(response);
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

void main() {
  test('body timeout cancels the actual response and leaves the client usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      if (request.uri.path == '/slow') {
        request.response
          ..bufferOutput = false
          ..write('first chunk');
        unawaited(request.response.flush());
      } else {
        request.response.write('next request');
        unawaited(request.response.close());
      }
    });
    final http = HttpClient()..maxConnectionsPerHost = 1;
    final observed = _ObservedClient(http);
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'), httpClient: observed);
    try {
      final timers = <_Deadline>[];
      await _withDeadline(timers, () async {
        final result = connection.get('/slow', timeout: _budget);
        final failure = expectLater(
          result,
          throwsA(isA<DshTransportException>().having((error) => error.cause, 'cause', isA<TimeoutException>())),
        );
        final response = await observed.firstResponse.future;
        await response.firstChunk.future;
        expect(response.bytes, greaterThan(0));
        expect(response.subscription.cancelRequested, isFalse);
        timers.singleWhere((timer) => timer.isActive).fire();
        await failure;
        expect(response.subscription.cancelRequested, isTrue, reason: 'timeout must retire the unfinished body read');
        expect((await connection.get('/next')).text, 'next request');
        expect(response.subscription.cancelFinished, isTrue);
      });
    } finally {
      connection.close();
      http.close(force: true);
      await server.close(force: true);
    }
  });

  test('complete HTTP body preserves response metadata and real connection reuse', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ports = <int>[];
    server.listen((request) {
      ports.add(request.connectionInfo!.remotePort);
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..headers.add(HttpHeaders.setCookieHeader, 'a=one; Path=/')
        ..headers.add(HttpHeaders.setCookieHeader, 'b=two; Path=/')
        ..write('complete body');
      unawaited(request.response.close());
    });
    final http = HttpClient()..maxConnectionsPerHost = 1;
    final observed = _ObservedClient(http);
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'), httpClient: observed);
    try {
      final timers = <_Deadline>[];
      final response = await _withDeadline(timers, () => connection.get('/complete', timeout: _budget));
      expect(response.statusCode, HttpStatus.notFound);
      expect(response.text, 'complete body');
      expect(response.contentType, 'text/plain');
      expect(response.contentTypeParameters['charset'], 'utf-8');
      expect(response.setCookies, ['a=one; Path=/', 'b=two; Path=/']);
      expect(timers.where((timer) => timer.isActive), isEmpty);
      expect((await connection.get('/next')).text, 'complete body');
      expect(ports, hasLength(2));
      expect(ports.last, ports.first);
    } finally {
      connection.close();
      http.close(force: true);
      await server.close(force: true);
    }
  });

  test('response byte limit still cancels the body and retains its typed failure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..bufferOutput = false
        ..write('larger than four');
      unawaited(request.response.flush());
    });
    final http = HttpClient();
    final observed = _ObservedClient(http);
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'), httpClient: observed);
    try {
      await expectLater(
        connection.postBytes('/bounded', [1, 2], maxResponseBytes: 4),
        throwsA(isA<DshProtocolException>()),
      );
      final response = await observed.firstResponse.future;
      expect(response.subscription.cancelRequested, isTrue);
      expect(response.subscription.cancelFinished, isTrue);
    } finally {
      connection.close();
      http.close(force: true);
      await server.close(force: true);
    }
  });
}
