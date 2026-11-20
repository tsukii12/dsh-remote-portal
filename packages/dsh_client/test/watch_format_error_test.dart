import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  for (final (code, attempts) in const [('session/format-unsupported', 1), ('gateway/internal', 6)]) {
    test('$code uses the existing terminal or transient follow policy', () async {
      final host = await FakeDsh.start();
      addTearDown(host.close);
      var follows = 0;
      host.onOpen = (socket, streamId, endpoint, payload) {
        expect(endpoint, 'session/follow');
        follows++;
        socket.send({
          'type': 'error',
          'streamId': streamId,
          'error': {
            'code': code,
            'message': 'Synthetic retained history cannot be read',
            'details': {'sessionId': 'synthetic-unreadable'},
          },
        });
      };
      final client = await DshClient.connect(
        baseUri: host.baseUri,
        token: FakeDsh.token,
        muxOptions: const MuxOptions(retryCaps: [Duration.zero]),
      );
      addTearDown(client.close);
      await expectLater(
        client.watch('synthetic-unreadable').drain<void>(),
        throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', code)),
      );
      expect(follows, attempts);
      expect(client.mux.state, DshConnectionState.connected, reason: 'the Host connection remains usable');
      expect(host.rpcCalls, isEmpty, reason: 'an unreadable opening does not activate or mutate the session');
    });
  }
}
