// Symmetry of the Bot pages, measured: the chat header's keys and the face
// in its title pill, the @ picker's rows, the unread badge, the monogram and
// the color swatches.

import 'package:dsh_app/ui/bots/bot_avatar.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bot_mention.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/page_hero.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget page, {FakeDsBotTransport? transport}) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(home: page, brightness: Brightness.light, overrides: dsBotOverrides(transport ?? FakeDsBotTransport())),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void near(double a, double b, String what) => expect((a - b).abs(), lessThan(0.6), reason: '$what: $a vs $b');

  testWidgets('the chat header mirrors its keys and centers the face in the pill', (tester) async {
    await pump(tester, const RoomChatPage(roomId: 'r1'));
    final screen = tester.getSize(find.byType(Scaffold).first);
    final back = tester.getRect(find.byKey(const ValueKey('bot-back')));
    final details = tester.getRect(find.byKey(const ValueKey('bot-details')));
    final pill = tester.getRect(find.byKey(const ValueKey('bot-title')));
    final face = tester.getRect(find.byKey(const ValueKey('bot-face')));
    expect(back.size, const Size(44, 44));
    expect(details.size, const Size(44, 44));
    near(back.left, screen.width - details.right, 'outer insets');
    near(back.left, 12, 'inset from the edge');
    near(pill.height, 44, 'pill height');
    near(back.center.dy, pill.center.dy, 'back and pill centers');
    near(details.center.dy, pill.center.dy, 'details and pill centers');
    near(face.left - pill.left, face.top - pill.top, 'face left vs top');
    near(face.top - pill.top, pill.bottom - face.bottom, 'face top vs bottom');
    near(pill.left - back.right, 8, 'gap after back');
  });

  testWidgets('the @ picker keeps the same air on both sides of its rows', (tester) async {
    await pump(tester, const RoomChatPage(roomId: 'r1'));
    await tester.enterText(find.byType(TextField), '@');
    await tester.pump(const Duration(milliseconds: 300));
    final picker = tester.getRect(find.byType(BotMentionPicker));
    final row = find.byKey(const ValueKey('mention-Chief'));
    final face = tester.getRect(find.descendant(of: row, matching: find.byType(BotAvatar)));
    final tag = tester.getRect(find.descendant(of: row, matching: find.byType(BotTag)));
    final title = tester.getRect(find.text('成员'));
    near(face.left - picker.left, picker.right - tag.right, 'row insets');
    near(title.left, face.left, 'section title on the faces\' edge');
    final rowRect = tester.getRect(row);
    near(face.center.dy, rowRect.center.dy, 'face centered in its row');
  });

  testWidgets('the unread badge is a 20 capsule with its count centered', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(
          body: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [UnreadBadge(3), UnreadBadge(128)]),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    final one = tester.getRect(find.byType(UnreadBadge).first);
    expect(one.size, const Size(20, 20));
    near(tester.getCenter(find.text('3')).dx, one.center.dx, 'count centered');
    final wide = tester.getRect(find.byType(UnreadBadge).last);
    expect(wide.height, 20);
    near(tester.getCenter(find.text('99+')).dx, wide.center.dx, 'wide count centered');
  });

  testWidgets('a monogram\'s letter sits in the middle of its circle', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const Scaffold(
          body: Center(
            child: BotMonogram(name: 'Writer', color: 'violet', size: 40),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    final circle = tester.getRect(find.byType(BotMonogram));
    near(tester.getCenter(find.text('W')).dx, circle.center.dx, 'letter centered across');
    expect((tester.getCenter(find.text('W')).dy - circle.center.dy).abs(), lessThan(1.5));
  });

  testWidgets('the color swatches fill their rows edge to edge, evenly', (tester) async {
    usePhoneView(tester);
    String picked = 'blue';
    await tester.pumpWidget(
      goldenApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(32),
            child: StatefulBuilder(
              builder: (context, setState) =>
                  BotColorPicker(selected: picked, onPick: (color) => setState(() => picked = color)),
            ),
          ),
        ),
        brightness: Brightness.light,
      ),
    );
    final picker = tester.getRect(find.byType(BotColorPicker));
    Rect swatch(String color) => tester.getRect(find.byKey(ValueKey('color-$color')));
    near(swatch(dsBotPickerColors.first).left, picker.left, 'first swatch on the left edge');
    near(swatch(dsBotPickerColors[4]).right, picker.right, 'row end on the right edge');
    near(swatch(dsBotPickerColors[5]).left, picker.left, 'second row starts on the edge');
    near(swatch(dsBotPickerColors.last).right, picker.right, 'second row ends on the edge');
    final gap1 = swatch(dsBotPickerColors[1]).left - swatch(dsBotPickerColors[0]).right;
    final gap2 = swatch(dsBotPickerColors[2]).left - swatch(dsBotPickerColors[1]).right;
    near(gap1, gap2, 'even gaps');
    await tester.tap(find.byKey(const ValueKey('color-green')));
    await tester.pump();
    expect(picked, 'green');
  });

  /// The composer's keys as end caps (the rule of `composer_geometry_test.dart`):
  /// the left key mirrors send, same 36 circle, same gap to every edge.
  void expectEndCaps(WidgetTester tester, Rect left) {
    final capsule = tester.getRect(find.byType(Composer));
    final send = tester.getRect(
      find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedContainer)).first,
    );
    final side = left.left - capsule.left;
    expect(left.size, const Size(36, 36));
    expect(send.size, left.size);
    near(capsule.right - send.right, side, 'right gap vs left gap');
    for (final key in [left, send]) {
      near(key.top - capsule.top, side, 'top gap');
      near(capsule.bottom - key.bottom, side, 'bottom gap');
    }
    // The text starts where the chat's own composer starts it: after the key.
    near(tester.getRect(find.byType(TextField)).left - left.right, 8, 'text after the left key');
  }

  testWidgets('in a group the @ key mirrors send, and opens the member list', (tester) async {
    await pump(tester, const RoomChatPage(roomId: 'r1'));
    expectEndCaps(tester, tester.getRect(find.byKey(const ValueKey('mention-key'))));
    await tester.tap(find.byKey(const ValueKey('mention-key')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '@');
    expect(find.byType(BotMentionPicker), findsOneWidget);
  });

  testWidgets('Bot composer starts at the text inset and keeps the send end cap', (tester) async {
    await pump(tester, const BotChatPage(botId: 'b2'));
    final capsule = tester.getRect(find.byType(Composer));
    final field = tester.getRect(find.byType(TextField));
    near(field.left - capsule.left, 18, 'text starts without an empty key');
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '给 Writer 发消息…');
    final send = tester.getRect(
      find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedContainer)).first,
    );
    expect(send.size, const Size(36, 36));
    near(capsule.right - send.right, 6, 'send right');
    near(send.top - capsule.top, 6, 'send top');
    near(capsule.bottom - send.bottom, 6, 'send bottom');
  });

  testWidgets('new rows align with the avatar rows', (tester) async {
    await pump(tester, const BotsPage());
    for (final (add, title) in [('新建 Bot', 'Chief'), ('新建群聊', '发布会')]) {
      near(tester.getRect(find.text(add)).left, tester.getRect(find.text(title)).left, 'title edges');
      final addRow = find.widgetWithText(ListPageRow, add);
      final row = find.widgetWithText(ListPageRow, title);
      final icon = tester.getRect(find.descendant(of: addRow, matching: find.byType(Icon)).first);
      final avatar = tester.getRect(
        find.descendant(of: row, matching: find.byType(add == '新建 Bot' ? BotAvatar : RoomAvatar)).first,
      );
      near(icon.center.dx, avatar.center.dx, 'leading centres');
    }
  });

  testWidgets('approval buttons mirror the composer width', (tester) async {
    await pump(tester, const RoomChatPage(roomId: 'r1'), transport: approvalTransport());
    final card = tester.getRect(find.byType(GroupApprovalCard));
    final composer = tester.getRect(find.byType(Composer));
    final a = tester.getRect(find.widgetWithText(OutlinedButton, '拒绝'));
    final b = tester.getRect(find.widgetWithText(FilledButton, '允许本次'));
    near(card.left, composer.left, 'card and composer left');
    near(card.right, composer.right, 'card and composer right');
    near(a.left - card.left, 16, 'left padding');
    near(card.right - b.right, 16, 'right padding');
    near(a.width, b.width, 'button widths');
    near(a.height, 44, 'reject height');
    near(b.height, 44, 'allow height');
    near(b.left - a.right, 12, 'button gap');
  });

  testWidgets('Bot header fits at twice the system text size', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: const RoomChatPage(roomId: 'r1'),
        ),
      ),
    );
    final title = tester.getRect(find.byKey(const ValueKey('bot-title')));
    final status = tester.getRect(find.text('3 位成员'));
    expect(status.top, greaterThanOrEqualTo(title.top));
    expect(status.bottom, lessThanOrEqualTo(title.bottom));
    expect(tester.takeException(), isNull);
  });

  for (final room in [false, true]) {
    testWidgets('detail figures share width for room=$room', (tester) async {
      await pump(tester, room ? const RoomDetailsPage(roomId: 'r1') : const BotDetailsPage(botId: 'b2'));
      final stats = tester.widgetList<HeroStat>(find.byType(HeroStat)).toList();
      expect(stats, hasLength(room ? 2 : 3));
      final rects = [for (final stat in stats) tester.getRect(find.byWidget(stat))];
      for (final rect in rects.skip(1)) {
        near(rect.width, rects.first.width, 'figure widths');
        near(rect.top, rects.first.top, 'figure tops');
      }
    });
  }
}
