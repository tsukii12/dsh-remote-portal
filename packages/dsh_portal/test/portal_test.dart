import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_portal/dsh_portal.dart';
import 'package:test/test.dart';

void main() {
  group('server and pairing QR links (ported from Swift PortalURL)', () {
    test('normalizes LAN, IPv6 and relay prefixes without query credentials', () {
      expect(normalizePortalUrl(' http://192.168.1.2:3080 ').toString(), 'http://192.168.1.2:3080/');
      expect(normalizePortalUrl('https://HOST:8443/__t/abc/?ignored=1#fragment').toString(),
          'https://host:8443/__t/abc/');
      expect(normalizePortalUrl('http://[::1]:3080').host, '::1');
    });
    test('plain server QR goes to password login', () {
      final scan = PortalScan.parse('https://host:8443/__t/abc/');
      expect(scan.base.path, '/__t/abc/');
      expect(scan.token, isNull);
    });
    test('pairing keeps its relay prefix and decodes the token exactly', () {
      final scan = PortalScan.parse('https://host/__t/abc/__portal/pair?t=a%2Bb%26%E4%B8%AD#ignored');
      expect(scan.base.toString(), 'https://host/__t/abc/');
      expect(scan.token, 'a+b&中');
    });
    test('rejects missing tokens, malformed links and non-HTTP QR codes', () {
      for (final raw in ['', 'host:3080', 'ftp://host/a', 'javascript:alert(1)',
        'https://user:password@host/', 'https:///no-host', 'https://host/__portal/pair']) {
        expect(() => PortalScan.parse(raw), throwsFormatException, reason: raw);
      }
    });
  });

  group('per-base cookies and stable UA (ported from Swift CookieVault)', () {
    test('honors paths, secure cookies, expiry and replacement/deletion', () async {
      var now = DateTime.utc(2026);
      final session = PortalSession(Uri.parse('https://host/__t/a/'), now: () => now);
      addTearDown(session.close);
      final api = session.connection.resolve('/api/session/list');
      await session.receiveCookies(api, [
        'portal=one; Path=/__t/a/; HttpOnly; Secure; Max-Age=60',
        'private=hidden; Path=/__t/a/private; Secure',
        'foreign=denied; Domain=other.example; Path=/',
      ]);
      final headers = session.headersFor(api);
      expect(headers['Cookie'], 'portal=one');
      expect(headers['Origin'], 'https://host');
      expect(headers['User-Agent'], PortalSession.userAgent);
      await session.receiveCookies(api, ['portal=two; Path=/__t/a/; Secure; Max-Age=60']);
      expect(session.headersFor(api)['Cookie'], 'portal=two');
      now = now.add(const Duration(seconds: 61));
      expect(session.headersFor(api)['Cookie'], isNull);
      await session.receiveCookies(api, ['private=; Path=/__t/a/private; Max-Age=0']);
      expect(session.hasCookies, isFalse);
    });
    test('refuses other origins, sibling relays and path traversal', () async {
      final session = PortalSession(Uri.parse('https://host/__t/a/'));
      addTearDown(session.close);
      for (final raw in ['https://other/__t/a/api/x', 'https://host/__t/b/api/x',
        'https://host/__t/a/../b/api/x', 'http://host/__t/a/api/x']) {
        expect(() => session.headersFor(Uri.parse(raw)), throwsArgumentError);
      }
    });
    test('secure cookies are not attached to plaintext HTTP', () async {
      final session = PortalSession(Uri.parse('http://host/'));
      addTearDown(session.close);
      await session.receiveCookies(session.base, ['secure=value; Path=/; Secure']);
      expect(session.headersFor(session.base)['Cookie'], isNull);
    });
    test('restoration cannot cross bases sharing the same relay authority', () async {
      String? stored;
      final a = PortalSession(Uri.parse('https://host/__t/a/'), saveCookies: (v) async => stored = v);
      final b = PortalSession(Uri.parse('https://host/__t/b/'));
      addTearDown(a.close); addTearDown(b.close);
      await a.receiveCookies(a.base, ['portal=value; Path=/; Max-Age=60']);
      b.restoreCookies(stored);
      expect(b.hasCookies, isFalse);
      final restored = PortalSession(a.base);
      addTearDown(restored.close);
      restored.restoreCookies(stored);
      expect(restored.headersFor(a.base)['Cookie'], 'portal=value');
    });
  });

  group('HTTP, RPC, binary and WebSocket share portal authentication', () {
    late HttpServer server;
    late PortalSession session;
    late List<String?> writes;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      writes = [];
      session = PortalSession(Uri.parse('http://127.0.0.1:${server.port}/__t/test/'),
        saveCookies: (v) async => writes.add(v));
    });
    tearDown(() async { await session.close(); await server.close(force: true); });

    test('password form is UTF-8 exact, follows no redirect, and authenticates HTTP/mux', () async {
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        expect(request.headers.value('user-agent'), PortalSession.userAgent);
        expect(request.headers.value('origin'), session.base.origin);
        if (request.uri.path.endsWith('/__portal/login')) {
          final form = Uri.splitQueryString(await utf8.decoder.bind(request).join());
          expect(form, {'password': '中文 + & 密码'});
          request.response.statusCode = 303;
          request.response.headers.set('Location', 'https://other.example/never-follow');
          request.response.headers.add('Set-Cookie', 'portal=test; Path=/__t/test/; HttpOnly');
          await request.response.close();
        } else if (WebSocketTransformer.isUpgradeRequest(request)) {
          expect(request.headers.value('cookie'), 'portal=test');
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((frame) => socket.add(frame));
        } else {
          expect(request.headers.value('cookie'), 'portal=test');
          final body = await utf8.decoder.bind(request).join();
          final rpcId = body.isEmpty ? null : (jsonDecode(body) as Map)['rpcId'];
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'type': 'server-response', 'rpcId': rpcId,
            'result': {'ok': true, 'value': '你好'}}));
          await request.response.close();
        }
      });
      await session.login('中文 + & 密码');
      expect(requests, ['/__t/test/__portal/login']);
      expect(writes, hasLength(1));
      expect(session.connection.canReadSessionsInBackground, isFalse);
      final result = await DshRpc(DshHttpCarrier(session.connection)).call('session/list');
      expect(result, '你好');
      final bytes = await session.connection.getBounded('/api/file', maxBytes: 1024);
      expect(bytes.statusCode, 200);
      final socket = await session.connection.connectWebSocket('/api/remote.mux');
      socket.add('多字节中文🙂');
      expect(await socket.first, '多字节中文🙂');
      await socket.close();
      expect(requests.last, '/__t/test/api/remote.mux');
    });

    test('pairing submits token, not password; HTTP 401 clears state and signals login', () async {
      final expired = Completer<void>();
      session.expired.listen((_) { if (!expired.isCompleted) expired.complete(); });
      server.listen((request) async {
        if (request.uri.path.endsWith('/__portal/login')) {
          expect(Uri.splitQueryString(await utf8.decoder.bind(request).join()), {'token': 'pair+令牌'});
          request.response.statusCode = 303;
          request.response.headers.add('Set-Cookie', 'portal=test; Path=/__t/test/');
        } else { request.response.statusCode = 401; }
        await request.response.close();
      });
      await session.login('pair+令牌', pairing: true);
      await session.connection.get('/api/denied');
      await expired.future;
      expect(session.hasCookies, isFalse);
      expect(session.headersFor(session.base)['Cookie'], isNull);
    });

    test('empty/no-cookie and rejected/rate-limited logins are errors', () async {
      var status = 303;
      server.listen((request) async { await request.drain<void>();
        request.response.statusCode = status; await request.response.close(); });
      for (final code in [303, 401, 429, 500]) {
        status = code;
        await expectLater(session.login(''), throwsA(isA<DshHttpException>()));
      }
    });
  });
}
