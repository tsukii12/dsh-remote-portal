import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/current_stream.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Link extends HostLink {
  final changes = StreamController<HostLinkStatus>.broadcast(sync: true);
  HostLinkStatus value = const HostLinkStatus(HostLinkPhase.connecting);
  bool advanceOnRead = false;
  @override
  HostLinkStatus get status {
    final snapshot = value;
    if (advanceOnRead) {
      advanceOnRead = false;
      scheduleMicrotask(() => emit(HostLinkPhase.connected));
    }
    return snapshot;
  }
  void emit(HostLinkPhase phase) { value = HostLinkStatus(phase); changes.add(value); }
  @override
  Stream<HostLinkStatus> get statuses => changes.stream;
  @override
  DshClient? get currentClient => null;
  @override
  Stream<DshClient> get clients => const Stream.empty();
  @override
  Future<DshClient> open() => throw UnimplementedError();
  @override
  void kick() {}
  @override
  void retry() {}
  @override
  Future<void> close() => changes.close();
}

void main() {
  test('snapshot works with an empty source', () async {
    expect(await currentStream(() => 1, const Stream<int>.empty()).toList(), [1]);
  });
  test('forwards errors and cancels the source subscription', () async {
    final source = StreamController<int>.broadcast();
    final values = <int>[];
    final errors = <Object>[];
    final failure = StateError('fixture');
    final subscription = currentStream(() => 0, source.stream).listen(values.add, onError: errors.add);
    source.add(1);
    source.addError(failure);
    await Future<void>.delayed(Duration.zero);
    expect(values, [0, 1]);
    expect(errors, [same(failure)]);
    await subscription.cancel();
    expect(source.hasListener, isFalse);
    await source.close();
  });
  for (final initial in [HostLinkPhase.connecting, HostLinkPhase.reconnecting]) {
    test('does not lose ready between initial $initial snapshot and listening', () async {
      final link = _Link()..value = HostLinkStatus(initial)..advanceOnRead = true;
      const host = HostRef.portal('status-race');
      final container = ProviderContainer(overrides: [hostLinkProvider(host).overrideWithValue(link)]);
      final sub = container.listen(hostLinkStatusProvider(host), (_, _) {});
      addTearDown(() async { sub.close(); container.dispose(); await link.close(); });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(link.status.phase, HostLinkPhase.connected);
      expect(container.read(hostLinkStatusProvider(host)).value?.phase, HostLinkPhase.connected);
      link.emit(HostLinkPhase.reconnecting);
      await Future<void>.delayed(Duration.zero);
      link.emit(HostLinkPhase.connected);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(hostLinkStatusProvider(host)).value?.phase, HostLinkPhase.connected);
    });
  }
  test('missing host remains idle', () async {
    final container = ProviderContainer(overrides: [hostLinkProvider(HostRef.none).overrideWithValue(null)]);
    final sub = container.listen(hostLinkStatusProvider(HostRef.none), (_, _) {});
    addTearDown(() { sub.close(); container.dispose(); });
    expect((await container.read(hostLinkStatusProvider(HostRef.none).future)).phase, HostLinkPhase.idle);
  });
}
