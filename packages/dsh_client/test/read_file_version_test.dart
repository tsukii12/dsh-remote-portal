import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// Real loopback HTTP and public readFile, without mocked private SDK methods.
class _Files {
  _Files(this.server, this.statVersion, this.versions);
  final HttpServer server;
  final String? statVersion;
  final List<String?> versions;
  final offsets = <int>[], errors = <Object>[];
  int fallbackReads = 0;
  late final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
  static Future<_Files> start(String? statVersion, List<String?> versions) async {
    final host = _Files(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), statVersion, versions);
    host.server.listen((request) async {
      try {
        if (request.uri.path == '/api/file') {
          host.fallbackReads++;
          request.response.add([9, 9]);
        } else {
          final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          Map<String, Object?> value;
          if (request.uri.path == '/api/workspaceFiles/stat') {
            value = {
              'absolutePath': '/synthetic/file',
              'bytes': versions.length * 2,
              'version': ?statVersion,
            };
          } else if (request.uri.path == '/api/workspaceFiles/readBytes') {
            final args = (envelope['payload'] as Map)['args'] as Map;
            final range = (args['options'] as Map)['range'] as Map;
            host.offsets.add(range['offset'] as int);
            final index = host.offsets.length - 1;
            value = {
              'absolutePath': '/synthetic/file',
              'bytes': versions.length * 2,
              'offset': range['offset'],
              'data': [index * 2 + 1, index * 2 + 2],
              'eof': index == versions.length - 1,
              'version': ?versions[index],
            };
          } else {
            throw StateError('Unexpected route ${request.uri.path}');
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'type': 'server-response',
              'rpcId': envelope['rpcId'],
              'result': {'ok': true, 'value': value},
            }),
          );
        }
        await request.response.close();
      } catch (error) {
        host.errors.add(error);
        request.response.statusCode = 500;
        await request.response.close();
      }
    });
    return host;
  }

  Future<void> close() async {
    await client.close();
    await server.close(force: true);
  }
}

Matcher get changed => isA<DshRemoteException>().having((error) => error.code, 'code', 'workspace-file/changed').having(
  (error) => error.details,
  'details',
  {'path': 'file'},
);
void main() {
  for (final scenario in <({String name, String? stat, List<String?> pages, int? rejected})>[
    (name: 'stable versions', stat: 'v1', pages: ['v1', 'v1'], rejected: null),
    (name: 'legacy missing versions', stat: null, pages: [null, null], rejected: null),
    (name: 'empty versions are absent', stat: '', pages: ['', null], rejected: null),
    (name: 'missing pages retain stat expectation', stat: 'v1', pages: [null, '', 'v1'], rejected: null),
    (name: 'first page changed since stat', stat: 'v1', pages: ['v2', 'v2'], rejected: 0),
    (name: 'second page changed', stat: 'v1', pages: ['v1', 'v2'], rejected: 1),
    (name: 'first available page establishes version', stat: null, pages: ['v1', 'v2'], rejected: 1),
    (name: 'late available page establishes version', stat: '', pages: [null, 'v1', 'v2'], rejected: 2),
    (name: 'missing page cannot reset version', stat: 'v1', pages: ['v1', null, 'v2'], rejected: 2),
  ]) {
    test(scenario.name, () async {
      final host = await _Files.start(scenario.stat, scenario.pages);
      addTearDown(host.close);
      final chunks = <List<int>>[], progress = <int>[];
      final read = host.client.readFile(
        's',
        'file',
        onChunk: (bytes) => chunks.add(bytes.toList()),
        onProgress: (received, _) => progress.add(received),
      );
      final rejected = scenario.rejected;
      if (rejected == null) {
        expect(await read, scenario.pages.length * 2);
      } else {
        await expectLater(read, throwsA(changed));
      }
      final delivered = rejected ?? scenario.pages.length;
      expect(chunks, [
        for (var i = 0; i < delivered; i++) [i * 2 + 1, i * 2 + 2],
      ]);
      expect(progress, [for (var i = 0; i <= delivered; i++) i * 2]);
      expect(host.offsets, [for (var i = 0; i < (rejected == null ? delivered : delivered + 1); i++) i * 2]);
      expect(host.fallbackReads, 0);
      expect(host.errors, isEmpty);
    });
  }
  test('async consumer finishes before changed window is requested and rejected', () async {
    final host = await _Files.start('v1', ['v1', 'v2']);
    addTearDown(host.close);
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final chunks = <List<int>>[], progress = <int>[];
    final read = host.client.readFile(
      's',
      'file',
      onChunk: (bytes) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        chunks.add(bytes.toList());
      },
      onProgress: (received, _) => progress.add(received),
    );
    final rejected = expectLater(read, throwsA(changed));
    await entered.future;
    expect(host.offsets, [0]);
    expect(progress, [0]);
    release.complete();
    await rejected;
    expect(chunks, [
      [1, 2],
    ]);
    expect(progress, [0, 2]);
    expect(host.offsets, [0, 2]);
    expect(host.fallbackReads, 0);
    expect(host.errors, isEmpty);
  });
}
