import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/update/downloader.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

final _bytes = List<int>.generate(64, (i) => (i * 23) & 255);
final _digest = sha256.convert(_bytes).toString();

// Observe ownership for cleanup; all HTTP operations use the real client.
class _Clients extends HttpOverrides {
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

Future<void> _checkRange(String start, {required bool fallback}) async {
  final directory = await Directory.systemTemp.createTemp('dsh_range_number_');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final clients = _Clients();
  final requests = <(String, String?)>[];
  final replies = <Future<void>>[];
  final subscription = server.listen((request) {
    requests.add((request.uri.path, request.headers.value(HttpHeaders.rangeHeader)));
    final first = request.uri.path == '/first';
    final body = first ? _bytes.sublist(16) : _bytes;
    request.response
      ..statusCode = first ? HttpStatus.partialContent : HttpStatus.ok
      ..contentLength = body.length;
    if (first) {
      final from = BigInt.parse(start);
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${from + BigInt.from(body.length - 1)}/${from + BigInt.from(body.length)}',
      );
    }
    request.response.add(body);
    // A rejected response can close the peer before server-side completion.
    replies.add(request.response.close().then<void>((_) {}, onError: (Object _) {}));
  });
  try {
    await File('${directory.path}/a.apk.part').writeAsBytes(_bytes.sublist(0, 16));
    await HttpOverrides.runWithHttpOverrides(() async {
      final http = IoUpdateHttp();
      final first = DownloadUrl(Uri.parse('http://127.0.0.1:${server.port}/first'), mirrorId: null, label: 'first');
      final next = DownloadUrl(
        Uri.parse('http://127.0.0.1:${server.port}/fallback'),
        mirrorId: null,
        label: 'fallback',
      );
      final outcome = await ApkDownloader(
        http: http,
        directory: directory,
      ).download(fileName: 'a.apk', sha256: _digest, urls: [first, next], expectedSize: _bytes.length);
      expect(outcome, isA<DownloadDone>());
      final completed = outcome as DownloadDone;
      expect(completed.file.readAsBytesSync(), _bytes);
      expect(completed.from?.label, fallback ? 'fallback' : 'first');
      expect(File('${directory.path}/a.apk.part').existsSync(), isFalse);
      expect(
        requests,
        fallback
            ? [('/first', 'bytes=16-'), ('/first', null), ('/first', null), ('/fallback', null)]
            : [('/first', 'bytes=16-')],
        reason: 'invalid ranges keep the original finite retry and mirror fallback policy',
      );
    }, clients);
  } finally {
    clients.close();
    await subscription.cancel();
    await server.close(force: true);
    await Future.wait(replies);
    await directory.delete(recursive: true);
  }
}

void main() {
  test('an HTTP range start above signed 64-bit range falls through to the next mirror', () async {
    await _checkRange('9223372036854775808', fallback: true);
  });

  test('a long decimal HTTP range start is rejected without escaping the download outcome', () async {
    await _checkRange('9999999999999999999999999999999999999999', fallback: true);
  });

  test('a representable but mismatched maximum range start keeps the existing fallback', () async {
    await _checkRange('9223372036854775807', fallback: true);
  });

  test('a matching HTTP range still resumes and verifies without contacting the fallback', () async {
    await _checkRange('16', fallback: false);
  });
}
