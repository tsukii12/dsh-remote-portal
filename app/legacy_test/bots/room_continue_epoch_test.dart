// Regression based on the independent W1 review reproducer.
import 'dart:async';

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
import 'room_continue_test.dart' show frames;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef host) => state = host;
}

Map<String, Object?> pausedTeam(String call) {
  final team = sampleTeam(working: false);
  ((team['rooms'] as List).single as Map<String, Object?>)['paused'] = [
    {'id': call, 'botId': 'b2'},
  ];
  return team;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('pending old-host continuation never blocks new-host room', (tester) async {
    final old = FakeDsBotTransport(team: pausedTeam('old-call'))..helloOnFeed = false;
    final next = FakeDsBotTransport(team: pausedTeam('new-call'))..helloOnFeed = false;
    final pending = Completer<Object?>();
    old.handlers['room-continue'] = (_) => pending.future;
    final nextPending = Completer<Object?>();
    next.handlers['room-continue'] = (_) => nextPending.future;
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
          dsBotApiFactoryProvider.overrideWithValue((connection) => DsBotApi((connection.hostId == HostRef.none.id) ? old : next)),
        ],
      ),
    );
    await frames(tester);
    final button = find.byKey(const ValueKey('room-continue'));
    await tester.tap(button);
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(RoomChatPage)));
    container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
    await frames(tester);
    expect(container.read(dsBotProvider).team!.room('r1')!.pausedCallIds, ['new-call']);
    expect(
      tester.widget<FilledButton>(button).onPressed,
      isNotNull,
      reason: 'new host may continue while old request is stalled',
    );
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    pending.complete(true);
    await frames(tester);
    expect(
      tester.widget<FilledButton>(button).onPressed,
      isNull,
      reason: 'old completion cannot release the new request',
    );
    nextPending.complete(true);
    await frames(tester);
  });
}
