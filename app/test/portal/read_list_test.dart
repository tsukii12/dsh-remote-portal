import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Selected extends ActiveHostController {
  @override
  HostRef build() => const HostRef.portal('one');
}

class _StateMux extends DshMux {
  _StateMux(super.carrier, this.value);
  final DshConnectionState value;
  @override
  DshConnectionState get state => value;
  @override
  Stream<DshConnectionState> get states => const Stream.empty();
}

class _StateClient extends DshClient {
  _StateClient(this.value) : super(DshConnection(Uri.parse('http://example.test/')));
  final DshConnectionState value;
  late final DshMux _testMux = _StateMux(carrier, value);
  @override
  DshMux get mux => _testMux;
}

void main() {
  for (final state in DshConnectionState.values) {
    test('portal read authority follows upstream mux state: ${state.name}', () {
      final client = _StateClient(state);
      final connection = HostConnection(client: client, hostId: 'one');
      final container = ProviderContainer(overrides: [
        activeHostProvider.overrideWith(_Selected.new),
        activeConnectionProvider.overrideWithValue(AsyncData(connection)),
      ]);
      addTearDown(() async {
        container.dispose();
        await client.close();
      });
      final blocked = {
        DshConnectionState.reconnecting,
        DshConnectionState.unauthorized,
        DshConnectionState.closed,
      }.contains(state);
      expect(container.read(readListLiveConnectionProvider), blocked ? isNull : same(connection));
    });
  }

  test('missing, stale, loading and failed connections have no read authority', () {
    final client = _StateClient(DshConnectionState.connected);
    addTearDown(client.close);
    final connection = HostConnection(client: client, hostId: 'one');
    const selected = HostRef.portal('one');
    expect(readListConnection(const AsyncData(null), selected), isNull);
    expect(readListConnection(const AsyncLoading(), selected), isNull);
    expect(readListConnection(AsyncError(StateError('offline'), StackTrace.current), selected), isNull);
    expect(readListConnection(AsyncData(connection), const HostRef.portal('two')), isNull);
    expect(readListConnection(AsyncData(connection), selected), same(connection));
  });
}
