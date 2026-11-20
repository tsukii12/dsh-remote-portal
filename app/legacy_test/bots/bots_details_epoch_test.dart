import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef host) => state = host;
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final action in [
    'bot-delete',
    'room-delete',
    'bot-name',
    'room-name',
    'room-member',
    'memory-add',
    'memory-edit',
    'memory-delete',
  ]) {
    for (final switched in [false, true]) {
      testWidgets('$action target with switched=$switched', (tester) async {
        final old = FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
        final next = FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
        final endpoint = switch (action) {
          'bot-delete' => 'delete-bot',
          'room-delete' => 'delete-room',
          'bot-name' => 'update-bot',
          'room-name' || 'room-member' => 'update-room',
          'memory-edit' => 'memory-edit',
          'memory-delete' => 'memory-forget',
          _ => 'memory-add',
        };
        old.handlers[endpoint] = (_) => true;
        next.handlers[endpoint] = (_) => true;
        final isRoom = action.startsWith('room');
        usePhoneView(tester);
        await tester.pumpWidget(
          goldenApp(
            home: isRoom ? const RoomDetailsPage(roomId: 'r1') : const BotDetailsPage(botId: 'm1'),
            brightness: Brightness.light,
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
              dsBotApiFactoryProvider.overrideWithValue((connection) => DsBotApi((connection.hostId == HostRef.none.id) ? old : next)),
            ],
          ),
        );
        await frames(tester);
        final container = ProviderScope.containerOf(
          tester.element(isRoom ? find.byType(RoomDetailsPage) : find.byType(BotDetailsPage)),
        );
        final label = switch (action) {
          'bot-delete' => appL10n.botsDeleteBot,
          'room-delete' => appL10n.botsDeleteGroup,
          'bot-name' => appL10n.botsBotName,
          'room-name' => appL10n.botsGroupName,
          'room-member' => 'Coder',
          'memory-edit' || 'memory-delete' => '回复尽量简短，先说结论',
          _ => appL10n.botsAddMemory,
        };
        await tester.scrollUntilVisible(find.text(label), 250, scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(find.text(label));
        await frames(tester);
        await tester.tap(find.text(label));
        await frames(tester);
        if (action == 'memory-edit') {
          await tester.tap(find.text(appL10n.commonEdit));
          await frames(tester);
        }
        if (!action.endsWith('delete') && action != 'room-member') {
          await tester.enterText(find.byType(TextField), 'From the old host');
        }
        if (switched) container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        await frames(tester);
        expect(container.read(dsBotProvider).ready, isTrue);
        final confirm = action == 'room-member'
            ? appL10n.botsSetAdmin
            : action.endsWith('delete')
            ? appL10n.commonDelete
            : action == 'memory-add'
            ? appL10n.commonAdd
            : appL10n.commonSave;
        await tester.tap(
          action == 'memory-delete' || action == 'room-member'
              ? find.text(confirm)
              : find.widgetWithText(FilledButton, confirm),
        );
        await frames(tester);
        expect(next.endpoints, isNot(contains(endpoint)), reason: 'stale $action must not target new host');
        expect(
          old.endpoints,
          switched ? isNot(contains(endpoint)) : contains(endpoint),
          reason: 'only current $action may mutate original target',
        );
      });
    }
  }
}
