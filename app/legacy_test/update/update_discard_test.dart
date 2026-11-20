import 'dart:async';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<T> _withDiscardDeadline<T>(List<_Deadline> timers, Future<T> Function() action) => runZoned(
  action,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      if (duration != const Duration(seconds: 5)) return parent.createTimer(zone, duration, callback);
      final timer = _Deadline(() => zone.runGuarded(callback));
      timers.add(timer);
      return timer;
    },
  ),
);

/// A transparent observer around the actual response subscription.
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
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture<E>(futureValue);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _ObservedBody extends Stream<List<int>> {
  _ObservedBody(this.inner);
  final Stream<List<int>> inner;
  final firstChunk = Completer<void>();
  late _ObservedSubscription subscription;
  int bytes = 0;

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
}

void main() {
  test('discard deadline cancels the real unfinished HTTP response subscription', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      if (request.uri.path == '/slow-error') {
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..bufferOutput = false
          ..write('first chunk');
        unawaited(request.response.flush());
      } else {
        request.response.write('next request');
        unawaited(request.response.close());
      }
    });
    final client = HttpClient();
    try {
      final original = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/slow-error'))).close();
      final body = _ObservedBody(original);
      final response = UpdateHttpResponse(status: original.statusCode, body: body);
      final timers = <_Deadline>[];
      await _withDiscardDeadline(timers, () async {
        final discarding = response.discard();
        await body.firstChunk.future;
        expect(body.bytes, greaterThan(0));
        expect(body.subscription.cancelRequested, isFalse);
        timers.singleWhere((timer) => timer.isActive).fire();
        await discarding;
        expect(body.subscription.cancelRequested, isTrue, reason: 'a timed-out drain must stop owning the response');
      });
      final next = await (await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/next'))).close();
      expect(await UpdateHttpResponse(status: next.statusCode, body: next).text(), 'next request');
      expect(body.subscription.cancelFinished, isTrue);
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });

  test('a complete discard drains all bytes and permits real HTTP connection reuse', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ports = <int>[];
    server.listen((request) {
      ports.add(request.connectionInfo!.remotePort);
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('complete error body');
      unawaited(request.response.close());
    });
    final client = HttpClient();
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.port}/missing');
      final original = await (await client.getUrl(uri)).close();
      final body = _ObservedBody(original);
      final timers = <_Deadline>[];
      await _withDiscardDeadline(timers, () => UpdateHttpResponse(status: original.statusCode, body: body).discard());
      expect(body.bytes, 'complete error body'.length);
      expect(body.subscription.cancelRequested, isFalse);
      expect(timers.where((timer) => timer.isActive), isEmpty);
      final next = await (await client.getUrl(uri)).close();
      await next.drain<void>();
      expect(ports, hasLength(2));
      expect(ports.last, ports.first, reason: 'a fully consumed response leaves the actual connection reusable');
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });

  test('discard does not extend its deadline while asynchronous cancellation is still completing', () async {
    final cancellation = Completer<void>();
    var cancelRequested = false;
    final body = StreamController<List<int>>(
      onCancel: () {
        cancelRequested = true;
        return cancellation.future;
      },
    );
    final timers = <_Deadline>[];
    try {
      await _withDiscardDeadline(timers, () async {
        final discarding = UpdateHttpResponse(status: HttpStatus.badGateway, body: body.stream).discard();
        timers.singleWhere((timer) => timer.isActive).fire();
        await discarding;
        expect(cancelRequested, isTrue);
        expect(cancellation.isCompleted, isFalse, reason: 'a producer cleanup future is not another wait budget');
        // A finite producer cleanup can itself fail; discard must have owned it.
        final cleanup = cancellation.future.then<void>((_) {}, onError: (Object _) {});
        cancellation.completeError(StateError('controlled cancellation cleanup failure'));
        await cleanup;
      });
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
      await body.close();
    }
  });
}
