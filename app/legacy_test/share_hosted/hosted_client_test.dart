import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A share host in memory, behaving like services/share-worker.
class FakeHost {
  final blobs = <String, Uint8List>{};
  final tokens = <String, String>{};
  final requests = <http.Request>[];
  int? failWith;
  var _n = 0;

  late final client = MockClient((request) async {
    requests.add(request);
    if (failWith case final status?) return http.Response('{"error":"x"}', status, headers: {'retry-after': '120'});
    final path = request.url.path;
    if (request.method == 'POST' && path == '/api/v1/c') {
      if (request.headers['Content-Type'] != 'application/octet-stream') return http.Response('', 415);
      final ttl = request.url.queryParameters['ttl'];
      final id =
          '${ttl == '7d'
              ? 'A'
              : ttl == 'forever'
              ? 'z'
              : 'M'}${(++_n).toString().padLeft(9, '0')}';
      blobs[id] = request.bodyBytes;
      tokens[id] = 'token-$id-0123456789';
      return http.Response(
        jsonEncode({
          'id': id,
          'deleteToken': tokens[id],
          'expiresAt': ttl == 'forever' ? null : '2026-11-24T00:00:00.000Z',
        }),
        201,
      );
    }
    final match = RegExp(r'^/api/v1/c/(\w+)$').firstMatch(path);
    if (match == null) return http.Response('', 404);
    final id = match.group(1)!;
    if (request.method == 'GET') {
      final blob = blobs[id];
      return blob == null ? http.Response('', 404) : http.Response.bytes(blob, 200);
    }
    if (request.method == 'DELETE') {
      if (!blobs.containsKey(id)) return http.Response('', 404);
      if (request.headers['Authorization'] != 'Bearer ${tokens[id]}') return http.Response('', 403);
      blobs.remove(id);
      return http.Response('', 204);
    }
    return http.Response('', 405);
  });
}

void main() {
  final file = Uint8List.fromList(utf8.encode('{"dshgo":2,"kind":"conversation","name":"修复登录"}'));
  final now = DateTime.utc(2026, 10, 25, 8);

  test('upload: only ciphertext leaves, and the link opens it', () async {
    final host = FakeHost();
    final client = HostedShareClient(client: host.client, origin: 'https://go.example', clock: () => now);
    final link = await client.upload(file, HostedTtl.week, title: '  修复登录  ');
    final sent = host.requests.single;
    expect(sent.url.toString(), 'https://go.example/api/v1/c?ttl=7d');
    expect(sent.bodyBytes.sublist(0, 4), hostedMagic);
    expect(utf8.decode(sent.bodyBytes, allowMalformed: true), isNot(contains('修复登录')));
    expect(sent.url.toString(), isNot(contains(link.key)));

    expect(link.id, 'A000000001');
    expect(link.title, '修复登录');
    expect(link.createdAt, now);
    expect(link.expiresAt, DateTime.utc(2026, 11, 24));
    expect(link.url, startsWith('https://go.example/c/A000000001#k='));
    final ref = parseHostedUrl(link.url)!;
    expect(openHosted(host.blobs[ref.id]!, decodeHostedKey(ref.key)!), file);

    expect(await client.download(link.url), file);
  });

  test('upload: forever has no expiry; each link has its own key', () async {
    final host = FakeHost();
    final client = HostedShareClient(client: host.client, origin: 'https://go.example');
    final a = await client.upload(file, HostedTtl.forever);
    final b = await client.upload(file, HostedTtl.month);
    expect(a.expiresAt, isNull);
    expect(a.title, '对话');
    expect(host.requests.last.url.queryParameters['ttl'], '30d');
    expect(a.key, isNot(b.key));
  });

  test('errors map to short messages', () async {
    final host = FakeHost();
    final client = HostedShareClient(client: host.client, origin: 'https://go.example');
    Future<HostedShareException> failing(int status) async {
      host.failWith = status;
      try {
        await client.upload(file, HostedTtl.month);
      } on HostedShareException catch (e) {
        return e;
      }
      fail('no exception for $status');
    }

    expect((await failing(413)).kind, HostedShareError.tooLarge);
    final limited = await failing(429);
    expect(limited.kind, HostedShareError.rateLimited);
    expect(limited.retryAfter, const Duration(seconds: 120));
    expect(limited.message, '分享太频繁，稍后再试');
    expect((await failing(503)).kind, HostedShareError.unavailable);
    expect((await failing(400)).kind, HostedShareError.rejected);
    expect((await failing(415)).message, '没能生成链接');
  });

  test('network trouble is one error', () async {
    for (final error in [
      const SocketException('down'),
      http.ClientException('reset'),
      const HandshakeException('tls'),
    ]) {
      final client = HostedShareClient(client: MockClient((_) async => throw error), origin: 'https://go.example');
      await expectLater(
        client.upload(file, HostedTtl.month),
        throwsA(isA<HostedShareException>().having((e) => e.kind, 'kind', HostedShareError.network)),
      );
    }
  });

  test('a malformed answer is not a link', () async {
    for (final body in ['nope', '{"id":"../x","deleteToken":"t"}', '{"id":"A000000001"}', '[]']) {
      final client = HostedShareClient(
        client: MockClient((_) async => http.Response(body, 201)),
        origin: 'https://go.example',
      );
      await expectLater(client.upload(file, HostedTtl.month), throwsA(isA<HostedShareException>()));
    }
  });

  test('delete: the token works, a gone link counts as deleted', () async {
    final host = FakeHost();
    final client = HostedShareClient(client: host.client, origin: 'https://go.example');
    final link = await client.upload(file, HostedTtl.month);
    final other = await client.upload(file, HostedTtl.month);
    final forged = HostedLink(
      id: link.id,
      key: link.key,
      deleteToken: other.deleteToken,
      title: 't',
      createdAt: now,
      ttl: HostedTtl.month,
      origin: link.origin,
    );
    await expectLater(
      client.delete(forged),
      throwsA(isA<HostedShareException>().having((e) => e.kind, 'kind', HostedShareError.forbidden)),
    );
    await client.delete(link);
    expect(host.blobs.containsKey(link.id), isFalse);
    expect(host.requests.last.headers['Authorization'], 'Bearer ${link.deleteToken}');
    await client.delete(link); // 404: already gone
    await expectLater(
      client.download(link.url),
      throwsA(isA<HostedShareException>().having((e) => e.kind, 'kind', HostedShareError.gone)),
    );
  });

  test('links survive a round trip through storage', () {
    final link = HostedLink(
      id: 'M000000001',
      key: encodeHostedKey(newHostedKey()),
      deleteToken: 'tok',
      title: '标题',
      createdAt: now,
      ttl: HostedTtl.month,
      expiresAt: now.add(const Duration(days: 30)),
      origin: 'https://go.example',
    );
    final back = HostedLink.fromJson(jsonDecode(jsonEncode(link.toJson())))!;
    expect(back.url, link.url);
    expect(back.deleteToken, 'tok');
    expect(back.expiresAt, link.expiresAt);
    expect(back.ttl, HostedTtl.month);
    expect(HostedLink.fromJson({'id': 'bad'}), isNull);
    expect(HostedLink.fromJson({...link.toJson(), 'k': 'short'}), isNull);
    expect(HostedLink.fromJson({...link.toJson(), 'origin': 'http://evil'})!.origin, 'https://go.dshtui.com');
  });
}
