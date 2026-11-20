// Real exporter, HTTP, SharePlus Dart path preparation and temporary files.
// Only the native share channel's queued read/result boundary is controlled.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_export.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _share = MethodChannel('dev.fluttercommunity.plus/share');
const _paths = MethodChannel('plugins.flutter.io/path_provider');
const _unavailable = 'dev.fluttercommunity.plus/share/unavailable';

class _RealHttp extends HttpOverrides {}

// An empty ZIP with a one-byte comment distinguishes the two valid archives.
List<int> _archive(int marker) => [0x50, 0x4b, 0x05, 0x06, ...List.filled(16, 0), 1, 0, marker];

class _QueuedShare {
  _QueuedShare(MethodCall call) {
    expect(call.method, 'share');
    final args = call.arguments as Map;
    path = (args['paths'] as List).single as String;
    expect(args['mimeTypes'], ['application/zip']);
    expect(File(path).uri.pathSegments.last, 'dsh-session-S.zip');
  }

  late final String path;
  final reply = Completer<String>();
}

void main() {
  final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  late HttpServer server;
  late Directory cache;
  late DshClient client;
  late SessionLogExporter exporter;
  var payload = _archive(1);
  var status = HttpStatus.ok;
  final requests = <Uri>[];

  setUp(() async {
    payload = _archive(1);
    status = HttpStatus.ok;
    requests.clear();
    await HttpOverrides.runWithHttpOverrides(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request.uri);
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType('application', 'zip');
        request.response.add(payload);
        await request.response.close();
      });
      client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      cache = await Directory.systemTemp.createTemp('session-share-source-');
    }, _RealHttp());
    exporter = SessionLogExporter(
      connection: HostConnection(hostId: '', client: client, isLocal: true, label: 'test Host'),
      channel: const FilesChannel(),
      cacheRoot: () async => cache,
    );
    // XFile.fromData must go through the actual locked plugin's file writer.
    messenger.setMockMethodCallHandler(_paths, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return cache.path;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_share, null);
    messenger.setMockMethodCallHandler(_paths, null);
    await client.close();
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  for (final earlyResult in [false, true]) {
    test('queued native read keeps its own archive; early share result=$earlyResult', () async {
      final calls = <_QueuedShare>[];
      final firstEntered = Completer<void>();
      final secondEntered = Completer<void>();
      messenger.setMockMethodCallHandler(_share, (call) {
        final queued = _QueuedShare(call);
        calls.add(queued);
        if (calls.length == 1) {
          firstEntered.complete();
        } else {
          // Android ShareSuccessManager.setCallback can complete A before
          // Share's serial IO queue has copied A. This is not a read receipt.
          if (earlyResult) calls.first.reply.complete(_unavailable);
          secondEntered.complete();
        }
        return queued.reply.future;
      });
      Future<void>? second;
      final first = exporter.share('S');
      try {
        await firstEntered.future;
        expect(await File(calls.first.path).readAsBytes(), _archive(1));
        payload = _archive(2);
        second = exporter.share('S');
        await secondEntered.future;
        if (earlyResult) await first;

        // Resume the actual-path read in native queue order, A then B.
        // No share_plus Android cache, Intent or recipient is simulated here.
        expect(
          await File(calls.first.path).readAsBytes(),
          _archive(1),
          reason: 'the first queued copy must not read the later export',
        );
        expect(await File(calls.last.path).readAsBytes(), _archive(2));
        expect(calls.first.path, isNot(calls.last.path));
        expect(requests, hasLength(2));
        for (final uri in requests) {
          expect(uri.path, '/api/session.export');
          expect(uri.queryParameters, {'sessionId': 'S', 'includeDescendants': 'true'});
        }
      } finally {
        for (final call in calls) {
          if (!call.reply.isCompleted) call.reply.complete(_unavailable);
        }
        await first;
        await second;
      }
    });
  }

  test('native share failure keeps its error after reading the original archive', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(_share, (call) async {
      calls++;
      final queued = _QueuedShare(call);
      expect(await File(queued.path).readAsBytes(), _archive(1));
      throw PlatformException(code: 'Share failed', message: 'controlled native copy failure');
    });
    await expectLater(
      exporter.share('S'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'Share failed')),
    );
    expect(calls, 1);
  });

  test('HTTP failure never starts the platform share', () async {
    status = HttpStatus.internalServerError;
    var called = false;
    messenger.setMockMethodCallHandler(_share, (_) async {
      called = true;
      return _unavailable;
    });
    await expectLater(
      exporter.share('S'),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session-export/http-500')),
    );
    expect(called, isFalse);
    expect(await cache.list().toList(), isEmpty);
  });
}
