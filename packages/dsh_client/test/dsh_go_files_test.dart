import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _Socket implements DshGoSocket {
  final input = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];

  /// What `welcome` agrees to; null: echo the hello's features.
  List<String>? agree;

  @override
  Stream<Object?> get messages => input.stream;

  @override
  void send(String text) {
    final map = jsonDecode(text) as Map<String, Object?>;
    sent.add(map);
    if (map['t'] == 'hello') {
      receive({
        't': 'welcome',
        'v': 1,
        'conn': 'c1',
        if (map['features'] != null) 'features': agree ?? map['features'],
      });
    }
  }

  void receive(Map<String, Object?> data) {
    if (!input.isClosed) input.add(jsonEncode(data));
  }

  @override
  Future<void> close([int? code]) async {
    if (!input.isClosed) await input.close();
  }
}

/// A Host with the media route: login, then scripted answers.
class _FileHost {
  _FileHost._(this._server) {
    _server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/' && request.uri.queryParameters['token'] == 't') {
        response
          ..statusCode = 303
          ..headers.set('location', './')
          ..headers.add('set-cookie', 'dsh-auth-k1=v1.sig; Path=/; HttpOnly');
        await response.close();
        return;
      }
      paths.add(request.uri.toString());
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      await answer(request);
    });
  }

  static Future<_FileHost> start() async => _FileHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final paths = <String>[];
  final cookies = <String?>[];
  Future<void> Function(HttpRequest request) answer = (request) async {
    request.response.headers.contentType = ContentType('audio', 'mpeg');
    request.response.add([1, 2, 3, 4]);
    await request.response.close();
  };

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

const _request = '12345678901234567890123456789012';

void main() {
  late _FileHost host;
  late DshClient client;
  setUp(() async {
    host = await _FileHost.start();
    client = await DshClient.connect(baseUri: host.baseUri, token: 't', startMux: false);
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('selected-file transport preserves bytes, authentication and stream binding', () async {
    final received = <int>[];
    host.answer = (request) async {
      await for (final chunk in request) {
        received.addAll(chunk);
      }
      expect(request.uri.path, '/dsh-go/v1/files/$_request/upload');
      expect(request.uri.queryParameters, {'stream': 's1', 'name': '中文 file.txt', 'mediaType': 'text/plain'});
      expect(request.headers.contentType!.mimeType, 'application/octet-stream');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'v': 1,
          'file': {'handle': _request, 'name': '中文 file.txt', 'bytes': 4, 'mediaType': 'text/plain', 'access': 'read'},
        }),
      );
      await request.response.close();
    };
    await client.uploadDshGoPickedFile(
      _request,
      Uint8List.fromList([0, 1, 128, 255]),
      stream: 's1',
      name: '中文 file.txt',
      mediaType: 'text/plain',
    );
    expect(received, [0, 1, 128, 255]);
    expect(host.cookies.single, contains('dsh-auth-k1='));
    host.answer = (request) async {
      expect(request.uri.queryParameters, {'stream': 's1'});
      expect(jsonDecode(await utf8.decoder.bind(request).join()), {'status': 'selected'});
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'v': 1,
          'effects': [
            {
              'type': 'patch',
              'id': 'panel',
              'data': {'done': true},
            },
          ],
        }),
      );
      await request.response.close();
    };
    final done = await client.completeDshGoFileSelection(_request, stream: 's1', status: 'selected');
    expect(done.effects.single['type'], 'patch');
  });

  test('uploads and callbacks never follow redirects, even to the same host', () async {
    host.answer = (request) async {
      await request.drain<void>();
      request.response
        ..statusCode = 307
        ..headers.set('location', '/stolen');
      await request.response.close();
    };
    await expectLater(
      client.uploadDshGoPickedFile(_request, Uint8List(1), stream: 's', name: 'a'),
      throwsA(isA<DshRemoteException>()),
    );
    await expectLater(
      client.completeDshGoFileSelection(_request, stream: 's', status: 'cancelled'),
      throwsA(isA<DshRemoteException>()),
    );
    expect(host.paths.length, 2);
    expect(host.paths.any((path) => path.contains('stolen')), false);
  });

  test('client rejects oversize before network and bounds a dishonest receipt', () async {
    await expectLater(
      client.uploadDshGoPickedFile(_request, Uint8List(8 * 1024 * 1024 + 1), stream: 's', name: 'a'),
      throwsArgumentError,
    );
    expect(host.paths, isEmpty);
    host.answer = (request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('x' * 4097);
      await request.response.close();
    };
    await expectLater(
      client.uploadDshGoPickedFile(_request, Uint8List(1), stream: 's', name: 'a'),
      throwsA(isA<DshProtocolException>()),
    );
  });

  test('gesture remains optional for old callers and files survive capability filtering', () {
    const old = DshGoInvocation(pkg: 'old', id: 'go', surface: 'composer.actions');
    expect(old.toJson().containsKey('userGesture'), false);
    expect(
      const DshGoInvocation(pkg: 'new', id: 'go', surface: 'panel', userGesture: false).toJson()['userGesture'],
      false,
    );
    final c = DshGoContributions.fromJson({
      'v': 1,
      'plugins': [
        {
          'pkg': 'files',
          'state': 'ok',
          'native': true,
          'capabilities': ['files', 'future'],
          'contributes': {},
        },
      ],
    });
    expect(c!.plugins.single.capabilities, {'files'});
  });

  test('system selection extends background grace only until its bounded release', () async {
    final socket = _Socket();
    final stream = DshGoStream(
      () async => socket,
      features: ['files'],
      backgroundGrace: const Duration(milliseconds: 5),
    );
    addTearDown(stream.close);
    await stream.hold();
    final release = stream.holdSystemSelection(timeout: const Duration(seconds: 1));
    stream.background();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(stream.conn, 'c1');
    release();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(stream.conn, isNull);
  });
}
