import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_portal/dsh_portal.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late PortalSession session;
  late PortalFileSystem files;
  late Future<void> Function(HttpRequest) respond;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => respond(request));
    session = PortalSession(Uri.parse('http://127.0.0.1:${server.port}/__t/fixture/'));
    await session.receiveCookies(session.base, ['portal=fixture-only; Path=/__t/fixture/']);
    files = PortalFileSystem(session.connection);
  });
  tearDown(() async { await session.close(); await server.close(force: true); });

  Future<void> json(HttpRequest request, Object body, {int status = 200}) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  test('browse preserves relay prefix, authenticated headers and Unicode query', () async {
    respond = (request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/__t/fixture/yuremote/fs');
      expect(request.uri.queryParameters, {'path': '/host/项目 & notes'});
      expect(request.headers.value('user-agent'), PortalSession.userAgent);
      expect(request.headers.value('origin'), session.base.origin);
      expect(request.headers.value('cookie'), 'portal=fixture-only');
      await json(request, {'ok': true, 'listing': {
        'path': '/canonical/项目', 'parent': '/canonical',
        'roots': [{'name': 'Home', 'path': '/host'}],
        'entries': [{'name': '.hidden', 'path': '/canonical/项目/.hidden', 'hidden': true}],
        'truncated': true,
      }});
    };
    final listing = await files.browse('/host/项目 & notes');
    expect(listing.path, '/canonical/项目');
    expect(listing.parent!.path, '/canonical');
    expect(listing.home, '/host');
    expect(listing.name, '项目');
    expect(listing.entries.single.hidden, isTrue);
    expect(listing.truncated, isTrue);
  });

  test('initial home and empty filesystem root do not invent parents or entries', () async {
    respond = (request) async {
      expect(request.uri.hasQuery, isFalse);
      await json(request, {'ok': true, 'listing': {'path': '/', 'parent': '', 'roots': [], 'entries': []}});
    };
    final listing = await files.browse();
    expect(listing.entries, isEmpty);
    expect(listing.roots, isEmpty);
    expect(listing.parent, isNull);
    expect(listing.name, '/');
    expect(listing.truncated, isFalse);
  });

  test('Windows paths and server-supplied parent remain unchanged', () async {
    respond = (request) => json(request, {'ok': true, 'listing': {
      'path': r'C:\Users\me', 'parent': r'C:\Users', 'roots': [], 'entries': [],
    }});
    final listing = await files.browse();
    expect(listing.path, r'C:\Users\me');
    expect(listing.parent!.path, r'C:\Users');
    expect(listing.name, 'me');
  });

  test('mkdir posts JSON and trusts the returned canonical path', () async {
    respond = (request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/__t/fixture/yuremote/fs/mkdir');
      expect(request.headers.contentType!.mimeType, 'application/json');
      expect(request.headers.value('cookie'), 'portal=fixture-only');
      expect(jsonDecode(await utf8.decoder.bind(request).join()), {'parent': '/host/a b', 'name': '新 & folder'});
      await json(request, {'ok': true, 'created': {'path': '/canonical/new'}});
    };
    expect(await files.mkdir('/host/a b', '新 & folder'), '/canonical/new');
  });

  for (final code in ['not-found', 'bad-name', 'exists', 'mkdir-failed']) {
    test('preserves host error code $code without exposing raw error bodies', () async {
      respond = (request) => json(request, {'ok': false, 'code': code, 'error': 'private host detail'}, status: 400);
      await expectLater(files.mkdir('/host', 'new'), throwsA(isA<DshRemoteException>()
        .having((e) => e.code, 'code', code)
        .having((e) => e.message.contains('private'), 'safe message', isFalse)));
    });
  }
  test('browse surfaces a host refusal', () async {
    respond = (request) => json(request, {'ok': false, 'code': 'not-found'}, status: 404);
    await expectLater(files.browse('/missing'), throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'not-found')));
  });
  for (final status in [401, 403, 302]) {
    test('does not follow auth/redirect responses ($status)', () async {
      var requests = 0;
      respond = (request) async {
        requests++;
        request.response.statusCode = status;
        request.response.headers.set('location', '/outside');
        await request.response.close();
      };
      await expectLater(files.browse(), throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', status)));
      expect(requests, 1);
      if (status == 401) expect(session.hasCookies, isFalse);
    });
  }
  for (final body in [<String, Object?>{}, {'ok': true}, {'ok': true, 'listing': {'path': '', 'roots': [], 'entries': []}},
    {'ok': true, 'listing': {'path': '/', 'roots': [], 'entries': null}}]) {
    test('rejects malformed filesystem response $body', () async {
      respond = (request) => json(request, body);
      await expectLater(files.browse(), throwsA(isA<DshProtocolException>()));
    });
  }
  test('mkdir requires a nonempty returned path', () async {
    respond = (request) => json(request, {'ok': true, 'created': {'path': ''}});
    await expectLater(files.mkdir('/', 'new'), throwsA(isA<DshProtocolException>()));
  });
  test('rejects a non-JSON response', () async {
    respond = (request) async { request.response.write('<html>login</html>'); await request.response.close(); };
    await expectLater(files.browse(), throwsA(isA<DshProtocolException>()));
  });
}
