import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/dsbot_official_v023.json').readAsStringSync()) as Map;
  test('unmodified official v0.2.3 route response rejects mobile hello', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final captured = fixture['hello'] as Map;
    server.listen((request) async {
      expect(request.uri.path, '/api/bot');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['endpoint'], 'hello');
      request.response.statusCode = captured['status'] as int;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(captured['body']));
      await request.response.close();
    });
    final api = DsBotApi(DsBotHttpTransport(DshConnection(Uri.parse('http://127.0.0.1:${server.port}'))));
    addTearDown(() async {
      await api.close();
      await server.close(force: true);
    });
    await expectLater(api.hello(), throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'bot/not-found')));
  });
  test('official route exists but legacy feed has no mobile boot or API contract', () {
    expect(fixture['registeredRoutes'], containsAll(['/api/bot', '/api/bot/feed']));
    final feed = fixture['feed'] as Map;
    expect(feed['status'], 200);
    final line = (feed['firstChunk'] as String).split('\n').firstWhere((line) => line.startsWith('data: '));
    final hello = jsonDecode(line.substring(6)) as Map;
    expect(hello['revision'], isA<int>());
    expect(hello.containsKey('api'), false);
    expect(hello.containsKey('boot'), false);
  });
}
