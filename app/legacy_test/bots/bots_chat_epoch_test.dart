import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show fakeConnection;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef host) => state = host;
}

Map<String, Object?> page(String text, {String sessionId = 'b2-c', Object? cursor}) => {
  'sessionId': sessionId,
  'roomId': 'r1',
  'items': [
    {'id': text, 'kind': 'bot', 'text': text, 'time': 1},
  ],
  'cursor': cursor,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> start(FakeDsBotTransport local, FakeDsBotTransport remote) async {
    final container = ProviderContainer(
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
        dsBotApiFactoryProvider.overrideWithValue((connection) => DsBotApi((connection.hostId == HostRef.none.id) ? local : remote)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    return container;
  }

  for (final isRoom in [false, true]) {
    test('${isRoom ? 'room' : 'bot'} history and late earlier page stay on their own host', () async {
      final earlier = Completer<Object?>();
      final local = FakeDsBotTransport()..helloOnFeed = false;
      final remote = FakeDsBotTransport()..helloOnFeed = false;
      final endpoint = isRoom ? 'room-chat' : 'chat';
      local.handlers[endpoint] = (payload) =>
          payload['cursor'] == null ? page('local', cursor: 'older') : earlier.future;
      remote.handlers[endpoint] = (_) => page('remote');
      final container = await start(local, remote);
      if (isRoom) {
        container.listen(roomChatProvider('r1'), (_, _) {});
      } else {
        container.listen(botChatProvider('b2'), (_, _) {});
      }
      await settle(12);
      final pending = isRoom
          ? container.read(roomChatProvider('r1').notifier).loadEarlier()
          : container.read(botChatProvider('b2').notifier).loadEarlier();
      await settle();
      container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
      await settle(20);
      List<DsBotItem> items() =>
          isRoom ? container.read(roomChatProvider('r1')).items : container.read(botChatProvider('b2')).items;
      expect(items().map((item) => item.text), ['remote']);
      earlier.complete(page('old-private-history'));
      await pending;
      await settle();
      expect(items().map((item) => item.text), ['remote']);
    });
  }

  test('a page from an old Bot part cannot prepend to the new part', () async {
    final earlier = Completer<Object?>();
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    fake.handlers['chat'] = (payload) =>
        payload['cursor'] == null ? page('old-part', cursor: 'old-cursor') : earlier.future;
    final container = await start(fake, FakeDsBotTransport());
    container.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    final pending = container.read(botChatProvider('b2').notifier).loadEarlier();
    await settle();
    final team = sampleTeam();
    (team['bots'] as List).cast<Map<String, Object?>>().firstWhere((bot) => bot['id'] == 'b2')['sessionId'] =
        'new-part';
    fake.handlers['state'] = (_) => team;
    fake.handlers['chat'] = (_) => page('new-part', sessionId: 'new-part');
    await container.read(dsBotProvider.notifier).refresh();
    await settle(12);
    earlier.complete(page('old-earlier'));
    await pending;
    expect(container.read(botChatProvider('b2')).items.single.text, 'new-part');
    expect(container.read(botChatProvider('b2')).sessionId, 'new-part');
  });

  test('stream text from another part is ignored and a lost feed clears the draft', () async {
    final fake = FakeDsBotTransport();
    final container = await start(fake, FakeDsBotTransport());
    container.listen(botChatProvider('b2'), (_, _) {});
    await settle(12);
    fake.emit('stream', {'botId': 'b2', 'sessionId': 'earlier', 'attemptId': 'old', 'phase': 'start'});
    fake.emit('stream', {'botId': 'b2', 'sessionId': 'earlier', 'attemptId': 'old', 'text': 'old text'});
    await settle();
    expect(container.read(botChatProvider('b2')).streaming, isNull);
    fake.emit('stream', {'botId': 'b2', 'sessionId': 'b2-c', 'attemptId': 'new', 'phase': 'start'});
    fake.emit('stream', {'botId': 'b2', 'sessionId': 'b2-c', 'attemptId': 'new', 'text': 'current text'});
    await settle();
    expect(container.read(botChatProvider('b2')).streaming, 'current text');
    await fake.dropFeed();
    await settle();
    expect(container.read(botChatProvider('b2')).streaming, isNull);
  });
}
