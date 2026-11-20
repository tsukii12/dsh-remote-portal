
import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/link_status.dart';
import '../remote/network_watch.dart';
import '../remote/portal_link.dart';
import 'hosts_state.dart';

class HostConnection {
  const HostConnection({required this.client, this.name, this.hostId, this.workingDirectory,
    this.isLocal = false, this.kind = HostKind.portal, String? label}) : _label = label ?? name;
  final DshClient client;
  final String? name;
  final String? hostId;
  final String? workingDirectory;
  final bool isLocal;
  final HostKind kind;
  final String? _label;
  String get label => _label ?? hostLabel(kind, name);
}

final networkKicksProvider = Provider<Stream<void>>((ref) => networkKicks());
final hostLinkProvider = Provider.autoDispose.family<HostLink?, HostRef>((ref, host) {
  final config = ref.watch(hostsProvider.select((value) => value.portalById(host.id)));
  if (config == null) return null;
  final link = PortalHostLink(config, ref.read(secretStoreProvider), kicks: ref.watch(networkKicksProvider));
  ref.onDispose(() => unawaited(link.close()));
  return link;
});
final hostLinkStatusProvider = StreamProvider.autoDispose.family<HostLinkStatus, HostRef>((ref, host) async* {
  final link = ref.watch(hostLinkProvider(host));
  if (link == null) { yield HostLinkStatus.idle; return; }
  yield link.status;
  yield* link.statuses;
});
final hostNameProvider = Provider.autoDispose.family<String?, HostRef>(
  (ref, host) => ref.watch(hostsProvider).portalById(host.id)?.name ?? host.name);

class RemoteConnectionController extends AsyncNotifier<HostConnection?> {
  RemoteConnectionController(this.host);
  final HostRef host;
  @override
  Future<HostConnection?> build() async {
    final link = ref.watch(hostLinkProvider(host));
    if (link == null) return null;
    final sub = link.statuses.listen((value) {
      if (value.phase == HostLinkPhase.failed && value.error != null && ref.mounted) {
        state = AsyncError(value.error!, StackTrace.current);
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));
    final client = await link.open();
    return HostConnection(client: client, name: ref.read(hostNameProvider(host)), hostId: host.id);
  }
  void retry() => ref.invalidate(hostLinkProvider(host));
}
final remoteConnectionProvider = AsyncNotifierProvider.autoDispose
  .family<RemoteConnectionController, HostConnection?, HostRef>(RemoteConnectionController.new);
final activeConnectionProvider = Provider<AsyncValue<HostConnection?>>(
  (ref) => ref.watch(remoteConnectionProvider(ref.watch(activeHostProvider))));

class ConnectionDiagnostics {
  Map<String, Object?> get snapshot => const {'transport': 'portal'};
  Stream<void> get changes => const Stream.empty();
}
final connectionDiagnosticsProvider = Provider((ref) => ConnectionDiagnostics());

final localConnectionProvider = Provider<AsyncValue<HostConnection?>>((ref) => const AsyncData(null));
