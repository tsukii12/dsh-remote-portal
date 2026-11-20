// Goldens of the media card (n = 1–4, portrait and wide batches, a video
// poster, a gone file; running, refused, three of four), the viewer, and a
// generation request in the chat;
// light and dark, and 320dp at 1.3× text.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/features_state.dart' show jobsProvider;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/media/media_card.dart';
import 'package:dsh_app/ui/chat/media/media_viewer.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/fx/image_gen/image_generation.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support.dart';

Future<void> _pumpCards(
  WidgetTester tester,
  List<MediaMeta> metas, {
  required Brightness brightness,
  double width = 390,
  double height = 1800,
  double scale = 1,
  Set<String> missing = const {},
  bool actions = false,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
  final pictures = (await tester.runAsync(() => picturesFor(metas)))!..removeWhere((k, _) => missing.contains(k));
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AppBackdrop(
            child: MediaCardActions(
              regenerate: actions ? (_) {} : null,
              revise: actions ? (_) {} : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final meta in metas) ...[MediaCard(meta: meta, sessionId: 's1'), const SizedBox(height: 20)],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      brightness: brightness,
      overrides: [
        workspaceImageReaderProvider.overrideWithValue(CachedImageReader(FakeMediaReader(pictures))),
        jobsProvider.overrideWith((ref, id) => const Stream.empty()),
      ],
    ),
  );
  await pumpFrames(tester, 3);
  await settlePictures(tester, find.byType(MediaCard));
}

void main() {
  // The generation mosaic starts at a random moment; the same one every run here.
  ImageGeneration.debugSeed = 7;
  for (final brightness in Brightness.values) {
    final suffix = brightness.name;

    testWidgets('portrait batches n = 1–4 ($suffix)', (tester) async {
      await _pumpCards(
        tester,
        [
          mediaMeta(width: 1536, height: 2048, aspect: '3:4', cost: 0.3),
          mediaMeta(n: 2, width: 1536, height: 2048, aspect: '3:4', cost: 0.6),
          mediaMeta(n: 3, width: 1536, height: 2048, aspect: '3:4'),
          mediaMeta(n: 4, width: 1152, height: 2048, aspect: '9:16', cost: 1.2),
        ],
        brightness: brightness,
        height: 2050,
      );
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/media_cards_portrait_$suffix.png'));
    });

    testWidgets('wide batches n = 1–4, a video and a gone file ($suffix)', (tester) async {
      final gone = mediaMeta(n: 2, width: 2048, height: 2048, label: 'Qwen Image 3.0', asked: 3);
      await _pumpCards(
        tester,
        [
          mediaMeta(width: 2048, height: 1152, aspect: '16:9', cost: 0.3),
          mediaMeta(n: 2, width: 2048, height: 1152, aspect: '16:9'),
          mediaMeta(n: 3, width: 2048, height: 1152, aspect: '16:9'),
          mediaMeta(n: 4, width: 2048, height: 1536, aspect: '4:3'),
          mediaMeta(video: true, width: 1280, height: 720, aspect: '16:9', duration: 5, label: 'Seedance 2.0', cost: 4),
          gone,
        ],
        brightness: brightness,
        height: 2500,
        missing: {gone.items.last.path.split('/').last},
      );
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/media_cards_wide_$suffix.png'));
    });

    testWidgets('running, refused, unauthorized, three of four ($suffix)', (tester) async {
      MediaMeta state(String status, {String? code, String aspect = '16:9', int n = 1}) => MediaMeta.fromJson({
        'v': 1,
        'rid': 'm_$status$code',
        'kind': 'image',
        'status': status,
        'items': const [],
        'request': {'provider': 'ark', 'label': 'Seedream 5.0', 'aspect': aspect, 'n': n},
        'prompt': '画一只在窗台上打盹的橘猫',
        if (code != null) 'error': {'code': code},
      })!;
      await _pumpCards(
        tester,
        [
          state('running', aspect: '3:4', n: 2),
          state('failed', code: 'policy'),
          state('failed', code: 'auth'),
          mediaMeta(n: 3, asked: 4, width: 2048, height: 2048, cost: 0.9),
        ],
        brightness: brightness,
        height: 1420,
        actions: true,
      );
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/media_states_$suffix.png'));
    });

    testWidgets('320dp at 1.3× ($suffix)', (tester) async {
      await _pumpCards(
        tester,
        [
          mediaMeta(n: 2, width: 1536, height: 2048, aspect: '3:4', cost: 0.6, label: 'Seedream 5.0 Pro 高像素版'),
          mediaMeta(n: 4, width: 1152, height: 2048, aspect: '9:16'),
          mediaMeta(width: 2048, height: 1152, aspect: '16:9', cost: 0.25),
        ],
        brightness: brightness,
        width: 320,
        height: 1300,
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/media_cards_320_$suffix.png'));
    });

    testWidgets('a generation request in the chat ($suffix)', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
      tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
      addTearDown(tester.view.reset);
      final transcript = fixtureTranscript('synthetic_header_image');
      final media = toolMedia(transcript.items.whereType<ToolChatItem>().single)!;
      final pictures = (await tester.runAsync(() => picturesFor([media])))!;
      final harness = ChatHarness(
        session: 's1',
        states: {'s1': ChatState(loading: false, items: transcript.items, turns: transcript.turns)},
      );
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          brightness: brightness,
          overrides: [
            ...harness.overrides,
            workspaceImageReaderProvider.overrideWithValue(CachedImageReader(FakeMediaReader(pictures))),
          ],
        ),
      );
      await pumpFrames(tester);
      await settlePictures(tester, find.byType(MediaCard));
      await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/media_chat_$suffix.png'));
    });

    testWidgets('viewer ($suffix)', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
      tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 32);
      addTearDown(tester.view.reset);
      final meta = mediaMeta(n: 4, width: 1536, height: 2048, aspect: '3:4', cost: 1.2);
      final pictures = (await tester.runAsync(() => picturesFor([meta])))!;
      await tester.pumpWidget(
        testApp(
          MediaViewerPage(sessionId: 's1', meta: meta, initial: 1, onEdit: (_, _) {}),
          brightness: brightness,
          overrides: [workspaceImageReaderProvider.overrideWithValue(CachedImageReader(FakeMediaReader(pictures)))],
        ),
      );
      await pumpFrames(tester, 3);
      await settlePictures(tester, find.byType(MediaViewerPage));
      await expectLater(find.byType(MediaViewerPage), matchesGoldenFile('goldens/media_viewer_$suffix.png'));
    });
  }
}
