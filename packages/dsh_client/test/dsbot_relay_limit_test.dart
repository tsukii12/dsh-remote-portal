import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'dsbot_api_test.dart' show FakeDsBot;

void main() {
  final captured = jsonDecode(File('test/fixtures/dsbot_relay_limit.json').readAsStringSync()) as Map<String, dynamic>;

  test('real upstream room snapshots preserve custom and computed relay limits', () {
    final initial = DsBotRoom.fromJson(captured['initialRoom']);
    final custom = DsBotRoom.fromJson(captured['customRoom']);
    final restored = DsBotRoom.fromJson(captured['defaultRoom']);
    expect(initial.relayLimit, isNull);
    expect(initial.relayLimitDefault, 6);
    expect(custom.relayLimit, 19);
    expect(custom.relayLimitDefault, 6);
    expect(restored.relayLimit, isNull);
    expect(restored.relayLimitDefault, 6);
    expect(DsBotRoom.fromJson({'id': 'legacy'}).relayLimitDefault, isNull);
    expect((captured['invalid'] as Map)['ok'], isFalse);
  });

  test('update-room writes integer or explicit null and rejects invalid limits before IO', () async {
    final host = await FakeDsBot.start();
    final connection = DshConnection(
      host.baseUri,
      cookie: DshCookie(name: 'dsh-auth-test', value: 'v1.payload.sig', authority: '127.0.0.1:${host.port}'),
    );
    final api = DsBotApi(DsBotHttpTransport(connection));
    addTearDown(() async {
      await api.close();
      await host.close();
    });
    host.handlers['update-room'] = (_) => (captured['changed'] as Map)['value'];
    await api.setRoomRelayLimit('r1', 1);
    await api.setRoomRelayLimit('r1', 200);
    await api.setRoomRelayLimit('r1', null);
    expect(host.calls.map((call) => call['payload']), [
      {'id': 'r1', 'relayLimit': 1},
      {'id': 'r1', 'relayLimit': 200},
      {'id': 'r1', 'relayLimit': null},
    ]);
    expect(() => api.setRoomRelayLimit('r1', 0), throwsRangeError);
    expect(() => api.setRoomRelayLimit('r1', 201), throwsRangeError);
    expect(host.calls, hasLength(3));
  });
}
