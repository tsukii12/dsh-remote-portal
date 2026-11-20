// 「对话回放」: goldens (light + dark, playing and finished), the transport
// (play / pause, speed, seek, 全文), 「接着聊」, pictures from the file, and
// the bar's symmetry.
//
//   flutter test --update-goldens test/replay/replay_page_test.dart

import 'dart:convert';

import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/replay/continue_chat.dart';
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/shell/page_frame.dart' show GlassIconButton;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/rich_conversation.dart';

List<Override> _overrides({bool web = false}) => [
  settingsProvider.overrideWith(() => TestSettings()),
  if (web) uiModeProvider.overrideWith(_WebMode.new),
];

class _WebMode extends UiModeController {
  @override
  UiModeState build() => const UiModeState(mode: UiMode.web, loaded: true);
}

Future<ProviderContainer> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool autoplay = false,
  bool preview = false,
  bool web = false,
  ConversationShare? share,
}) async {
  await tester.runAsync(loadTestFonts);
  usePhoneView(tester);
  final asset = richAsset();
  late ProviderContainer container;
  await tester.pumpWidget(
    testApp(
      Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReplayPage(
                      share: share ?? richConversation(),
                      assets: {asset.id: asset},
                      autoplay: autoplay,
                      preview: preview,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          );
        },
      ),
      brightness: brightness,
      overrides: _overrides(web: web),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

/// The page's playback clock, read from the progress bar.
double _progress(WidgetTester tester) => tester.widget<Slider>(find.byKey(const ValueKey('replay-progress'))).value;

Future<void> _settleImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final brightness in Brightness.values) {
    final mode = brightness.name;

    testWidgets('finished replay golden ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      await tester.tap(find.byKey(const ValueKey('replay-all')));
      await tester.pumpAndSettle();
      // From the top: the prompt with its picture, the folded process.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 4000));
      await tester.pumpAndSettle();
      await _settleImages(tester);
      await expectLater(find.byType(ReplayPage), matchesGoldenFile('goldens/replay_end_$mode.png'));
    });

    testWidgets('playing replay golden ($mode)', (tester) async {
      await _open(tester, brightness: brightness);
      // Mid-turn: the code reply streaming in, the todo list over the button.
      await tester.tap(find.byKey(const ValueKey('replay-play')));
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (_progress(tester) > 0.42) break;
      }
      await tester.tap(find.byKey(const ValueKey('replay-play')));
      await tester.pump(const Duration(milliseconds: 400));
      await _settleImages(tester);
      await expectLater(find.byType(ReplayPage), matchesGoldenFile('goldens/replay_playing_$mode.png'));
    });
  }

  testWidgets('plays, pauses, changes speed, seeks and shows everything', (tester) async {
    await _open(tester);
    // Paused at the start: only the first turn's opening.
    expect(_progress(tester), 0);
    final play = find.byKey(const ValueKey('replay-play'));
    await tester.tap(play);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final at1 = _progress(tester);
    expect(at1, greaterThan(0));
    // 2×: the clock runs twice as fast.
    await tester.tap(find.byKey(const ValueKey('replay-speed')));
    await tester.pump();
    expect(find.text('2×'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    final at2 = _progress(tester);
    expect(at2 - at1, greaterThan(at1 * 1.5));
    await tester.tap(find.byKey(const ValueKey('replay-speed')));
    await tester.pump();
    expect(find.text('4×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('replay-speed')));
    await tester.pump();
    expect(find.text('1×'), findsOneWidget);
    // Pause holds the clock.
    await tester.tap(play);
    await tester.pump();
    final held = _progress(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), held);

    // Seek to the end by dragging the bar.
    final bar = find.byKey(const ValueKey('replay-progress'));
    await tester.drag(bar, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(_progress(tester), 1);
    expect(find.textContaining('18 个登录测试全部通过'), findsOneWidget);
    // Back to the start: the answer is gone again.
    await tester.drag(bar, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(_progress(tester), 0);
    expect(find.textContaining('18 个登录测试全部通过'), findsNothing);

    // 全文: everything, paused; the key has nothing left to do.
    await tester.tap(find.byKey(const ValueKey('replay-all')));
    await tester.pumpAndSettle();
    expect(_progress(tester), 1);
    expect(find.textContaining('18 个登录测试全部通过'), findsOneWidget);
    expect(tester.widget<GlassIconButton>(find.byKey(const ValueKey('replay-all'))).onPressed, isNull);
  });

  testWidgets('a whole replay runs to its end, then plays again from the start', (tester) async {
    await _open(tester, autoplay: true);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('replay-speed')));
    await tester.tap(find.byKey(const ValueKey('replay-speed')));
    await tester.pump();
    for (var i = 0; i < 200 && _progress(tester) < 1; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_progress(tester), 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('18 个登录测试全部通过'), findsOneWidget);
    // The todo list of the last turn stays, all done.
    expect(find.textContaining('全部完成', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('replay-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_progress(tester), lessThan(0.05));
  });

  testWidgets('接着聊 opens a new chat with the conversation attached', (tester) async {
    final container = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('replay-continue')));
    await tester.pumpAndSettle();
    expect(find.byType(ReplayPage), findsNothing);
    final request = container.read(composeInboxProvider).single;
    expect(request.text, continueChatPrompt);
    final file = request.attachments.single;
    expect(file.name, '修复登录重复提交.md');
    expect(file.isImage, isFalse);
    final md = utf8.decode(file.bytes);
    expect(md, startsWith('# 修复登录重复提交'));
    expect(md, contains('## 用户'));
    expect(md, contains('登录按钮连点会重复提交'));
    expect(md, contains('- 运行 `flutter test test/auth`'));
    expect(md, isNot(contains('用户说登录会重复提交')));
  });

  testWidgets('接着聊 in web mode: the page opens a new chat with it, not the native composer', (tester) async {
    final container = await _open(tester, web: true);
    await tester.tap(find.byKey(const ValueKey('replay-continue')));
    await tester.pumpAndSettle();
    expect(find.byType(ReplayPage), findsNothing);
    final open = container.read(webOpenProvider)!;
    expect(open.target.newSession, isTrue);
    expect(open.compose!.text, continueChatPrompt);
    expect(open.compose!.attachments.single.name, '修复登录重复提交.md');
    expect(container.read(composeInboxProvider), isEmpty);
  });

  testWidgets('the preview has no 接着聊', (tester) async {
    await _open(tester, preview: true);
    expect(find.byKey(const ValueKey('replay-continue')), findsNothing);
  });

  testWidgets('the picture comes from the file; a missing one shows its frame', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('replay-all')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 4000));
    await tester.pumpAndSettle();
    await _settleImages(tester);
    var provider = tester.widget<Image>(find.byType(Image).first).image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    expect(provider, isA<MemoryImage>());
    expect((provider as MemoryImage).bytes, richPicture);
  });

  testWidgets('bar symmetry: mirrored keys, even insets in the capsule', (tester) async {
    await _open(tester);
    final screen = tester.getSize(find.byType(ReplayPage));
    final back = tester.getRect(find.byKey(const ValueKey('replay-back')));
    final all = tester.getRect(find.byKey(const ValueKey('replay-all')));
    final title = tester.getRect(find.byKey(const ValueKey('replay-title')));
    expect(back.size, all.size);
    expect(back.left, closeTo(screen.width - all.right, 0.01));
    expect(back.center.dy, closeTo(all.center.dy, 0.01));
    expect(title.center.dy, closeTo(back.center.dy, 0.01));
    expect(title.left - back.right, closeTo(all.left - title.right, 0.01));

    final capsule = tester.getRect(find.byKey(const ValueKey('replay-transport')));
    final play = tester.getRect(find.byKey(const ValueKey('replay-play')));
    final speed = tester.getRect(find.byKey(const ValueKey('replay-speed')));
    expect(capsule.left, back.left);
    expect(capsule.right, closeTo(all.right, 0.01));
    expect(play.left - capsule.left, closeTo(ReplayHeader.inset, 0.01));
    expect(play.top - capsule.top, closeTo(ReplayHeader.inset, 0.01));
    expect(capsule.bottom - play.bottom, closeTo(ReplayHeader.inset, 0.01));
    expect(capsule.right - speed.right, closeTo(ReplayHeader.inset, 0.01));
    expect(speed.top - capsule.top, closeTo(ReplayHeader.inset, 0.01));
    expect(speed.height, play.height);

    final button = tester.getRect(find.byKey(const ValueKey('replay-continue')));
    expect(button.left, closeTo(screen.width - button.right, 0.01));
  });

  testWidgets('a turn still running when shared stays open; no rows after its end', (tester) async {
    final running = ConversationShare(
      title: '还在跑',
      start: richStart,
      entries: const [
        TurnEntry(t: 0),
        UserEntry(t: 10, text: '跑一下'),
        ToolEntry(
          t: 500,
          name: 'bash',
          verb: '运行',
          summary: 'sleep 100',
          args: {'command': 'sleep 100'},
          status: ToolOutcome.cancelled,
        ),
      ],
    );
    await _open(tester, share: running);
    await tester.tap(find.byKey(const ValueKey('replay-all')));
    await tester.pumpAndSettle();
    expect(find.text('跑一下'), findsOneWidget);
    expect(find.textContaining('sleep 100'), findsOneWidget);
  });

  test('markdown for 接着聊 keeps the work as one line a call', () {
    final md = conversationMarkdown(richConversation());
    expect(md.split('\n').where((l) => l.startsWith('- ')).length, 4);
    expect(md, contains('（附件：1 张图片）'));
    expect(ToolStatus.values, isNotEmpty);
  });
}
