import 'dart:async';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../media/support.dart';
import 'support/harness.dart';

const _url = 'http://127.0.0.1:3080/api/test-image.png';

class _PendingReader implements WorkspaceImageReader {
  final calls = <(String, String)>[];
  final requests = <Completer<LoadedImage>>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) {
    calls.add((sessionId, path));
    final request = Completer<LoadedImage>();
    requests.add(request);
    return request.future;
  }
}

class _ImmediateReader implements WorkspaceImageReader {
  _ImmediateReader(this.image);
  final LoadedImage image;
  int calls = 0;

  @override
  Future<LoadedImage> read(String sessionId, String path) {
    calls++;
    return SynchronousFuture(image);
  }
}

void main() {
  setUpAll(loadTestFonts);

  test('forget retires a pending read without cancelling its caller', () async {
    final source = _PendingReader();
    final cache = CachedImageReader(source);
    final image = RasterImage(MemoryImage(Uint8List(0)));
    final original = cache.read('session', 'image.png');
    cache.forget('session', 'image.png');
    source.requests.single.complete(image);
    expect(await original, same(image));
    expect(cache.peek('session', 'image.png'), isNull);
  });

  test('a synchronous source remains readable and cached', () async {
    final image = RasterImage(MemoryImage(Uint8List(0)));
    final source = _ImmediateReader(image);
    final cache = CachedImageReader(source);
    expect(await cache.read('session', 'image.png'), same(image));
    expect(cache.peek('session', 'image.png'), same(image));
    expect(await cache.read('session', 'image.png'), same(image));
    expect(source.calls, 1);
  });

  test('pending consumers share the same completion', () async {
    final source = _PendingReader();
    final cache = CachedImageReader(source);
    final first = cache.read('session', 'image.png');
    final second = cache.read('session', 'image.png');
    expect(second, same(first));
    expect(source.requests, hasLength(1));
    final image = RasterImage(MemoryImage(Uint8List(0)));
    source.requests.single.complete(image);
    expect(await first, same(image));
    expect(await second, same(image));
  });

  test('forgetting one session does not retire another session read', () async {
    final source = _PendingReader();
    final cache = CachedImageReader(source);
    final image = RasterImage(MemoryImage(Uint8List(0)));
    final first = cache.read('a', 'image.png');
    final second = cache.read('b', 'image.png');
    cache.forget('a', 'image.png');
    source.requests[0].complete(image);
    source.requests[1].complete(image);
    await Future.wait([first, second]);
    expect(cache.peek('b', 'image.png'), same(image));
    expect(source.calls, [('a', 'image.png'), ('b', 'image.png')]);
  });

  for (final completion in ['success before latest', 'success after latest', 'failure before latest']) {
    testWidgets('repeated image retries keep the latest cache after $completion', (tester) async {
      final pictures = (await tester.runAsync(
        () async => [await drawPicture(48, 48), await drawPicture(48, 48, index: 1)],
      ))!;
      final oldImage = RasterImage(MemoryImage(pictures[0]));
      final latestImage = RasterImage(MemoryImage(pictures[1]));
      final reader = _PendingReader();
      final cache = CachedImageReader(reader);
      final count = ValueNotifier(2);
      final client = DshClient.withCarrier(DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:3080'))));
      addTearDown(count.dispose);
      addTearDown(client.close);
      addTearDown(() {
        for (final request in reader.requests) {
          if (!request.isCompleted) request.complete(latestImage);
        }
      });
      Finder tile(int index) => find.byKey(ValueKey('image-$index'));
      Finder picturesIn(int index) => find.descendant(of: tile(index), matching: find.byType(Image));
      MemoryImage shownImage(int index) =>
          (tester.widget<Image>(picturesIn(index)).image as ResizeImage).imageProvider as MemoryImage;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: ValueListenableBuilder(
              valueListenable: count,
              builder: (_, value, _) => Column(
                children: [
                  for (var i = 0; i < value; i++)
                    SizedBox(
                      key: ValueKey('image-$i'),
                      width: 220,
                      height: 150,
                      child: const MarkdownImage(url: _url),
                    ),
                ],
              ),
            ),
          ),
          overrides: [
            artifactFilesProvider.overrideWithValue(
              ArtifactFiles(
                connection: HostConnection(hostId: '', client: client, isLocal: true),
                channel: const FilesChannel(),
              ),
            ),
            engineImageReaderProvider.overrideWithValue(cache),
          ],
        ),
      );
      expect(reader.calls, [('', _url)]);
      reader.requests[0].completeError(const ArtifactError('offline'));
      await tester.pump();
      expect(find.textContaining('重试'), findsNWidgets(2));
      await tester.tap(find.descendant(of: tile(0), matching: find.textContaining('重试')));
      await tester.pump();
      await tester.tap(find.descendant(of: tile(1), matching: find.textContaining('重试')));
      await tester.pump();
      expect(reader.calls, [('', _url), ('', _url), ('', _url)]);

      if (completion == 'success after latest') {
        reader.requests[2].complete(latestImage);
        await tester.pump();
      }
      if (completion == 'failure before latest') {
        reader.requests[1].completeError(const ArtifactError('offline'));
      } else {
        reader.requests[1].complete(oldImage);
      }
      await tester.pump();
      count.value = 3;
      await tester.pump();
      // The third tile must join or reuse the most recent retry, not an older
      // completion, and an old failure must not start an extra request.
      expect(reader.calls, hasLength(3));
      if (completion != 'success after latest') {
        expect(picturesIn(2), findsNothing);
        reader.requests[2].complete(latestImage);
        await tester.pump();
      }
      await tester.pump();
      expect(shownImage(1).bytes, pictures[1]);
      expect(shownImage(2).bytes, pictures[1]);
      if (completion != 'failure before latest') {
        // Retiring cache ownership does not cancel an existing consumer.
        expect(shownImage(0).bytes, pictures[0]);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
