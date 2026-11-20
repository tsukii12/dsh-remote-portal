import 'package:dsh_client/dsh_client.dart';

import 'engine_settings_state.dart' show InventoryStatus, inventoryStatus;

/// A bundle row joined to the current Loader inventory by its exact entry id.
/// Module names are not identities: another bundle may import the same module.
class BundleRowLoad {
  const BundleRowLoad(this.row, this.entry);

  final PluginBundleRow row;
  final PluginInventoryEntry? entry;

  InventoryStatus? get status =>
      entry == null ? null : inventoryStatus(enabled: entry!.enabled, fiberPhase: entry!.fiberPhase);

  /// Metadata errors describe metadata, not a runtime exception or its cause.
  List<String> get metadataErrors => {
    for (final error in [row.meta?.error, entry?.meta?.error])
      if (error != null && error.trim().isNotEmpty) error.trim(),
  }.toList(growable: false);

  bool get incomplete => status != InventoryStatus.running && status != InventoryStatus.off;
  bool get hasIssue => incomplete || metadataErrors.isNotEmpty;
}

/// Disabled bundles and bundles without Loader rows have no load result here.
/// An absent or ambiguous entry stays unknown, even if its module is active
/// elsewhere. Preset compositions are separate from the global Loader state.
List<BundleRowLoad> bundleLoadRows(PluginBundle bundle, PluginInventory inventory) {
  if (!bundle.enabled) return const [];
  final entries = <String, List<PluginInventoryEntry>>{};
  for (final entry in inventory.entries) {
    (entries[entry.entryId] ??= []).add(entry);
  }
  return [
    for (final row in bundle.rows)
      BundleRowLoad(row, row.entryId == null || row.entryId!.isEmpty ? null : entries[row.entryId]?.singleOrNull),
  ];
}
