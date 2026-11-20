import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

// The baseline/snapshot JSON is emitted by the real fixed Cordis services,
// SessionStore, SessionProjectionRegistry, SessionControlController and
// sessionStats definition. Transport is controlled loopback, not a full Host.
void main() {
  for (final cold in [false, true]) {
    test('same client real mux reconnect repairs ${cold ? 'cold' : 'resident'} stats', () async {
      final raw = jsonDecode(File('test/state/fixtures/control-baseline-real-module.json').readAsStringSync()) as Map;
      const id = 'cold-projection-probe';
      final host = await FakeDsh.start();
      final connection = DshConnection(host.baseUri);
      await connection.login(FakeDsh.token);
      final client = DshClient.withCarrier(
        DshHttpCarrier(connection),
        muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 20)]),
      );
      var reopened = false;
      var seeds = 0;
      var opens = 0;
      host.handlers['session/projections'] = (_) {
        seeds++;
        final snapshot = reopened ? raw['detachedQuerySnapshot'] as Map : (raw['before']['projections'][id] as Map);
        return {
          'ok': true,
          'value': {'kind': 'sequenced', ...snapshot.cast<String, Object?>()},
        };
      };
      host.onOpen = (socket, stream, endpoint, _) {
        if (endpoint != 'session/control') throw StateError(endpoint);
        opens++;
        final baseline = !reopened ? raw['before'] : raw[cold ? 'coldBaseline' : 'latestResident'];
        socket.item(stream, {'type': 'baseline', 'value': baseline});
      };
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true))),
        ],
      );
      final sub = container.listen(sessionUsageProvider(id), (_, _) {});
      addTearDown(() async {
        sub.close();
        container.dispose();
        await client.close();
        await host.close();
      });
      Future<void> until(bool Function() condition) async {
        for (var n = 0; n < 200; n++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await container.pump();
          if (condition()) return;
        }
        fail('condition timed out: opens=$opens seeds=$seeds');
      }

      await until(() => opens == 1 && seeds == 1 && container.read(sessionUsageProvider(id)).turns == 0);
      final ready = client.mux.lastReadyGenerationNumber;
      reopened = true;
      await host.sockets.last.ws.close(1001, 'real reconnect');
      await until(() => opens == 2 && client.mux.lastReadyGenerationNumber > ready);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await container.pump();
      // Diagnostic output for this controlled transport regression.
      // ignore: avoid_print
      print(
        'B26 cold=$cold opens=$opens seeds=$seeds turns=${container.read(sessionUsageProvider(id)).turns} generation=${client.mux.lastReadyGenerationNumber}',
      );
      expect(
        container.read(sessionUsageProvider(id)).turns,
        1,
        reason: 'cold control absence is not deletion: the sequenced query snapshot still has turns1',
      );
    });
  }
}
