// Goldens for reply rendering: maths with workspace images (loaded and
// missing), the text constructs, the block constructs, and a reply caught
// mid-stream.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/markdown_samples.dart';

/// `chart.png` is a real picture; anything else is missing.
class _Reader implements WorkspaceImageReader {
  _Reader(this.chart);

  final ImageProvider chart;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    if (path.endsWith('/chart.png')) return RasterImage(chart);
    throw const ArtifactError('missing');
  }
}

/// A 640×400 bar chart, drawn here so the golden shows a real image.
Future<Uint8List> _chartPng() async {
  const size = Size(640, 400);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF6F8FC));
  final bars = [0.42, 0.68, 0.55, 0.86, 0.73];
  const colors = [Color(0xFF4D6BFE), Color(0xFF6E86FF), Color(0xFF8FA1FF), Color(0xFF4D6BFE), Color(0xFF6E86FF)];
  for (var i = 0; i < bars.length; i++) {
    final h = bars[i] * 300;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(70 + i * 110.0, 350 - h, 70, h), const Radius.circular(10)),
      Paint()..color = colors[i],
    );
  }
  canvas.drawLine(
    const Offset(40, 350),
    const Offset(600, 350),
    Paint()
      ..color = const Color(0xFFB8C0D0)
      ..strokeWidth = 3,
  );
  final image = await recorder.endRecording().toImage(640, 400);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Widget _page(String markdown, {bool streaming = false}) => Scaffold(
  body: AppBackdrop(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 56, 16, 40),
      child: MarkdownBody(text: markdown, streaming: streaming, selectable: false),
    ),
  ),
);

const _imageReply =
    '''
$mathReply

生成的示意图：

![示意图](chart.png)

这张没找到：

![](out/test-image.jpg)''';

const _textReply = '$headingsReply\n\n$listsReply\n\n$quotesReply';

const _blocksReply = '$tableReply\n\n$codeReply\n\n$miscReply';

const _streamingReply = '''
推导分三步。**关键一步**是把矩阵写成

\$\$
\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1} = \\frac{1}{ad-bc}''';

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    final suffix = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('reply with maths and images ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 2400);
      final png = (await tester.runAsync(_chartPng))!;
      final chart = MemoryImage(png);
      await tester.pumpWidget(
        testApp(
          _page(_imageReply),
          brightness: brightness,
          overrides: [
            workspaceImageReaderProvider.overrideWithValue(CachedImageReader(_Reader(chart))),
            activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
            currentSessionProvider.overrideWith(() => FixedSession('s1')),
            sessionsProvider.overrideWith(FakeSessions.new),
            chatProvider.overrideWith2((id) => FakeChatController(id, const ChatState(loading: false))),
          ],
        ),
      );
      final context = tester.element(find.byType(MarkdownBody));
      final inline = inlineImageProvider(chart, MediaQuery.devicePixelRatioOf(context), null);
      await tester.runAsync(() => precacheImage(inline, context));
      await pumpFrames(tester, 3);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/markdown_math_$suffix.png'));
    });

    testWidgets('headings, lists, quotes and alerts ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 3100);
      await tester.pumpWidget(testApp(_page(_textReply), brightness: brightness));
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/markdown_text_$suffix.png'));
    });

    testWidgets('tables, code and the rest ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 2700);
      await tester.pumpWidget(testApp(_page(_blocksReply), brightness: brightness));
      await pumpFrames(tester, 2);
      await tester.tap(find.text('展开细节'));
      await pumpFrames(tester, 4);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/markdown_blocks_$suffix.png'));
    });

    testWidgets('a reply mid-stream ($suffix)', (tester) async {
      usePhoneView(tester);
      tester.view.physicalSize = const Size(780, 700);
      await tester.pumpWidget(testApp(_page(_streamingReply, streaming: true), brightness: brightness));
      await pumpFrames(tester, 2);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/markdown_streaming_$suffix.png'));
    });
  }
}
