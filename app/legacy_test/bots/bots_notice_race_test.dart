import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Map<String, Object?> notice(int seq, {String kind = 'message'}) => {
  'seq': seq,
  'kind': kind,
  'botId': 'b2',
  'name': 'Writer',
  'text': 'Notice $seq',
  'time': seq,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = 'dsbot_cursor_${HostRef.none.encode()}';
  setUp(() => SharedPreferences.setMockInitialValues({key: '{"boot":"boot-1","seq":0}'}));

  Future<ProviderContainer> start(FakeDsBotTransport fake) async {
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    container.listen(dsBotInboxProvider, (_, _) {});
    await settle(12);
    return container;
  }

  test('a live notice racing catch-up is counted once and cannot acknowledge the gap', () async {
    final pending = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['notices'] = (_) => pending.future;
    final container = await start(fake);
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 2});
    await settle();
    fake.emit('notice', notice(2));
    await settle();
    expect(container.read(dsBotInboxProvider).total, 1);
    expect((await SharedPreferences.getInstance()).getString(key), '{"boot":"boot-1","seq":0}');
    pending.complete({
      'boot': 'boot-1',
      'seq': 2,
      'reset': false,
      'notices': [notice(1), notice(2)],
    });
    await settle(12);
    expect(container.read(dsBotInboxProvider).total, 2);
    expect((await SharedPreferences.getInstance()).getString(key), '{"boot":"boot-1","seq":2}');
    fake.emit('notice', notice(2));
    await settle();
    expect(container.read(dsBotInboxProvider).total, 2);
  });

  test('overlapping live and backlog notice only increments unread once', () async {
    final pending = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['notices'] = (_) => pending.future;
    final container = await start(fake);
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 1});
    await settle();
    fake.emit('notice', notice(1));
    await settle();
    pending.complete({
      'boot': 'boot-1',
      'seq': 1,
      'reset': false,
      'notices': [notice(1)],
    });
    await settle(12);
    expect(container.read(dsBotInboxProvider).total, 1);
  });

  test('an old boot catch-up cannot overwrite a restarted feed cursor', () async {
    final pending = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['notices'] = (_) => pending.future;
    final container = await start(fake);
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 8});
    await settle();
    // A real plugin restart changes both HTTP hello and the newly opened feed.
    fake.handlers['hello'] = (_) => {...fake.helloAnswer(), 'boot': 'boot-2'};
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-2', 'seq': 0});
    await settle(12);
    // This fake disables automatic feed hello; send the replacement feed's hello.
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-2', 'seq': 0});
    await settle(12);
    pending.complete({
      'boot': 'boot-1',
      'seq': 8,
      'reset': false,
      'notices': [notice(8)],
    });
    await settle(12);
    expect(container.read(dsBotInboxProvider).total, 0);
    expect(jsonDecode((await SharedPreferences.getInstance()).getString(key)!), {'boot': 'boot-2', 'seq': 0});
  });

  test('failed catch-up preserves the gap and deduplicates live notices on retry', () async {
    final pending = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['notices'] = (_) => pending.future;
    final container = await start(fake);
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 2});
    await settle();
    fake.emit('notice', notice(2));
    pending.completeError(StateError('temporary disconnect'));
    await settle(12);
    expect((await SharedPreferences.getInstance()).getString(key), '{"boot":"boot-1","seq":0}');
    fake.handlers['notices'] = (_) => {
      'boot': 'boot-1',
      'seq': 2,
      'reset': false,
      'notices': [notice(1), notice(2)],
    };
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-1', 'seq': 2});
    await settle(12);
    expect(container.read(dsBotInboxProvider).total, 2);
  });

  test('a restarted feed uses its new boot for subsequent live cursor writes', () async {
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    await start(fake);
    // A real plugin restart changes both HTTP hello and the newly opened feed.
    fake.handlers['hello'] = (_) => {...fake.helloAnswer(), 'boot': 'boot-2'};
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-2', 'seq': 0});
    await settle(12);
    // This fake disables automatic feed hello; send the replacement feed's hello.
    fake.emit('hello', {'revision': 7, 'api': 1, 'boot': 'boot-2', 'seq': 0});
    await settle(12);
    fake.emit('notice', notice(1));
    await settle(12);
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString(key)!);
    expect(saved, {'boot': 'boot-2', 'seq': 1});
  });

  test('unknown notice kinds advance the cursor without creating unread messages', () async {
    final fake = FakeDsBotTransport();
    final container = await start(fake);
    fake.emit('notice', notice(1, kind: 'future-kind'));
    await settle(12);
    expect(container.read(dsBotInboxProvider).total, 0);
    expect((await SharedPreferences.getInstance()).getString(key), '{"boot":"boot-1","seq":1}');
  });
}
