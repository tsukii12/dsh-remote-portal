import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _RelayOnly extends DshCarrier {
  final calls = <String>[];
  @override
  String get kind => 'relay-fixture';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    throw StateError('deletion must not use relay RPC');
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('unexpected link');
  @override
  Future<void> close() async {}
}

void main() {
  late HttpServer server;
  late DshClient client;
  late Future<void> Function(HttpRequest request) handler;
  final requests = <String>[];

  Future<void> reply(HttpRequest request, int status, Object body) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (request) => reply(request, 404, {});
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      await handler(request);
    });
    client = DshClient(
      DshConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        cookie: DshCookie(name: 'dsh-auth-fixture', value: 'test-cookie', authority: '127.0.0.1:${server.port}'),
      ),
    );
  });

  tearDown(() async {
    await client.close();
    await server.close(force: true);
  });

  test('capability is explicit and never inferred from a generic successful page', () async {
    handler = (request) => reply(request, 200, {'supported': true, 'version': 1});
    expect(await client.supportsSessionDeletion(), isTrue);
    for (final body in [
      {'supported': true},
      {'supported': true, 'version': 2},
      {'supported': false, 'version': 1},
      {'supported': 'true', 'version': 1},
      <String, Object?>{},
    ]) {
      handler = (request) => reply(request, 200, body);
      expect(await client.supportsSessionDeletion(), isFalse);
    }
    handler = (request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('{"supported":true,"version":1}');
      await request.response.close();
    };
    expect(await client.supportsSessionDeletion(), isFalse);
  });

  test('old Host is unsupported; capability never dispatches a mutation', () async {
    expect(await client.supportsSessionDeletion(), isFalse);
    expect(requests, ['GET $sessionDeletionCapabilityPath']);
  });

  test('authenticated single-item POST needs exact positive acknowledgement', () async {
    handler = (request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, sessionDeletionPath);
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.headers.value(HttpHeaders.cookieHeader), 'dsh-auth-fixture=test-cookie');
      expect(request.headers.value('origin'), isNull);
      expect(jsonDecode(await utf8.decoder.bind(request).join()), {'sessionId': 's1'});
      await reply(request, 200, {'deleted': true, 'sessionId': 's1'});
    };
    await client.deleteSessionPermanently('s1');
    expect(requests, ['POST $sessionDeletionPath']);
  });

  test('wrong id, false and malformed acknowledgements fail closed', () async {
    for (final body in [
      {'deleted': true, 'sessionId': 'other'},
      {'deleted': false, 'sessionId': 's1'},
      {'deleted': true},
      <String, Object?>{},
    ]) {
      handler = (request) => reply(request, 200, body);
      await expectLater(client.deleteSessionPermanently('s1'), throwsA(isA<DshProtocolException>()));
    }
  });

  test('stable refusal codes are preserved without exposing raw server text', () async {
    handler = (request) => reply(request, 409, {
      'error': {'code': 'writer-held', 'message': '/private/path secret'},
    });
    await expectLater(
      client.deleteSessionPermanently('s1'),
      throwsA(
        isA<DshRemoteException>()
            .having((e) => e.code, 'code', 'writer-held')
            .having((e) => e.message, 'sanitized message', isNot(contains('secret'))),
      ),
    );
    expect(requests, ['POST $sessionDeletionPath']);
  });

  test('unclaimed deletion endpoint is unavailable, never archive fallback', () async {
    await expectLater(
      client.deleteSessionPermanently('s1'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'unavailable')),
    );
    expect(requests, ['POST $sessionDeletionPath']);
  });

  test('destructive requests never follow redirects or retry', () async {
    handler = (request) async {
      request.response
        ..statusCode = HttpStatus.temporaryRedirect
        ..headers.set(HttpHeaders.locationHeader, '/redirect-target');
      await request.response.close();
    };
    await expectLater(client.deleteSessionPermanently('s1'), throwsA(isA<DshHttpException>()));
    expect(requests, ['POST $sessionDeletionPath']);
  });

  test('oversized reply is not accepted or retried', () async {
    handler = (request) => reply(request, 200, {'deleted': true, 'sessionId': 's1', 'padding': 'x' * 9000});
    await expectLater(client.deleteSessionPermanently('s1'), throwsA(isA<DshProtocolException>()));
    expect(requests, ['POST $sessionDeletionPath']);
  });

  test('relay-only carrier never probes a filesystem or substitutes archive', () async {
    final carrier = _RelayOnly();
    final relay = DshClient.withCarrier(carrier);
    addTearDown(relay.close);
    expect(await relay.supportsSessionDeletion(), isFalse);
    await expectLater(
      relay.deleteSessionPermanently('s1'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'unavailable')),
    );
    expect(carrier.calls, isEmpty);
    expect(requests, isEmpty);
  });

  test('invalid id sends no request', () async {
    for (final id in ['', 'a\nb', 'x' * 257]) {
      await expectLater(client.deleteSessionPermanently(id), throwsArgumentError);
    }
    expect(requests, isEmpty);
  });
}
