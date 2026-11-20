import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'dsbot_api_test.dart' show FakeDsBot;

void main() {
  final captured = jsonDecode(File('test/fixtures/dsbot_v023_mobile.json').readAsStringSync()) as Map<String, dynamic>;
  Object? value(String endpoint) => (captured[endpoint] as Map)['value'];

  test('real v0.2.3 + mobile-PR responses preserve handshake, owners and parked calls', () {
    final hello = DsBotHello.fromJson(value('hello'));
    final state = DsBotState.fromJson(value('state'));
    expect(hello.pluginVersion, '0.2.3');
    expect(hello.compatible, isTrue);
    expect(state.team!.bots, hasLength(2));
    final room = state.team!.rooms.single;
    expect(room.members, state.team!.bots.map((bot) => bot.id).toList());
    expect(room.pausedCallIds, ['fixture-parked-call']);
    expect(room.paused, isTrue);
    final chat = DsBotChatPage.fromJson(value('chat'));
    expect(chat.sessionId, state.team!.bots.first.sessionId);
    expect(DsBotRoomPage.fromJson(value('roomChat')).roomId, room.id);
    expect(DsBotRoom.fromJson({'id': 'old-room'}).paused, isFalse);
  });

  test('continue calls the real upstream endpoint with the room identifier', () async {
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
    host.handlers['room-continue'] = (payload) {
      expect(payload, {'roomId': 's3'});
      return value('continued');
    };
    await api.continueRoom('s3');
    expect(host.calls.single['endpoint'], 'room-continue');
  });
}
