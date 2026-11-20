// `cordis` (plugin-seams.md §4.2): the list part of `tool.view.cordis` drawn
// with the native Cordis rows; the plugin's interactive region stays an
// island ([NativeCoverage.partial]).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show CordisPlugin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/cordis_state.dart';
import '../../../ui/common/list_page_row.dart';
import '../../../ui/cordis/cordis_page.dart' show CordisPluginRow;
import '../../../ui/cordis/cordis_plugin_sheet.dart';
import '../seat_models.dart';
import '../seat_planner.dart';
import '../slot_catalog.dart';

class CordisAdapter implements NativeSlotAdapter {
  const CordisAdapter();

  @override
  String get id => 'cordis';

  @override
  Set<String> get slots => const {Slots.cordisView};

  /// Always: the host's dynamic plugins are read natively.
  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => true;

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.partial;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) =>
      CordisSeat(occupant: o, placement: seat.placement);

  /// [plugin] is the one behind [o] (its plugin or one of its packages).
  static bool matches(CordisPlugin plugin, SlotOccupant o) =>
      plugin.pluginId == o.cell ||
      plugin.pluginId == o.package ||
      plugin.packages.any((p) => p.packageId == o.cell || p.packageId == o.package);
}

/// The Cordis rows of one occupant; nothing until the inventory names it.
class CordisSeat extends ConsumerWidget {
  const CordisSeat({super.key, required this.occupant, required this.placement});

  final SlotOccupant occupant;
  final SeatPlacement placement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(cordisInventoryProvider).value ?? const <CordisPlugin>[];
    final rows = [
      for (final plugin in plugins)
        if (CordisAdapter.matches(plugin, occupant))
          CordisPluginRow(plugin: plugin, onTap: () => unawaited(showCordisPluginSheet(context, plugin))),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    if (placement == SeatPlacement.row) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    }
    return ListPageCard(margin: EdgeInsets.zero, children: rows);
  }
}
