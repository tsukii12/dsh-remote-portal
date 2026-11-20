import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_detail_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

void main() {
  for (final kind in ['panels', 'team']) {
    for (final cold in [false, true]) {
      test('$kind actual module snapshot across sameclient reconnect cold=$cold', () async {
        final raw = jsonDecode(File('test/state/fixtures/panels-team-real-module.json').readAsStringSync()) as Map;
        const id = 'panels-team-probe';
        final host = await FakeDsh.start();
        final connection = DshConnection(host.baseUri);
        await connection.login(FakeDsh.token);
        final client = DshClient.withCarrier(
          DshHttpCarrier(connection),
          muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 20)]),
        );
        var reopened = false;
        var reads = 0;
        var opens = 0;
        host.handlers['session/projections'] = (_) {
          reads++;
          final snapshot = reopened ? raw['querySnapshot'] as Map : raw['before']['projections'][id] as Map;
          return {
            'ok': true,
            'value': {'kind': 'sequenced', ...snapshot.cast<String, Object?>()},
          };
        };
        host.onOpen = (socket, stream, endpoint, _) {
          if (endpoint != 'session/control') throw StateError(endpoint);
          opens++;
          socket.item(stream, {
            'type': 'baseline',
            'value': !reopened ? raw['before'] : raw[cold ? 'coldBaseline' : 'latestResident'],
          });
        };
        final c = ProviderContainer(
          overrides: [
            activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, isLocal: true))),
            hostSessionsProvider.overrideWithValue(const {}),
            // Installed/available Team capability remains enabled throughout;
            // this case is cold-session absence, not plugin disable/unload.
            agentTeamBundleProvider.overrideWithValue(
              AsyncData(PluginBundle.fromJson({'name': agentTeamBundle, 'enabled': true, 'installed': true})),
            ),
          ],
        );
        final sub = kind == 'panels'
            ? c.listen(sessionPanelsProvider(id), (_, _) {})
            : c.listen(teamProvider(id), (_, _) {});
        addTearDown(() async {
          sub.close();
          c.dispose();
          await client.close();
          await host.close();
        });
        int? value() => kind == 'panels'
            ? (c.read(sessionPanelsProvider(id)).planActive ? 1 : 0)
            : c.read(teamProvider(id)).value?.members.length;
        Object notifier() =>
            kind == 'panels' ? c.read(sessionPanelsProvider(id).notifier) : c.read(teamProvider(id).notifier);
        Future<void> until(bool Function() condition) async {
          for (var i = 0; i < 200; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await c.pump();
            if (condition()) return;
          }
          fail('condition timed out opens=$opens reads=$reads value=${value()}');
        }

        await until(() => opens == 1 && reads == 1 && value() == (kind == 'panels' ? 0 : 1));
        final original = notifier();
        final generation = client.mux.lastReadyGenerationNumber;
        reopened = true;
        await host.sockets.last.ws.close(1001, 'B29 controlled reconnect');
        await until(() => opens == 2 && client.mux.lastReadyGenerationNumber > generation);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await c.pump();
        expect(notifier(), same(original));
        expect(c.read(agentTeamBundleProvider).value!.enabled, isTrue);
        // ignore: avoid_print
        print(
          'B29 kind=$kind cold=$cold opens=$opens reads=$reads value=${value()} ready=${client.mux.lastReadyGenerationNumber}',
        );
        expect(
          value(),
          kind == 'panels' ? 1 : 2,
          reason: 'cold absence must be repaired through the available current query, not treated as deletion',
        );
      });
    }
  }
}
