import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/install_card.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class MissingFeed extends FakeDsBotTransport {
  final stream = StreamController<DsBotSseEvent>();
  @override
  Stream<DsBotSseEvent> openFeed() {
    feedOpens++;
    return stream.stream;
  }

  @override
  Future<void> close() => stream.close();
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_official_v023.json').readAsStringSync()) as Map;
  final officialError = DshRemoteException.fromJson((fixture['hello'] as Map)['body']['error']);
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, page) in <(String, Widget)>[
    ('home', const BotsPage()),
    ('bot chat', const BotChatPage(botId: 'm1')),
    ('room chat', const RoomChatPage(roomId: 'r1')),
    ('bot details', const BotDetailsPage(botId: 'm1')),
    ('room details', const RoomDetailsPage(roomId: 'r1')),
  ]) {
    testWidgets('official v0.2.3 $name explains capability and opens Web', (tester) async {
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw officialError;
      var webOpens = 0;
      usePhoneView(tester);
      await tester.pumpWidget(
        goldenApp(
          home: page,
          brightness: Brightness.light,
          overrides: [...dsBotOverrides(fake), dsBotWebOpenerProvider.overrideWithValue((_, _) => webOpens++)],
        ),
      );
      await frames(tester);
      expect(find.text(appL10n.botsMobileUnsupportedTitle), findsOneWidget);
      expect(find.text(appL10n.botsMobileApiRequired), findsOneWidget);
      // The copy names no release: none with the mobile API has shipped yet.
      expect(find.textContaining(RegExp(r'v\d+\.\d+')), findsNothing);
      expect(fake.feedOpens, 0);
      expect(fake.endpoints, ['hello']);
      await tester.ensureVisible(find.byKey(const ValueKey('dsbot-open-web')));
      await tester.tap(find.byKey(const ValueKey('dsbot-open-web')));
      expect(webOpens, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('missing route at 320dp 2x $brightness has explicit capability and Web action', (tester) async {
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw const DshHttpException(404, 'controlled missing route');
      usePhoneView(tester);
      tester.view.physicalSize = const Size(640, 1688);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        goldenApp(
          home: const BotsPage(),
          brightness: brightness,
          overrides: [...dsBotOverrides(fake), dsBotWebOpenerProvider.overrideWithValue((_, _) {})],
        ),
      );
      await frames(tester);
      expect(find.text(appL10n.botsMobileApiMissing), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('dsbot-open-web')));
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('dsbot-open-web'))).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing feed hides already loaded room and Retry recovers', (tester) async {
    final fake = MissingFeed();
    final next = FakeDsBotTransport();
    var opens = 0;
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RoomChatPage(roomId: 'r1'),
        brightness: Brightness.light,
        overrides: [
          ...(dsBotOverrides(fake)..removeAt(1)),
          dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(opens++ == 0 ? fake : next)),
          dsBotWebOpenerProvider.overrideWithValue((_, _) {}),
        ],
      ),
    );
    await frames(tester);
    expect(find.byType(TextField), findsOneWidget);
    fake.stream.addError(const DshHttpException(404, 'controlled missing feed'));
    await frames(tester);
    expect(find.text(appL10n.botsMobileUnsupportedTitle), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(fake.feedOpens, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('dsbot-recheck-mobile')));
    await tester.tap(find.byKey(const ValueKey('dsbot-recheck-mobile')));
    await frames(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(next.endpoints, contains('hello'));
  });
}
