import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Feed extends FakeDsBotTransport {
  bool failReconnect = false;
  bool silentReconnect = false;
  @override
  Stream<DsBotSseEvent> openFeed() {
    if (failReconnect && silentReconnect) return const Stream.empty();
    if (failReconnect) return Stream.error(const DshTransportException('synthetic SSE unavailable'));
    return super.openFeed();
  }
}

Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in ['connected', 'early loss', 'late loss', 'HTTP recovers', 'feed recovers', 'stopped']) {
    testWidgets('room polling $mode', (t) async {
      final fixture =
          jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_room_poll.json').readAsStringSync()) as Map;
      final running = Map<String, Object?>.from(fixture['running']['value'] as Map);
      final finished = Map<String, Object?>.from(fixture['finished']['value'] as Map);
      final fake = _Feed();
      var current = mode == 'stopped' ? finished : running;
      var failHttp = false;
      fake.handlers['room-chat'] = (_) {
        if (failHttp) {
          failHttp = false;
          throw const DshTransportException('synthetic HTTP unavailable');
        }
        return current;
      };
      final c = dsBotContainer(fake);
      try {
        c.listen(dsBotProvider, (_, _) {});
        c.listen(roomChatProvider('r1'), (_, _) {});
        await flush(t);
        expect(c.read(dsBotProvider).feedConnected, isTrue);
        expect(
          c.read(roomChatProvider('r1')).running,
          mode != 'stopped',
          reason: '${fake.endpoints} ${c.read(roomChatProvider("r1")).error}',
        );
        final reads = fake.endpoints.where((v) => v == 'room-chat').length;
        if (mode != 'early loss' && mode != 'HTTP recovers') {
          await t.pump(const Duration(seconds: 4));
          await flush(t);
          expect(
            fake.endpoints.where((v) => v == 'room-chat').length,
            reads,
            reason: 'no polling while feed is connected',
          );
        }
        if (mode != 'connected') {
          fake.failReconnect = true;
          fake.silentReconnect = mode == 'HTTP recovers';
          unawaited(fake.dropFeed());
          await flush(t);
          expect(c.read(dsBotProvider).feedConnected, isFalse);
        }
        current = finished;
        failHttp = mode == 'HTTP recovers';
        if (mode == 'feed recovers') {
          fake.failReconnect = false;
          await t.pump(const Duration(seconds: 1));
          await flush(t);
          expect(c.read(dsBotProvider).feedConnected, isTrue);
        }
        await t.pump(const Duration(seconds: 4));
        await flush(t);
        if (mode == 'connected' || mode == 'stopped') {
          expect(fake.endpoints.where((v) => v == 'room-chat').length, reads);
          expect(c.read(roomChatProvider('r1')).running, mode == 'connected');
        } else {
          expect(fake.endpoints.where((v) => v == 'room-chat').length, greaterThan(reads));
          if (mode == 'HTTP recovers') {
            expect(c.read(roomChatProvider('r1')).error, isNotNull);
            expect(c.read(roomChatProvider('r1')).running, isTrue);
            await t.pump(const Duration(seconds: 4));
            await flush(t);
          }
          expect(c.read(roomChatProvider('r1')).running, isFalse);
          expect(c.read(roomChatProvider('r1')).items.last.text, 'SYNTHETIC final reply');
          expect(c.read(roomChatProvider('r1')).speaking, isNull);
          expect(c.read(roomChatProvider('r1')).error, isNull);
          final settledReads = fake.endpoints.where((v) => v == 'room-chat').length;
          await t.pump(const Duration(seconds: 4));
          await flush(t);
          expect(
            fake.endpoints.where((v) => v == 'room-chat').length,
            settledReads,
            reason: 'stopped round or recovered feed must not keep polling',
          );
        }
        expect(t.takeException(), isNull);
      } finally {
        // Let all scripted failed reconnect attempts settle before disposal.
        fake.failReconnect = false;
        await t.pump(const Duration(seconds: 11));
        await flush(t);
        c.dispose();
        await flush(t);
      }
    });
  }
}
