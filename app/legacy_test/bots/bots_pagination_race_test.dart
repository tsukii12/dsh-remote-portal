// Regression based on the independent W1 review reproducer.
import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Map<String, Object?> page(String id, {Object? cursor}) => {
  'sessionId': 'b2-c',
  'roomId': 'r1',
  'items': [
    {'id': id, 'kind': 'bot', 'text': id, 'time': 1},
  ],
  'cursor': cursor,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final room in [false, true]) {
    test('${room ? 'room' : 'bot'} refresh completion preserves earlier read started afterwards', () async {
      final fake = FakeDsBotTransport()..helloOnFeed = false;
      final endpoint = room ? 'room-chat' : 'chat';
      fake.handlers[endpoint] = (_) => page('first', cursor: 'older');
      final c = dsBotContainer(fake);
      addTearDown(c.dispose);
      c.listen(dsBotProvider, (_, _) {});
      await settle(12);
      if (room) {
        c.listen(roomChatProvider('r1'), (_, _) {});
      } else {
        c.listen(botChatProvider('b2'), (_, _) {});
      }
      await settle(12);
      final fresh = Completer<Object?>(), older = Completer<Object?>();
      fake.handlers[endpoint] = (p) => p['cursor'] == null ? fresh.future : older.future;
      final refreshing = room
          ? c.read(roomChatProvider('r1').notifier).refresh()
          : c.read(botChatProvider('b2').notifier).reload();
      await settle();
      final paging = room
          ? c.read(roomChatProvider('r1').notifier).loadEarlier()
          : c.read(botChatProvider('b2').notifier).loadEarlier();
      await settle();
      fresh.complete(page('first', cursor: 'older'));
      await refreshing;
      final busy = room ? c.read(roomChatProvider('r1')).loadingEarlier : c.read(botChatProvider('b2')).loadingEarlier;
      older.complete(page('old'));
      await paging;
      expect(
        busy,
        isTrue,
        reason: 'refresh started before earlier read; its completion must not unlock that live read',
      );
    });
  }
}
