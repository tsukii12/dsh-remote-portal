import 'dart:async';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

const _budget = Duration(milliseconds: 1731);

/// Only the public get() budget is manual; socket I/O uses the real event loop.
class _Deadline implements Timer {
  _Deadline(this.callback);

  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) throw StateError('deadline is no longer active');
    _active = false;
    _tick++;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

class _ObservedRequest {
  _ObservedRequest(this.request) {
    request.done.then<void>(
      (_) => completed = true,
      onError: (Object error) {
        completed = true;
        failure = error;
      },
    );
  }

  final HttpClientRequest request;
  bool completed = false;
  Object? failure;
}

/// Observes real requests without replacing their close/abort/body behavior.
class _ObservedClient implements HttpClient {
  _ObservedClient(this.inner);

  final HttpClient inner;
  final requests = <_ObservedRequest>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = await inner.getUrl(url);
    requests.add(_ObservedRequest(request));
    return request;
  }

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;

  @override
  set userAgent(String? value) => inner.userAgent = value;

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _ObservedHttp extends HttpOverrides {
  final clients = <_ObservedClient>[];

  List<_ObservedRequest> get requests => [for (final client in clients) ...client.requests];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _ObservedClient(super.createHttpClient(context));
    clients.add(client);
    return client;
  }

  void close() {
    for (final client in clients) {
      client.inner.close(force: true);
    }
  }
}

Future<T> _withDeadlines<T>(List<_Deadline> deadlines, Future<T> Function() action) => runZoned(
  action,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      if (duration != _budget) return parent.createTimer(zone, duration, callback);
      final deadline = _Deadline(() => zone.runGuarded(callback));
      deadlines.add(deadline);
      return deadline;
    },
  ),
);

void main() {
  test('a header deadline retires the real request before returning timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<HttpRequest>();
    server.listen((request) {
      if (request.uri.path == '/slow') {
        received.complete(request);
      } else {
        request.response.write('next mirror');
        unawaited(request.response.close());
      }
    });
    final overrides = _ObservedHttp();
    final deadlines = <_Deadline>[];
    try {
      await HttpOverrides.runWithHttpOverrides(
        () => _withDeadlines(deadlines, () async {
          final http = IoUpdateHttp();
          final pending = http.get(Uri.parse('http://127.0.0.1:${server.port}/slow'), timeout: _budget);
          await received.future;
          final observed = overrides.requests.single;
          expect(observed.completed, isFalse);
          // getUrl completed; only the wait for response headers remains.
          expect(deadlines.where((timer) => timer.isActive), hasLength(1));
          final result = expectLater(pending, throwsA(isA<TimeoutException>()));
          deadlines.singleWhere((timer) => timer.isActive).fire();
          await result;
          expect(observed.completed, isTrue, reason: 'the timed-out real request must no longer own the connection');
          expect(observed.failure, isA<Exception>());
          final next = await http.get(Uri.parse('http://127.0.0.1:${server.port}/next'), timeout: _budget);
          expect(next.status, HttpStatus.ok);
          expect(await next.text(), 'next mirror');
          expect(overrides.requests, hasLength(2));
        }),
        overrides,
      );
    } finally {
      overrides.close();
      await server.close(force: true);
    }
  });

  test('a timely non-200 response keeps its real body and cancels the header deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('missing release');
      unawaited(request.response.close());
    });
    final overrides = _ObservedHttp();
    final deadlines = <_Deadline>[];
    try {
      await HttpOverrides.runWithHttpOverrides(
        () => _withDeadlines(deadlines, () async {
          final response = await IoUpdateHttp().get(
            Uri.parse('http://127.0.0.1:${server.port}/missing'),
            timeout: _budget,
          );
          expect(response.status, HttpStatus.notFound);
          expect(await response.text(), 'missing release');
          expect(deadlines.where((timer) => timer.isActive), isEmpty);
          final observed = overrides.requests.single;
          expect(observed.completed, isTrue);
          expect(observed.failure, isNull);
        }),
        overrides,
      );
    } finally {
      overrides.close();
      await server.close(force: true);
    }
  });
}
