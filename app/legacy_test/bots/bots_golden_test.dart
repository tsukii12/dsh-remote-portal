// Goldens (light + dark) of the Bot pages: the home with unread and working
// states, the install card, a Bot chat with a question card, a group chat
// with the @ picker open, both details pages, the new Bot form and the new
// group sheet. Regenerate with
// `flutter test --update-goldens test/bots/bots_golden_test.dart`.

import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/new_bot_page.dart';
import 'package:dsh_app/ui/bots/new_room_sheet.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

/// Renders [home] at phone width and [height] in light and dark.
void goldenBots(
  String name,
  Widget Function() home, {
  required FakeDsBotTransport Function() transport,
  Future<void> Function(WidgetTester tester, FakeDsBotTransport transport)? before,
  double height = 844,
  List<Override> extra = const [],
}) {
  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('$name ($mode)', (tester) async {
      useBotGoldenClock();
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(loadGoldenFonts);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(390 * 2, height * 2);
      tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
      addTearDown(tester.view.reset);
      final fake = transport();
      await tester.pumpWidget(
        goldenApp(home: home(), brightness: brightness, overrides: [...dsBotOverrides(fake), ...extra]),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The photo decodes off the frame clock.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
      if (before != null) await before(tester, fake);
      await tester.pump(const Duration(milliseconds: 600));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));
    });
  }
}

Map<String, Object?> notice(int seq, String kind, String text, {String? roomId}) => {
  'seq': seq,
  'kind': kind,
  'botId': 'b2',
  'name': 'Writer',
  'roomId': ?roomId,
  'title': roomId == null ? null : '发布会',
  'text': text,
  // Today at a fixed clock time, so the row's time reads the same on every run.
  'time': todayAt(9, 40 + seq).millisecondsSinceEpoch,
};

void main() {
  goldenBots(
    'bots_home',
    () => const BotsPage(),
    transport: FakeDsBotTransport.new,
    before: (tester, fake) async {
      fake
        ..emit('notice', notice(1, 'message', '海报文案我今晚给出，先发你一版提纲。'))
        ..emit('notice', notice(2, 'message', '提纲在 docs/poster.md'))
        ..emit('notice', notice(3, 'group', '初稿写好了，放在 docs/launch.md', roomId: 'r1'));
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  goldenBots(
    'bots_home_install',
    () => const BotsPage(),
    transport: () => FakeDsBotTransport()..handlers['hello'] = (_) => throw const DshHttpException(404, 'missing'),
  );

  goldenBots(
    'bot_chat',
    () => const BotChatPage(botId: 'm1'),
    transport: () => FakeDsBotTransport(
      team: sampleTeam(
        working: false,
        questions: {
          'm1c': {
            'id': 'q1',
            'question': '演示脚本交给 Coder 吗？',
            'options': [
              {'label': '交给 Coder'},
              {'label': '我自己写'},
            ],
          },
        },
      ),
    ),
  );

  goldenBots(
    'room_chat_mention',
    () => const RoomChatPage(roomId: 'r1'),
    transport: () => FakeDsBotTransport()
      ..roomRunning = true
      ..roomSpeaking = 'b3',
    before: (tester, fake) async {
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  goldenBots('bot_details', () => const BotDetailsPage(botId: 'm1'), transport: FakeDsBotTransport.new, height: 1500);

  goldenBots(
    'room_details',
    () => const RoomDetailsPage(roomId: 'r1'),
    transport: FakeDsBotTransport.new,
    height: 1300,
  );

  goldenBots('new_bot', () => const NewBotPage(), transport: FakeDsBotTransport.new, height: 980);

  goldenBots(
    'new_room_sheet',
    () => const _SheetHost(),
    transport: FakeDsBotTransport.new,
    before: (tester, fake) async {
      await tester.tap(find.text('open'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('member-m1')));
      await tester.tap(find.byKey(const ValueKey('member-b2')));
      await tester.pump(const Duration(milliseconds: 300));
    },
  );
}

/// A page with a button that opens the new group sheet.
class _SheetHost extends StatelessWidget {
  const _SheetHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => showNewRoomSheet(context), child: const Text('open')),
    ),
  );
}
