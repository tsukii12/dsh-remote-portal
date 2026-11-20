import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _origin = 'http://127.0.0.1:3080';
const _asset = '/api/dsh-emoji/assets/yuzusoft-lemonade/1.0.0/happy.png';
const _url = '$_origin$_asset';

// Real DshRpc and origin classification; only wire replies and image bytes
// are supplied. The source is a genuine 320×320 PNG, not a one-pixel stand-in.
class _Wire extends DshHttpCarrier {
  _Wire() : super(DshConnection(Uri.parse(_origin)));
  final reads = <String>[];
  final pending = <Completer<RpcResult>>[];
  String size = 'normal';
  bool hold = false;
  bool fail = false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    reads.add(endpoint);
    expect(endpoint, 'dsh-emoji-settings/get');
    expect(args, isEmpty);
    if (hold) {
      final result = Completer<RpcResult>();
      pending.add(result);
      return result.future;
    }
    if (fail) throw const DshHttpException(404, 'plugin settings unavailable');
    return settings(size);
  }

  static RpcOk settings(String size) => RpcOk({
    'settings': {'displaySize': size},
  });
}

class _Client extends DshClient {
  _Client(this.wire) : super.withCarrier(wire);
  final _Wire wire;
  final events = StreamController<HostEvent>.broadcast(sync: true);
  @override
  Stream<HostEvent> get hostEvents => events.stream;
}

class _Files extends Notifier<ArtifactFiles> {
  _Files(this.initial);
  final DshClient initial;
  @override
  ArtifactFiles build() => files(initial);
  void use(DshClient client) => state = files(client);
  static ArtifactFiles files(DshClient client) => ArtifactFiles(
    connection: HostConnection(hostId: '', client: client, isLocal: true),
    channel: const FilesChannel(),
  );
}

class _Images implements WorkspaceImageReader {
  _Images(this.bytes);
  final Uint8List bytes;
  final reads = <String>[];
  Completer<LoadedImage>? pending;
  bool fail = false;
  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    reads.add(path);
    if (fail) throw const DshHttpException(401, 'unauthorized');
    return pending?.future ?? RasterImage(MemoryImage(bytes));
  }
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.amber);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}

Rect _rect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(box.localToGlobal(Offset.zero), box.localToGlobal(box.size.bottomRight(Offset.zero)));
}

Future<void> _decode(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  final image = find.byType(Image).first;
  await tester.runAsync(() => precacheImage(tester.widget<Image>(image).image, tester.element(image)));
  await tester.pump();
}

void main() {
  late _Wire wire;
  late _Client client;
  late _Images images;
  late NotifierProvider<_Files, ArtifactFiles> files;

  setUpAll(loadTestFonts);

  setUp(() async {
    wire = _Wire();
    client = _Client(wire);
    files = NotifierProvider<_Files, ArtifactFiles>(() => _Files(client));
    images = _Images(await _png(320, 320));
  });
  tearDown(() async {
    await client.events.close();
    await client.close();
  });

  Widget scene({
    String url = _url,
    String alt = 'happy',
    double scale = 1,
    bool secondary = false,
    bool heading = false,
    String? text,
    double? fontSize,
    Brightness brightness = Brightness.light,
  }) => testApp(
    Builder(
      builder: (context) => Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context).textTheme
              .copyWith(bodyLarge: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: fontSize)),
        ),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 390,
                child: MarkdownBody(
                  text: text ?? '${heading ? '# ' : ''}Before ![$alt]($url) after',
                  secondary: secondary,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    brightness: brightness,
    overrides: [
      artifactFilesProvider.overrideWith((ref) => ref.watch(files)),
      engineImageReaderProvider.overrideWith((ref) {
        ref.watch(artifactFilesProvider);
        return CachedImageReader(images);
      }),
    ],
  );

  for (final scale in [1.0, 1.3]) {
    testWidgets('320px emoji stays on the text line at scale $scale', (tester) async {
      await tester.pumpWidget(scene(scale: scale));
      await _decode(tester);
      final image = _rect(tester, find.byType(MarkdownImage));
      expect(image.width, closeTo(24 * scale, 0.1));
      expect(image.height, closeTo(24 * scale, 0.1));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(MarkdownBody), matching: find.byType(RichText)).first,
      );
      final text = paragraph.text.toPlainText();
      final before = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 6)).first;
      final after = paragraph
          .getBoxesForSelection(TextSelection(baseOffset: text.indexOf('after'), extentOffset: text.length))
          .last;
      expect(after.top, closeTo(before.top, 0.1));
      expect(images.reads, [_url]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in {'small': 1.25, 'normal': 1.5, 'large': 2.0, 'xlarge': 2.5}.entries) {
    testWidgets('plugin ${entry.key} setting controls the inline size', (tester) async {
      wire.size = entry.key;
      await tester.pumpWidget(scene());
      await _decode(tester);
      expect(_rect(tester, find.byType(MarkdownImage)).width, closeTo(16 * entry.value, 0.1));
      expect(wire.reads, ['dsh-emoji-settings/get']);
    });
  }

  testWidgets('root-relative secondary emoji uses the local body font', (tester) async {
    await tester.pumpWidget(scene(url: _asset, secondary: true));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, closeTo(16 * 0.9 * 1.5, 0.1));
    expect(images.reads, [_asset]);
  });

  testWidgets('heading emoji follows the heading font and scales once', (tester) async {
    await tester.pumpWidget(scene(heading: true, scale: 1.3));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, closeTo(20 * 1.5 * 1.3, 0.1));
  });

  testWidgets('custom body font controls the em independently of text scale', (tester) async {
    await tester.pumpWidget(scene(fontSize: 20, scale: 1.3));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, closeTo(20 * 1.5 * 1.3, 0.1));
  });

  testWidgets('block marker keeps the existing full image treatment', (tester) async {
    await tester.pumpWidget(scene(url: '$_url#dsh-emoji-block'));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, 320);
    expect(wire.reads, isEmpty);
  });

  testWidgets('explicit Markdown size keeps its original treatment', (tester) async {
    await tester.pumpWidget(scene(alt: '96x48'));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, 48);
    expect(wire.reads, isEmpty);
  });

  for (final attribute in ['width="96"', 'height="48"']) {
    testWidgets('single HTML $attribute does not opt into emoji sizing', (tester) async {
      await tester.pumpWidget(scene(text: '<img src="$_url" $attribute>'));
      await _decode(tester);
      expect(_rect(tester, find.byType(MarkdownImage)).height, 320);
      expect(wire.reads, isEmpty);
    });
  }

  testWidgets('legacy two-segment assets retain their inline protocol', (tester) async {
    await tester.pumpWidget(scene(url: '/api/dsh-emoji/assets/deepseek/ds_01.png'));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
  });

  testWidgets('other engine assets stay full images', (tester) async {
    await tester.pumpWidget(scene(url: '$_origin/api/other/assets/happy.png'));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).height, 320);
    expect(wire.reads, isEmpty);
  });

  for (final url in [
    '$_origin/api/other/image.png?source=/api/dsh-emoji/assets/a/b/c.png',
    '$_origin/api/dsh-emoji/assets/a/b/c/d.png',
  ]) {
    testWidgets('only the exact asset route opts in: $url', (tester) async {
      await tester.pumpWidget(scene(url: url));
      await _decode(tester);
      expect(_rect(tester, find.byType(MarkdownImage)).height, 320);
      expect(wire.reads, isEmpty);
    });
  }

  testWidgets('a matching path on another origin never reads local emoji settings', (tester) async {
    await tester.pumpWidget(scene(url: 'https://example.com$_asset'));
    await tester.pump();
    expect(images.reads, isEmpty);
    expect(wire.reads, isEmpty);
  });

  testWidgets('loading reserves only the inline emoji box', (tester) async {
    images.pending = Completer<LoadedImage>();
    await tester.pumpWidget(scene());
    await tester.pump();
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
    images.pending!.complete(RasterImage(MemoryImage(images.bytes)));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
  });

  testWidgets('settings failure uses the default without breaking image loading', (tester) async {
    wire.fail = true;
    await tester.pumpWidget(scene());
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).width, 24);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image authentication failures keep the visible retry and inline retry placeholder', (tester) async {
    images.fail = true;
    await tester.pumpWidget(scene());
    await tester.pump();
    final retry = find.textContaining('重试');
    expect(retry, findsOneWidget);
    images.fail = false;
    images.pending = Completer<LoadedImage>();
    await tester.tap(retry);
    await tester.pump();
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
    images.pending!.complete(RasterImage(MemoryImage(images.bytes)));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
    expect(images.reads, [_url, _url]);
  });

  testWidgets('tap opens original bytes and long press keeps the image menu', (tester) async {
    await tester.pumpWidget(scene());
    await _decode(tester);
    await tester.longPress(find.byType(MarkdownImage));
    await pumpFrames(tester, 4);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    Navigator.of(tester.element(find.text('分享'))).pop();
    await pumpFrames(tester, 4);
    await tester.tap(find.byType(MarkdownImage));
    await pumpFrames(tester, 4);
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.image, isA<MemoryImage>());
    expect((viewer.image as MemoryImage).bytes, orderedEquals(images.bytes));
  });

  testWidgets('images share settings and reconnect or bad replies keep the last valid size', (tester) async {
    wire.size = 'large';
    await tester.pumpWidget(scene(text: '![]($_url) ![]($_url)'));
    await _decode(tester);
    expect(wire.reads, ['dsh-emoji-settings/get']);
    expect(_rect(tester, find.byType(MarkdownImage).first).width, 32);
    wire.fail = true;
    client.events.add(const HostReadyEvent('generation-2', '/home/test'));
    await tester.pump();
    expect(wire.reads.length, 2);
    expect(_rect(tester, find.byType(MarkdownImage).first).width, 32);
    wire.fail = false;
    wire.size = 'future-size';
    client.events.add(const SettingsUpdatedEvent('dsh-emoji', 1));
    await tester.pump();
    expect(wire.reads.length, 3);
    expect(_rect(tester, find.byType(MarkdownImage).first).width, 32);
  });

  testWidgets('settings refresh only this plugin and reject stale replies', (tester) async {
    await tester.pumpWidget(scene());
    await _decode(tester);
    client.events.add(const SettingsUpdatedEvent('unrelated-plugin', 1));
    await tester.pump();
    expect(wire.reads.length, 1);
    wire.hold = true;
    client.events.add(const SettingsUpdatedEvent('dsh-emoji', 2));
    client.events.add(const SettingsUpdatedEvent('dsh-emoji', 3));
    await tester.pump();
    expect(wire.pending, hasLength(2));
    wire.pending.last.complete(_Wire.settings('large'));
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).width, 32);
    wire.pending.first.complete(_Wire.settings('small'));
    await tester.pump();
    expect(_rect(tester, find.byType(MarkdownImage)).width, 32);
  });

  testWidgets('replaced connection does not inherit a pending old size', (tester) async {
    wire.hold = true;
    await tester.pumpWidget(scene());
    await _decode(tester);
    final next = _Client(_Wire()..size = 'small');
    addTearDown(() async {
      await next.events.close();
      await next.close();
    });
    final container = ProviderScope.containerOf(tester.element(find.byType(MarkdownImage)));
    container.read(files.notifier).use(next);
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).width, 20);
    wire.pending.single.complete(_Wire.settings('xlarge'));
    await tester.pump();
    expect(_rect(tester, find.byType(MarkdownImage)).width, 20);
    expect(images.reads, [_url, _url]);
  });

  testWidgets('a valid 512x1 emoji retains its aspect without zero-sized decoding', (tester) async {
    images = _Images((await tester.runAsync(() => _png(512, 1)))!);
    await tester.pumpWidget(scene());
    await _decode(tester);
    expect(_rect(tester, find.byType(MarkdownImage)).size, const Size(24, 24));
    expect(find.textContaining('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
