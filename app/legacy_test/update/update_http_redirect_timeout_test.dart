// Real loopback sockets; only the public get() header deadline is manual.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

const _budget = Duration(milliseconds: 1731);
const _watchdog = Duration(seconds: 5);
const _closeWait = Duration(seconds: 2);
const _lateBody = 'download body';

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

class _ObservedHttp extends HttpOverrides {
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

class _Loopback {
  _Loopback(this.server) {
    server.listen((socket) {
      sockets.add(socket);
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      final closed = Completer<void>();
      var buffered = '';
      socket.listen(
        (bytes) {
          buffered += String.fromCharCodes(bytes);
          while (buffered.contains('\r\n\r\n')) {
            final end = buffered.indexOf('\r\n\r\n');
            final firstLine = buffered.substring(0, end).split('\r\n').first;
            buffered = buffered.substring(end + 4);
            final path = Uri.parse(firstLine.split(' ')[1]).path;
            if (path == '/start') {
              socket.write('HTTP/1.1 302 Found\r\nLocation: $redirectTo\r\nContent-Length: 0\r\n\r\n');
            } else if (path == '/stall') {
              // Keep the connection open but send no response headers.
              stalled.complete((closed: closed.future));
            } else if (path == '/body') {
              socket.write('HTTP/1.1 200 OK\r\nContent-Length: ${_lateBody.length}\r\n\r\n');
              delayedBody.complete(socket);
            } else {
              socket.write('HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnext');
            }
          }
        },
        onError: (Object _) {}, // A peer reset may precede onDone.
        onDone: closed.complete,
      );
    });
  }

  final ServerSocket server;
  final sockets = <Socket>[];
  final stalled = Completer<({Future<void> closed})>();
  final delayedBody = Completer<Socket>();
  Uri? redirectTo;

  static Future<_Loopback> open() async => _Loopback(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

Future<bool> _closedWithin(Future<void> closed) => closed.then((_) => true).timeout(_closeWait, onTimeout: () => false);

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
  for (final route in ['direct', 'same-origin', 'cross-origin']) {
    test('$route: header timeout closes the target socket before the next request', () async {
      final target = await _Loopback.open();
      final origin = route == 'cross-origin' ? await _Loopback.open() : target;
      origin.redirectTo = target.url('/stall');
      final overrides = _ObservedHttp();
      final deadlines = <_Deadline>[];
      try {
        await HttpOverrides.runWithHttpOverrides(
          () => _withDeadlines(deadlines, () async {
            final http = IoUpdateHttp();
            final url = route == 'direct' ? target.url('/stall') : origin.url('/start');
            final pending = http.get(url, timeout: _budget);
            final result = expectLater(pending, throwsA(isA<TimeoutException>()));
            final stalled = await target.stalled.future.timeout(_watchdog);
            expect(deadlines.where((timer) => timer.isActive), hasLength(1));
            deadlines.singleWhere((timer) => timer.isActive).fire();
            await result;
            final closedByTimeout = await _closedWithin(stalled.closed);

            // Exercise recovery and cleanup even when checking the old implementation.
            final next = await http.get(target.url('/ok'), timeout: _budget).timeout(_watchdog);
            final nextText = await next.text(timeout: _watchdog);
            overrides.close();
            final closedByExplicitClose = await _closedWithin(stalled.closed);

            expect(next.status, HttpStatus.ok);
            expect(nextText, 'next');
            expect(closedByExplicitClose, isTrue, reason: 'client.close(force: true) must retire the target');
            expect(
              closedByTimeout,
              isTrue,
              reason: 'the target request must not survive the reported header timeout ($route)',
            );
          }),
          overrides,
        );
      } finally {
        overrides.close();
        await origin.close();
        if (!identical(origin, target)) await target.close();
      }
    });
  }

  test('final headers complete get before the delayed body is sent and the body remains readable', () async {
    final target = await _Loopback.open();
    final overrides = _ObservedHttp();
    final deadlines = <_Deadline>[];
    try {
      await HttpOverrides.runWithHttpOverrides(
        () => _withDeadlines(deadlines, () async {
          final response = await IoUpdateHttp().get(target.url('/body'), timeout: _budget).timeout(_watchdog);
          final sender = await target.delayedBody.future.timeout(_watchdog);
          expect(response.status, HttpStatus.ok);
          expect(response.contentLength, _lateBody.length);
          expect(deadlines.where((timer) => timer.isActive), isEmpty);

          // get() already returned; no body byte was available until now.
          sender.write(_lateBody);
          expect(await response.text(timeout: _watchdog), _lateBody);
        }),
        overrides,
      );
    } finally {
      overrides.close();
      await target.close();
    }
  });

  test('a redirected header timeout does not close another get body on the same IoUpdateHttp', () async {
    final target = await _Loopback.open();
    final origin = await _Loopback.open();
    origin.redirectTo = target.url('/stall');
    final overrides = _ObservedHttp();
    final deadlines = <_Deadline>[];
    try {
      await HttpOverrides.runWithHttpOverrides(
        () => _withDeadlines(deadlines, () async {
          final http = IoUpdateHttp();
          final response = await http.get(target.url('/body'), timeout: _budget).timeout(_watchdog);
          final sender = await target.delayedBody.future.timeout(_watchdog);
          expect(response.status, HttpStatus.ok);
          expect(response.contentLength, _lateBody.length);

          final pending = http.get(origin.url('/start'), timeout: _budget);
          final result = expectLater(pending, throwsA(isA<TimeoutException>()));
          final stalled = await target.stalled.future.timeout(_watchdog);
          expect(deadlines.where((timer) => timer.isActive), hasLength(1));
          deadlines.singleWhere((timer) => timer.isActive).fire();
          await result;
          final closedByTimeout = await _closedWithin(stalled.closed);

          // The first response still owns a live connection after the other
          // GET has timed out. Closing a shared client would truncate it.
          sender.write(_lateBody);
          expect(await response.text(timeout: _watchdog), _lateBody);
          expect(closedByTimeout, isTrue, reason: 'the redirected request must also be retired');
        }),
        overrides,
      );
    } finally {
      overrides.close();
      await origin.close();
      await target.close();
    }
  });
}
