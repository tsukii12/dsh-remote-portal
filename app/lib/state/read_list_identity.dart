import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/current_stream.dart';

import 'connection_state.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';

class ReadListIdentity {
  const ReadListIdentity(this.digest);
  factory ReadListIdentity.of(List<Object?> fields) =>
      ReadListIdentity(sha256.convert(utf8.encode(jsonEncode([1, ...fields]))).toString());
  final String digest;
  @override
  bool operator ==(Object other) => other is ReadListIdentity && digest == other.digest;
  @override
  int get hashCode => digest.hashCode;
}

HostConnection? readListConnection(AsyncValue<HostConnection?> value, HostRef selected) {
  if (value.isLoading || value.hasError) return null;
  final connection = value.value;
  return connection?.hostId == selected.id ? connection : null;
}

final _muxStateProvider = StreamProvider.autoDispose.family<DshConnectionState, DshClient>(
  (ref, client) => currentStream(() => client.mux.state, client.mux.states),
);

final readListLiveConnectionProvider = Provider<HostConnection?>((ref) {
  final connection = readListConnection(ref.watch(activeConnectionProvider), ref.watch(activeHostProvider));
  if (connection == null) return null;
  final state = ref.watch(_muxStateProvider(connection.client)).value ?? connection.client.mux.state;
  if (state == DshConnectionState.reconnecting ||
      state == DshConnectionState.unauthorized ||
      state == DshConnectionState.closed) {
    return null;
  }
  return connection;
});

final readListIdentityProvider = Provider<ReadListIdentity?>((ref) {
  final host = ref.watch(activeHostProvider);
  final config = ref.watch(hostsProvider).portalById(host.id);
  final epoch = ref.watch(readListCredentialEpochProvider);
  if (config == null) return null;
  return ReadListIdentity.of(['portal', config.id, config.base.toString(), epoch]);
});
