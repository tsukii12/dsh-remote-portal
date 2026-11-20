import 'dart:async';
import 'dart:io';
import 'dart:mirrors';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

// Transparent VM-only observation: every network operation is delegated to
// native dart:io. No replacement bytes, tee, buffering or second subscription.
dynamic delegate(Object target, Invocation invocation) {
  final mirror = reflect(target);
  if (invocation.isGetter) return mirror.getField(invocation.memberName).reflectee;
  if (invocation.isSetter) {
    final name = MirrorSystem.getName(invocation.memberName);
    return mirror.setField(Symbol(name.substring(0, name.length - 1)), invocation.positionalArguments.single).reflectee;
  }
  return mirror.invoke(invocation.memberName, invocation.positionalArguments, invocation.namedArguments).reflectee;
}

class ObservedClient implements HttpClient {
  ObservedClient(this.native, this.bodyRead);
  final HttpClient native;
  final Completer<int> bodyRead;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      ObservedRequest(await native.openUrl(method, url), bodyRead);
  @override
  dynamic noSuchMethod(Invocation invocation) => delegate(native, invocation);
}

class ObservedRequest implements HttpClientRequest {
  ObservedRequest(this.native, this.bodyRead);
  final HttpClientRequest native;
  final Completer<int> bodyRead;
  @override
  Future<HttpClientResponse> close() async => ObservedResponse(await native.close(), bodyRead);
  @override
  dynamic noSuchMethod(Invocation invocation) => delegate(native, invocation);
}

class ObservedResponse extends Stream<List<int>> implements HttpClientResponse {
  ObservedResponse(this.native, this.bodyRead);
  final HttpClientResponse native;
  final Completer<int> bodyRead;
  @override
  Future<E> drain<E>([E? futureValue]) => native
      .map((bytes) {
        if (!bodyRead.isCompleted) bodyRead.complete(bytes.length);
        return bytes; // Same native chunk; passive single-subscription observation.
      })
      .drain<E>(futureValue);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return native.listen(
      (bytes) {
        if (!bodyRead.isCompleted) bodyRead.complete(bytes.length);
        onData?.call(bytes);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => delegate(native, invocation);
}

class _Host {
  _Host(this.server, this.status) {
    server.listen((request) {
      unawaited(
        _serve(request).catchError((Object error) {
          // Native peer cancellation may reject the server's close. It is not
          // a fabricated client cleanup rejection or the status under test.
          errors.add(error);
        }),
      );
    });
  }

  final HttpServer server;
  final int status;
  final release = Completer<void>();
  final errors = <Object>[];
  final paths = <String>[];
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> _serve(HttpRequest request) async {
    paths.add(request.uri.path);
    if (request.uri.path == '/barrier') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.uri.path != DsBotHttpTransport.feedRoute) {
      throw StateError('Unexpected route: ${request.uri.path}');
    }
    request.response.bufferOutput = false;
    request.response.statusCode = status;
    if (status == HttpStatus.ok) {
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('event: hello\ndata: {"api":1,"boot":"local"}\n\n');
    } else {
      request.response.write('ordinary local service error body');
    }
    await request.response.flush();
    await release.future;
    await request.response.close();
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

void main() {
  for (final status in [HttpStatus.notFound, HttpStatus.serviceUnavailable]) {
    test('HTTP $status precedes unused body EOF; shared client stays usable', () async {
      final host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), status);
      final native = HttpClient()..maxConnectionsPerHost = 1;
      final bodyRead = Completer<int>();
      final connection = DshConnection(host.base);
      final transport = DsBotHttpTransport(connection, httpClient: ObservedClient(native, bodyRead));
      final failure = Completer<Object>();
      final completed = Completer<void>();
      final events = <DsBotSseEvent>[];
      final sub = transport.openFeed().listen(
        events.add,
        onError: (Object error) {
          if (!failure.isCompleted) failure.complete(error);
        },
        onDone: completed.complete,
      );
      try {
        // Actual native body delivery vs public error. No clock advance,
        // fake bytes, second reader or private production callback.
        final first = await Future.any([
          failure.future.then((_) => 'http-error'),
          bodyRead.future.then((_) => 'error-body-read'),
        ]);
        expect(first, 'http-error', reason: 'known status must not wait for unused body EOF');
        final error = await failure.future;
        expect(error, isA<DshHttpException>());
        expect((error as DshHttpException).statusCode, status);
        expect(error.body, isEmpty);
        expect(events, isEmpty);
        expect(host.release.isCompleted, isFalse);
        expect(bodyRead.isCompleted, isFalse);
        await completed.future;
        await transport.close();
        final next = await native.getUrl(host.base.resolve('/barrier'));
        final response = await next.close();
        expect(response.statusCode, HttpStatus.noContent);
        await response.drain<void>();
        expect(host.paths, [DsBotHttpTransport.feedRoute, '/barrier']);
      } finally {
        if (!host.release.isCompleted) host.release.complete();
        await sub.cancel();
        await transport.close();
        connection.close(force: true);
        native.close(force: true);
        await host.close();
      }
    });
  }

  test('native 200 SSE and consumer cancellation preserve shared client', () async {
    final host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), HttpStatus.ok);
    final native = HttpClient()..maxConnectionsPerHost = 1;
    final connection = DshConnection(host.base);
    final transport = DsBotHttpTransport(connection, httpClient: native);
    final first = Completer<DsBotSseEvent>();
    final errors = <Object>[];
    final sub = transport.openFeed().listen(first.complete, onError: errors.add);
    try {
      final hello = await first.future;
      expect(hello.event, 'hello');
      expect(hello.data, {'api': 1, 'boot': 'local'});
      expect(host.release.isCompleted, isFalse);
      await sub.cancel();
      await transport.close();
      final next = await native.getUrl(host.base.resolve('/barrier'));
      final response = await next.close();
      expect(response.statusCode, HttpStatus.noContent);
      await response.drain<void>();
      expect(errors, isEmpty);
      expect(host.paths, [DsBotHttpTransport.feedRoute, '/barrier']);
    } finally {
      if (!host.release.isCompleted) host.release.complete();
      await sub.cancel();
      await transport.close();
      connection.close(force: true);
      native.close(force: true);
      await host.close();
    }
  });
}
