import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Reply {
  const _Reply(this.status, this.body, {this.truncated = false, this.etag});

  final int status;
  final String body;
  final bool truncated;
  final String? etag;
}

/// Real TCP and HTTP framing. A truncated reply sends fewer body bytes than
/// its Content-Length and then closes its write side: no stalled fake Future.
class _Server {
  _Server(this.socket, this.reply) {
    socket.listen((peer) {
      peers.add(peer);
      var header = '';
      var sent = false;
      peer.listen((bytes) {
        if (sent) return;
        header += ascii.decode(bytes);
        if (!header.contains('\r\n\r\n')) return;
        sent = true;
        final uri = Uri.parse(header.split('\r\n').first.split(' ')[1]);
        paths.add(uri.path);
        unawaited(_respond(peer, reply(uri)));
      }, onError: (Object _) {});
    });
  }

  final ServerSocket socket;
  final _Reply Function(Uri) reply;
  final peers = <Socket>[];
  final paths = <String>[];

  static Future<_Server> start(_Reply Function(Uri) reply) async =>
      _Server(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), reply);

  Uri url(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: socket.port, path: path);

  Future<void> _respond(Socket peer, _Reply reply) async {
    final body = utf8.encode(reply.body);
    final headers =
        'HTTP/1.1 ${reply.status} Fixture\r\n'
        'Content-Length: ${body.length + (reply.truncated ? 7 : 0)}\r\n'
        'Content-Type: application/json\r\n'
        'Connection: close\r\n'
        '${reply.etag == null ? '' : 'ETag: ${reply.etag}\r\n'}\r\n';
    try {
      peer.add([...ascii.encode(headers), ...body]);
      await peer.flush();
      await peer.close();
    } on SocketException {
      // The caller may already have rejected the HTTP status and closed.
    }
  }

  Future<void> close() async {
    for (final peer in peers) {
      peer.destroy();
    }
    await socket.close();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final status in [404, 503]) {
    test('HTTP $status survives a truncated error body', () async {
      final server = await _Server.start(
        (_) => _Reply(status, 'error', truncated: true),
      );
      addTearDown(server.close);

      await expectLater(
        fetchMarketFile(server.url('/index.json')),
        throwsA(
          isA<MarketFetchException>().having(
            (e) => e.statusCode,
            'HTTP status',
            status,
          ),
        ),
      );
      expect(server.paths, ['/index.json']);
    });
  }

  test('a complete error body keeps the same HTTP status', () async {
    final server = await _Server.start(
      (_) => const _Reply(404, 'not published'),
    );
    addTearDown(server.close);

    await expectLater(
      fetchMarketFile(server.url('/index.json')),
      throwsA(
        isA<MarketFetchException>().having(
          (e) => e.statusCode,
          'HTTP status',
          404,
        ),
      ),
    );
  });

  test('a complete accepted body and ETag are still read', () async {
    final server = await _Server.start(
      (_) => const _Reply(200, '{"format":1}', etag: '"v1"'),
    );
    addTearDown(server.close);

    expect(await fetchMarketFile(server.url('/index.json')), (
      text: '{"format":1}',
      etag: '"v1"',
    ));
  });

  test(
    'a truncated accepted body still reports an interrupted download',
    () async {
      final server = await _Server.start(
        (_) => const _Reply(200, '{"format":', truncated: true),
      );
      addTearDown(server.close);

      await expectLater(
        fetchMarketFile(server.url('/index.json')),
        throwsA(
          isA<MarketFetchException>()
              .having((e) => e.statusCode, 'HTTP status', isNull)
              .having(
                (e) => e.message,
                'message',
                appL10n.stateMarketInterrupted,
              ),
        ),
      );
    },
  );

  test('the official catalog accepts a missing sidecar even if its error body breaks', () async {
    final index = await File('test/plugins/fixtures/official-index.json')
        .readAsString();
    final server = await _Server.start(
      (uri) => uri.path.endsWith('/index.json')
          ? _Reply(200, index)
          : const _Reply(404, 'not published', truncated: true),
    );
    addTearDown(server.close);

    final catalog = await fetchOfficialMarket(
      refresh: true,
      get: (url, {etag}) => fetchMarketFile(server.url(url.path), etag: etag),
    );
    expect(catalog.entries, isNotEmpty);
    expect(catalog.entries.every((entry) => entry.listing == null), isTrue);
    expect(
      server.paths,
      unorderedEquals(['/market/index.json', '/market/dsh-go.json']),
    );
  });
}
