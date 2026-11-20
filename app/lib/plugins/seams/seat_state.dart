// Providers behind the seats (docs/design/plugin-seams.md): the active host's
// client inventory (§5), the adapter registry, and the hooks the islands
// runtime and ui.json plug into. Nothing here runs until a PluginSeat is on
// screen.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart';
import '../../state/hosts_state.dart';
import '../../state/plugins_state.dart';
import '../../ui/plugins/islands/island_host.dart' show liveIslandBudgetProvider;
import '../../ui/plugins/seats/seat_island.dart';
import '../../ui/plugins/seats/seat_links.dart';
import '../../ui_config/ui_config_state.dart' show uiConfigProvider, uiSeatOverridesProvider;
import '../native/native_state.dart' show nativePanelsProvider;
import 'seat_inventory.dart';
import 'seat_models.dart';
import 'seat_planner.dart';
import 'seat_preferences.dart';
import 'slot_catalog.dart' show Slots;

// ── Inventory ────────────────────────────────────────────────────────────────

/// Tier A: the boot graph of the active host's web page; read again whenever
/// the installed list changes. Null without a page (relay) or when it could
/// not be read.
final webBootProvider = FutureProvider.autoDispose<WebBootGraph?>((ref) async {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.canReadWebBoot) return null;
  ref.watch(installedPluginsProvider.select((s) => s.value));
  try {
    return await client.readWebBoot();
  } on DshException {
    return null;
  }
});

/// Tier B: the bridge's occupancy table. Null when the bridge is not
/// installed, the carrier has no pages, or the read failed. The islands
/// runtime invalidates it after a probe island reported.
final bridgeInventoryProvider = FutureProvider.autoDispose<BridgeInventory?>((ref) async {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null || !client.canReadWebBoot) return null;
  ref.watch(installedPluginsProvider.select((s) => s.value));
  try {
    return await client.readBridgeInventory();
  } on DshException {
    return null;
  }
});

/// The active host's inventory as the seats read it; null while not
/// connected or before the bundle list arrived.
final seatInventoryProvider = Provider.autoDispose<SeatInventory?>((ref) {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
  if (client == null || bundles == null) return null;
  final boot = ref.watch(webBootProvider.select((s) => s.value));
  final bridge = ref.watch(bridgeInventoryProvider.select((s) => s.value));
  final namespaces = ref.watch(engineSettingsProvider.select((s) => s.value?.namespaces));
  return SeatInventory.from(
    ClientInventory.combine(bundles: bundles, boot: boot, bridge: bridge),
    namespaces: namespaces,
    webReachable: client.canReadWebBoot,
    nativePanels: ref.watch(nativePanelsProvider),
  );
});

// ── Hooks ────────────────────────────────────────────────────────────────────

/// The native adapters in priority order.
final slotAdapterRegistryProvider = Provider<SlotAdapterRegistry>((ref) => SlotAdapterRegistry.standard());

/// Whether islands may be planned: the islands runtime's memory policy and
/// security gate.
final islandBudgetProvider = Provider<IslandBudget>((ref) => ref.watch(liveIslandBudgetProvider));

/// What [host]'s bridge says about its route guard (`routeGuard` in
/// `/dsh-go/v1/inventory`); null for a host other than the active one, or
/// without the bridge. The islands' security gate reads it
/// (`islandRouteGuardReportProvider`).
final seatRouteGuardReportProvider = Provider.family<bool?, HostRef>((ref, host) {
  if (ref.watch(activeHostProvider) != host) return null;
  return ref.watch(bridgeInventoryProvider.select((s) => s.value?.routeGuard));
});

/// Explicit ui.json values win over the active host's local overlay choices.
final seatOverridesProvider = Provider<SeatOverrides>((ref) {
  final host = ref.watch(activeHostProvider);
  final preferences = ref.watch(seatPreferencesProvider)[seatPreferenceHostKey(host)] ?? const <String, bool>{};
  final configured = ref.watch(uiSeatOverridesProvider);
  // Do not flash a locally enabled overlay before a cached ui.json hide loads.
  final restored = ref.watch(uiConfigProvider(host).select((s) => s.restored));
  return SeatOverrides({
    ...configured.bySlot,
    Slots.shellOverlay: {
      for (final entry in preferences.entries)
        if (!entry.value) entry.key: SeatOverride.hidden else if (restored) entry.key: SeatOverride.island,
      ...?configured.bySlot[Slots.shellOverlay],
    },
  });
});

/// Draws the island for [items] (one or more items sharing [spec]);
/// [fallback] is what to show when the island cannot come up.
typedef IslandSeatBuilder = Widget Function(
  BuildContext context,
  IslandSpec spec,
  List<SeatItem> items,
  WidgetBuilder fallback,
);

/// Draws one "open in DSH Web" entry.
typedef WebLinkSeatBuilder = Widget Function(BuildContext context, SeatContext seat, SeatItem item);

/// How seats draw what is not native. Unset parts draw nothing: an island
/// shows its fallback, a web entry shows nothing.
@immutable
class SeatRenderers {
  const SeatRenderers({this.island, this.webLink});

  final IslandSeatBuilder? island;
  final WebLinkSeatBuilder? webLink;
}

/// `island` → the islands runtime's `IslandView`, `webLink` → the entry that
/// opens DSH Web at the occupant.
final seatRenderersProvider = Provider<SeatRenderers>(
  (ref) => SeatRenderers(
    island: (context, spec, items, fallback) => SeatIslandView(spec: spec, items: items, fallback: fallback),
    webLink: (context, seat, item) => SeatWebLink(seat: seat, item: item),
  ),
);

// ── Plans ────────────────────────────────────────────────────────────────────

/// One seat: a slot at a place in the native UI, optionally narrowed to one
/// package (a plugin's own page) or one cell.
@immutable
class SeatRequest {
  const SeatRequest({required this.slot, required this.placement, this.sessionId, this.package, this.cell});

  final String slot;
  final SeatPlacement placement;
  final String? sessionId;
  final String? package;
  final String? cell;

  @override
  bool operator ==(Object other) =>
      other is SeatRequest &&
      other.slot == slot &&
      other.placement == placement &&
      other.sessionId == sessionId &&
      other.package == package &&
      other.cell == cell;

  @override
  int get hashCode => Object.hash(slot, placement, sessionId, package, cell);
}

/// A seat's context and planned items.
@immutable
class SeatPlan {
  const SeatPlan(this.seat, this.items);

  final SeatContext seat;
  final List<SeatItem> items;

  /// Items that draw something.
  List<SeatItem> get visible => [
    for (final item in items)
      if (item.mode != SeatMode.hidden) item,
  ];

  /// Nothing to show: the seat renders nothing (and a page can leave out the
  /// tab or entry that would lead to it).
  bool get isEmpty => visible.isEmpty;
}

/// The plan of one seat on the active host.
final seatPlanProvider = Provider.autoDispose.family<SeatPlan, SeatRequest>((ref, request) {
  final host = ref.watch(activeHostProvider);
  final inventory = ref.watch(seatInventoryProvider);
  final seat = SeatContext(
    host: host,
    sessionId: request.sessionId,
    placement: request.placement,
    webAvailable: inventory?.webReachable ?? false,
  );
  if (inventory == null) return SeatPlan(seat, const []);
  final isolatedPage = const {
    Slots.sidebarFooter,
    Slots.settingsPluginsTab,
    Slots.pluginDetailSection,
  }.contains(request.slot);
  if (isolatedPage && inventory.occupancyStale) return SeatPlan(seat, const []);
  final occupants = inventory
      .occupantsFor(request.slot, package: request.package, cell: request.cell)
      .where((o) => !isolatedPage || (inventory.packages.containsKey(o.package) && inventory.infoOf(o.package).enabled))
      .toList();
  final items = ref
      .watch(slotAdapterRegistryProvider)
      .plan(
        request.slot,
        occupants,
        seat,
        budget: ref.watch(islandBudgetProvider),
        overrides: ref.watch(seatOverridesProvider),
        inventory: inventory,
      );
  return SeatPlan(seat, items);
});
