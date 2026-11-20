import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Real HTTP upgrade, held after the request arrives. No fake client/socket.
class _UpgradeHost {
  _UpgradeHost(this.server) {
    server.listen((request) async {
      received.complete(request);
      final status = await release.future;
      if (status != null) {
        request.response.statusCode = status;
        await request.response.close();
        responded.complete();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      peer = socket;
      socket.listen((message) => socket.add(message), onDone: () => peerClosed.complete());
      upgraded.complete(socket);
      responded.complete();
    });
  }

  final HttpServer server;
  final received = Completer<HttpRequest>();
  final release = Completer<int?>();
  final upgraded = Completer<WebSocket>();
  final responded = Completer<void>();
  final peerClosed = Completer<void>();
  WebSocket? peer;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');

  static Future<_UpgradeHost> start() async => _UpgradeHost(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() async {
    if (!release.isCompleted) release.complete(HttpStatus.serviceUnavailable);
    final socket = peer;
    if (socket != null) unawaited(socket.close());
    await server.close(force: true);
  }
}

void main() {
  late _UpgradeHost host;
  late DshConnection connection;

  setUp(() async {
    host = await _UpgradeHost.start();
    connection = DshConnection(host.uri);
  });
  tearDown(() async {
    connection.close(force: true);
    await host.close();
  });

  test('a timed-out upgrade closes its late socket without an owner close', () async {
    final rejected = expectLater(
      connection.connectWebSocket('/api/remote.mux', timeout: const Duration(milliseconds: 200)),
      throwsA(isA<DshTransportException>().having((e) => e.cause, 'cause', isA<TimeoutException>())),
    );
    await host.received.future;
    await rejected;
    host.release.complete(null);
    await host.upgraded.future;
    await host.peerClosed.future.timeout(const Duration(seconds: 2));
    expect(host.peer!.readyState, WebSocket.closed);
  });

  test('closing the connection before upgrade retires the late socket', () async {
    final rejected = expectLater(connection.connectWebSocket('/api/remote.mux'), throwsA(isA<DshClosedException>()));
    await host.received.future;
    // Graceful HttpClient close lets this already pending upgrade finish.
    connection.close();
    host.release.complete(null);
    await rejected;
    await host.peerClosed.future.timeout(const Duration(seconds: 2));
  });

  test('a timely upgrade transfers ownership and keeps cookie and Host headers', () async {
    connection.cookie = DshCookie(name: 'test', value: 'fixed-fake-cookie', authority: host.uri.authority);
    final pending = connection.connectWebSocket('/api/remote.mux');
    final request = await host.received.future;
    expect(request.headers.value(HttpHeaders.cookieHeader), 'test=fixed-fake-cookie');
    expect(request.headers.value(HttpHeaders.hostHeader), host.uri.authority);
    expect(request.headers.value('origin'), isNull);
    host.release.complete(null);
    final socket = await pending;
    final echo = Completer<Object?>();
    socket.listen((message) => echo.complete(message));
    socket.add('still-owned');
    expect(await echo.future, 'still-owned');
    expect(host.peerClosed.isCompleted, isFalse);
    await socket.close(WebSocketStatus.normalClosure);
    await host.peerClosed.future.timeout(const Duration(seconds: 2));
  });

  for (final status in [HttpStatus.unauthorized, HttpStatus.forbidden]) {
    test('an upgrade rejected with $status preserves the HTTP error', () async {
      final rejected = expectLater(
        connection.connectWebSocket('/api/remote.mux'),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', status)),
      );
      await host.received.future;
      host.release.complete(status);
      await rejected;
      expect(host.peer, isNull);
    });
  }

  test('late upgrade failure does not replace the already reported timeout', () async {
    final rejected = expectLater(
      connection.connectWebSocket('/api/remote.mux', timeout: const Duration(milliseconds: 200)),
      throwsA(isA<DshTransportException>().having((e) => e.cause, 'cause', isA<TimeoutException>())),
    );
    await host.received.future;
    await rejected;
    host.release.complete(HttpStatus.forbidden);
    await host.responded.future;
    expect(host.peer, isNull);
  });
}
