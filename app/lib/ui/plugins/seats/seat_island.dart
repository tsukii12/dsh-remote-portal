// `SeatRenderers.island`: the [IslandView] with what the seats know —
// every name the occupants go by in DSH Web (how island.js finds a
// third-party section, panel or tab, which have no ids on screen), room for
// the gesture bar, and a conversation a plugin asks for, opened natively.

import 'package:dsh_client/dsh_client.dart' show BridgeInventory, ClientSlotOccupant;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/seams/seams.dart';
import '../../../state/sessions_state.dart';
import '../../features/feature_widgets.dart' show openSessionInChat;
import '../islands/island_view.dart';

class SeatIslandView extends ConsumerWidget {
  const SeatIslandView({super.key, required this.spec, required this.items, required this.fallback});

  final IslandSpec spec;

  /// The seat's items this island shows (one for a page island).
  final List<SeatItem> items;
  final WidgetBuilder fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(bridgeInventoryProvider.select((s) => s.value));
    return IslandView(
      spec: spec,
      fallback: fallback,
      labels: seatIslandLabels(items, bridge),
      // A page island runs down to the screen's bottom edge: its last line
      // stays above the gesture bar.
      insets: switch (spec.form) {
        IslandForm.page => EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        IslandForm.overlay => EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top,
          bottom: MediaQuery.viewInsetsOf(context).bottom > MediaQuery.paddingOf(context).bottom
              ? MediaQuery.viewInsetsOf(context).bottom
              : MediaQuery.paddingOf(context).bottom,
        ),
        _ => EdgeInsets.zero,
      },
      onOpenSession: (id) async {
        final known = ref.read(sessionsProvider).value?.any((s) => s.sessionId == id) ?? false;
        if (!known || !context.mounted) return false;
        openSessionInChat(context, ref, id);
        return true;
      },
    );
  }
}

/// Every name the occupants of [items] go by in DSH Web: their own labels,
/// in each language the bridge reported, and for a panel or a tab the label
/// of its sidebar entry or tab title (the `main` or tab body itself is
/// registered without one).
List<String> seatIslandLabels(List<SeatItem> items, BridgeInventory? bridge) {
  final names = <String>{};
  void add(String? name) {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) names.add(trimmed);
  }

  for (final item in items) {
    final o = item.occupant;
    add(o.label);
    final reported = bridge?.slots ?? const <String, List<ClientSlotOccupant>>{};
    for (final r in reported[o.slot] ?? const <ClientSlotOccupant>[]) {
      if (r.package == o.package && r.cell == o.cell) r.label?.all.forEach(add);
    }
    final named = switch (o.slot) {
      Slots.main => Slots.panelList,
      Slots.rightPaneTab => Slots.rightPaneTabTitle,
      _ => null,
    };
    if (named == null) continue;
    final entries = [
      for (final r in reported[named] ?? const <ClientSlotOccupant>[])
        if (r.package == o.package) r,
    ];
    // The entry under the same id, else the package's only one.
    final same = entries.where((r) => r.cell == o.cell).toList();
    for (final r in same.isNotEmpty ? same : (entries.length == 1 ? entries : const <ClientSlotOccupant>[])) {
      r.label?.all.forEach(add);
    }
  }
  return [...names];
}
