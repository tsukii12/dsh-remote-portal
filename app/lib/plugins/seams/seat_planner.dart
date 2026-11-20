// Native adapters and the seat planner (docs/design/plugin-seams.md §4):
// each third-party occupant of a seat gets one presentation, native adapter
// first, web island second, "open in DSH Web" last.

import 'package:dsh_client/dsh_client.dart' show ClientInventoryTier;
import 'package:flutter/widgets.dart';

import 'adapters/cordis_adapter.dart';
import 'adapters/dsh_ui_panel_adapter.dart';
import 'adapters/pet_adapter.dart';
import 'adapters/schema_config_adapter.dart';
import 'seat_inventory.dart';
import 'seat_models.dart';
import 'slot_catalog.dart';

/// How much of an occupant an adapter draws.
enum NativeCoverage {
  /// Everything: no island or web entry for it.
  full,

  /// Part of it (Cordis: the list, not the plugin's interactive region): the
  /// rest still goes to an island or a web entry after the native item.
  partial,
}

/// Draws some occupants with native widgets.
abstract interface class NativeSlotAdapter {
  /// `schema-config`, `cordis`, `dsh-ui-panel`, `pet`.
  String get id;

  /// Slot keys it serves.
  Set<String> get slots;

  /// Read-only, no requests: [info] comes from the inventory.
  bool canRender(SlotOccupant o, PluginClientInfo info);

  NativeCoverage coverage(SlotOccupant o);

  Widget build(BuildContext context, SeatContext seat, SlotOccupant o);
}

/// How one occupant is shown.
enum SeatMode { native, island, webLink, hidden }

/// One planned occupant.
@immutable
class SeatItem {
  const SeatItem.native(this.occupant, NativeSlotAdapter this.adapter)
    : mode = SeatMode.native,
      island = null,
      configNamespace = null;

  const SeatItem.island(this.occupant, IslandSpec this.island)
    : mode = SeatMode.island,
      adapter = null,
      configNamespace = null;

  const SeatItem.webLink(this.occupant)
    : mode = SeatMode.webLink,
      adapter = null,
      island = null,
      configNamespace = null;

  /// One unsupported sibling beside a package's native settings namespaces.
  const SeatItem.schemaFallback(this.occupant, this.configNamespace)
    : mode = SeatMode.webLink,
      adapter = null,
      island = null;

  /// Hidden by ui.json, or nothing can show it here (no web on this host).
  const SeatItem.hidden(this.occupant) : mode = SeatMode.hidden, adapter = null, island = null, configNamespace = null;

  final SlotOccupant occupant;
  final SeatMode mode;
  final String? configNamespace;

  /// Set when [mode] is [SeatMode.native].
  final NativeSlotAdapter? adapter;

  /// Set when [mode] is [SeatMode.island].
  final IslandSpec? island;

  @override
  bool operator ==(Object other) =>
      other is SeatItem &&
      other.occupant == occupant &&
      other.mode == mode &&
      other.configNamespace == configNamespace &&
      identical(other.adapter, adapter) &&
      other.island == island;

  @override
  int get hashCode => Object.hash(occupant, mode, adapter?.id, island, configNamespace);

  @override
  String toString() => 'SeatItem(${mode.name}${adapter == null ? '' : ' ${adapter!.id}'}, $occupant)';
}

/// The native adapters, in priority order, and the planner.
class SlotAdapterRegistry {
  SlotAdapterRegistry([Iterable<NativeSlotAdapter> adapters = const []]) {
    adapters.forEach(register);
  }

  /// The first batch (§4.2): schema forms, Cordis, declarative panels, pets.
  factory SlotAdapterRegistry.standard() =>
      SlotAdapterRegistry(const [SchemaConfigAdapter(), CordisAdapter(), DshUiPanelAdapter(), PetAdapter()]);

  final List<NativeSlotAdapter> _adapters = [];

  List<NativeSlotAdapter> get adapters => List.unmodifiable(_adapters);

  /// Registered at app start; registration order is priority. An adapter
  /// with an id already present replaces it in place.
  void register(NativeSlotAdapter adapter) {
    final at = _adapters.indexWhere((a) => a.id == adapter.id);
    if (at < 0) {
      _adapters.add(adapter);
    } else {
      _adapters[at] = adapter;
    }
  }

  /// The first adapter that serves [o]'s slot and can draw it.
  NativeSlotAdapter? adapterFor(SlotOccupant o, PluginClientInfo info) {
    for (final adapter in _adapters) {
      if (adapter.slots.contains(o.slot) && adapter.canRender(o, info)) return adapter;
    }
    return null;
  }

  /// Pure: drops official occupants and repeated cells, orders by `order`
  /// (reported order on ties), then per occupant: ui.json override →
  /// native adapter → island → "open in DSH Web" → hidden. A slot the app
  /// never seats (a replacement point of its own UI) plans to nothing.
  List<SeatItem> plan(
    String slot,
    List<SlotOccupant> occupants,
    SeatContext seat, {
    required IslandBudget budget,
    required SeatOverrides overrides,
    SeatInventory inventory = SeatInventory.empty,
  }) {
    final info = slotInfo(slot);
    final policy = info?.policy ?? SeatPolicy.other;
    if (!policy.seatable) return const [];

    final seen = <(String, String)>{};
    final ordered = [
      for (final (index, o) in occupants.indexed)
        if (o.slot == slot && !o.official && !inventory.isOfficial(o.package) && seen.add((o.package, o.cell)))
          (index, o),
    ]..sort((a, b) => a.$2.order != b.$2.order ? a.$2.order.compareTo(b.$2.order) : a.$1.compareTo(b.$1));

    // A package with a native panel here shows it instead of its web
    // entries — unless ui.json asks for the web (island / web), which then
    // drops the native ones.
    final native = {
      for (final (_, o) in ordered)
        if (SeatInventory.nativePanelId(o.cell) != null) o.package,
    };
    if (native.isNotEmpty) {
      ordered.removeWhere((entry) {
        final o = entry.$2;
        if (!native.contains(o.package)) return false;
        final override = overrides.lookup(slot, o.package);
        final web = override == SeatOverride.island || override == SeatOverride.web;
        return (SeatInventory.nativePanelId(o.cell) != null) == web;
      });
    }

    final items = <SeatItem>[];
    for (final (_, o) in ordered) {
      final override = overrides.lookup(slot, o.package);
      if (override == SeatOverride.hidden) {
        items.add(SeatItem.hidden(o));
        continue;
      }
      final adapter = override == null || override == SeatOverride.native
          ? adapterFor(o, inventory.infoOf(o.package))
          : null;
      if (adapter != null) {
        items.add(SeatItem.native(o, adapter));
        if (override == null && adapter is SchemaConfigAdapter && o.slot != Slots.rowConfig && seat.webAvailable) {
          for (final ns in inventory.infoOf(o.package).fallbackNamespaces) {
            items.add(SeatItem.schemaFallback(o, ns));
          }
        }
        // The rest of a partly drawn occupant, unless ui.json pinned it native.
        if (override == null && adapter.coverage(o) == NativeCoverage.partial) {
          final rest = _webItem(info, policy, o, seat, budget, inventory, override);
          if (rest != null) items.add(rest);
        }
        continue;
      }
      // A native panel has no web side.
      if (SeatInventory.nativePanelId(o.cell) != null) {
        items.add(SeatItem.hidden(o));
        continue;
      }
      items.add(_webItem(info, policy, o, seat, budget, inventory, override) ?? SeatItem.hidden(o));
    }
    return items;
  }

  SeatItem? _webItem(
    SlotInfo? info,
    SeatPolicy policy,
    SlotOccupant o,
    SeatContext seat,
    IslandBudget budget,
    SeatInventory inventory,
    SeatOverride? override,
  ) {
    final spec = islandSpecFor(info, policy, o, seat, inventory, override);
    if (spec != null && budget.canOpen(spec)) return SeatItem.island(o, spec);
    if (seat.webAvailable && policy.webLink) return SeatItem.webLink(o);
    return null;
  }

  /// The island [o] could open in [seat], before the budget is asked; null
  /// when the rules of §3, §5 and §9 rule one out.
  static IslandSpec? islandSpecFor(
    SlotInfo? info,
    SeatPolicy policy,
    SlotOccupant o,
    SeatContext seat,
    SeatInventory inventory,
    SeatOverride? override,
  ) {
    final form = seat.placement.islandForm;
    if (form == null || !policy.islands.contains(form)) return null;
    if (override == SeatOverride.web) return null;
    if (policy.optIn && override != SeatOverride.island) return null;
    if (!seat.webAvailable) return null;
    // Local islands only once the engine guards its plugin routes.
    if (seat.host.isLocal && !inventory.routeGuard) return null;
    // Hiding official entries takes the bridge, and a reported occupant.
    if (policy.needsOccupancy && (inventory.tier != ClientInventoryTier.bridge || o.inferred)) return null;
    if (o.inferred && policy.inference == SlotInference.none) return null;
    if ((info?.needsSession ?? false) && seat.sessionId == null) return null;
    final whole = form == IslandForm.panel;
    // A page or overlay island lands on one cell; it has to be known.
    if (!whole && o.cell.isEmpty && info?.kind != SlotKind.single) return null;
    return IslandSpec(
      host: seat.host,
      form: form,
      slot: o.slot,
      cell: whole ? null : o.cell,
      package: whole ? null : o.package,
      sessionId: info?.scope == SlotScope.root ? null : seat.sessionId,
      maskOfficial: policy.masksOfficial,
    );
  }
}
