import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart';
import 'package:dsh_app/ui/chat/widgets/image_gallery.dart';
import 'package:dsh_app/ui/chat/widgets/tool_images.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../files/support/files_harness.dart';
import 'support/harness.dart';

class _PreviewFiles extends ArtifactFiles {
  _PreviewFiles(this.file, {this.local = true}) : super(connection: fakeConnection, channel: const FilesChannel());

  final File file;
  final bool local;
  final reads = <String>[];

  @override
  bool get isLocal => local;

  @override
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double? progress)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) async {
    reads.add(artifact.path);
    return file;
  }
}

class _ImageWorkspace extends MemoryWorkspace {
  _ImageWorkspace() : super(files: {'a.png': 'a', 'large.png': 'large', 'b.png': 'b'});

  @override
  Future<DshFileStat> stat(String path) async {
    final stat = await super.stat(path);
    return DshFileStat(
      absolutePath: stat.absolutePath,
      version: stat.version,
      bytes: rel(path) == 'large.png' ? 33 * 1024 * 1024 : tinyPng.length,
    );
  }
}

class _RecordingImages implements WorkspaceImageReader {
  final reads = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add((sessionId, path));
    return RasterImage(MemoryImage(tinyPng));
  }
}

class _ReplyImages implements WorkspaceImageReader {
  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    if (path.endsWith('large.png')) throw const ImageTooLarge();
    return RasterImage(MemoryImage(tinyPng));
  }
}

Future<void> _decodeInline(WidgetTester tester) async {
  final images = find.byType(Image);
  await tester.runAsync(() async {
    for (final element in images.evaluate().toList()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await pumpFrames(tester, 4);
}

Future<void> _next(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(-320, 0), 1000);
  await tester.pumpAndSettle();
}

Artifact _artifact(String name) => Artifact(path: '/root/work/$name', origin: ArtifactOrigin.linked, turn: 0);

void main() {
  testWidgets('gallery lazily loads the initial page and saves the currently selected original', (tester) async {
    usePhoneView(tester);
    final provider = MemoryImage(tinyPng);
    final calls = <int>[];
    final pending = Completer<ImageProvider>();
    await tester.pumpWidget(
      testApp(
        ImageViewerPage.gallery(
          initial: 1,
          images: [
            ViewerImage.lazy(
              name: 'first.png',
              load: () async {
                calls.add(0);
                return provider;
              },
            ),
            ViewerImage.lazy(
              name: 'second.png',
              load: () {
                calls.add(1);
                return pending.future;
              },
            ),
            ViewerImage(name: 'third.png', image: provider),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(calls, [1]);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(tester.widget<GallerySaveButton>(find.byType(GallerySaveButton)).name, 'second.png');
    pending.complete(provider);
    await tester.pumpAndSettle();
    await _next(tester);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('third.png'), findsOneWidget);
    final save = tester.widget<GallerySaveButton>(find.byType(GallerySaveButton));
    expect(save.name, 'third.png');
    final bytes = await tester.runAsync(save.load);
    expect(bytes, orderedEquals(tinyPng));
    expect(calls.where((i) => i == 1).length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy image constructor and route remain usable', (tester) async {
    final provider = MemoryImage(tinyPng);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(ImageViewerPage.route(title: 'old.png', image: provider)),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final page = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(page.image, same(provider));
    expect(page.title, 'old.png');
    expect(find.byType(ZoomableImage), findsOneWidget);
    expect(find.byKey(const ValueKey('image-gallery-page')), findsNothing);
  });

  testWidgets('a lazy gallery load failure stays on its own page', (tester) async {
    await tester.pumpWidget(
      testApp(
        ImageViewerPage.gallery(
          images: [
            ViewerImage.lazy(name: 'missing.png', load: () => throw StateError('missing')),
            ViewerImage(name: 'ok.png', image: MemoryImage(tinyPng)),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(appL10n.viewArtifactImageFailed), findsOneWidget);
    await _next(tester);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('ok.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool images group only loaded sources and retain the tapped index', (tester) async {
    usePhoneView(tester);
    final pending = Completer<Uint8List>();
    final view = ToolView.of(
      ToolChatItem(
        callId: 'gallery',
        name: 'phone_screenshot',
        arguments: '{}',
        status: ToolStatus.succeeded,
        resultParts: [
          for (var i = 0; i < 3; i++)
            ImagePart(ImageAttachment(attachmentId: 'image-$i', mediaType: 'image/png', name: '$i.png')),
        ],
      ),
    );
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: MarkdownImageScope(
            sessionId: 's1',
            child: ToolImages(view: view),
          ),
        ),
        overrides: [
          sessionImageProvider.overrideWith((ref, key) =>
              key.$2.attachmentId == 'image-1' ? pending.future : Future.value(tinyPng)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await _decodeInline(tester);
    await tester.tap(find.byType(Image).last);
    await tester.pumpAndSettle();
    final page = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(page.images!.map((image) => image.name), ['0.png', '2.png']);
    expect(page.initial, 1);
    expect(find.text('2 / 2'), findsOneWidget);
    pending.complete(tinyPng);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown galleries use rendered images and never cross reply bodies', (tester) async {
    usePhoneView(tester);
    final url = 'data:image/png;base64,${base64Encode(tinyPng)}';
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                MarkdownBody(text: '![first]($url)\n\n<img src="$url">', selectable: false),
                MarkdownBody(text: '![other reply]($url)', selectable: false),
              ],
            ),
          ),
        ),
        overrides: [
          artifactFilesProvider.overrideWithValue(ArtifactFiles(connection: null, channel: const FilesChannel())),
        ],
      ),
    );
    await _decodeInline(tester);
    expect(find.byType(MarkdownImage), findsNWidgets(3));
    await tester.tap(find.byType(Image).at(1));
    await tester.pumpAndSettle();
    final page = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(page.images, hasLength(2));
    expect(page.initial, 1);
    await tester.drag(find.byType(PageView), const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relative engine images join web images instead of workspace images', (tester) async {
    usePhoneView(tester);
    const enginePath = '/api/dsh-emoji/assets/deepseek/8/ds_01.png';
    const webUrl = 'https://example.com/gallery-web.png';
    final engine = _RecordingImages();
    final workspace = _RecordingImages();
    final network = inlineImageProvider(const NetworkImage(webUrl), 2, null);
    final key = await network.obtainKey(ImageConfiguration.empty);
    final stream = MemoryImage(tinyPng).resolve(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(key, () => stream.completer!);
    addTearDown(() => network.evict());

    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: SingleChildScrollView(
            child: MarkdownImageScope(
              sessionId: 's1',
              child: MarkdownBody(
                selectable: false,
                text: '![engine]($enginePath)\n\n![web]($webUrl)\n\n![workspace](/root/work/a.png)',
              ),
            ),
          ),
        ),
        overrides: [
          artifactFilesProvider.overrideWithValue(ArtifactFiles(connection: fakeConnection, channel: const FilesChannel())),
          engineImageReaderProvider.overrideWithValue(CachedImageReader(engine)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(workspace)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await _decodeInline(tester);
    expect(engine.reads, [('', enginePath)]);
    expect(workspace.reads, [('s1', '/root/work/a.png')]);
    expect(find.byType(Image), findsNWidgets(3));

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    var page = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(page.images!.map((image) => image.name), ['ds_01.png', 'gallery-web.png']);
    expect(page.initial, 0);
    expect(find.byType(ArtifactPreviewPage), findsNothing);
    await tester.tap(find.byTooltip(appL10n.commonBack));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).at(1));
    await tester.pumpAndSettle();
    page = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(page.images!.map((image) => image.name), ['ds_01.png', 'gallery-web.png']);
    expect(page.initial, 1);
    expect(find.byType(ArtifactPreviewPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace gallery switches watches, reloads, and preserves the 32 MiB gate and actions', (tester) async {
    usePhoneView(tester);
    final dir = Directory.systemTemp.createTempSync('reply-gallery-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/image.png')..writeAsBytesSync(tinyPng);
    final files = _PreviewFiles(file, local: false);
    final workspace = _ImageWorkspace();
    final images = [_artifact('a.png'), _artifact('large.png'), _artifact('b.png')];
    await tester.pumpWidget(
      filesApp(
        ArtifactPreviewPage(sessionId: 's1', artifact: images.first, gallery: images),
        workspace,
        overrides: [artifactFilesProvider.overrideWithValue(files)],
      ),
    );
    await tester.pumpAndSettle();
    expect(workspace.watching('a.png'), 1);
    expect(files.reads, ['/root/work/a.png']);
    expect(find.byTooltip(appL10n.commonShare), findsOneWidget);
    expect(find.byTooltip(appL10n.viewArtifactMore), findsOneWidget);
    await _next(tester);
    expect(workspace.watching('a.png'), 0);
    expect(workspace.watching('large.png'), 1);
    expect(files.reads, isNot(contains('/root/work/large.png')));
    expect(find.textContaining(appL10n.viewArtifactLarge), findsOneWidget);
    await _next(tester);
    expect(workspace.watching('large.png'), 0);
    expect(workspace.watching('b.png'), 1);
    expect(files.reads.last, '/root/work/b.png');
    workspace.delete('a.png');
    await tester.pump();
    expect(find.text(appL10n.viewArtifactMissing), findsNothing);
    workspace.delete('b.png');
    await tester.pumpAndSettle();
    expect(find.text(appL10n.viewArtifactMissing), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);
    workspace.write('b.png', tinyPng);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.viewArtifactMissing), findsNothing);
    expect(files.reads.where((path) => path.endsWith('b.png')), hasLength(2));
    expect(tester.widget<GallerySaveButton>(find.byType(GallerySaveButton)).name, 'b.png');
    await tester.pumpWidget(const SizedBox());
    expect(workspace.watching('b.png'), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown workspace groups remain separate and large-image fallback remains single', (tester) async {
    usePhoneView(tester);
    final dir = Directory.systemTemp.createTempSync('reply-gallery-fallback-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/image.png')..writeAsBytesSync(tinyPng);
    final workspace = _ImageWorkspace();
    final url = 'data:image/png;base64,${base64Encode(tinyPng)}';
    await tester.pumpWidget(
      filesApp(
        Scaffold(
          body: SingleChildScrollView(
            child: MarkdownImageScope(
              sessionId: 's1',
              child: MarkdownBody(
                selectable: false,
                text:
                    '![a](/root/work/a.png)\n\n![web]($url)\n\n![b](/root/work/b.png)\n\n![large](/root/work/large.png)',
              ),
            ),
          ),
        ),
        workspace,
        overrides: [
          artifactFilesProvider.overrideWithValue(_PreviewFiles(file)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(_ReplyImages())),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await _decodeInline(tester);
    await tester.tap(find.byType(Image).at(2));
    await tester.pumpAndSettle();
    final workspacePage = tester.widget<ArtifactPreviewPage>(find.byType(ArtifactPreviewPage));
    expect(workspacePage.gallery!.map((artifact) => artifact.name), ['a.png', 'b.png']);
    expect(workspacePage.initial, 1);
    await tester.tap(find.byTooltip(appL10n.commonBack));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(appL10n.chatImageTapToView));
    await tester.pumpAndSettle();
    final fallback = tester.widget<ArtifactPreviewPage>(find.byType(ArtifactPreviewPage));
    expect(fallback.artifact.name, 'large.png');
    expect(fallback.gallery, isNull);
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
