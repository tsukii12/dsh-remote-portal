import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/memory_card.dart';
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

Map<String, Object?> memory(String marker) => {
  'entries': [
    {'scope': 'own', 'topic': 'travel', 'text': marker},
  ],
};
Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final entity in ['bot', 'room']) {
    for (final mode in ['cached', 'pending', 'new-error', 'reconnect']) {
      testWidgets('$entity memory $mode never exposes prior connection contents', (t) async {
        final old = FakeDsBotTransport()..helloOnFeed = false;
        final next = FakeDsBotTransport()..helloOnFeed = false;
        final oldRead = Completer<Object?>();
        final nextRead = Completer<Object?>();
        old.handlers['memory-view'] = (_) => mode == 'pending' ? oldRead.future : memory('OLD_HOST_MEMORY');
        next.handlers['memory-view'] = (_) => nextRead.future;
        addTearDown(() {
          if (!oldRead.isCompleted) oldRead.complete(memory('OLD_HOST_MEMORY'));
          if (!nextRead.isCompleted) nextRead.complete(memory('NEW_HOST_MEMORY'));
        });
        var opens = 0;
        usePhoneView(t);
        await t.pumpWidget(
          goldenApp(
            home: Scaffold(
              body: entity == 'bot' ? const BotMemoryCard(botId: 'b2') : const BotMemoryCard(roomId: 'r1'),
            ),
            brightness: Brightness.light,
            overrides: [
              activeHostProvider.overrideWith(_Host.new),
              activeConnectionProvider.overrideWith((ref) {
                final h = ref.watch(activeHostProvider);
                return AsyncData(
                  HostConnection(
                    client: fakeConnection.client,
                    label: h.id,
                    isLocal: h.isLocal,
                    kind: h.kind,
                    hostId: h.id,
                  ),
                );
              }),
              dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(opens++ == 0 ? old : next)),
            ],
          ),
        );
        await frames(t);
        final c = ProviderScope.containerOf(t.element(find.byType(BotMemoryCard)));
        if (mode != 'pending') expect(find.text('OLD_HOST_MEMORY'), findsOneWidget);
        if (mode == 'reconnect') {
          c.read(dsBotProvider.notifier).retry();
        } else {
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        }
        await frames(t);
        expect(c.read(dsBotProvider).ready, isTrue);
        expect(
          find.text('OLD_HOST_MEMORY'),
          findsNothing,
          reason: 'stale entries must not be actionable on another connection',
        );
        expect(next.endpoints, contains('memory-view'));
        if (mode == 'pending') {
          oldRead.complete(memory('OLD_HOST_MEMORY'));
          await frames(t);
          expect(find.text('OLD_HOST_MEMORY'), findsNothing);
        }
        if (mode == 'new-error') {
          nextRead.completeError(const DshTransportException('new read failed'));
        } else {
          nextRead.complete(memory('NEW_HOST_MEMORY'));
        }
        await frames(t);
        expect(find.text('OLD_HOST_MEMORY'), findsNothing);
        expect(find.text('NEW_HOST_MEMORY'), mode == 'new-error' ? findsNothing : findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }
}
