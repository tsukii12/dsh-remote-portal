// Optional live smoke against W2/upstream/scripts/wave7-server.mjs.
// The server uses actual DS Bot routes and a fake DSH runtime, not a full engine.
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['DSBOT_E2E_URL'];
  test('Dart HTTP and SSE reach real upstream route handlers', () async {
    final api = DsBotApi(DsBotHttpTransport(DshConnection(Uri.parse(url!))));
    addTearDown(api.close);
    final hello = await api.hello();
    expect(hello.compatible, isTrue);
    expect(hello.pluginVersion, '0.2.3');
    final team = (await api.state()).team!;
    final room = team.rooms.single;
    expect(room.paused, isTrue);
    expect((await api.chat(team.bots.first.id)).sessionId, team.bots.first.sessionId);
    expect((await api.roomChat(room.id)).roomId, room.id);
    final raw = await api.transport.openFeed().first.timeout(const Duration(seconds: 5));
    expect(DsBotFeedEvent.parse(raw), isA<DsBotFeedHello>());
    await api.continueRoom(room.id);
  }, skip: url == null ? 'Set DSBOT_E2E_URL to the local upstream runtime fixture server.' : false);
}
