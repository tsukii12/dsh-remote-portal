import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/new_bot_page.dart';
import 'package:dsh_app/ui/bots/new_room_sheet.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
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

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final kind in ['bot', 'room']) {
    for (final mode in [
      'late-host',
      'late-reconnect',
      'selected-host',
      'readonly',
      if (kind == 'room') 'removed',
      'same',
    ]) {
      testWidgets('$kind creation $mode keeps request and navigation on its origin', (t) async {
        final old = FakeDsBotTransport()..helloOnFeed = false;
        final next = FakeDsBotTransport()..helloOnFeed = false;
        final pending = Completer<Object?>();
        final endpoint = kind == 'bot' ? 'create-bot' : 'create-room';
        final reply = kind == 'bot'
            ? {'id': 'b2', 'name': 'Writer', 'sessionId': 'b2'}
            : {
                'id': 'r1',
                'name': '发布会',
                'members': ['m1', 'b2'],
              };
        old.handlers[endpoint] = (_) => mode.startsWith('late') ? pending.future : reply;
        next.handlers[endpoint] = (_) => reply;
        usePhoneView(t);
        if (mode == 'selected-host') {
          t.view.physicalSize = const Size(640, 1688);
          t.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        }
        await t.pumpWidget(
          goldenApp(
            brightness: mode == 'selected-host' ? Brightness.dark : Brightness.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () {
                    if (kind == 'bot') {
                      Navigator.of(context).push(NewBotPage.route());
                    } else {
                      showNewRoomSheet(context);
                    }
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
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
              dsBotApiFactoryProvider.overrideWithValue((c) => DsBotApi((c.hostId == HostRef.none.id) ? old : next)),
            ],
          ),
        );
        await t.tap(find.text('Open'));
        await frames(t);
        final page = kind == 'bot' ? find.byType(NewBotPage) : find.byType(NewRoomSheet);
        final container = ProviderScope.containerOf(t.element(page));
        if (kind == 'bot') {
          await t.enterText(find.byKey(const ValueKey('bot-name')), 'Writer');
        } else {
          await t.tap(find.byKey(const ValueKey('member-m1')));
          await t.tap(find.byKey(const ValueKey('member-b2')));
        }
        await frames(t);
        final create = find.byKey(ValueKey('$kind-create'));
        if (mode.startsWith('late')) {
          await t.tap(create);
          await frames(t);
          expect(old.endpoints, contains(endpoint));
        }
        if (mode == 'late-host' || mode == 'selected-host') {
          container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        }
        if (mode == 'late-reconnect') {
          container.read(dsBotProvider.notifier).retry();
        }
        if (mode == 'removed') {
          final team = sampleTeam();
          team['bots'] = (team['bots'] as List).where((b) => (b as Map)['id'] != 'b2').toList();
          old.handlers['state'] = (_) => team;
          await container.read(dsBotProvider.notifier).refresh();
        }
        if (mode == 'readonly') {
          old.handlers['state'] = (_) => {...sampleTeam(), 'readOnly': 'owned elsewhere'};
          await container.read(dsBotProvider.notifier).refresh();
        }
        await frames(t);
        final reads = next.endpoints.where((e) => e == 'state').length;
        if (mode.startsWith('late')) {
          pending.complete(reply);
          await frames(t);
        } else if (mode == 'same') {
          await t.tap(create);
          await frames(t);
        } else {
          expect(t.widget<FilledButton>(create).onPressed, isNull);
        }
        if (mode == 'same') {
          expect(kind == 'bot' ? find.byType(BotChatPage) : find.byType(RoomChatPage), findsOneWidget);
        } else {
          expect(page, findsOneWidget);
          if (mode.contains('host') || mode == 'late-reconnect') {
            expect(find.text('连接已变化，请重新打开创建页面后再操作。'), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
          }
          expect(next.endpoints, isNot(contains(endpoint)));
          expect(
            next.endpoints.where((e) => e == 'state').length,
            reads,
            reason: 'old completion must not refresh new host',
          );
        }
        expect(t.takeException(), isNull);
      });
    }
  }
}
