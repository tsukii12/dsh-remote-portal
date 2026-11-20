import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  for (final expired in [false, true]) {
    test(
      'real connection queue ${expired ? 'does not send POST after deadline' : 'sends POST before deadline'}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final entered = Completer<void>();
        final release = Completer<void>();
        final paths = <String>[];
        final postedBodies = <String>[];
        server.listen((request) async {
          paths.add(request.uri.path);
          if (request.uri.path == '/occupied') {
            entered.complete();
            await release.future;
          } else if (request.uri.path == '/late') {
            postedBodies.add(await request.cast<List<int>>().transform(SystemEncoding().decoder).join());
          }
          request.response.write('ok');
          await request.response.close();
        });
        final http = HttpClient()..maxConnectionsPerHost = 1;
        final base = Uri.parse('http://127.0.0.1:${server.port}');
        final connection = DshConnection(base, httpClient: http);
        try {
          final first = await http.getUrl(base.resolve('/occupied'));
          final draining = first.close().then((response) => response.drain<void>());
          await entered.future;
          final pending = connection.postJson('/late', {
            'operation': 'synthetic',
          }, timeout: expired ? Duration.zero : const Duration(seconds: 10));
          if (expired) {
            await expectLater(pending, throwsA(isA<DshTransportException>()));
            expect(paths, ['/occupied']);
          }
          release.complete();
          await draining;
          if (!expired) {
            expect((await pending).statusCode, HttpStatus.ok);
          }
          // A successful subsequent exchange is a real finite queue-drain barrier.
          final barrier = await http.getUrl(base.resolve('/barrier'));
          await (await barrier.close()).drain<void>();
          expect(paths, expired ? ['/occupied', '/barrier'] : ['/occupied', '/late', '/barrier']);
          expect(postedBodies, expired ? isEmpty : ['{"operation":"synthetic"}']);
        } finally {
          if (!release.isCompleted) release.complete();
          connection.close();
          http.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }
}
