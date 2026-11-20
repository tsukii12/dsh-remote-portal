import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _LoopbackBinding();
  for (final badCache in [true, false]) {
    for (final stop in ['complete', 'headers', 'body']) {
      test('${badCache ? 'bad complete cache' : 'uncached control'} $stop: downloading phase and retry', () async {
        final dir = await Directory.systemTemp.createTemp('updater-retry-phase-');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        const name = 'dsh-go-1.2.0-arm64.apk';
        final bytes = Uint8List.fromList(List.generate(1024 * 1024, (i) => i % 251));
        final target = File('${dir.path}/$name');
        if (badCache) await target.writeAsBytes(Uint8List(bytes.length));
        final headersEntered = Completer<void>();
        final sendHeaders = Completer<void>();
        final sendRest = Completer<void>();
        final bodyProgress = Completer<void>();
        final errors = <Object>[];
        var requests = 0;
        final serverFinished = Completer<void>();
        final serving = server.listen((request) async {
          try {
            requests++;
            if (requests > 1) {
              request.response.contentLength = bytes.length;
              request.response.add(bytes);
              await request.response.close();
              return;
            }
            headersEntered.complete();
            await sendHeaders.future;
            request.response.contentLength = bytes.length;
            request.response.add(bytes.sublist(0, 600 * 1024));
            await request.response.flush();
            await sendRest.future;
            request.response.add(bytes.sublist(600 * 1024));
            await request.response.close();
          } catch (e) {
            // A deliberately cancelled HTTP response may close at the server.
            if (stop == 'complete' || e is! HttpException && e is! SocketException) errors.add(e);
          } finally {
            if (!serverFinished.isCompleted) serverFinished.complete();
          }
        });
        SharedPreferences.setMockInitialValues({
          'update_latest': jsonEncode({
            'schema': 1,
            'version': '1.2.0',
            'tag': 'v1.2.0',
            'assets': {
              'arm64': {
                'name': name,
                'url': 'http://127.0.0.1:${server.port}/$name',
                'size': bytes.length,
                'sha256': sha256.convert(bytes).toString(),
              },
            },
          }),
        });
        final installer = FakeInstaller();
        final container = ProviderContainer(
          overrides: [
            updateHttpProvider.overrideWithValue(IoUpdateHttp()),
            updateInstallerProvider.overrideWithValue(installer),
            updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [])),
            updateFlavorNameProvider.overrideWithValue('arm64'),
            updateDirectoryProvider.overrideWithValue(() async => dir),
          ],
        );
        Future<void>? pending;
        addTearDown(() async {
          if (!sendHeaders.isCompleted) sendHeaders.complete();
          if (!sendRest.isCompleted) sendRest.complete();
          await pending;
          container.dispose();
          await server.close(force: true);
          await serving.cancel();
          await dir.delete(recursive: true);
          expect(errors, isEmpty);
        });
        final controller = container.read(appUpdateProvider.notifier);
        await controller.ready;
        container.listen(appUpdateProvider, (_, next) {
          if (next.received >= 512 * 1024 && !bodyProgress.isCompleted) bodyProgress.complete();
        });
        pending = controller.startDownload();
        await headersEntered.future.timeout(const Duration(seconds: 5));
        final duringHeaders = container.read(appUpdateProvider).task;
        expect(await target.exists(), isFalse, reason: 'bad cached file was really hashed and removed');
        if (stop == 'headers') controller.cancelDownload();
        sendHeaders.complete();
        UpdateTaskPhase? duringBody;
        if (stop != 'headers') {
          await bodyProgress.future.timeout(const Duration(seconds: 5));
          duringBody = container.read(appUpdateProvider).task;
          if (stop == 'body') controller.cancelDownload();
        }
        if (stop != 'complete') {
          await pending;
          expect(container.read(appUpdateProvider).task, UpdateTaskPhase.idle);
          expect(await target.exists(), isFalse);
        }
        sendRest.complete();
        await serverFinished.future.timeout(const Duration(seconds: 5));
        await pending;
        if (stop != 'complete') {
          pending = controller.startDownload();
          await pending;
        }
        expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
        expect(await target.readAsBytes(), bytes);
        expect(requests, stop == 'complete' ? 1 : 2);
        expect(installer.installed, isEmpty);
        expect(duringHeaders, UpdateTaskPhase.downloading);
        if (duringBody != null) expect(duringBody, UpdateTaskPhase.downloading);
      });
    }
  }
}
