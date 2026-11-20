import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// The production readFile loop owns all sequencing; this carrier only answers windows.
class _Windows extends DshCarrier {
  int reads = 0;
  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'workspaceFiles/stat') {
      return const RpcOk({'absolutePath': '/w/file', 'bytes': 4, 'version': 'v1'});
    }
    if (endpoint == 'workspaceFiles/readBytes') {
      reads++;
      return RpcOk({
        'data': reads == 1 ? [1, 2] : [3, 4],
        'eof': reads > 1,
        'bytes': 4,
      });
    }
    throw StateError('Unexpected endpoint: $endpoint');
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {}
}

/// Real HTTP decoding and fallback. No mocked private SDK methods.
class _HttpFiles {
  _HttpFiles(this.server, this.malformed);
  final HttpServer server;
  final bool malformed;
  int reads = 0;
  int gets = 0;
  final errors = <Object>[];
  late final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));

  static Future<_HttpFiles> start({required bool malformed}) async {
    final host = _HttpFiles(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), malformed);
    host.server.listen((request) async {
      try {
        if (request.uri.path == '/api/file') {
          host.gets++;
          request.response.add([1, 2, 3, 4]);
        } else {
          final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          Object value;
          if (request.uri.path == '/api/workspaceFiles/stat') {
            value = {'absolutePath': '/w/file', 'bytes': 4, 'version': 'v1'};
          } else if (request.uri.path == '/api/workspaceFiles/readBytes') {
            host.reads++;
            if (malformed) {
              // Same real undecodable-first-response condition as deliverables_test.
              request.response.write('not an RPC envelope');
              await request.response.close();
              return;
            }
            value = {
              'data': host.reads == 1 ? [1, 2] : [3, 4],
              'eof': host.reads > 1,
              'bytes': 4,
            };
          } else {
            throw StateError('Unexpected URI: ${request.uri}');
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

/// Observes both error channels; no ignored async consumer failure can count as success.
Future<({Object result, List<Object> zoneErrors})> _failure(
  Future<int> Function(Future<void> Function(Object) failConsumer) read,
) async {
  final parentZone = Zone.current;
  final settled = Completer<Object>();
  final consumers = <Completer<void>>[];
  final zoneErrors = <Object>[];
  Future<void> failConsumer(Object error) async {
    final terminal = Completer<void>();
    consumers.add(terminal);
    try {
      await Future<void>.value();
      throw error;
    } finally {
      // This separate successful signal does not attach an error handler to the
      // consumer Future. The old void API must still expose its real zone leak.
      terminal.complete();
    }
  }

  unawaited(
    runZonedGuarded(
      () async {
        try {
          settled.complete(await read(failConsumer));
        } catch (error) {
          settled.complete(error);
        }
      },
      (error, stack) {
        zoneErrors.add(error);
        parentZone.handleUncaughtError(error, stack);
      },
    ),
  );
  final result = await settled.future;
  // No more consumers can start after this readFile terminates. Join every one
  // it started, including the extra windows the old API erroneously delivered.
  await Future.wait(consumers.map((consumer) => consumer.future));
  // Do not await a predicted number of zone errors: a broken implementation may
  // swallow a consumer error and return success. The result assertion must then
  // fail promptly. The captured parent zone also receives every uncaught error,
  // including one delivered after this helper returns.
  return (result: result, zoneErrors: zoneErrors);
}

void main() {
  test('an async chunk holds the next window and progress until it is consumed', () async {
    final carrier = _Windows();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    final entered = Completer<void>();
    final release = Completer<void>();
    final consumed = Completer<void>();
    final progress = <int>[];
    final bytes = BytesBuilder();
    var chunks = 0;
    final reading = client.readFile(
      's',
      'file',
      onChunk: (chunk) async {
        if (chunks++ == 0) {
          entered.complete();
          await release.future;
          bytes.add(chunk);
          consumed.complete();
        } else {
          bytes.add(chunk);
        }
      },
      onProgress: (received, _) => progress.add(received),
    );
    await entered.future;
    final readsWhileHeld = carrier.reads;
    final progressWhileHeld = List<int>.of(progress);
    release.complete();
    final total = await reading;
    await consumed.future;
    expect(readsWhileHeld, 1);
    expect(progressWhileHeld, [0]);
    expect(total, 4);
    expect(bytes.takeBytes(), [1, 2, 3, 4]);
    expect(progress, [0, 2, 4]);
  });

  test('an async consumer error belongs to readFile and stops further windows', () async {
    final carrier = _Windows();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    final failure = StateError('consumer failed');
    final progress = <int>[];
    final observed = await _failure(
      (failConsumer) => client.readFile(
        's',
        'file',
        onChunk: (_) => failConsumer(failure),
        onProgress: (received, _) => progress.add(received),
      ),
    );
    expect(observed.zoneErrors, isEmpty);
    expect(observed.result, same(failure));
    expect(carrier.reads, 1);
    expect(progress, [0]);
  });

  for (final asynchronous in [false, true]) {
    test('HTTP ${asynchronous ? 'async' : 'sync'} consumer protocol error never requests fallback', () async {
      final host = await _HttpFiles.start(malformed: false);
      addTearDown(host.close);
      const failure = DshProtocolException('consumer protocol error');
      void syncFailure(Uint8List _) => throw failure;
      final observed = await _failure(
        (failConsumer) =>
            host.client.readFile('s', 'file', onChunk: asynchronous ? (_) => failConsumer(failure) : syncFailure),
      );
      expect(observed.zoneErrors, isEmpty);
      expect(observed.result, same(failure));
      expect(host.reads, 1);
      expect(host.gets, 0);
      expect(host.errors, isEmpty);
    });
  }

  test('a genuine first decode failure still falls back and awaits the async consumer', () async {
    final host = await _HttpFiles.start(malformed: true);
    addTearDown(host.close);
    final entered = Completer<void>();
    final release = Completer<void>();
    final consumed = Completer<void>();
    final progress = <int>[];
    var finished = false;
    final reading = host.client
        .readFile(
          's',
          'file',
          onChunk: (chunk) async {
            expect(chunk, [1, 2, 3, 4]);
            entered.complete();
            await release.future;
            consumed.complete();
          },
          onProgress: (received, _) => progress.add(received),
        )
        .whenComplete(() => finished = true);
    await entered.future;
    // Consumer entry completes before either implementation can settle readFile;
    // a microtask barrier lets the old non-awaiting completion become observable.
    await Future<void>.value();
    final finishedWhileHeld = finished;
    final progressWhileHeld = List<int>.of(progress);
    release.complete();
    final total = await reading;
    await consumed.future;
    expect(finishedWhileHeld, isFalse);
    expect(progressWhileHeld, [0]);
    expect(total, 4);
    expect(progress, [0, 4]);
    expect(host.reads, 1);
    expect(host.gets, 1);
    expect(host.errors, isEmpty);
  });

  test('an async fallback consumer error propagates without another request', () async {
    final host = await _HttpFiles.start(malformed: true);
    addTearDown(host.close);
    const failure = DshProtocolException('fallback consumer failed');
    final progress = <int>[];
    final observed = await _failure(
      (failConsumer) => host.client.readFile(
        's',
        'file',
        onChunk: (_) => failConsumer(failure),
        onProgress: (received, _) => progress.add(received),
      ),
    );
    expect(observed.zoneErrors, isEmpty);
    expect(observed.result, same(failure));
    expect(host.reads, 1);
    expect(host.gets, 1);
    expect(progress, [0]);
    expect(host.errors, isEmpty);
  });
}
