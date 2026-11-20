// State behind the native Agent preset editor. The Host has no Remote that
// writes a preset: like the official creator entry, a new or changed preset
// is handed to creator mode (`cordis`) in a new conversation, here with the
// exact bundle files to write and install. Deleting a custom preset removes
// the profile bundle that declares it (`pluginManager/removeBundle`).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'features_state.dart';
import 'schedule_editor_state.dart';
import 'sessions_state.dart';

/// The removable bundle that declares preset [id] (null for built-ins and
/// presets no single bundle owns).
final presetBundleProvider = FutureProvider.autoDispose.family<PluginBundle?, String>((ref, id) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null || builtInAgentPresets.contains(id)) return null;
  return client.agentPresetBundle(id);
});

/// Whether this connection may remove bundles (relay hosts can't).
bool canRemoveBundles(DshClient client) => client.supportsEndpoint('pluginManager/removeBundle');

/// Creator mode is available: the `cordis` preset is listed and healthy.
bool creatorAvailable(List<AgentPresetInfo>? presets) =>
    presets?.any((p) => p.id == 'cordis' && p.broken == null) ?? false;

/// Opens a new conversation in creator mode and sends it [request]; returns
/// the conversation to show.
Future<String> startCreator(WidgetRef ref, String request, {required bool Function() isCurrent}) async {
  final conn = ref.read(activeConnectionProvider).value;
  if (conn == null) throw const DshClosedException('not connected');
  final id = await ref.read(sessionsProvider.notifier).createForConnection(conn, isCurrent: isCurrent);
  if (!isCurrent()) throw const DshClosedException('preset creation owner changed');
  await conn.client.selectAgentPreset(id, 'cordis');
  if (!isCurrent()) throw const DshClosedException('preset creation owner changed');
  await conn.client.prompt(id, request, timeZone: ref.read(deviceTimeZoneProvider).value);
  return id;
}

/// Removes [bundle] (and with it the preset it declares).
Future<bool> deletePresetBundle(WidgetRef ref, PluginBundle bundle) async {
  final client = ref.read(activeConnectionProvider).value?.client;
  if (client == null) return false;
  final result = await client.removeBundle(bundle.name);
  ref.invalidate(agentPresetsProvider);
  return result.succeeded;
}
