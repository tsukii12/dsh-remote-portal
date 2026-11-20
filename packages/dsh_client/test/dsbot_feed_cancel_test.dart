import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _Host {
  _Host(this.server) {
    server.listen((request) {
      unawaited(_serve(request).catchError((Object error) => errors.add(error)));
    });
  }

  final HttpServer server;
  final entered = Completer<void>();
  final release = Completer<void>();
  final paths = <String>[];
  final headers = <(String?, String?)>[];
  final errors = <Object>[];

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> _serve(HttpRequest request) async {
    paths.add(request.uri.path);
    if (request.uri.path == '/hold') {
      entered.complete();
      await release.future;
    } else if (request.uri.path == DsBotHttpTransport.feedRoute) {
      headers.add((request.headers.value(HttpHeaders.cookieHeader), request.headers.value(HttpHeaders.acceptHeader)));
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('event: hello\ndata: {"api":1,"boot":"fixture"}\n\n');
    }
    await request.response.close();
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

void main() {
  late _Host host;
  late HttpClient http;
  late DshConnection connection;
  late DsBotHttpTransport transport;

  setUp(() async {
    host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    // Real connection-pool admission holds openUrl pending without a sleep or
    // a replacement HTTP implementation. All requests use this one origin.
    http = HttpClient()..maxConnectionsPerHost = 1;
    connection = DshConnection(
      host.base,
      cookie: DshCookie(name: 'dsh-auth-test', value: 'fixture', authority: '127.0.0.1:${host.server.port}'),
    );
    transport = DsBotHttpTransport(connection, httpClient: http);
  });

  tearDown(() async {
    await transport.close();
    connection.close(force: true);
    http.close(force: true);
    await host.close();
  });

  Future<HttpClientResponse> hold() async {
    final request = await http.getUrl(host.base.resolve('/hold'));
    final response = request.close();
    await host.entered.future;
    return response;
  }

  Future<void> barrier() async {
    // A later acquisition cannot overtake an earlier queued acquisition in
    // dart:io's single-slot pool. The finite SSE response also lets the
    // unfixed implementation reach this observation boundary naturally.
    final request = await http.getUrl(host.base.resolve('/barrier'));
    await (await request.close()).drain<void>();
  }

  test('cancelled feed never sends a late GET after acquiring its connection', () async {
    final holding = hold();
    await host.entered.future;
    final events = <DsBotSseEvent>[];
    final errors = <Object>[];
    final sub = transport.openFeed().listen(events.add, onError: errors.add);
    try {
      await sub.cancel();
      host.release.complete();
      await (await holding).drain<void>();
      await barrier();

      expect(host.paths, ['/hold', '/barrier']);
      expect(events, isEmpty);
      expect(errors, isEmpty);
      expect(host.errors, isEmpty);
    } finally {
      await sub.cancel();
    }
  });

  test('cancelling an old pending feed leaves a new feed on the same client usable', () async {
    final holding = hold();
    await host.entered.future;
    final old = transport.openFeed().listen((_) {}, onError: (Object _) {});
    try {
      await old.cancel();
      final next = transport.openFeed().toList();
      host.release.complete();
      await (await holding).drain<void>();
      final events = await next;
      await barrier();

      expect(host.paths, ['/hold', DsBotHttpTransport.feedRoute, '/barrier']);
      expect(events, hasLength(1));
      expect(events.single.event, 'hello');
      expect(events.single.data, {'api': 1, 'boot': 'fixture'});
      expect(host.headers, [('dsh-auth-test=fixture', 'text/event-stream')]);
      expect(host.errors, isEmpty);
    } finally {
      await old.cancel();
    }
  });

  test('a timely feed still delivers the real SSE event and authentication headers', () async {
    final events = await transport.openFeed().toList();
    await barrier();

    expect(host.paths, [DsBotHttpTransport.feedRoute, '/barrier']);
    expect(events, hasLength(1));
    expect(events.single.event, 'hello');
    expect(events.single.data, {'api': 1, 'boot': 'fixture'});
    expect(host.headers, [('dsh-auth-test=fixture', 'text/event-stream')]);
    expect(host.errors, isEmpty);
  });
}
