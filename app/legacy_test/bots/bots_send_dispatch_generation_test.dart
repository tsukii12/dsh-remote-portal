import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'room_continue_test.dart' show frames;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final room in [false, true]) {
    for (final change in ['host', 'HTTP boot', 'readOnly', if (!room) 'part', 'unchanged']) {
      testWidgets('${room ? 'room' : 'bot'} send validates its rendered target before clearing draft: $change', (
        tester,
      ) async {
        final old = FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
        final next = FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
        next.handlers['hello'] = (_) => {...next.helloAnswer(), 'boot': 'boot-2'};
        var reconnect = false;
        usePhoneView(tester);
        await tester.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: room ? const RoomChatPage(roomId: 'r1') : const BotChatPage(botId: 'b2'),
            overrides: [
              activeHostProvider.overrideWith(_Host.new),
              activeConnectionProvider.overrideWith((ref) {
                final host = ref.watch(activeHostProvider);
                return AsyncData(
                  HostConnection(
                    client: fakeConnection.client,
                    label: host.id,
                    isLocal: host.isLocal,
                    kind: host.kind,
                    hostId: host.id,
                  ),
                );
              }),
              dsBotApiFactoryProvider.overrideWithValue(
                (connection) => DsBotApi((connection.hostId == HostRef.none.id) && !reconnect ? old : next),
              ),
            ],
          ),
        );
        await frames(tester);
        final composer = tester.widget<Composer>(find.byType(Composer));
        composer.controller.text = 'SYNTHETIC draft from the rendered target';
        final container = ProviderScope.containerOf(tester.element(find.byType(Composer)));
        final originalApi = container.read(dsBotProvider.notifier).api;
        if (change == 'host') {
          container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        } else if (change == 'HTTP boot') {
          reconnect = true;
          old.emit('hello', {'api': 1, 'boot': 'boot-2', 'seq': 0, 'revision': 1});
        } else if (change == 'readOnly' || change == 'part') {
          final team = sampleTeam(working: false);
          if (change == 'readOnly') {
            team['readOnly'] = 'another-host';
          } else {
            (team['bots'] as List).firstWhere((bot) => bot['id'] == 'b2')['sessionId'] = 'new-part';
          }
          old.handlers['state'] = (_) => team;
          await container.read(dsBotProvider.notifier).refresh();
        }
        if (change == 'host' || change == 'HTTP boot') {
          for (var i = 0; i < 12; i++) {
            await tester.idle();
            container.read(dsBotProvider);
          }
          expect(container.read(dsBotProvider).ready, isTrue);
          expect(container.read(dsBotProvider).hello?.boot, 'boot-2');
          expect(container.read(dsBotProvider.notifier).api, isNot(same(originalApi)));
        }
        // Still no rendered frame after the identity/read-only change.
        composer.onSend();
        await frames(tester);
        expect(
          next.endpoints.where((endpoint) => endpoint == 'send'),
          isEmpty,
          reason: 'an old composer callback must not submit its draft through the new API',
        );
        expect(old.endpoints.where((endpoint) => endpoint == 'send'), change == 'unchanged' ? hasLength(1) : isEmpty);
        expect(
          composer.controller.text,
          change == 'unchanged' ? '' : 'SYNTHETIC draft from the rendered target',
          reason: 'a rejected stale action must not erase text that was never sent',
        );
        if (change == 'host' || change == 'HTTP boot' || change == 'part') {
          final current = tester.widget<Composer>(find.byType(Composer));
          current.controller.text = 'SYNTHETIC fresh draft';
          current.onSend();
          await frames(tester);
          final recipient = change == 'part' ? old : next;
          expect(recipient.endpoints.where((endpoint) => endpoint == 'send'), hasLength(1));
          expect(current.controller.text, isEmpty);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
