// Every way into 「分享」 opens the same panel, and every way out is one tap
// from it: the key under a reply (beside 复制, the same size), a reply inside
// a replay (shared from the replay, not from the open chat). The long-press
// menu, the drawer and a delivered file are covered beside their own widgets
// (message_actions_test, wiring_test, artifact_card_test).

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/state/artifacts.dart' show FilesChannel;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/replay/conversation_out.dart';
import 'package:dsh_app/ui/replay/replay_page.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_image_page.dart';
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_app/ui/share/share_panel_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../replay/support/rich_conversation.dart';
import 'support.dart';

class _Out extends ConversationOut {
  _Out(Directory dir) : super(files: const FilesChannel(), cacheRoot: () async => dir);

  final shared = <(File, ConversationFormat)>[];
  final texts = <String>[];

  @override
  Future<void> shareFile(File file, ConversationFormat format) async => shared.add((file, format));

  @override
  Future<void> shareText(String text) async => texts.add(text);
}

class _Links implements ConversationLinkMaker {
  final uploads = <String>[];

  @override
  Future<ConversationLink> upload(Uint8List fileBytes, LinkExpiry expiry, {required String title}) async {
    uploads.add(title);
    return ConversationLink(url: Uri.parse('https://go.example.cn/c/a1B2c3D4e5#k=${'K' * 43}'), id: 'a1B2c3D4e5');
  }

  @override
  Future<void> revoke(ConversationLink link) async {}

  @override
  Future<void> restore(ConversationLink link) async {}

  @override
  Duration get undoWindow => const Duration(seconds: 4);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
    if (i > 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(SharePanel), matching: find.byTooltip('返回')));
  await tester.pumpAndSettle();
}

/// From the panel's first page: every way out opens, and back.
Future<void> _everyWayOut(WidgetTester tester, _Out out) async {
  await _key(tester, 'share-to-link');
  expect(find.byType(ShareLinkPage), findsOneWidget);
  await _back(tester);
  await _key(tester, 'share-to-image');
  expect(find.byType(ShareImagePage), findsOneWidget);
  await _back(tester);
  await _key(tester, 'share-to-file');
  expect(find.byType(ShareFilePage), findsOneWidget);
  await _key(tester, 'share-file-send');
  expect(out.shared, isNotEmpty);
  await _back(tester);
  await _key(tester, 'share-to-text');
  expect(out.texts, isNotEmpty);
  expect(find.byType(SharePanelHome), findsOneWidget);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('share-entries'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('the key under a reply: beside 复制, the same size; the panel at this reply', (tester) async {
    final out = _Out(dir);
    final state = shareChatState();
    final harness = ChatHarness(session: 's1', states: {'s1': state});
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          ...harness.overrides,
          conversationOutProvider.overrideWithValue(out),
          conversationLinkMakerProvider.overrideWithValue(_Links()),
        ],
      ),
    );
    await pumpFrames(tester);

    final share = find.byKey(const ValueKey('reply-share')).last;
    final copy = find.byTooltip('复制').last;
    final shareBox = tester.getRect(share);
    final copyBox = tester.getRect(copy);
    expect(shareBox.size, copyBox.size, reason: 'the row\'s 36 keys');
    expect(shareBox.top, copyBox.top);
    expect(shareBox.left, moreOrLessEquals(copyBox.right), reason: 'keys sit box to box, as the row does');
    expect(tester.getSize(find.descendant(of: share, matching: find.byType(Icon))), const Size.square(20));
    expect(find.byTooltip('分享'), findsWidgets);
    expect(find.byTooltip('好的回答'), findsNothing);

    await tester.tap(share);
    await pumpFrames(tester);
    expect(find.byType(SharePanel), findsOneWidget);
    final scope = tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>));
    expect(scope.selected, ShareScope.reply);
    expect(tester.widget<ShareCard>(find.byType(ShareCard)).content.blocks.last, isA<ShareAnswer>());
    await _everyWayOut(tester, out);
  });

  testWidgets('a reply in a replay shares from the replay: its card, its file, its pictures', (tester) async {
    final out = _Out(dir);
    final asset = richAsset();
    usePhoneView(tester);
    await tester.runAsync(loadTestFonts);
    await tester.pumpWidget(
      testApp(
        ReplayPage(share: richConversation(), assets: {asset.id: asset}, autoplay: false),
        overrides: [
          settingsProvider.overrideWith(() => TestSettings()),
          conversationOutProvider.overrideWithValue(out),
          conversationLinkMakerProvider.overrideWithValue(_Links()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全文'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reply-share')).last);
    await _settle(tester);
    expect(find.byType(SharePanel), findsOneWidget);
    final card = tester.widget<ShareCard>(find.byType(ShareCard)).content;
    expect(card.title, '修复登录重复提交');
    expect((card.blocks.first as ShareQuestion).text, startsWith('登录按钮连点会重复提交'));

    await _key(tester, 'share-to-file');
    await _key(tester, 'share-file-send');
    final file = decodeConversationFile(out.shared.single.$1.readAsStringSync());
    expect(file.share.title, '修复登录重复提交');
    expect(file.share.entries.whereType<UserEntry>().single.text, startsWith('登录按钮连点会重复提交'));
    expect(file.assets.keys, [asset.id], reason: 'the picture comes from the replayed file');
    await _back(tester);
    await _everyWayOut(tester, out);
  });
}
