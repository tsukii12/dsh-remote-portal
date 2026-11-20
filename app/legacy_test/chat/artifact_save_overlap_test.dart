import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _channel = MethodChannel('dsh/files');
const _artifacts = [
  Artifact(path: '/home/me/a.zip', origin: ArtifactOrigin.linked, turn: 1),
  Artifact(path: '/home/me/b.zip', origin: ArtifactOrigin.linked, turn: 1),
];

class _Downloads extends DshCarrier {
  final entered = List.generate(2, (_) => Completer<void>());
  final release = List.generate(2, (_) => Completer<void>());

  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final index = _artifacts.indexWhere((artifact) => artifact.path == args['path']);
    if (index < 0) return const RpcError(DshRemoteException('gateway/not-found', 'unknown path'));
    final bytes = utf8.encode('file-$index');
    final stat = {'absolutePath': _artifacts[index].path, 'version': 'v1', 'bytes': bytes.length};
    if (endpoint == 'workspaceFiles/stat') return RpcOk(stat);
    if (endpoint == 'workspaceFiles/readBytes') {
      entered[index].complete();
      await release[index].future;
      return RpcOk({...stat, 'offset': 0, 'data': base64Encode(bytes), 'eof': true});
    }
    return const RpcError(DshRemoteException('gateway/not-found', 'unused endpoint'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<void> close() async {}
}

// Observe the real action, including failures before it reaches native.
// No download, cache, FilesChannel or error handling is replaced.
class _ObservedFiles extends ArtifactFiles {
  _ObservedFiles({required HostConnection connection, required Directory cache})
    : super(connection: connection, channel: const FilesChannel(), cacheRoot: () async => cache);

  final started = <int>{};
  final terminal = List.generate(2, (_) => Completer<void>());
  final errors = <int, Object>{};

  @override
  Future<String> saveToDownloads(String sessionId, Artifact artifact, {void Function(double?)? onProgress}) async {
    final index = _artifacts.indexWhere((entry) => entry.path == artifact.path);
    started.add(index);
    try {
      return await super.saveToDownloads(sessionId, artifact, onProgress: onProgress);
    } catch (error) {
      errors[index] = error;
      rethrow; // ArtifactTile._run remains the owner of the action error.
    } finally {
      terminal[index].complete();
    }
  }

  Future<T> beforeTerminal<T>(int index, Future<T> entered) async {
    final result = await Future.any<Object?>([
      entered.then<Object?>((value) => (value,)),
      terminal[index].future.then<Object?>((_) => null),
    ]);
    if (result == null) {
      throw StateError('save $index ended before the expected boundary: ${errors[index]}');
    }
    return (result as (T,)).$1;
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('two started tile downloads reach native save while the first reply is pending', (tester) async {
    usePhoneView(tester);
    final cache = Directory.systemTemp.createTempSync('artifact-save-overlap-');
    late _Downloads downloads;
    late DshClient client;
    late HostConnection remote;
    late _ObservedFiles files;
    late List<Completer<Map<String, Object?>>> nativeEntered;
    late List<Completer<void>> nativeRelease;
    late List<Completer<void>> nativeFinished;
    // Async completers retain their creation zone. All real-IO boundaries and
    // the client owning stream-close futures must be created in the real zone.
    await tester.runAsync(() async {
      downloads = _Downloads();
      client = DshClient.withCarrier(downloads);
      remote = HostConnection(client: client, label: 'remote', isLocal: false, hostId: 'remote');
      nativeEntered = List.generate(2, (_) => Completer<Map<String, Object?>>());
      nativeRelease = List.generate(2, (_) => Completer<void>());
      nativeFinished = List.generate(2, (_) => Completer<void>());
      files = _ObservedFiles(connection: remote, cache: cache);
    });
    final calls = <Map<String, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'saveToDownloads') throw StateError('unexpected ${call.method}');
      final args = (call.arguments as Map).cast<String, Object?>();
      final index = _artifacts.indexWhere((artifact) => artifact.name == args['name']);
      calls.add(args);
      nativeEntered[index].complete(args);
      try {
        await nativeRelease[index].future;
        return 'Download/DSH-Go/${args['name']}';
      } finally {
        nativeFinished[index].complete();
      }
    });

    try {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ArtifactCard(
              sessionId: 's1',
              group: const TurnArtifacts(turn: 1, endSeq: 9, files: _artifacts),
            ),
          ),
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(remote)),
            artifactFilesProvider.overrideWithValue(files),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactTile), findsNWidgets(2));

      for (var index = 0; index < 2; index++) {
        // Create the menu/action continuation in the real async zone so its
        // materialize call can perform actual file IO without polling sleeps.
        final tile = find.byWidgetPredicate(
          (widget) => widget is ArtifactTile && widget.artifact.path == _artifacts[index].path,
        );
        expect(tile, findsOneWidget);
        final menu = find.descendant(of: tile, matching: find.byTooltip('更多操作'));
        expect(menu, findsOneWidget);
        await tester.runAsync(() => tester.tap(menu));
        await tester.pump();
        // Virtual animation time only; the first tile may already be spinning.
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => tester.tap(find.text('存到「下载」')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(files.started, contains(index), reason: 'menu must start the real save before waiting for IO');
        await tester.runAsync(() async {
          await files.beforeTerminal(index, downloads.entered[index].future);
        });
      }
      expect(downloads.entered.every((entry) => entry.isCompleted), isTrue);
      expect(calls, isEmpty, reason: 'both real downloads started before either native save');

      await tester.runAsync(() async {
        downloads.release[0].complete();
        final first = await files.beforeTerminal(0, nativeEntered[0].future);
        expect(await File(first['path']! as String).readAsString(), 'file-0');
        expect(nativeFinished[0].isCompleted, isFalse);
        // No UI action occurs after A enters native. B was already downloading.
        downloads.release[1].complete();
        final second = await files.beforeTerminal(1, nativeEntered[1].future);
        expect(await File(second['path']! as String).readAsString(), 'file-1');
        expect(nativeFinished[0].isCompleted, isFalse);
        expect(calls.map((call) => call['name']), ['a.zip', 'b.zip']);
        expect(first['path'], isNot(second['path']));
      });
    } finally {
      // Release all gates even if an assertion fails. Widget _run owns action
      // errors; these gates only hold successful Host/native responses.
      await tester.runAsync(() async {
        for (final gate in [...downloads.release, ...nativeRelease]) {
          if (!gate.isCompleted) gate.complete();
        }
        // Join actual actions, including materialize failures before native.
        await Future.wait([for (final index in files.started) files.terminal[index].future]);
        await Future.wait([
          for (var index = 0; index < 2; index++)
            if (nativeEntered[index].isCompleted) nativeFinished[index].future,
        ]);
      });
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(_channel, null);
      await tester.runAsync(() async {
        await client.close();
        await cache.delete(recursive: true);
      });
    }
  });
}
