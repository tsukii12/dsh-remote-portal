import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'room_continue_epoch_test.dart' show pausedTeam;
import 'room_continue_test.dart' show frames;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final transition in [
    'host before frame',
    'HTTP boot rehandshake',
    'read-only before frame',
    'pause changed before frame',
    'same boot refresh',
    'unchanged',
  ]) {
    testWidgets('rendered Continue belongs to its generation: $transition', (tester) async {
      final old = FakeDsBotTransport(team: pausedTeam('old-call'))..helloOnFeed = false;
      final next = FakeDsBotTransport(team: pausedTeam('new-call'))..helloOnFeed = false;
      old.handlers['room-continue'] = (_) => true;
      next.handlers['room-continue'] = (_) => true;
      next.handlers['hello'] = (_) => {...next.helloAnswer(), 'boot': 'boot-2'};
      var reconnect = false;
      usePhoneView(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: const RoomChatPage(roomId: 'r1'),
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
      final button = find.byKey(const ValueKey('room-continue'));
      final oldAction = tester.widget<FilledButton>(button).onPressed!;
      final container = ProviderScope.containerOf(tester.element(find.byType(RoomChatPage)));
      final oldApi = container.read(dsBotProvider.notifier).api;
      if (transition == 'host before frame') {
        container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        // Deliberately no pump: the visible callback is still the old one.
      } else if (transition == 'HTTP boot rehandshake') {
        reconnect = true;
        old.emit('hello', {'api': 1, 'boot': 'boot-2', 'seq': 0, 'revision': 1});
        await frames(tester);
        expect(container.read(dsBotProvider).hello?.boot, 'boot-2');
        expect(container.read(dsBotProvider.notifier).api, isNot(same(oldApi)));
      } else if (transition == 'read-only before frame') {
        old.handlers['state'] = (_) => {...pausedTeam('old-call'), 'readOnly': 'another-host'};
        await container.read(dsBotProvider.notifier).refresh();
      } else if (transition == 'pause changed before frame') {
        old.handlers['state'] = (_) => pausedTeam('changed-call');
        await container.read(dsBotProvider.notifier).refresh();
      } else if (transition == 'same boot refresh') {
        old.handlers['state'] = (_) => pausedTeam('old-call');
        await container.read(dsBotProvider.notifier).refresh();
      }
      oldAction();
      await frames(tester);
      expect(
        next.endpoints.where((endpoint) => endpoint == 'room-continue'),
        isEmpty,
        reason: 'an action rendered by the old generation must not use the new API',
      );
      expect(
        old.endpoints.where((endpoint) => endpoint == 'room-continue'),
        transition == 'unchanged' || transition == 'same boot refresh' ? hasLength(1) : isEmpty,
      );
      if (transition == 'unchanged') {
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        oldAction();
        await frames(tester);
        expect(
          old.endpoints.where((endpoint) => endpoint == 'room-continue'),
          hasLength(1),
          reason: 'a successful parked call stays deduplicated even through the old callback',
        );
      }
      if (transition == 'host before frame' ||
          transition == 'HTTP boot rehandshake' ||
          transition == 'pause changed before frame') {
        // The new generation still has an operable continuation button.
        final fresh = tester.widget<FilledButton>(button).onPressed;
        expect(fresh, isNotNull);
        fresh!();
        await frames(tester);
        final recipient = transition == 'pause changed before frame' ? old : next;
        expect(recipient.endpoints.where((endpoint) => endpoint == 'room-continue'), hasLength(1));
      } else if (transition == 'read-only before frame') {
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
      }
    });
  }
}
