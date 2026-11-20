import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('optional gzip decoding retains the decompressed byte limit and binary default', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final text = 'release HTML ' * 1000;
    final compressed = gzip.encode(utf8.encode(text));
    server.listen((request) async {
      request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.contentLength = compressed.length;
      request.response.add(compressed);
      await request.response.close();
    });
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'));
    try {
      final binary = await connection.getBounded('/', maxBytes: compressed.length + 1);
      expect(binary.body, compressed, reason: 'existing media callers retain compressed bytes');
      final decoded = await connection.getBounded('/', maxBytes: text.length + 1, autoUncompress: true);
      expect(decoded.text, text);
      expect(compressed.length, lessThan(1024));
      await expectLater(
        connection.getBounded('/', maxBytes: 1024, autoUncompress: true),
        throwsA(isA<DshProtocolException>()),
        reason: 'compressed Content-Length must not bypass the decoded byte budget',
      );
    } finally {
      connection.close(force: true);
      await server.close(force: true);
    }
  });
}
