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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a stalled old host never blocks or overwrites the new Bot team', () async {
    final oldRead = Completer<Object?>();
    final local = FakeDsBotTransport()..helloOnFeed = false;
    local.handlers['state'] = (_) => oldRead.future;
    final next = FakeDsBotTransport()..helloOnFeed = false;
    final nextTeam = {...sampleTeam(), 'revision': 90};
    next.handlers['state'] = (_) => nextTeam;
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
        dsBotApiFactoryProvider.overrideWithValue((connection) => DsBotApi((connection.hostId == HostRef.none.id) ? local : next)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    expect(local.endpoints, contains('state'));
    container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
    await settle(12);
    expect(container.read(dsBotProvider).ready, isTrue);
    expect(container.read(dsBotProvider).team!.revision, 90);
    oldRead.complete({...sampleTeam(), 'revision': 1});
    await settle(12);
    expect(container.read(dsBotProvider).team!.revision, 90);
    expect(container.read(dsBotProvider).host, const HostRef.portal('next'));
  });
}
