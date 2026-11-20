// `pet` (plugin-seams.md §4.2): a `shell.overlay` pet drawn by the app's own
// pet layer instead of an overlay island. Skeleton: no pet protocol is wired
// to the native layer yet, so the adapter never matches.

import 'package:flutter/widgets.dart';

import '../seat_models.dart';
import '../seat_planner.dart';
import '../slot_catalog.dart';

class PetAdapter implements NativeSlotAdapter {
  const PetAdapter();

  /// Pet manifests the native layer can draw (`codex`, `linxin` later).
  static const protocols = <String>{};

  @override
  String get id => 'pet';

  @override
  Set<String> get slots => const {Slots.shellOverlay};

  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => protocols.contains(info.pet);

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.full;

  /// Later: hand the package's pack to the pet stage (`app/lib/ui/pets/`).
  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) => const SizedBox.shrink();
}
