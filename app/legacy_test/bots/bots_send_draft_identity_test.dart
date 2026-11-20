import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
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
import 'support.dart';

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_send_draft.json').readAsStringSync()) as Map;
  for (final room in [false, true]) {
    for (final mode in [
      'reconnect',
      'current failure',
      'new input cleared',
      'new input',
      'reconnect new input',
      'current success',
      'entity ABA',
    ]) {
      testWidgets('${room ? 'room' : 'bot'} failed-send draft ownership: $mode', (t) async {
        usePhoneView(t);
        final pending = Completer<Object?>();
        final old = FakeDsBotTransport()..helloOnFeed = false;
        final next = FakeDsBotTransport()..helloOnFeed = false;
        old.handlers['send'] = (_) => pending.future;
        var reconnect = false;
        await t.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: room ? const RoomChatPage(roomId: 'r1') : const BotChatPage(botId: 'b2'),
            overrides: [
              activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
              dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(reconnect ? next : old)),
            ],
          ),
        );
        await frames(t);
        final c = ProviderScope.containerOf(t.element(find.byType(Composer)));
        final origin = c.read(dsBotProvider.notifier).api;
        final host = c.read(dsBotProvider).host;
        final editor = t.widget<Composer>(find.byType(Composer));
        editor.controller.text = 'SYNTHETIC old draft';
        editor.onSend();
        await frames(t);
        expect(old.endpoints.where((e) => e == 'send'), hasLength(1));
        expect(editor.controller.text, isEmpty);
        if (mode.startsWith('reconnect')) {
          reconnect = true;
          c.read(dsBotProvider.notifier).retry();
          await frames(t);
          expect(c.read(dsBotProvider).host, host);
          expect(c.read(dsBotProvider).ready, isTrue);
          expect(identical(c.read(dsBotProvider.notifier).api, origin), isFalse);
        }
        if (mode == 'entity ABA') {
          final removed = sampleTeam();
          if (room) {
            removed['rooms'] = <Object?>[];
          } else {
            removed['bots'] = (removed['bots'] as List).where((b) => b['id'] != 'b2').toList();
          }
          old.handlers['state'] = (_) => removed;
          await c.read(dsBotProvider.notifier).refresh();
          old.handlers['state'] = (_) => sampleTeam();
          await c.read(dsBotProvider.notifier).refresh();
          // Both state transitions precede the next rendered frame.
        }
        final newInput = mode.endsWith('new input');
        if (mode == 'new input cleared') {
          final controller = t.widget<Composer>(find.byType(Composer)).controller;
          controller.text = 'SYNTHETIC intervening draft';
          controller.clear();
        }
        if (newInput) t.widget<Composer>(find.byType(Composer)).controller.text = 'SYNTHETIC new draft';
        if (mode == 'current success') {
          pending.complete(fixture['success']['value']);
        } else {
          final error = fixture[room ? 'roomFailure' : 'botFailure']['error'] as Map;
          pending.completeError(DshRemoteException(error['code'] as String, error['message'] as String));
        }
        await frames(t);
        expect(
          t.widget<Composer>(find.byType(Composer)).controller.text,
          newInput
              ? 'SYNTHETIC new draft'
              : (mode == 'current failure' || mode == 'new input cleared')
              ? 'SYNTHETIC old draft'
              : '',
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final aba in [false, true]) {
    testWidgets('Bot part ${aba ? 'ABA without a frame' : 'change'} retires failed-send restoration', (t) async {
      usePhoneView(t);
      final pending = Completer<Object?>();
      final fake = FakeDsBotTransport()..helloOnFeed = false;
      fake.handlers['send'] = (_) => pending.future;
      await t.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: const BotChatPage(botId: 'b2'),
          overrides: dsBotOverrides(fake),
        ),
      );
      await frames(t);
      final c = ProviderScope.containerOf(t.element(find.byType(Composer)));
      final input = t.widget<Composer>(find.byType(Composer));
      input.controller.text = 'SYNTHETIC old draft';
      input.onSend();
      await frames(t);
      final changed = sampleTeam();
      (changed['bots'] as List).firstWhere((b) => b['id'] == 'b2')['sessionId'] = 'b2-next';
      fake.handlers['state'] = (_) => changed;
      await c.read(dsBotProvider.notifier).refresh();
      if (aba) {
        fake.handlers['state'] = (_) => sampleTeam();
        await c.read(dsBotProvider.notifier).refresh();
      }
      final error = fixture['botFailure']['error'] as Map;
      pending.completeError(DshRemoteException(error['code'] as String, error['message'] as String));
      await frames(t);
      expect(t.widget<Composer>(find.byType(Composer)).controller.text, isEmpty);
      expect(t.takeException(), isNull);
    });
  }
}
