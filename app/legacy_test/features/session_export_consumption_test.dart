// Controlled native-consumption boundary, not an Android device test.
// Production page/exporter/client/files channel; actual loopback HTTP and files.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_export.dart';
import 'package:dsh_app/ui/features/session_export_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/session_sync_host.dart' show RealSyncHttp;

class _Save {
  _Save(this.path);
  final String path;
  final release = Completer<void>();
  List<int>? consumed;
}

Future<void> _until(WidgetTester tester, bool Function() done, String reason) async {
  for (var i = 0; i < 300; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('did not settle: $reason');
}

class _ConsumeChannel extends FilesChannel {
  _ConsumeChannel(this.consume);
  final Future<String> Function(String path) consume;
  @override
  Future<String> saveToDownloads(String path, {required String name, required String mime}) {
    expect(name, 'dsh-session-S.zip');
    expect(mime, 'application/zip');
    return consume(path);
  }
}

void main() {
  setUpAll(loadTestFonts);
  group('isolated Downloads sources', () {
    late HttpServer server;
    late Directory cache;
    late DshClient client;
    var payload = <int>[];
    var status = 200;
    setUp(() async {
      payload = [0x50, 0x4b, 1, 1];
      status = 200;
      await HttpOverrides.runWithHttpOverrides(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.statusCode = status;
          request.response.add(payload);
          await request.response.close();
        });
        cache = await Directory.systemTemp.createTemp('session-save');
        client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      }, RealSyncHttp());
    });
    tearDown(() async {
      await client.close();
      await server.close(force: true);
      await cache.delete(recursive: true);
    });
    SessionLogExporter exporter(Future<String> Function(String) consume) => SessionLogExporter(
      connection: HostConnection(hostId: '', client: client, isLocal: true, label: 'same Host'),
      channel: _ConsumeChannel(consume),
      cacheRoot: () async => cache,
    );
    for (final failure in [false, true]) {
      for (final missingAtCleanup in [false, true]) {
        test('source lifetime: failure=$failure missingAtCleanup=$missingAtCleanup', () async {
          String? source;
          final original = PlatformException(code: 'permission', message: 'original native failure');
          final operation = exporter((path) async {
            source = path;
            expect(await File(path).readAsBytes(), [0x50, 0x4b, 1, 1]);
            if (missingAtCleanup) await File(path).parent.delete(recursive: true);
            if (failure) throw original;
            return 'Download/DSH-Go/dsh-session-S.zip';
          }).saveToDownloads('S');
          if (failure) {
            await expectLater(operation, throwsA(same(original)));
          } else {
            expect(await operation, 'Download/DSH-Go/dsh-session-S.zip');
          }
          expect(source, isNotNull);
          expect(await File(source!).parent.exists(), isFalse);
        });
      }
    }
    test('concurrent saves own distinct source paths until their native completion', () async {
      final received = Completer<void>();
      final release = Completer<void>();
      String? aPath;
      String? bPath;
      final a = exporter((path) async {
        aPath = path;
        received.complete();
        await release.future;
        expect(await File(path).readAsBytes(), [0x50, 0x4b, 1, 1]);
        return 'A';
      }).saveToDownloads('S');
      await received.future;
      payload = [0x50, 0x4b, 2, 2];
      expect(
        await exporter((path) async {
          bPath = path;
          expect(await File(path).readAsBytes(), [0x50, 0x4b, 2, 2]);
          return 'B';
        }).saveToDownloads('S'),
        'B',
      );
      expect(aPath, isNot(bPath));
      expect(await File(aPath!).exists(), isTrue);
      expect(await File(bPath!).exists(), isFalse);
      release.complete();
      expect(await a, 'A');
      expect(await Directory('${cache.path}/exports').list().toList(), isEmpty);
    });
    test('download failure creates no operation directory or native request', () async {
      status = 500;
      var consumed = false;
      await expectLater(
        exporter((_) async {
          consumed = true;
          return 'unexpected';
        }).saveToDownloads('S'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session-export/http-500')),
      );
      expect(consumed, isFalse);
      expect(await Directory('${cache.path}/exports').exists(), isFalse);
    });
  });

  for (final reopen in [false, true]) {
    testWidgets(
      reopen
          ? 'leaving and reopening permits export B before native consumption A'
          : 'one page blocks a second export until native consumption completes',
      (tester) async {
        late HttpServer server;
        late Directory cache;
        late DshClient client;
        var payload = <int>[0x50, 0x4b, 1, 1];
        var requests = 0;
        final saves = <_Save>[];
        const channel = MethodChannel('dsh/files');
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            server.listen((request) async {
              requests++;
              request.response.headers.contentType = ContentType('application', 'zip');
              request.response.add(payload);
              await request.response.close();
            });
            cache = await Directory.systemTemp.createTemp('session-consume');
            client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
          }, RealSyncHttp()),
        );
        final connection = HostConnection(hostId: '', client: client, isLocal: true, label: 'same Host');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveToDownloads');
          final save = _Save((call.arguments as Map)['path'] as String);
          saves.add(save);
          // Kotlin FilesPlugin queues a worker/permission continuation before
          // file.inputStream/copyTo. Hold this same pre-read boundary explicitly.
          if (saves.length == 1) await save.release.future;
          save.consumed = await File(save.path).readAsBytes();
          return 'Download/DSH-Go/${(call.arguments as Map)['name']}';
        });
        usePhoneView(tester);
        try {
          await tester.pumpWidget(
            testApp(
              Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => const SessionExportPage(sessionId: 'S'))),
                      child: const Text('open export'),
                    ),
                  ),
                ),
              ),
              overrides: [
                activeConnectionProvider.overrideWithValue(AsyncData(connection)),
                sessionLogExporterProvider.overrideWithValue(
                  SessionLogExporter(
                    connection: connection,
                    channel: const FilesChannel(),
                    cacheRoot: () async => cache,
                  ),
                ),
              ],
            ),
          );
          await tester.tap(find.text('open export'));
          await pumpFrames(tester, 12);
          await tester.tap(find.text('存到「下载」'));
          await _until(tester, () => saves.length == 1, 'A handed its path to native channel');
          final a = saves.single;
          expect(a.consumed, isNull);
          final bytesAtHandoff = await tester.runAsync(() => File(a.path).readAsBytes());
          expect(bytesAtHandoff, [0x50, 0x4b, 1, 1]);
          payload = [0x50, 0x4b, 2, 2];
          if (reopen) {
            await tester.tap(find.byTooltip('返回'));
            await pumpFrames(tester, 16);
            expect(find.byType(SessionExportPage), findsNothing);
            await tester.tap(find.text('open export'));
            await pumpFrames(tester, 12);
            await tester.tap(find.text('存到「下载」'));
            await _until(
              tester,
              () => saves.length == 2 && saves[1].consumed != null,
              'B consumed from reopened real page',
            );
            expect(saves[1].consumed, [0x50, 0x4b, 2, 2]);
            expect(saves[1].path.split('/').last, a.path.split('/').last);
            expect(requests, 2);
          } else {
            await tester.tap(find.text('存到「下载」'));
            await pumpFrames(tester, 8);
            expect(requests, 1);
            expect(saves.length, 1);
          }
          a.release.complete();
          await _until(tester, () => a.consumed != null, 'A native consumption resumes');
          expect(a.consumed, [
            0x50,
            0x4b,
            1,
            1,
          ], reason: 'A export must consume its own fetched archive, not reopened B bytes');
        } finally {
          for (final save in saves) {
            if (!save.release.isCompleted) save.release.complete();
          }
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await client.close();
            await server.close(force: true);
            await cache.delete(recursive: true);
          });
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}
