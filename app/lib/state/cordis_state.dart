// Native Cordis panel of the active host: the Host's dynamic plugins, read
// again whenever the Host announces a change.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'connection_state.dart';

/// Whether the active connection can show Cordis at all.
enum CordisReach {
  /// Not connected yet (or the connection failed).
  offline,

  /// Connected through a carrier without `dynamicCordisRunner/*` (the DSH
  /// Remote tunnel).
  unsupported,

  available,
}

final cordisReachProvider = Provider.autoDispose<CordisReach>((ref) {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return CordisReach.offline;
  return client.canReadCordis ? CordisReach.available : CordisReach.unsupported;
});

/// Every dynamic plugin on the active host (`dynamicCordisRunner/inventory`),
/// read again on the official panel's four announcements and after a
/// reconnect. Null while there is nothing to ask.
final cordisInventoryProvider = FutureProvider.autoDispose<List<CordisPlugin>?>((ref) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null || !client.canReadCordis) return null;
  final sub = client.hostEvents.listen((event) {
    if (event is HostReadyEvent || (event is UnknownHostEvent && cordisInventoryEvents.contains(event.event))) {
      ref.invalidateSelf();
    }
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  return client.cordisInventory();
});

/// The panel's two groups: the plugins of the conversation open in the chat,
/// then everyone else's. Within each, the ones waiting for an answer first
/// (the official `blockingFirst`), otherwise the Host's order.
({List<CordisPlugin> current, List<CordisPlugin> others}) cordisGroups(
  List<CordisPlugin> plugins,
  String? currentSessionId,
) {
  List<CordisPlugin> blockingFirst(Iterable<CordisPlugin> rows) => [
    ...rows.where((p) => p.status == CordisPluginStatus.awaitingApproval),
    ...rows.where((p) => p.status != CordisPluginStatus.awaitingApproval),
  ];
  bool mine(CordisPlugin p) => currentSessionId != null && p.agentId == currentSessionId;
  return (current: blockingFirst(plugins.where(mine)), others: blockingFirst(plugins.where((p) => !mine(p))));
}

/// What a row shows next to its name.
String cordisStatusLabel(CordisPluginStatus status) => switch (status) {
  CordisPluginStatus.idle => appL10n.stateNotRunning,
  CordisPluginStatus.awaitingApproval => appL10n.stateCordisPending,
  CordisPluginStatus.starting => appL10n.stateCordisStarting,
  CordisPluginStatus.running => appL10n.commonRunning,
  CordisPluginStatus.failed => appL10n.stateCordisRunFailed,
};

/// The failed stage, in words (`CordisRunDiagnostic.phase`).
String cordisFailureText(CordisRunFailure failure) => switch (failure.phase) {
  'approval' => appL10n.stateCordisNoApproval,
  'host-load' || 'host-apply' => appL10n.stateCordisBackendFailed,
  'client-load' || 'client-apply' => appL10n.stateCordisClientLoadFailed,
  'client-render' => appL10n.stateCordisRenderFailed,
  _ => appL10n.stateCordisFailed,
};
