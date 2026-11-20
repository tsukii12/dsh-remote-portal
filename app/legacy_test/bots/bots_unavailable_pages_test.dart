import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/features/feature_kit.dart';
import 'package:dsh_app/ui/features/feature_widgets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'bots_mobile_unavailable_test.dart' show frames;
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, page, room) in <(String, Widget, bool)>[
    ('bot details', const BotDetailsPage(botId: 'b2'), false),
    ('bot chat', const BotChatPage(botId: 'b2'), false),
    ('room details', const RoomDetailsPage(roomId: 'r1'), true),
    ('room chat', const RoomChatPage(roomId: 'r1'), true),
  ]) {
    for (final scenario in [
      'hello failure',
      'state failure',
      'offline',
      'relay',
      'disconnect',
      'empty',
      'connecting',
    ]) {
      testWidgets('$name distinguishes $scenario from a missing entity', (tester) async {
        final fake = FakeDsBotTransport(team: sampleTeam(working: false));
        final hello = Completer<Object?>();
        var connected = scenario != 'offline';
        var fail = true;
        if (scenario == 'hello failure') {
          fake.handlers['hello'] = (_) =>
              fail ? throw const DshTransportException('SYNTHETIC hello failure') : fake.helloAnswer();
        } else if (scenario == 'state failure') {
          fake.handlers['state'] = (_) =>
              fail ? throw const FormatException('SYNTHETIC state failure') : sampleTeam(working: false);
        } else if (scenario == 'empty') {
          fake.handlers['state'] = (_) => {...sampleTeam(working: false), 'bots': <Object?>[], 'rooms': <Object?>[]};
        } else if (scenario == 'connecting') {
          fake.handlers['hello'] = (_) => hello.future;
        }
        usePhoneView(tester);
        await tester.pumpWidget(
          goldenApp(
            home: page,
            brightness: Brightness.light,
            overrides: [
              activeConnectionProvider.overrideWith((ref) => AsyncData(connected ? fakeConnection : null)),
              dsBotApiFactoryProvider.overrideWithValue((_) => scenario == 'relay' ? null : DsBotApi(fake)),
            ],
          ),
        );
        await frames(tester);
        final container = ProviderScope.containerOf(tester.element(find.byWidget(page)));
        if (scenario == 'disconnect') {
          expect(container.read(dsBotProvider).ready, isTrue);
          connected = false;
          container.invalidate(activeConnectionProvider);
          await frames(tester);
        }
        if (scenario == 'hello failure' || scenario == 'state failure') {
          expect(container.read(dsBotProvider).availability, DsBotAvailability.failed);
          expect(find.text(appL10n.botsTeamLoadFailed), findsOneWidget);
          expect(find.byType(FeatureMessage), findsOneWidget);
          expect(find.byType(QuietSpinner), findsNothing);
          expect(find.text(room ? appL10n.botsRoomGone : appL10n.botsBotGone), findsNothing);
          fail = false;
          await tester.tap(find.text(appL10n.commonRetry));
          await frames(tester);
          expect(container.read(dsBotProvider).ready, isTrue);
          expect(fake.endpoints.where((endpoint) => endpoint == 'hello'), hasLength(2));
          expect(find.text(appL10n.botsTeamLoadFailed), findsNothing);
        } else if (scenario == 'offline' || scenario == 'disconnect') {
          expect(container.read(dsBotProvider).availability, DsBotAvailability.offline);
          expect(find.byType(FeatureOffline), findsOneWidget);
          expect(find.byType(QuietSpinner), findsNothing);
          expect(find.text(room ? appL10n.botsRoomGone : appL10n.botsBotGone), findsNothing);
        } else if (scenario == 'relay') {
          expect(container.read(dsBotProvider).availability, DsBotAvailability.relay);
          expect(find.text(appL10n.botsRelayUnavailable), findsOneWidget);
          expect(find.text(appL10n.botsUseSsh), findsOneWidget);
          expect(find.byType(QuietSpinner), findsNothing);
        } else if (scenario == 'empty') {
          expect(container.read(dsBotProvider).ready, isTrue);
          expect(find.text(room ? appL10n.botsRoomGone : appL10n.botsBotGone), findsOneWidget);
          expect(find.byType(QuietSpinner), findsNothing);
        } else {
          expect(container.read(dsBotProvider).availability, DsBotAvailability.connecting);
          expect(find.byType(QuietSpinner), findsOneWidget);
          hello.complete(fake.helloAnswer());
          await frames(tester);
          expect(container.read(dsBotProvider).ready, isTrue);
          expect(find.byType(QuietSpinner), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
