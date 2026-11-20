import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final f = jsonDecode(
    File('../packages/dsh_client/test/fixtures/dsbot_chat_live_race.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final first in [true, false]) {
    test(
      'actual live message survives ${first ? 'initial history' : 'reconnect history'} generated before it',
      () async {
        final delayed = Completer<Object?>();
        final fake = FakeDsBotTransport()..helloOnFeed = false;
        fake.handlers['chat'] = (_) => first ? delayed.future : f['snapshot']['value'];
        final c = dsBotContainer(fake);
        addTearDown(c.dispose);
        c.listen(dsBotProvider, (_, _) {});
        await settle(12);
        c.listen(botChatProvider('b2'), (_, _) {});
        await settle(12);
        if (!first) {
          fake.handlers['chat'] = (_) => delayed.future;
          fake.emit('hello', {'api': 1, 'boot': 'boot-1', 'seq': 0, 'revision': 7});
          await settle(12);
        }
        fake.emit('message', Map<String, Object?>.from(f['live']['data']));
        await settle(8);
        expect(c.read(botChatProvider('b2')).items.any((i) => i.text == 'SYNTHETIC live reply'), isTrue);
        delayed.complete(f['snapshot']['value']);
        await settle(12);
        expect(c.read(botChatProvider('b2')).items.map((i) => i.text), [
          'SYNTHETIC prior message',
          'SYNTHETIC live reply',
        ]);
      },
    );
  }
  test('live row already present in the completed snapshot appears once', () async {
    final delayed = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (_) => delayed.future;
    final c = dsBotContainer(fake);
    addTearDown(c.dispose);
    c.listen(dsBotProvider, (_, _) {});
    await settle(12);
    c.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    fake.emit('message', Map<String, Object?>.from(f['live']['data']));
    await settle();
    delayed.complete(f['after']['value']);
    await settle(12);
    expect(c.read(botChatProvider('b2')).items.length, 2);
  });
  test('later authoritative empty page drops old rows without retaining a permanent union', () async {
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (_) => f['after']['value'];
    final c = dsBotContainer(fake);
    addTearDown(c.dispose);
    c.listen(dsBotProvider, (_, _) {});
    await settle(12);
    c.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    expect(c.read(botChatProvider('b2')).items.length, 2);
    fake.handlers['chat'] = (_) => f['empty']['value'];
    await c.read(botChatProvider('b2').notifier).reload();
    expect(c.read(botChatProvider('b2')).items, isEmpty);
  });
  test('failed read clears its live journal and next authoritative read can remove it', () async {
    final delayed = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (_) => delayed.future;
    final c = dsBotContainer(fake);
    addTearDown(c.dispose);
    c.listen(dsBotProvider, (_, _) {});
    await settle(12);
    c.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    fake.emit('message', Map<String, Object?>.from(f['live']['data']));
    await settle();
    delayed.completeError(StateError('synthetic history failure'));
    await settle(12);
    expect(c.read(botChatProvider('b2')).error, isNotNull);
    expect(c.read(botChatProvider('b2')).items.length, 1);
    fake.handlers['chat'] = (_) => f['empty']['value'];
    await c.read(botChatProvider('b2').notifier).reload();
    expect(c.read(botChatProvider('b2')).items, isEmpty);
    expect(c.read(botChatProvider('b2')).error, isNull);
  });
  test('superseded read completion cannot release the current live journal', () async {
    final older = Completer<Object?>(), current = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (_) => older.future;
    final c = dsBotContainer(fake);
    addTearDown(c.dispose);
    c.listen(dsBotProvider, (_, _) {});
    await settle(12);
    c.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    fake.handlers['chat'] = (_) => current.future;
    final loading = c.read(botChatProvider('b2').notifier).reload();
    older.complete(f['empty']['value']);
    await settle();
    fake.emit('message', Map<String, Object?>.from(f['live']['data']));
    await settle();
    current.complete(f['snapshot']['value']);
    await loading;
    expect(c.read(botChatProvider('b2')).items.map((i) => i.text), ['SYNTHETIC prior message', 'SYNTHETIC live reply']);
  });
  test('a live arrival from another part is not attached to the authoritative page', () async {
    final delayed = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (_) => delayed.future;
    final c = dsBotContainer(fake);
    addTearDown(c.dispose);
    c.listen(dsBotProvider, (_, _) {});
    await settle(12);
    c.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    fake.emit('message', {...Map<String, Object?>.from(f['live']['data']), 'sessionId': 'different-part'});
    await settle();
    delayed.complete(f['snapshot']['value']);
    await settle(12);
    expect(c.read(botChatProvider('b2')).items.map((i) => i.text), ['SYNTHETIC prior message']);
  });
}
