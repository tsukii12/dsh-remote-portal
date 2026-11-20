import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../chat/support/session_sync_host.dart' show HeldReplyCarrier, ReplyHold;

void main() {
  for (final frameFirst in [false, true]) {
    test('cold empty seq -1 snapshot; newer frame first=$frameFirst', () async {
      final raw = jsonDecode(File('test/state/fixtures/control-baseline-real-module.json').readAsStringSync()) as Map;
      const id = 'cold-projection-probe';
      final host = await FakeDsh.start();
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      final hold = ReplyHold();
      if (frameFirst) hold.arm('session/projections');
      final client = DshClient.withCarrier(HeldReplyCarrier(DshHttpCarrier(connection), hold));
      var opens = 0;
      var seeds = 0;
      FakeMuxSocket? controlSocket;
      String? controlId;
      host.handlers['session/projections'] = (_) {
        seeds++;
        return {
          'ok': true,
          'value': {'kind': 'sequenced', ...(raw['emptyColdSnapshot'] as Map).cast<String, Object?>()},
        };
      };
      host.onOpen = (socket, stream, endpoint, _) {
        if (endpoint != 'session/control') throw StateError(endpoint);
        opens++;
        controlSocket = socket;
        controlId = stream;
        socket.item(stream, {'type': 'baseline', 'value': raw['coldBaseline']});
      };
      final c = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true))),
        ],
      );
      final sub = c.listen(sessionUsageProvider(id), (_, _) {});
      addTearDown(() async {
        hold.finish();
        sub.close();
        c.dispose();
        await client.close();
        await host.close();
      });
      Future<void> until(bool Function() condition) async {
        for (var n = 0; n < 200; n++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await c.pump();
          if (condition()) return;
        }
        fail('condition timed out opens=$opens seeds=$seeds');
      }

      await until(() => opens == 1 && seeds >= 1);
      if (frameFirst) {
        await hold.received!.future;
        final block = raw['latestResident']['projections'][id] as Map;
        controlSocket!.item(controlId!, {
          'type': 'projection',
          'sessionId': id,
          'seq': block['asOfSeq'],
          'key': 'sessionStats',
          'value': block['values']['sessionStats'],
        });
        await until(() => c.read(sessionUsageProvider(id)).turns == 1);
        hold.finish();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.pump();
      expect(c.read(sessionUsageProvider(id)).turns, frameFirst ? 1 : 0);
    });
  }
}
