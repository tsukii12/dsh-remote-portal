// v1.2 capabilities on the client side (docs/design/native-plugins-protocol.md
// §11): features only when offered, the micro channel, cap.event, the media
// route and its bounded read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

Future<void> _tick([int ms = 5]) => Future<void>.delayed(Duration(milliseconds: ms));

/// A Host with the media route: login, then scripted answers.
class _MediaHost {
  _MediaHost._(this._server) {
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

  static Future<_MediaHost> start() async => _MediaHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

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

void main() {
  group('negotiation', () {
    test('no features: the v1.1 caps query and hello', () async {
      expect(const DshGoCaps(app: '0.9.2').query.containsKey('features'), isFalse);
      expect(const DshGoCaps(features: ['audio', 'micro']).query['features'], 'audio,micro');
      expect(const DshGoCaps(features: ['audio']) == const DshGoCaps(), isFalse);

      final socket = _Socket();
      final stream = DshGoStream(() async => socket);
      addTearDown(stream.close);
      await stream.hold();
      expect(socket.sent.first.containsKey('features'), isFalse);
      expect(stream.negotiatedFeatures, isEmpty);
      expect(stream.capabilityEvent('lease', 1, 'audio.ended'), isFalse, reason: 'nothing negotiated');
      expect(socket.sent.where((m) => m['t'] == 'cap.event'), isEmpty);
    });

    test('features in hello; welcome decides; a drop forgets them', () async {
      final socket = _Socket()..agree = ['audio', 'future'];
      final stream = DshGoStream(() async => socket, features: const ['audio', 'voice']);
      addTearDown(stream.close);
      await stream.hold();
      expect(socket.sent.first['features'], ['audio', 'voice']);
      expect(stream.negotiatedFeatures, {'audio'}, reason: 'only what both sides have');
      expect(stream.capabilityEvent('lease', 1, 'voice.speechStart'), isFalse);
      expect(stream.capabilityEvent('lease', 1, 'audio.ended', reason: 'x' * 200), isTrue);
      final sent = socket.sent.lastWhere((m) => m['t'] == 'cap.event');
      expect((sent['lease'], sent['seq'], sent['event']), ('lease', 1, 'audio.ended'));
      expect((sent['reason'] as String).length, 120);
      expect(stream.capabilityEvent('lease', 2, 'audio.unknown'), isFalse);
      await socket.input.close();
      await _tick();
      expect(stream.negotiatedFeatures, isEmpty);
      stream.release();
    });

    test('plugin declarations are read leniently', () {
      final plugin = DshGoPlugin.fromJson({
        'pkg': 'voice',
        'state': 'ok',
        'capabilities': ['audio', 'voice', 'micro', 'overlay', 'teleport'],
        'contributes': {
          'composer.actions': [
            {
              'id': 'read',
              'label': '朗读',
              'requires': ['audio'],
            },
          ],
          'panels': [
            {'id': 'p', 'title': 'P', 'micro': 'caption'},
          ],
          'media': [
            {'id': 'speech'},
            {'id': 'bad id'},
          ],
          'micro': [
            {'id': 'caption'},
          ],
          'overlays': [
            {'id': 'line', 'channel': 'caption', 'text': '朗读中'},
            {'id': 'empty'},
          ],
        },
      })!;
      expect(plugin.capabilities, {'audio', 'voice', 'micro', 'overlay'});
      expect(plugin.media, ['speech']);
      expect(plugin.micro, ['caption']);
      expect(plugin.overlays, [const DshGoOverlay('line', channel: 'caption', text: '朗读中')]);
      expect(plugin.composerActions.single.requires, ['audio']);
      expect(plugin.panels.single.micro, 'caption');
      final legacy = DshGoPlugin.fromJson({'pkg': 'old', 'contributes': {}})!;
      expect(legacy.capabilities, isEmpty);
      expect(legacy.media, isEmpty);
      expect(legacy.overlays, isEmpty);
    });
  });

  group('micro', () {
    test('needs the feature; sub / latest at 10 Hz / epoch and order / unsub', () async {
      expect(await DshGoStream(() async => _Socket()).subscribeMicro(pkg: 'p', id: 'c').first, isA<DshGoEnded>());

      final socket = _Socket();
      final stream = DshGoStream(() async => socket, features: const ['micro']);
      addTearDown(stream.close);
      final texts = <Object?>[];
      final sub = stream
          .subscribeMicro(
            pkg: 'voice',
            id: 'caption',
            scope: const DshGoScope(sessionId: 's1'),
          )
          .listen((e) => texts.add(e is DshGoData ? (e.data as Map)['text'] : e));
      await _tick();
      final frame = socket.sent.singleWhere((m) => m['t'] == 'micro.sub');
      expect(frame['scope'], {'sessionId': 's1'});
      expect(socket.sent.any((m) => m['t'] == 'sub'), isFalse, reason: 'never the panel data path');
      final sid = frame['sub'];
      void data(String rev, Object? value) =>
          socket.receive({'t': 'micro.data', 'sub': sid, 'rev': rev, 'data': value});
      data('0123456789abcdef.1', {'text': 'one'});
      await _tick();
      data('0123456789abcdef.2', {'text': 'two'});
      data('0123456789abcdef.3', {'text': 'three'});
      data('0123456789abcdef.4', {'text': 'bad', 'effects': []});
      data('0123456789abcdef.2', {'text': 'older'});
      data('fedcba9876543210.9', {'text': 'other epoch'});
      data('0123456789abcdef.10', {'text': 'three'});
      await _tick(150);
      expect(texts, ['one', 'three'], reason: 'latest only, same value not again, stale dropped');
      await sub.cancel();
      expect(socket.sent.last, {'t': 'micro.unsub', 'sub': sid});
    });

    test('a third subscription for one plugin is refused locally', () async {
      final socket = _Socket();
      final stream = DshGoStream(() async => socket, features: const ['micro']);
      addTearDown(stream.close);
      final a = stream.subscribeMicro(pkg: 'p', id: 'a').listen((_) {});
      final b = stream.subscribeMicro(pkg: 'p', id: 'b').listen((_) {});
      expect(await stream.subscribeMicro(pkg: 'p', id: 'c').first, isA<DshGoEnded>());
      await a.cancel();
      await b.cancel();
    });

    test('the small model', () {
      expect(dshGoMicroData({'text': 'ok', 'progress': 0.5}), {'text': 'ok', 'progress': 0.5});
      expect(dshGoMicroData({'progress': null}), {'progress': null});
      for (final bad in <Object?>[
        {},
        {'text': 'x', 'effects': []},
        {'progress': double.nan},
        {'progress': 1.5},
        {'text': List.filled(241, '鲸').join()},
        {'text': 7},
        'text',
      ]) {
        expect(dshGoMicroData(bad), isNull, reason: '$bad');
      }
    });
  });

  group('media', () {
    late _MediaHost host;
    late DshClient client;

    setUp(() async {
      host = await _MediaHost.start();
      client = await DshClient.connect(baseUri: host.baseUri, token: 't', startMux: false);
    });

    tearDown(() async {
      await client.close();
      await host.close();
    });

    test('reads the clip with the cookie, lease and key; only audio types', () async {
      final media = await client.readDshGoMedia('@acme/voice', 'speech', lease: 'L1', key: 'k_1');
      expect(media.bytes, [1, 2, 3, 4]);
      expect(media.contentType, 'audio/mpeg');
      expect(host.paths.single, '/dsh-go/v1/media/@acme/voice/speech?lease=L1&key=k_1');
      expect(host.cookies.single, contains('dsh-auth-k1='));

      host.answer = (request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html>');
        await request.response.close();
      };
      await expectLater(client.readDshGoMedia('voice', 'speech', lease: 'L1'), throwsA(isA<DshProtocolException>()));

      host.answer = (request) async {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'v': 1,
            'error': {'code': 'not-found', 'message': 'no lease'},
          }),
        );
        await request.response.close();
      };
      await expectLater(
        client.readDshGoMedia('voice', 'speech', lease: 'L1'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'dsh-go/not-found')),
      );
      expect(() => client.readDshGoMedia('voice', '../x', lease: 'L1'), throwsArgumentError);
    });

    test('no redirect is followed, a body past the cap fails, one deadline', () async {
      var followed = 0;
      host.answer = (request) async {
        if (request.uri.path.endsWith('/elsewhere')) followed++;
        request.response
          ..statusCode = 302
          ..headers.set('location', '/dsh-go/v1/media/voice/elsewhere');
        await request.response.close();
      };
      await expectLater(client.readDshGoMedia('voice', 'speech', lease: 'L1'), throwsA(isA<DshHttpException>()));
      expect(followed, 0);

      host.answer = (request) async {
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(List.filled(64, 0));
        await request.response.close();
      };
      await expectLater(
        client.readDshGoMedia('voice', 'speech', lease: 'L1', maxBytes: 16),
        throwsA(isA<DshProtocolException>()),
      );

      final hold = Completer<void>();
      host.answer = (request) async {
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.bufferOutput = false;
        request.response.add([1]);
        await request.response.flush();
        await hold.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        await request.response.close().catchError((Object _) {});
      };
      final started = DateTime.now();
      await expectLater(
        client.readDshGoMedia('voice', 'speech', lease: 'L1', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<DshTransportException>()),
      );
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 2)));
      hold.complete();
    });
  });

  test('getBounded: redirect, length and timeout each close their own connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = <Completer<void>>[];
    final serving = server.listen((socket) {
      final done = Completer<void>();
      closed.add(done);
      // Writes after the client hung up fail here, not as uncaught errors.
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      final request = StringBuffer();
      Timer? producer;
      socket.listen(
        (data) {
          request.write(ascii.decode(data, allowInvalid: true));
          if (!request.toString().contains('\r\n\r\n') || producer != null) return;
          final head = request.toString();
          if (head.startsWith('GET /ok ')) {
            socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n'));
            socket.add([1, 2, 3]);
            unawaited(socket.close());
            producer = Timer(Duration.zero, () {});
            return;
          }
          final kind = head.split(' ')[1];
          socket.add(
            ascii.encode(switch (kind) {
              '/redirect' => 'HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nTransfer-Encoding: chunked\r\n\r\n',
              '/length' => 'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 100000000\r\n\r\n',
              _ => 'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\n\r\n',
            }),
          );
          // A slow, endless body: only the client can end this connection.
          producer = Timer.periodic(const Duration(milliseconds: 50), (_) {
            try {
              socket.add(ascii.encode(kind == '/length' ? 'x' * 64 : '40\r\n${'x' * 64}\r\n'));
            } catch (_) {}
          });
        },
        onDone: () {
          producer?.cancel();
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          producer?.cancel();
          if (!done.isCompleted) done.complete();
        },
      );
    });
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'));
    try {
      for (final (path, error) in [
        ('/redirect', isA<DshHttpException>()),
        ('/length', isA<DshProtocolException>()),
        ('/slow', isA<DshTransportException>()),
      ]) {
        await expectLater(
          connection.getBounded(path, maxBytes: 1024 * 1024, timeout: const Duration(milliseconds: 400)),
          throwsA(error),
          reason: path,
        );
        await closed.last.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('$path left its connection open'),
        );
      }
      final next = await connection.get('/ok');
      expect(next.statusCode, 200);
      expect(next.body, [1, 2, 3]);
    } finally {
      connection.close(force: true);
      await serving.cancel();
      await server.close();
    }
  });
}
