// Symmetry of the forum's floating and paired controls, measured:
// - the composer's bottom row: 图片 / 分享码 / 发送 all 40 tall on one line,
//   the first and last [kSheetGutter] in from the sheet's edges;
// - the topic page's 「写回复…」 pill: 12 from both screen edges, like the
//   chat composer;
// - the home bar: the account key and the bell are the same 44 circle on one
//   line, 12 from the right edge like the back key on the left;
// - 「发帖」 floats 12 from the right and bottom (above the gesture bar);
// - a share card: the glyph's left inset equals the button's right inset.

import 'package:dsh_app/ui/common/app_sheet.dart' show kSheetGutter;
import 'package:dsh_app/ui/forum/forum_composer_sheet.dart';
import 'package:dsh_app/ui/forum/forum_home_page.dart';
import 'package:dsh_app/ui/forum/forum_post_body.dart';
import 'package:dsh_app/ui/forum/forum_topic_page.dart';
import 'package:dsh_app/ui/shell/page_frame.dart' show GlassIconButton;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../providers/support.dart' show settle;
import '../shell/golden_harness.dart';
import 'support.dart';

const _width = 390.0;
const _height = 844.0;
const _bottomInset = 24.0;

void main() {
  Future<void> pump(WidgetTester tester, Widget home, {bool signedIn = true}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: home,
        brightness: Brightness.light,
        overrides: forumOverrides(FakeForumApi(signedIn: signedIn), auth: signedIn ? signedInAuth : signedOutAuth),
      ),
    );
    await settle(tester);
  }

  testWidgets('composer toolbar: one line, equal heights, mirrored insets', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showForumComposer(context, const ForumNewTopicTarget()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    final sheet = tester.getRect(find.byType(ForumComposerSheet));
    final image = tester.getRect(find.byKey(const ValueKey('forum-composer-image')));
    final share = tester.getRect(find.byKey(const ValueKey('forum-composer-share')));
    final send = tester.getRect(find.byKey(const ValueKey('forum-composer-send')));
    expect(image.height, ForumComposerToolbar.height);
    expect(share.height, ForumComposerToolbar.height);
    expect(send.height, ForumComposerToolbar.height);
    expect(image.width, image.height, reason: 'the image key is a circle');
    expect(share.center.dy, closeTo(image.center.dy, 0.01));
    expect(send.center.dy, closeTo(image.center.dy, 0.01));
    expect(image.left - sheet.left, closeTo(kSheetGutter, 0.01));
    expect(sheet.right - send.right, closeTo(kSheetGutter, 0.01));
    expect(share.left - image.right, 8);
  });

  testWidgets('reply pill: 12 from both edges and above the gesture bar', (tester) async {
    await pump(tester, const ForumTopicPage(topicId: 101));
    final pill = tester.getRect(find.ancestor(of: find.text('写回复…'), matching: find.byType(GlassSurface)).first);
    expect(pill.left, closeTo(12, 0.01));
    expect(_width - pill.right, closeTo(12, 0.01));
    expect(_height - pill.bottom, closeTo(_bottomInset + 12, 0.01));
    expect(pill.height, 48);
    final veil = tester.widgetList<BackdropVeil>(find.byType(BackdropVeil)).singleWhere((v) => !v.fromTop);
    final top = _height - veil.solidHeight.value - veil.feather;
    expect(top, closeTo(pill.top - 8, 0.01));
  });

  testWidgets('home bar: bell and account are twin 44 circles, mirrored with the back key', (tester) async {
    await pump(tester, const ForumHomePage());
    final back = tester.getRect(find.byType(GlassIconButton).first);
    final bell = tester.getRect(find.byTooltip('通知，3 条未读'));
    final account = tester.getRect(find.byTooltip('论坛账号'));
    expect(account.size, const Size(44, 44));
    expect(bell.size, account.size);
    expect(account.center.dy, closeTo(bell.center.dy, 0.01));
    expect(account.center.dy, closeTo(back.center.dy, 0.01));
    expect(_width - account.right, closeTo(back.left, 0.01));
    expect(account.left - bell.right, 8);

    final compose = tester.getRect(find.byType(ForumComposeButton));
    expect(_width - compose.right, closeTo(12, 0.01));
    expect(_height - compose.bottom, closeTo(_bottomInset + 12, 0.01));
    expect(compose.height, ForumComposeButton.height);
  });

  testWidgets('signed out: the account key alone takes the same seat', (tester) async {
    await pump(tester, const ForumHomePage(), signedIn: false);
    final back = tester.getRect(find.byType(GlassIconButton).first);
    final account = tester.getRect(find.byTooltip('登录论坛'));
    expect(account.size, const Size(44, 44));
    expect(_width - account.right, closeTo(back.left, 0.01));
  });

  testWidgets('share card: glyph and button inset alike, centred on one line', (tester) async {
    await pump(tester, const ForumTopicPage(topicId: 101));
    final card = tester.getRect(find.byType(ForumShareCard));
    final button = tester.getRect(find.widgetWithText(FilledButton, '安装'));
    final glyph = tester.getRect(
      find.ancestor(of: find.byIcon(AppIcons.plugin), matching: find.byType(SizedBox)).first,
    );
    expect(glyph.size, const Size.square(ForumShareCard.glyphSize));
    expect(glyph.left - card.left, closeTo(card.right - button.right, 0.01));
    expect(glyph.center.dy, closeTo(card.center.dy, 0.01));
    expect(button.center.dy, closeTo(card.center.dy, 0.01));
  });
}
