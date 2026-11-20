import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/tool_images.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/english_preview.dart';
import 'support/harness.dart';

// A deterministic blue header on a pale image; generated without external assets.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAABaCAYAAAA/xl1SAAABDElEQVR4nO3SoQ2AQADAwJ+Nddgbg0AinxUggVRw4nxFx36cEyqjDuDfDEjKgKQMSMqApAxIyoCkDEjKgKQMSMqApAxI6taAy7rBIwYkZUBSBiRlQFIGJGVAUgYkZUBSBiRlQFIGJGVAUgYkZUBSBiRlQFIGJGVAUgYkZUBSBiT16oDwFQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgKQOSMiApA5IyICkDkjIgqQsZZ3JmhramNAAAAABJRU5ErkJggg==',
);

// A portrait phone screenshot: letterboxed inside its tile.
final portrait = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAALQAAAGQCAIAAACI5d3xAAADWElEQVR42u3csQ2AIBBAUYagcBCHc10TO42FhQWxcIFrgQRe8ieA113uUs6LFJY8geAQHIJDcAgOwSE4BIfgEBwSHIJDcAgOdcGxbq8UBofgEByCQ3AIDsEhOASH4BAcEhyCQ3AIDsEhOASH4BAcgkOCQ3AIDsEhOASH4BAcgkNwSHAIDsEhOASH4BAcgkPj4Cjlk8LgEByCQ3AIDsEhOASH4BAcgkOCQ3CoFY5KE+HrftQrOASH4BAcggMOOOCAAw444IADDjjggAMOwSE4BIfgEBxwwAEHHHDAAQcccMABh+AQHIJDcAgOOOCAYxYcskgtwSE4BIfgEByCQ3AIDsEhOCSDN4M3OASH4BAcgkNwwAEHHHDAAQcccMABBxyCQ3AIDsEhOOCAAw444IADDjjggAMOwSE4BIfgEBxwwAGHO6SyZS84JDgEh+AQHIJDcAgOwSE4BIfBm8EbHHDAITgEh+AQHIIDDjjggAMOOOCAAw444BAcgkNwCA7BAQcccMABBxxwwAEHHHDAAYfgEByCQ3D4JHdIZctecAgOweEJBIfgEByCQ3AIDsEhd0gN3gze4IADDjjgEByCQ3AIDsEBBxxwwAEHHHDAAQcccMABh+AQHIJDcPgkOOCAAw444IADDjjggAMOwSE4BIfcIZUte8EhOASH4JDgEByCQ3AIDsEhd0gN3kxl4YADDjjggAMOOOAQHIJDcAgOPwQHHHDAAQcccMABBxxwwCE4BIfgEByCAw444IADDjjggAMOOOAQHIJD7pDKlr3gEByCQ3AIDgkOwSE4BIfgkDukBm+msnDAAQcccMABBxxwwAGH4BAcgkNwCA444IADDjjggAMOOOCAQ3AIDsEhOAQHHHDAAQcccMABBxxwwCE45A6pbNkLDsEhOASH4BAcEhyCQ3AIDsEhOASH4BAcgkNwSHAIDsEhOASH4BAcgkNwCA4JDsEhOASH4BAcgkNwCA7BIcEhOASH4BAcgkNwCA7BITgEhwSH4BAcgkNwCA7BITgEh+CQ4BAcaoFjP04NFhyCQ3AIDsEhOASH4BAccMABBxxwCA7BITgEh+AQHIJDcMABBxxwwCE4BIfgEByCQ3AIDsHhNeGAAw44BIfgEByCQ3AIDsEhODQVjh9XfsNlv2Yt3wAAAABJRU5ErkJggg==',
);

ToolChatItem result({int count = 1, String name = 'phone_screenshot', String arguments = '{}'}) => ToolChatItem(
  callId: 'image-call',
  name: name,
  arguments: arguments,
  status: ToolStatus.succeeded,
  resultParts: [for (var i = 0; i < count; i++) ImagePart(imageAt(i))],
);

Widget scene(
  ToolChatItem item, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
  bool english = false,
}) {
  Widget body = MarkdownImageScope(
    sessionId: 'child-session',
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ToolRow(item: item, onRespond: (_, _) async {}),
      ),
    ),
  );
  if (english) body = inEnglish(body);
  return testApp(
    Scaffold(body: body),
    brightness: brightness,
    overrides: overrides,
  );
}

Future<void> openDetails(WidgetTester tester) async {
  await tester.tap(find.byType(ToolRow));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    // Image widgets exist before their first decoded frame makes them tappable.
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element, onError: (_, _) {});
    }
  });
  await tester.pumpAndSettle();
}

class RemoteImages extends DshCarrier {
  RemoteImages(this.bytes, {this.reportedSize});
  final Uint8List bytes;
  final int? reportedSize;
  final calls = <(String, Map<String, Object?>)>[];
  @override
  String get kind => 'test-remote';
  @override
  DshTracer? get tracer => null;
  @override
  Future<void> close() async {}
  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('unused');
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    return RpcOk(
      endpoint == 'workspaceFiles/stat'
          ? {'absolutePath': '/remote/screen.png', 'version': 'v1', 'bytes': reportedSize ?? bytes.length}
          : {'data': base64Encode(bytes), 'eof': true},
    );
  }
}

ImageAttachment imageAt(int i) =>
    ImageAttachment(attachmentId: 'image-$i', mediaType: 'image/png', bytes: png.length, name: 'screen-$i.png');

void main() {
  setUpAll(loadTestFonts);

  testWidgets('one image loads only on expansion and opens the existing viewer', (tester) async {
    usePhoneView(tester);
    var requests = 0;
    await tester.pumpWidget(
      scene(
        result(),
        overrides: [
          sessionImageProvider(('child-session', imageAt(0))).overrideWith((ref) async {
            requests++;
            return png;
          }),
        ],
      ),
    );
    expect(requests, 0);
    await openDetails(tester);
    expect(requests, 1);
    expect(find.byType(Image), findsOneWidget);
    final thumbnail = tester.widget<Image>(find.byType(Image));
    expect(thumbnail.image, isA<ResizeImage>());
    expect((thumbnail.image as ResizeImage).width, lessThanOrEqualTo(1024));
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple image blocks stay ordered in a symmetric two-column grid', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      scene(
        result(count: 3),
        overrides: [
          for (var i = 0; i < 3; i++)
            sessionImageProvider(('child-session', imageAt(i))).overrideWith((ref) async => png),
        ],
      ),
    );
    await openDetails(tester);
    expect(find.byType(Image), findsNWidgets(3));
    final first = tester.getRect(find.byType(Image).at(0));
    final second = tester.getRect(find.byType(Image).at(1));
    expect(first.width, second.width);
    expect(second.left - first.right, greaterThanOrEqualTo(8));
    // Tiles: equal halves with an 8 gap, the grid inset 12 on both sides of the well.
    final well = tester.getRect(find.byType(ToolDetail));
    final grid = tester.getRect(find.byType(ToolImages));
    expect(grid.left - well.left, 12);
    expect(well.right - grid.right, 12);
    final tile = find.descendant(
      of: find.byType(ToolImages),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 144),
    );
    expect(tile, findsNWidgets(3));
    final cells = [for (var i = 0; i < 3; i++) tester.getRect(tile.at(i))];
    expect(cells[0].left, grid.left);
    expect(cells[1].right, grid.right);
    expect(cells[0].width, cells[1].width);
    expect(cells[1].left - cells[0].right, 8);
    expect(cells[2].left, grid.left);
    expect(cells[2].top - cells[0].bottom, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading and failed bytes stay quiet and have no clickable viewer', (tester) async {
    usePhoneView(tester);
    final pending = Completer<Uint8List>();
    await tester.pumpWidget(
      scene(
        result(count: 2),
        overrides: [
          sessionImageProvider(('child-session', imageAt(0))).overrideWith((ref) => pending.future),
          sessionImageProvider(('child-session', imageAt(1)))
              .overrideWith((ref) async => Uint8List.fromList([1, 2, 3])),
        ],
      ),
    );
    await openDetails(tester);
    pending.completeError(StateError('gone'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote path uses Host stat/readBytes with the scoped session', (tester) async {
    usePhoneView(tester);
    final carrier = RemoteImages(png);
    final cache = Directory.systemTemp.createTempSync('tool-images-');
    addTearDown(() => cache.deleteSync(recursive: true));
    final files = ArtifactFiles(
      connection: HostConnection(client: DshClient.withCarrier(carrier), isLocal: false, hostId: 'remote'),
      channel: const FilesChannel(),
      cacheRoot: () async => cache,
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        scene(
          result(count: 0, name: 'read_image', arguments: '{"file_path":"/remote/screen.png"}'),
          overrides: [artifactFilesProvider.overrideWithValue(files)],
        ),
      );
      await tester.tap(find.byType(ToolRow));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(ToolImages)));
      await container.read(artifactThumbnailProvider(('child-session', '/remote/screen.png')).future);
    });
    await tester.pumpAndSettle();
    expect(carrier.calls.any((c) => c.$1 == 'workspaceFiles/readBytes'), isTrue, reason: '${carrier.calls}');
    expect(carrier.calls.every((c) => c.$2['workspaceFileScopeId'] == 'child-session'), isTrue);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('path is fallback only, and failure/ordinary text reads never guess images', () {
    expect(ToolView.of(result(name: 'read_image', arguments: '{"file_path":"/remote/screen.png"}')).imagePath, isNull);
    expect(
      ToolView.of(result(count: 0, name: 'read', arguments: '{"file_path":"/remote/screen.png"}')).hasImages,
      isFalse,
    );
  });

  // The expanded card as it sits in a chat: a portrait screenshot, a wide
  // image and one that failed to load, in both languages and themes.
  for (final english in [false, true]) {
    for (final brightness in Brightness.values) {
      final name = '${english ? 'en_' : ''}tool_images_${brightness.name}';
      testWidgets('golden $name', (tester) async {
        if (english) useEnglish();
        usePhoneView(tester);
        await tester.pumpWidget(
          scene(
            result(count: 3),
            brightness: brightness,
            english: english,
            overrides: [
              sessionImageProvider(('child-session', imageAt(0))).overrideWith((ref) async => portrait),
              sessionImageProvider(('child-session', imageAt(1))).overrideWith((ref) async => png),
              sessionImageProvider(('child-session', imageAt(2)))
                  .overrideWith((ref) async => throw StateError('missing')),
            ],
          ),
        );
        await openDetails(tester);
        await expectLater(find.byType(ToolRow), matchesGoldenFile('goldens/$name.png'));
      });
    }
  }
}
