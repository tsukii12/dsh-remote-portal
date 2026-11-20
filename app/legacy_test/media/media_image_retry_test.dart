import 'dart:async';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/ui/chat/media/media_card.dart';
import 'package:dsh_app/ui/chat/media/media_image_feedback.dart';
import 'package:dsh_app/ui/chat/media/media_viewer.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/support/harness.dart';
import 'support.dart';

class _Reader implements WorkspaceImageReader {
  _Reader(this.load);
  final Future<LoadedImage> Function(String sessionId, String path, int call) load;
  final calls = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) {
    calls.add((sessionId, path));
    return load(sessionId, path, calls.length);
  }
}

Widget _cell({String session = 's1'}) => Scaffold(
  body: Center(
    child: SizedBox(
      width: 220,
      height: 220,
      child: MediaCell(
        sessionId: session,
        meta: mediaMeta(),
        index: 0,
        radius: BorderRadius.circular(12),
        size: const Size(220, 220),
      ),
    ),
  ),
);

void main() {
  testWidgets('pending card shows loading; a failed file reload never invokes generation', (tester) async {
    final first = Completer<LoadedImage>();
    final bytes = (await tester.runAsync(() => drawPicture(32, 32)))!;
    final reader = _Reader(
      (session, path, call) => call == 1 ? first.future : Future.value(RasterImage(MemoryImage(bytes))),
    );
    var generated = 0;
    await tester.pumpWidget(
      testApp(
        MediaCardActions(regenerate: (_) => generated++, child: _cell()),
        overrides: [workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader))],
      ),
    );
    expect(find.text('正在加载图片'), findsOneWidget);
    first.completeError(const ArtifactError('offline'));
    await tester.pump();
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await pumpFrames(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await pumpFrames(tester);
    expect(reader.calls, hasLength(2));
    expect(generated, 0);
    expect(find.text('重新加载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same path in another session cannot keep or complete the old request', (tester) async {
    final old = Completer<LoadedImage>();
    final next = Completer<LoadedImage>();
    final session = ValueNotifier('s1');
    addTearDown(session.dispose);
    final reader = _Reader((id, path, call) => id == 's1' ? old.future : next.future);
    await tester.pumpWidget(
      testApp(
        ValueListenableBuilder(
          valueListenable: session,
          builder: (_, id, _) => _cell(session: id),
        ),
        overrides: [workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader))],
      ),
    );
    session.value = 's2';
    await tester.pump();
    expect(reader.calls.map((e) => e.$1), ['s1', 's2']);
    old.completeError(const ArtifactError('missing'));
    await tester.pump();
    expect(find.text('正在加载图片'), findsOneWidget);
    expect(find.text('文件已不在'), findsNothing);
    next.completeError(const ArtifactError('offline'));
    await tester.pump();
    expect(find.text('重新加载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full-screen image failure can reload its workspace source', (tester) async {
    final bytes = (await tester.runAsync(() => drawPicture(32, 32)))!;
    final reader = _Reader((session, path, call) async {
      if (call == 1) throw const ArtifactError('offline');
      return RasterImage(MemoryImage(bytes));
    });
    await tester.pumpWidget(
      testApp(
        MediaViewerPage(sessionId: 's1', meta: mediaMeta()),
        overrides: [workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader))],
      ),
    );
    await pumpFrames(tester);
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await pumpFrames(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await pumpFrames(tester);
    expect(reader.calls, hasLength(2));
    expect(find.text('重新加载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer reload stays on the original Host after active reader changes', (tester) async {
    final original = _Reader((id, path, call) async => throw const ArtifactError('offline'));
    final other = _Reader((id, path, call) async => throw const ArtifactError('missing'));
    final cached = CachedImageReader(original);
    await tester.pumpWidget(
      testApp(
        ProviderScope(
          overrides: [workspaceImageReaderProvider.overrideWithValue(cached)],
          child: MediaViewerPage(sessionId: 'original-session', meta: mediaMeta()),
        ),
      ),
    );
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(MediaViewerPage)));
    container.updateOverrides([workspaceImageReaderProvider.overrideWithValue(CachedImageReader(other))]);
    await tester.pump();
    await tester.tap(find.text('重新加载'));
    await pumpFrames(tester);
    expect(original.calls, hasLength(2));
    expect(other.calls, isEmpty);
    expect(original.calls.every((call) => call.$1 == 'original-session'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('feedback remains usable in a narrow tile with large text', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 90,
              child: MediaQuery.withClampedTextScaling(
                minScaleFactor: 2,
                maxScaleFactor: 2,
                child: MediaImageFeedback(error: '图片加载失败', onRetry: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
