import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/binary_response.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

List<SessionLogEvent> _events() => [
  for (final frame in loadJsonl('follow_presented.jsonl'))
    if (parseFollowFrame('s', frame) case final SessionLogEvent event) event,
];

/// Unary calls only, scripted per endpoint.
class _BytesCarrier extends DshCarrier {
  _BytesCarrier(this.handlers, {this.allowed});

  final Map<String, Object? Function(Map<String, Object?> args)> handlers;
  final Set<String>? allowed;
  final List<(String, Map<String, Object?>)> calls = [];

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  bool allowsEndpoint(String endpoint) => allowed?.contains(endpoint) ?? true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) return const RpcError(DshRemoteException('gateway/not-found', 'missing'));
    return RpcOk(handler(args));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('no streams');

  @override
  Future<void> close() async {}
}

void main() {
  group('deliverables/presented', () {
    test('the transcript keeps the events as UnknownEvent of a known type', () {
      final presented = _events().where((e) => e.type == presentedEventType).toList();
      expect(presented, hasLength(4));
      expect(presented.first, isA<UnknownEvent>());
      expect((presented.first as UnknownEvent).isKnownType, isTrue);
    });

    test('one event: valid entries in order, malformed ones skipped with their index kept', () {
      final second = _events().where((e) => e.type == presentedEventType).elementAt(1);
      final files = presentedFilesOf(second)!;
      expect(
        [for (final f in files) (f.path, f.description, f.index)],
        [('/root/workspace/out/report.pdf', '季度销售报告(终版)', 0), ('out/data.xlsx', '原始数据', 1)],
      );
      expect(files.first.callId, 'c-present2');
      expect(files.first.turn, 1);
      expect(files.first.seq, second.seq);
    });

    test('malformed events and other event types yield nothing', () {
      final presented = _events().where((e) => e.type == presentedEventType).toList();
      expect(presentedFilesOf(presented[2]), isNull, reason: 'turn 0');
      expect(presentedFilesOf(presented[3]), isNull, reason: 'empty callId');
      expect(presentedFilesOf(_events().first), isNull);
      SessionLogEvent event(Object? data) =>
          SessionLogEvent.fromJson({'seq': 1, 'time': 0, 'type': presentedEventType, 'data': data});
      expect(presentedFilesOf(event({'turn': 1.5, 'callId': 'c', 'files': []})), isNull);
      expect(presentedFilesOf(event({'turn': 1, 'callId': 'c', 'files': 'x'})), isNull);
      expect(presentedFilesOf(event('nope')), isNull);
      expect(presentedFilesOf(event({'turn': 2, 'callId': 'c', 'files': []})), isEmpty);
    });

    test('per turn: first-seen order, latest declaration wins, bad turns dropped', () {
      final byTurn = presentedByTurn(_events());
      expect(byTurn.keys, [1]);
      final files = byTurn[1]!;
      expect(
        [for (final f in files) f.path],
        ['/root/workspace/out/report.pdf', '/root/workspace/out/chart.png', 'out/data.xlsx'],
      );
      expect(files[0].description, '季度销售报告(终版)');
      expect(files[0].callId, 'c-present2');
      expect(files[1].description, isNull);
      expect(files[1].callId, 'c-present');
    });

    test('a ChatTranscript fed the follow frames exposes the same events', () {
      final transcript = ChatTranscript();
      for (final frame in loadJsonl('follow_presented.jsonl')) {
        transcript.apply(parseFollowFrame('s', frame));
      }
      expect(transcript.header?.cwd, '/root/workspace');
      final byTurn = presentedByTurn(transcript.events);
      expect(byTurn[1], hasLength(3));
      // The present call itself is an ordinary tool row.
      final present = transcript.items.whereType<ToolChatItem>().where((t) => t.name == 'present');
      expect(present, hasLength(3));
      expect(present.first.status, ToolStatus.succeeded);
      expect(present.last.status, ToolStatus.failed);
    });
  });

  group('resolveSessionPath', () {
    test('relative paths join the working directory; dots fold', () {
      expect(resolveSessionPath('out/data.xlsx', cwd: '/root/workspace'), '/root/workspace/out/data.xlsx');
      expect(resolveSessionPath('./a/../b.pdf', cwd: '/root/workspace/'), '/root/workspace/b.pdf');
      expect(resolveSessionPath('/sdcard//Download/DSH/./r.pdf'), '/sdcard/Download/DSH/r.pdf');
      expect(resolveSessionPath('file:///tmp/a%20b.png'), '/tmp/a b.png');
    });

    test('nothing to resolve against: unchanged', () {
      expect(resolveSessionPath('out/a.pdf'), 'out/a.pdf');
      expect(resolveSessionPath(r'C:\Users\me\a.pdf', cwd: '/root'), r'C:\Users\me\a.pdf');
    });
  });

  group('readFile', () {
    test('remote carrier: stat, then base64 byte windows until eof', () async {
      final content = Uint8List.fromList(List.generate(fileWindowBytes + 10, (i) => i % 251));
      final carrier = _BytesCarrier({
        'workspaceFiles/stat': (_) => {'absolutePath': '/w/a.bin', 'version': 'v1', 'bytes': content.length},
        'workspaceFiles/readBytes': (args) {
          final range = ((args['options'] as Map)['range'] as Map);
          final offset = range['offset'] as int;
          final length = range['length'] as int;
          final end = (offset + length).clamp(0, content.length);
          return {
            'offset': offset,
            'data': base64Encode(content.sublist(offset, end)),
            'eof': end >= content.length,
            'absolutePath': '/w/a.bin',
            'version': 'v1',
            'bytes': content.length,
          };
        },
      });
      final client = DshClient.withCarrier(carrier);
      final progress = <(int, int?)>[];
      final bytes = BytesBuilder();
      final total = await client.readFile(
        's1',
        'a.bin',
        onChunk: bytes.add,
        onProgress: (r, t) => progress.add((r, t)),
      );
      expect(total, content.length);
      expect(bytes.takeBytes(), content);
      expect(progress.first, (0, content.length));
      expect(progress.last, (content.length, content.length));
      final reads = [
        for (final (e, a) in carrier.calls)
          if (e == 'workspaceFiles/readBytes') a,
      ];
      expect(reads, hasLength(2));
      expect(reads.first['workspaceFileScopeId'], 's1');
      expect(reads.first['path'], 'a.bin');
    });

    test('a known size over the limit is refused before reading', () async {
      final carrier = _BytesCarrier({
        'workspaceFiles/stat': (_) => {'absolutePath': '/w/big.zip', 'version': 'v', 'bytes': 500},
      });
      final client = DshClient.withCarrier(carrier);
      await expectLater(
        client.readFileBytes('s', 'big.zip', maxBytes: 100),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/too-large')),
      );
      expect(carrier.calls.map((c) => c.$1), ['workspaceFiles/stat']);
    });

    test('a growing file never delivers a byte window past maxBytes', () async {
      final carrier = _BytesCarrier({
        'workspaceFiles/stat': (_) => {'absolutePath': '/w/a.png', 'version': 'v', 'bytes': 1},
        'workspaceFiles/readBytes': (_) => {
          'data': base64Encode([1, 2, 3]),
          'eof': true,
        },
      });
      final chunks = <Uint8List>[];
      await expectLater(
        DshClient.withCarrier(carrier).readFile('s', 'a.png', maxBytes: 2, onChunk: chunks.add),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/too-large')),
      );
      expect(chunks, isEmpty);
    });

    test('a carrier without readBytes says so', () async {
      final carrier = _BytesCarrier(
        {
          'workspaceFiles/stat': (_) => {'absolutePath': '/w/a', 'version': 'v'},
        },
        allowed: {'workspaceFiles/stat'},
      );
      final client = DshClient.withCarrier(carrier);
      expect(client.canReadFileBytes, isFalse);
      await expectLater(
        client.readFileBytes('s', 'a'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/unsupported')),
      );
    });

    test('HTTP carrier, undecodable readBytes: falls back to GET /api/file', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      server.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        if (request.method == 'POST' && request.uri.path == '/api/workspaceFiles/stat') {
          final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final path = ((envelope['payload'] as Map)['args'] as Map)['path'];
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'type': 'server-response',
                'rpcId': envelope['rpcId'],
                'result': {
                  'ok': true,
                  'value': {'absolutePath': '/root/workspace/$path', 'version': 'v', 'bytes': 4},
                },
              }),
            );
        } else if (request.uri.path == '/api/file') {
          final path = request.uri.queryParameters['path'];
          if (path == '/root/workspace/out/chart.png') {
            request.response
              ..headers.contentType = ContentType('image', 'png')
              ..add([1, 2, 3, 4]);
          } else {
            request.response
              ..statusCode = 404
              ..write('FS_NOT_FOUND');
          }
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      final bytes = await client.readFileBytes('s', 'out/chart.png', maxBytes: 4);
      expect(bytes, [1, 2, 3, 4]);
      expect(seen.last, 'GET /api/file?path=%2Froot%2Fworkspace%2Fout%2Fchart.png');
      await expectLater(
        client.readFileBytes('s', 'out/missing.png'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/not-found')),
      );
    });

    test('HTTP fallback enforces maxBytes while reading a stale-size response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/api/workspaceFiles/stat') {
          final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'type': 'server-response',
              'rpcId': envelope['rpcId'],
              'result': {
                'ok': true,
                'value': {'absolutePath': '/w/a.png', 'version': 'v', 'bytes': 1},
              },
            }),
          );
        } else if (request.uri.path == '/api/file') {
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      final chunks = <Uint8List>[];
      await expectLater(
        client.readFile('s', 'a.png', maxBytes: 2, onChunk: chunks.add),
        throwsA(isA<DshProtocolException>()),
      );
      expect(chunks, isEmpty);
    });

    test('HTTP carrier: multipart readBytes windows and Office PDFs', () async {
      final content = Uint8List.fromList(List.generate(fileWindowBytes + 7, (i) => (i * 7) % 256));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoints = <String>[];
      server.listen((request) async {
        final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final args = ((envelope['payload'] as Map)['args'] as Map).cast<String, Object?>();
        final endpoint = request.uri.path.substring('/api/'.length);
        endpoints.add(endpoint);
        final stat = {'absolutePath': '/w/${args['path']}', 'version': 'v', 'bytes': content.length};
        if (endpoint == 'workspaceFiles/stat') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'type': 'server-response',
                'rpcId': envelope['rpcId'],
                'result': {'ok': true, 'value': stat},
              }),
            );
        } else {
          final Uint8List bytes;
          final Map<String, Object?> value;
          if (endpoint == 'officeToPdf/render') {
            bytes = Uint8List.fromList(utf8.encode('%PDF-1.7 fake'));
            value = {
              ...stat,
              'offset': 0,
              'eof': true,
              'data': null,
              'missingFonts': ['Calibri'],
              'generation': 'g1',
            };
          } else {
            final range = (args['options'] as Map)['range'] as Map;
            final offset = range['offset'] as int;
            final end = (offset + (range['length'] as int)).clamp(0, content.length);
            bytes = content.sublist(offset, end);
            value = {...stat, 'offset': offset, 'eof': end >= content.length, 'data': null};
          }
          // The Host's Connection answer: undici's FormData encoding.
          const boundary = '----formdata-undici-0123456789';
          final metadata = jsonEncode({
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {'ok': true, 'value': value},
            'attachments': [
              {
                'path': ['data'],
                'codec': 'bytes',
                'part': 'bytes-0',
              },
            ],
          });
          request.response.headers.set('content-type', 'multipart/form-data; boundary=$boundary');
          request.response
            ..add(
              utf8.encode(
                '--$boundary\r\nContent-Disposition: form-data; name="bytes-0"; filename="blob"\r\n'
                'Content-Type: application/octet-stream\r\n\r\n',
              ),
            )
            ..add(bytes)
            ..add(utf8.encode('\r\n--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\n\r\n'))
            ..add(utf8.encode(metadata))
            ..add(utf8.encode('\r\n--$boundary--\r\n'));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      expect(await client.readFileBytes('s', 'big.bin'), content);
      expect(endpoints, ['workspaceFiles/stat', 'workspaceFiles/readBytes', 'workspaceFiles/readBytes']);

      final office = await client.renderOfficePdf('s', 'deck.pptx');
      expect(utf8.decode(office.pdf), '%PDF-1.7 fake');
      expect(office.missingFonts, ['Calibri']);
    });
  });

  group('decodeBinaryResponse', () {
    Uint8List body(String boundary, Map<String, List<int>> parts) => Uint8List.fromList([
      for (final MapEntry(:key, :value) in parts.entries) ...[
        ...utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="$key"\r\n\r\n'),
        ...value,
        ...utf8.encode('\r\n'),
      ],
      ...utf8.encode('--$boundary--'),
    ]);
    List<int> meta(Object? value, List<Object?> attachments) => utf8.encode(
      jsonEncode({
        'type': 'server-response',
        'rpcId': 'r1',
        'result': {'ok': true, 'value': value},
        'attachments': attachments,
      }),
    );

    test('fills nested placeholders; bytes may contain CRLF and dashes', () {
      final tricky = [13, 10, 45, 45, 0, 255, 13, 10];
      final decoded = decodeBinaryResponse(
        body('b', {
          'metadata': meta(
            {
              'pages': [
                {'png': null},
                {'png': null},
              ],
            },
            [
              {
                'path': ['pages', 0, 'png'],
                'codec': 'bytes',
                'part': 'p0',
              },
              {
                'path': ['pages', 1, 'png'],
                'codec': 'bytes',
                'part': 'p1',
              },
            ],
          ),
          'p0': tricky,
          'p1': [1],
        }),
        'b',
      );
      final pages = ((decoded['result'] as Map)['value'] as Map)['pages'] as List;
      expect((pages[0] as Map)['png'], tricky);
      expect((pages[1] as Map)['png'], [1]);
      expect(decoded['rpcId'], 'r1');
    });

    test('malformed bodies are protocol errors', () {
      final Matcher fails = throwsA(isA<DshProtocolException>());
      expect(() => decodeBinaryResponse(Uint8List.fromList(utf8.encode('nothing')), 'b'), fails);
      final attachment = {
        'path': ['data'],
        'codec': 'bytes',
        'part': 'p0',
      };
      expect(
        () => decodeBinaryResponse(
          body('b', {
            'metadata': meta({'data': null}, [attachment]),
          }),
          'b',
        ),
        fails,
        reason: 'missing part',
      );
      expect(
        () => decodeBinaryResponse(
          body('b', {
            'metadata': meta({'data': 'x'}, [attachment]),
            'p0': [1],
          }),
          'b',
        ),
        fails,
        reason: 'placeholder not null',
      );
      expect(
        () => decodeBinaryResponse(
          body('b', {
            'metadata': meta({'data': null}, [attachment]),
            'p0': [1],
            'p9': [2],
          }),
          'b',
        ),
        fails,
        reason: 'unclaimed part',
      );
      expect(
        () => decodeBinaryResponse(
          body('b', {
            'p0': [1],
          }),
          'b',
        ),
        fails,
        reason: 'no metadata',
      );
    });
  });
}
