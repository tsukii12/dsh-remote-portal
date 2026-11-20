import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _engine = 'http://127.0.0.1:3080';
const _emoji = '$_engine/api/dsh-emoji/assets/deepseek/8/ds_01.png';

class _Reader implements WorkspaceImageReader {
  final reads = <String>[];
  bool fails = false;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add(path);
    if (fails) throw const DshHttpException(401, 'unauthorized');
    return RasterImage(MemoryImage(Uint8List(0)));
  }
}

class _Files extends Notifier<ArtifactFiles> {
  @override
  ArtifactFiles build() => _filesOn(_engine);

  void reconnect() => state = _filesOn(_engine);
}

ArtifactFiles _filesOn(String base) => ArtifactFiles(
  connection: HostConnection(hostId: '', 
    client: DshClient.withCarrier(DshHttpCarrier(DshConnection(Uri.parse(base)))),
    isLocal: true,
  ),
  channel: const FilesChannel(),
);

final _files = NotifierProvider<_Files, ArtifactFiles>(_Files.new);

void main() {
  late _Reader reader;

  Widget scene(String url) => testApp(
    Scaffold(body: MarkdownImage(url: url)),
    overrides: [
      artifactFilesProvider.overrideWith((ref) => ref.watch(_files)),
      engineImageReaderProvider.overrideWith((ref) {
        ref.watch(artifactFilesProvider);
        return CachedImageReader(reader);
      }),
    ],
  );

  setUp(() => reader = _Reader());

  // #361: the engine's own assets answer 401 to a plain NetworkImage.
  testWidgets('an image on the engine address is read through the session', (tester) async {
    await tester.pumpWidget(scene(_emoji));
    await tester.pump();
    expect(reader.reads, [_emoji]);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
  });

  testWidgets('a root-relative plugin image uses the authenticated engine reader', (tester) async {
    const url = '/api/dsh-emoji/assets/deepseek/8/ds_01.png';
    await tester.pumpWidget(scene(url));
    await tester.pump();
    expect(reader.reads, [url]);
    expect(find.textContaining('离线'), findsNothing);
    ProviderScope.containerOf(tester.element(find.byType(MarkdownImage))).read(_files.notifier).reconnect();
    await tester.pump();
    await tester.pump();
    expect(reader.reads, [url, url]);
  });

  testWidgets('an absolute workspace image keeps its file reader', (tester) async {
    final workspace = _Reader();
    await tester.pumpWidget(
      testApp(
        const MarkdownImageScope(
          sessionId: 's1',
          child: MarkdownImage(url: '/root/chart.png'),
        ),
        overrides: [
          artifactFilesProvider.overrideWith((ref) => ref.watch(_files)),
          engineImageReaderProvider.overrideWithValue(CachedImageReader(reader)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(workspace)),
        ],
      ),
    );
    await tester.pump();
    expect(reader.reads, isEmpty);
    expect(workspace.reads, ['/root/chart.png']);
  });

  testWidgets('an image on any other address stays a plain web image', (tester) async {
    await tester.pumpWidget(scene('https://example.com/a.png'));
    await tester.pump();
    expect(reader.reads, isEmpty);
  });

  testWidgets('a failed engine image shows why and a retry reads it again', (tester) async {
    reader.fails = true;
    await tester.pumpWidget(scene(_emoji));
    await tester.pump();
    await tester.pump();
    expect(reader.reads, [_emoji]);
    final retry = find.textContaining('重试');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    expect(reader.reads, [_emoji, _emoji]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replaced connection reads the image again through the new one', (tester) async {
    reader.fails = true;
    await tester.pumpWidget(scene(_emoji));
    await tester.pump();
    await tester.pump();
    expect(reader.reads, [_emoji]);
    reader.fails = false;
    ProviderScope.containerOf(tester.element(find.byType(MarkdownImage))).read(_files.notifier).reconnect();
    await tester.pump();
    await tester.pump();
    expect(reader.reads, [_emoji, _emoji]);
    expect(find.textContaining('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('what the engine reader holds', () {
    final big = Uint8List(maxHeldEngineImageBytes + 1);
    final small = Uint8List(16);

    Future<CachedImageReader> reading(Uint8List bytes) async {
      final container = ProviderContainer(
        overrides: [artifactFilesProvider.overrideWithValue(_filesOn(_engine))],
      );
      addTearDown(container.dispose);
      final keeps = container.read(engineImageReaderProvider).keeps!;
      return CachedImageReader(_Fixed(bytes), keeps: keeps);
    }

    test('a small asset stays for the next read', () async {
      final cache = await reading(small);
      await cache.read('', _emoji);
      expect(cache.peek('', _emoji), isNotNull);
    });

    test('a large image is not held in memory', () async {
      final cache = await reading(big);
      await cache.read('', _emoji);
      expect(cache.peek('', _emoji), isNull);
    });
  });
}

class _Fixed implements WorkspaceImageReader {
  _Fixed(this.bytes);

  final Uint8List bytes;

  @override
  Future<LoadedImage> read(String sessionId, String path) async => RasterImage(MemoryImage(bytes));
}
