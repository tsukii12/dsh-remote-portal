import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _RelayCarrier extends DshCarrier {
  @override
  String get kind => 'relay';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw UnsupportedError(endpoint);

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}

void main() {
  test('the archive name follows the Host and official client', () {
    expect(sessionLogZipName('ses_01J9/x y'), 'dsh-session-ses_01J9_x_y.zip');
  });

  test('HTTP carrier: GET /api/session.export with descendants', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    server.listen((request) async {
      seen.add('${request.method} ${request.uri}');
      if (request.uri.queryParameters['sessionId'] == 'gone') {
        request.response.statusCode = 404;
        request.response.write('no such session');
      } else {
        request.response.headers.contentType = ContentType('application', 'zip');
        request.response.add([0x50, 0x4b, 0x03, 0x04]);
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    expect(client.canExportSessionLog, isTrue);

    expect(await client.exportSessionLog('s1'), [0x50, 0x4b, 0x03, 0x04]);
    expect(seen.single, 'GET /api/session.export?sessionId=s1&includeDescendants=true');
    await expectLater(
      client.exportSessionLog('gone'),
      throwsA(
        isA<DshRemoteException>()
            .having((e) => e.code, 'code', 'session-export/http-404')
            .having((e) => e.message, 'message', contains('no such session')),
      ),
    );
  });

  test('the relay tunnel cannot fetch it and says so', () async {
    final client = DshClient.withCarrier(_RelayCarrier());
    expect(client.canExportSessionLog, isFalse);
    await expectLater(
      client.exportSessionLog('s1'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session-export/unsupported')),
    );
  });
}
